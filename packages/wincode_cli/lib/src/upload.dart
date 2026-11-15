import 'dart:convert';
import 'dart:io';

import 'package:wincode_asc/wincode_asc.dart';
import 'package:wincode_core/wincode_core.dart';

import 'config.dart';
import 'credentials.dart';
import 'failure.dart';
import 'init.dart' show ReadLine;
import 'preflight.dart';
import 'redact.dart';
import 'sign.dart';

/// What `wincode upload` sends, read from the signed IPA.
class UploadPlan {
  const UploadPlan({
    required this.bundleId,
    required this.version,
    required this.build,
    required this.fileName,
    required this.size,
    required this.md5,
    required this.sha256,
  });

  final String bundleId;
  final String version;
  final String build;
  final String fileName;
  final int size;

  /// The checksum that App Store Connect checks the upload against.
  final String md5;
  final String sha256;

  Map<String, Object?> toJson() => {
    'version': version,
    'build': build,
    'file': fileName,
    'size': size,
    'md5': md5,
    'sha256': sha256,
  };
}

/// What [Uploader.upload] did: every finding, in order, and the object that `--json` adds to them.
typedef UploadResult = ({List<Finding> findings, Map<String, Object?> json});

/// `wincode upload` for one app (ADR-0013 phase 4): the checks of preflight in strict mode and of the signature, then
/// the Build Uploads API as the spike's `asc_upload.py` drives it, and the wait for Apple's processing result.
///
/// - Every check runs before the first write. One that fails stops the run with nothing uploaded.
/// - Writes are never repeated. The parts of the file and the reads that wait for the result are: a part sent twice
///   lands in the same place, and a read changes nothing.
/// - What is printed passes through the [redactor]. The links and headers of the parts, which are signed, are
///   registered with it as secrets, and are never printed by this code.
class Uploader {
  Uploader({
    required this.config,
    required this.environment,
    required this.redactor,
    required this.clock,
    required this.connect,
    required this.run,
    required this.report,
    this.readLine,
    this.timeout = defaultUploadTimeout,
    this.pollInterval = const Duration(seconds: 30),
    this.log,
  });

  final WincodeConfig config;
  final Map<String, String> environment;
  final Redactor redactor;
  final DateTime Function() clock;
  final AscConnect connect;
  final RunProcess run;

  /// Where the checks, the plan and each step are written.
  final StringSink report;

  /// Reads the answer to the confirmation. Needed unless the run has `--yes`.
  final ReadLine? readLine;

  /// How long to wait for Apple's processing result after the commit, and how often to ask.
  final Duration timeout;
  final Duration pollInterval;

  /// Gets each HTTP request with `--verbose`.
  final void Function(String line)? log;

  /// How many reads of the state in a row may fail before the wait gives up. Each read has its own retries.
  static const _pollFailures = 3;

  String get _bundleId => config.bundleId;

  /// What the person types to confirm: the app's name, or for a file without names its bundle ID.
  String get _confirmation => config.name ?? config.bundleId;

  /// Checks and uploads [ipa], or with [dryRun] checks what needs no network and prints the plan and the requests.
  /// With [yes], nothing is asked.
  Future<UploadResult> upload(
    File ipa, {
    required bool dryRun,
    required bool yes,
  }) async {
    redactor.hide(ipa.path, '<signed IPA>');
    return dryRun ? _dryRun(ipa) : _upload(ipa, yes: yes);
  }

  Preflight _preflight(File ipa) => Preflight(
    config: config,
    ipa: ipa,
    environment: environment,
    redactor: redactor,
    clock: clock,
    connect: connect,
    log: log,
    run: run,
    strict: true,
  );

  Signer _signer() => Signer(
    config: config,
    environment: environment,
    redactor: redactor,
    clock: clock,
    connect: connect,
    run: run,
    log: log,
  );

  static bool _failed(List<Finding> findings) =>
      findings.any((f) => f.status == 'FAIL');

  /// The end of a run that a check stopped: the report, with the line that says that nothing was uploaded.
  UploadResult _stopped(List<Finding> findings) {
    findings.add(
      const Finding.info(
        'upload',
        'nothing was uploaded: a check above failed',
      ),
    );
    writeReport(findings, report, command: 'upload');
    return (findings: findings, json: const {});
  }

  // Without a network.

  Future<UploadResult> _dryRun(File ipa) async {
    final dry = await _preflight(ipa).dryRun();
    final findings = <Finding>[...dry.failures];
    if (!_failed(findings)) {
      // Another Preflight: the first one has an empty answer of App Store Connect to compare the profiles with.
      final local = _preflight(ipa);
      findings
        ..add(local.profileCheck())
        ..addAll(local.localChecks());
    }
    if (!_failed(findings)) {
      findings.addAll(
        await _signer().verify(
          ipa,
          offline: false,
          dryRun: true,
          withPreflight: false,
        ),
      );
    }
    if (_failed(findings)) {
      return _stopped(findings);
    }
    final UploadPlan plan;
    try {
      plan = await _plan(ipa);
    } on _Unreadable catch (e) {
      findings.add(Finding.fail('ipa', e.problem));
      return _stopped(findings);
    }
    writeFindings(findings, report);
    _printPlan(plan, dry: true);
    final requests = _requests(plan, authorization: dry.authorization);
    requests.forEach(report.writeln);
    findings.add(
      const Finding.info('upload', 'dry run: nothing was sent or uploaded'),
    );
    writeFindings([findings.last], report);
    writeSummary(findings, report, command: 'upload');
    return (
      findings: findings,
      json: {'dryRun': true, 'plan': plan.toJson(), 'requests': requests},
    );
  }

  /// The requests of a real run, as `asc_upload.py --dry-run` prints them: what only Apple's answers give is a
  /// placeholder, and the token is never shown.
  List<String> _requests(UploadPlan plan, {required String authorization}) {
    const api = 'https://api.appstoreconnect.apple.com';
    final upload = _createUploadBody(plan, '{id of the app record}');
    final file = _createFileBody(plan, '{id of the build upload}');
    final commit = _commitBody(plan, '{id of the upload file}');
    return [
      'GET $api/v1/apps?filter[bundleId]=${plan.bundleId}&fields[apps]=bundleId&limit=200',
      '    Authorization: Bearer <$authorization>',
      'POST $api/v1/buildUploads',
      '    ${_pyJson(upload)}',
      'POST $api/v1/buildUploadFiles',
      '    ${_pyJson(file)}',
      '<each uploadOperations entry of the answer>: its method and URL, its byte range of the ${plan.size}-byte IPA '
          'and its requestHeaders; no token',
      'PATCH $api/v1/buildUploadFiles/{id of the upload file}',
      '    ${_pyJson(commit)}',
      'GET $api/v1/buildUploads/{id of the build upload}?$_pollQuery',
      '    every ${pollInterval.inSeconds} s, for up to ${_minutes(timeout)} after the commit',
      'Authorization on every API request: Bearer <$authorization>',
    ];
  }

  static const _pollParameters = {
    'include': 'build,assetFile',
    'fields[builds]': 'processingState',
    'fields[buildUploadFiles]': 'assetDeliveryState',
  };

  static final _pollQuery = [
    for (final MapEntry(:key, :value) in _pollParameters.entries) '$key=$value',
  ].join('&');

  // The upload.

  Future<UploadResult> _upload(File ipa, {required bool yes}) async {
    final findings = <Finding>[];
    findings.addAll(await _preflight(ipa).check());
    if (_failed(findings)) {
      return _stopped(findings);
    }
    findings.addAll(
      await _signer().verify(
        ipa,
        offline: false,
        dryRun: false,
        withPreflight: false,
      ),
    );
    if (_failed(findings)) {
      return _stopped(findings);
    }
    final UploadPlan plan;
    try {
      plan = await _plan(ipa);
    } on _Unreadable catch (e) {
      findings.add(Finding.fail('ipa', e.problem));
      return _stopped(findings);
    }
    writeFindings(findings, report);
    _printPlan(plan, dry: false);
    if (!yes) {
      report.write(
        'To upload this build, type the name of the app ($_confirmation): ',
      );
      final answer = readLine?.call()?.trim();
      report.writeln();
      if (answer != _confirmation) {
        findings.add(
          Finding.fail(
            'upload',
            const WincodeException(
              ExitCode.failed,
              'upload-cancelled',
              'the upload was not confirmed: what you typed is not the name of the app',
              why: 'an upload cannot be taken back: the build number is used from the moment Apple has the file.',
              next: 'run the command again and type the name as it is above, or give --yes. Nothing was uploaded.',
            ),
          ),
        );
        writeFindings([findings.last], report);
        writeSummary(findings, report, command: 'upload');
        return (findings: findings, json: {'plan': plan.toJson()});
      }
    }
    return _send(ipa, plan, findings);
  }

  Future<UploadResult> _send(
    File ipa,
    UploadPlan plan,
    List<Finding> findings,
  ) async {
    var created = false;
    var keySource = 'WINCODE_ASC_KEY_DIR';
    final json = <String, Object?>{'plan': plan.toJson()};
    try {
      final files = (await locateAscKeyFiles(
        config,
        environment: environment,
        redactor: redactor,
        run: run,
      ))!;
      keySource = files.source;
      final key = loadAscKey(files, redactor);
      final client = connect(() => ascToken(key, clock, redactor), log);

      // 1. The app record.
      final apps = await client.getAll('/v1/apps', {
        'filter[bundleId]': _bundleId,
        'fields[apps]': 'bundleId',
        'limit': '200',
      });
      final appId = apps
          .where((a) => _attribute(a, 'bundleId') == _bundleId)
          .map((a) => '${a['id']}')
          .firstOrNull;
      if (appId == null) {
        throw WincodeException(
          ExitCode.failed,
          'app-record-missing',
          'App Store Connect has no app record for $_bundleId',
          why: 'an upload goes to the app record of its bundle ID.',
          next:
              'create the app record in App Store Connect (Apps, New App), or correct bundle_id in wincode.yaml. '
              'Nothing was uploaded.',
        );
      }
      redactor.hide(appId, '<app record ID>');
      _say('app record found');

      // 2. The build upload. From here on, the build number may be used.
      final upload = _dataOf(
        await client.write(
          'POST',
          '/v1/buildUploads',
          _createUploadBody(plan, appId),
        ),
        'POST /v1/buildUploads',
        'The last request may have made a build upload: look at the builds of the app in App Store Connect before '
            'uploading again.',
      );
      created = true;
      final uploadId = '${upload['id']}';
      redactor.hide(uploadId, '<build upload ID>');
      json['buildUploadId'] = uploadId;
      _say(
        'build upload created: version ${plan.version}, build ${plan.build}',
      );

      // 3. The file, and what Apple wants sent.
      final reserved = _dataOf(
        await client.write(
          'POST',
          '/v1/buildUploadFiles',
          _createFileBody(plan, uploadId),
        ),
        'POST /v1/buildUploadFiles',
        _builtNumber(plan),
      );
      final fileId = '${reserved['id']}';
      redactor.hide(fileId, '<upload file ID>');
      final List<AscUploadPart> parts;
      try {
        parts = uploadPartsOf(reserved);
      } on AscException catch (e) {
        throw WincodeException(
          ExitCode.failed,
          'upload-answer-invalid',
          "App Store Connect's answer to the file reservation is not one that wincode upload can use: ${e.message}",
          why: 'upload follows the answer of the Build Uploads API, and cannot guess a part.',
          next:
              'run the command again with --verbose --redact; if the answer comes again, report it with that output at '
              'https://github.com/wincode-org/wincode/issues. ${_builtNumber(plan)}',
        );
      }
      _say('file reserved: ${parts.length} part(s) to send');
      if (parts.isEmpty || parts.any((p) => p.offset + p.length > plan.size)) {
        throw WincodeException(
          ExitCode.failed,
          'upload-answer-invalid',
          parts.isEmpty
              ? "App Store Connect's answer gives no upload operations"
              : "App Store Connect's answer asks for bytes that the IPA does not have",
          why: 'upload sends the parts that Apple names, and has none, or one beyond the file, to send.',
          next:
              'run the command again with --verbose --redact; if the answer comes again, report it with that output at '
              'https://github.com/wincode-org/wincode/issues. ${_builtNumber(plan)}',
        );
      }
      // The links and the headers are signed and temporary: a secret from here on, wherever it could be printed.
      for (final part in parts) {
        redactor.secret(part.url.toString(), '<upload URL>');
        if (part.url.hasQuery && part.url.query.length > 8) {
          redactor.secret(part.url.query, '<upload URL>');
        }
        for (final value in part.headers.values) {
          if (value.length >= 8 && !_mediaType.hasMatch(value)) {
            redactor.secret(value, '<upload header>');
          }
        }
      }

      // 4. The parts.
      final reader = await ipa.open();
      try {
        for (final part in parts) {
          await reader.setPosition(part.offset);
          final bytes = await reader.read(part.length);
          if (bytes.length != part.length) {
            throw WincodeException(
              ExitCode.failed,
              'ipa-changed',
              '${ipa.uri.pathSegments.last} is shorter than it was when the upload was planned',
              why: 'the file was changed while it was being uploaded.',
              next:
                  'do not touch the IPA during an upload. ${_builtNumber(plan)}',
            );
          }
          await client.sendPart(part, bytes);
          _say('part ${part.number} sent: ${bytes.length} bytes');
        }
      } finally {
        await reader.close();
      }

      // 5. The commit.
      final committed = _dataOf(
        await client.write(
          'PATCH',
          '/v1/buildUploadFiles/$fileId',
          _commitBody(plan, fileId),
        ),
        'PATCH /v1/buildUploadFiles',
        _builtNumber(plan),
      );
      final delivery = switch (committed['attributes']) {
        {'assetDeliveryState': final Object? state} => state,
        _ => null,
      };
      _say('commit accepted; file: ${_pyJson(delivery, ascii: false)}');

      // 6. Apple's processing result.
      final end = await _wait(client, uploadId, plan, json);
      findings.add(end);
    } on AscException catch (e) {
      findings.add(
        Finding.fail(
          'upload',
          _problem(e, keySource: keySource, created: created, plan: plan),
        ),
      );
    } on WincodeException catch (e) {
      findings.add(Finding.fail('upload', e));
    } on FileSystemException catch (e) {
      findings.add(
        Finding.fail(
          'upload',
          WincodeException(
            ExitCode.failed,
            'ipa-unreadable',
            '${plan.fileName} cannot be read: ${e.osError?.message ?? e.message}',
            why: 'upload reads the IPA part by part while it sends it.',
            next:
                'check the file and its permissions, and do not touch it during an upload.${created ? ' ${_builtNumber(plan)}' : ' Nothing was uploaded.'}',
          ),
        ),
      );
    }
    writeFindings([findings.last], report);
    writeSummary(findings, report, command: 'upload');
    return (findings: findings, json: json);
  }

  /// Asks for the state of the upload every [pollInterval] until Apple gives a result or [timeout] has passed since the
  /// commit. Returns the finding that says the build is valid; anything else throws.
  Future<Finding> _wait(
    AscClient client,
    String uploadId,
    UploadPlan plan,
    Map<String, Object?> json,
  ) async {
    final watch = Stopwatch()..start();
    (Object?, Object?, Object?)? seen;
    final said = <String>{};
    var failures = 0;
    final label = 'version ${plan.version} (build ${plan.build})';
    for (;;) {
      final Map<String, Object?> answer;
      try {
        answer = await client.getDocument(
          '/v1/buildUploads/$uploadId',
          _pollParameters,
        );
        failures = 0;
      } on AscException catch (e) {
        // A read that fails after its own retries may be a hiccup: ask again a few times, then give up.
        final again =
            (e.failure == AscFailure.offline ||
                e.failure == AscFailure.unavailable) &&
            ++failures < _pollFailures &&
            watch.elapsed + pollInterval <= timeout;
        if (!again) {
          rethrow;
        }
        _say(
          'could not read the state (${e.message}); asking again in ${pollInterval.inSeconds} s',
        );
        await Future<void>.delayed(pollInterval);
        continue;
      }
      final status = _map(_map(answer['data'])['attributes'])['state'];
      final statusMap = status is Map<String, Object?> ? status : const {};
      final included = {
        for (final i in answer['included'] as List<Object?>? ?? const [])
          if (i is Map<String, Object?>) '${i['type']}': _map(i['attributes']),
      };
      final deliveryState = included['buildUploadFiles']?['assetDeliveryState'];
      final delivery = deliveryState is Map<String, Object?>
          ? deliveryState
          : const <String, Object?>{};
      final state = statusMap['state'];
      final fileState = delivery['state'];
      final build = included['builds']?['processingState'];
      if (seen != (state, fileState, build)) {
        seen = (state, fileState, build);
        json['state'] = {'upload': state, 'file': fileState, 'build': build};
        _say(
          'upload $state, file $fileState, build ${build ?? 'not created yet'}',
        );
      }
      for (final (source, details) in [
        ('upload', statusMap),
        ('file', delivery),
      ]) {
        for (final kind in ['errors', 'warnings', 'infos']) {
          for (final detail in details[kind] as List<Object?>? ?? const []) {
            final line =
                '$source ${kind.substring(0, kind.length - 1)}: ${_pyJson(detail, ascii: false)}';
            if (said.add(line)) {
              _say(line);
            }
          }
        }
      }
      if (state == 'FAILED' ||
          fileState == 'FAILED' ||
          build == 'FAILED' ||
          build == 'INVALID') {
        throw WincodeException(
          ExitCode.rejected,
          'processing-failed',
          'App Store Connect failed the processing of $label: upload $state, file $fileState, build ${build ?? 'not created yet'}',
          why: "Apple's messages above say why. A build number stays used even when its processing fails.",
          next:
              'fix what they name, raise the build number above ${plan.build} (version: x.y.z+N in pubspec.yaml), '
              'then build, sign and upload again.',
        );
      }
      if (build == 'VALID') {
        return Finding.pass(
          'upload',
          'App Store Connect processed $label as valid',
        );
      }
      if (watch.elapsed + pollInterval > timeout) {
        throw WincodeException(
          ExitCode.pending,
          'processing-timeout',
          'App Store Connect had not finished processing $label after ${_minutes(timeout)}; stopped waiting',
          why:
              'the upload was accepted, and Apple processes a build in its own time, which is usually minutes and '
              'sometimes longer.',
          next:
              'look at the build in App Store Connect (TestFlight) later, and do not upload build ${plan.build} '
              'again: it is used. A longer --timeout waits longer next time.',
        );
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  // The plan.

  Future<UploadPlan> _plan(File ipa) async {
    ZipArchive? zip;
    try {
      zip = ZipArchive.open(ipa);
      final plists = [
        for (final n in zip.names)
          if (_infoPlist.hasMatch(n)) n,
      ];
      if (plists.length != 1) {
        throw const FormatException('it holds no single Payload/<name>.app');
      }
      final info = parsePlistBytes(zip.read(plists.single));
      String text(String key) => switch (info) {
        final PlistMap m when m[key] is String => m[key]! as String,
        _ => throw FormatException('its Info.plist has no $key'),
      };
      final digests = await digestsOfFile(ipa);
      return UploadPlan(
        bundleId: text('CFBundleIdentifier'),
        version: text('CFBundleShortVersionString'),
        build: text('CFBundleVersion'),
        fileName: ipa.uri.pathSegments.last,
        size: ipa.lengthSync(),
        md5: digests.md5,
        sha256: digests.sha256,
      );
    } on FormatException catch (e) {
      throw _Unreadable(
        WincodeException(
          ExitCode.failed,
          'ipa-unreadable',
          '${ipa.uri.pathSegments.last} cannot be read as an IPA: ${e.message}',
          why: 'upload sends the IPA and the version and build number that its Info.plist names.',
          next: 'sign the IPA again with wincode sign.',
        ),
      );
    } on FileSystemException catch (e) {
      throw _Unreadable(
        WincodeException(
          ExitCode.failed,
          'ipa-unreadable',
          '${ipa.uri.pathSegments.last} cannot be read: ${e.osError?.message ?? e.message}',
          why: 'upload reads the IPA to send it.',
          next: 'check the file and its permissions.',
        ),
      );
    } finally {
      zip?.close();
    }
  }

  void _printPlan(UploadPlan plan, {required bool dry}) {
    report
      ..writeln()
      ..writeln(dry ? 'Upload plan (nothing is sent):' : 'Upload plan:')
      ..writeln('  app:      $_confirmation')
      ..writeln('  version:  ${plan.version}, build ${plan.build}')
      ..writeln('  file:     ${plan.fileName}, ${plan.size} bytes')
      ..writeln('  MD5:      ${plan.md5}')
      ..writeln('  SHA-256:  ${plan.sha256}');
    if (!dry) {
      report.writeln();
    }
  }

  // The bodies of the requests: the spike's, which follow App Store Connect API 4.5.1.

  Map<String, Object?> _createUploadBody(UploadPlan plan, String appId) => {
    'data': {
      'type': 'buildUploads',
      'attributes': {
        'cfBundleShortVersionString': plan.version,
        'cfBundleVersion': plan.build,
        'platform': 'IOS',
      },
      'relationships': {
        'app': {
          'data': {'type': 'apps', 'id': appId},
        },
      },
    },
  };

  Map<String, Object?> _createFileBody(UploadPlan plan, String uploadId) => {
    'data': {
      'type': 'buildUploadFiles',
      'attributes': {
        'assetType': 'ASSET',
        'fileName': plan.fileName,
        'fileSize': plan.size,
        'uti': 'com.apple.ipa',
      },
      'relationships': {
        'buildUpload': {
          'data': {'type': 'buildUploads', 'id': uploadId},
        },
      },
    },
  };

  // The checksum is a hex MD5, as the spike sends it, which App Store Connect accepted for a real upload.
  Map<String, Object?> _commitBody(UploadPlan plan, String fileId) => {
    'data': {
      'type': 'buildUploadFiles',
      'id': fileId,
      'attributes': {
        'uploaded': true,
        'sourceFileChecksums': {
          'file': {'hash': plan.md5, 'algorithm': 'MD5'},
        },
      },
    },
  };

  // Failures.

  /// The sentence that says where the build number stands, for the end of a next step.
  static String _builtNumber(UploadPlan plan) =>
      'The build upload exists, and build ${plan.build} now counts as used. To send this build again, raise the build '
      'number, then build and sign again.';

  WincodeException _problem(
    AscException e, {
    required String keySource,
    required bool created,
    required UploadPlan plan,
  }) {
    final said = [
      for (final error in e.errors)
        [error['code'], error['detail'] ?? error['title']].nonNulls.join(': '),
    ].join('; ');
    final answer = said.isEmpty ? e.message : '${e.message} $said';
    final isPart = e.request.startsWith('PUT part');
    final isWrite =
        e.request.startsWith('POST') || e.request.startsWith('PATCH');
    // A write that got no answer, or a 5xx, may have been done.
    final unsure =
        isWrite &&
        (e.failure == AscFailure.offline ||
            e.failure == AscFailure.unavailable);
    final tail = created
        ? '${_builtNumber(plan)}${unsure ? ' The last request may or may not have reached Apple.' : ''}'
        : unsure
        ? 'The last request may or may not have reached Apple: look at the builds of the app in App Store Connect '
              'before uploading again.'
        : 'Nothing was uploaded.';
    return switch (e.failure) {
      AscFailure.unauthorized || AscFailure.forbidden => () {
        final p = ascProblem(e, keySource: keySource, command: 'upload');
        return WincodeException(
          p.exitCode,
          p.id,
          p.what,
          why: p.why,
          next: '${p.next} $tail',
        );
      }(),
      AscFailure.offline => WincodeException(
        ExitCode.unavailable,
        'offline',
        isPart
            ? 'cannot reach the upload store for ${e.request}: ${e.message}'
            : 'cannot reach api.appstoreconnect.apple.com: ${e.message}',
        why: "there is no network, a proxy or a firewall is in the way, or Apple's service is down.",
        next:
            "check the connection (and HTTPS_PROXY, if you use one) and Apple's system status page"
            '${created || unsure ? '.' : ', then run the command again.'} $tail',
      ),
      AscFailure.unavailable => WincodeException(
        ExitCode.unavailable,
        isPart ? 'upload-part-unavailable' : 'asc-unavailable',
        isPart
            ? "Apple's upload store kept answering ${e.request} with $answer"
            : 'App Store Connect answered ${e.request} with $answer',
        why: "Apple's service is down or overloaded.",
        next:
            "check Apple's system status page${created || unsure ? '.' : ', then run the command again.'} $tail",
      ),
      AscFailure.refused when isPart => WincodeException(
        ExitCode.failed,
        'upload-part-refused',
        "Apple's upload store refused ${e.request}: $answer",
        why: 'the link of a part is signed and expires, and the store refuses bytes that are not the part it expects.',
        next:
            'raise the build number, then build, sign and upload again. $tail',
      ),
      AscFailure.refused when isWrite => WincodeException(
        ExitCode.failed,
        'upload-refused',
        'App Store Connect refused the upload: $answer',
        why:
            'version ${plan.version} build ${plan.build} may have been uploaded already, from this PC or elsewhere; a '
            "build number stays used even when its processing fails. Apple's message above says which.",
        next:
            'look at the builds of the app in App Store Connect (TestFlight). To send this build anyway, raise the '
            'build number, then build and sign again. $tail',
      ),
      AscFailure.refused => WincodeException(
        ExitCode.failed,
        'asc-error',
        "App Store Connect's answer to ${e.request} is not what upload expects: $answer",
        why: 'upload follows the Build Uploads API, so this answer is unexpected.',
        next:
            'run the command again with --verbose --redact; if the answer comes again, report it with that output at '
            'https://github.com/wincode-org/wincode/issues. $tail',
      ),
    };
  }

  // Printing.

  void _say(String message) => report.writeln('${_stamp(clock())}  $message');
}

/// The default wait for Apple's processing result.
const defaultUploadTimeout = Duration(minutes: 20);

/// [time] as `2026-11-11 18:58:48 UTC`, as the spike's script writes it.
String _stamp(DateTime time) =>
    '${time.toUtc().toIso8601String().substring(0, 19).replaceFirst('T', ' ')} UTC';

String _minutes(Duration d) => d.inSeconds % 60 == 0
    ? '${d.inMinutes} minute${d.inMinutes == 1 ? '' : 's'}'
    : '${d.inSeconds} second${d.inSeconds == 1 ? '' : 's'}';

/// An IPA that cannot be read for the plan.
class _Unreadable implements Exception {
  const _Unreadable(this.problem);

  final WincodeException problem;
}

final _infoPlist = RegExp(r'^Payload/[^/]+\.app/Info\.plist$');

/// A header value that is a media type, such as `application/octet-stream`: not a secret.
final _mediaType = RegExp(r'^[a-z]+/[a-z0-9.+-]+(;.*)?$', caseSensitive: false);

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? value : const {};

/// The `data` object of an answer to [request]. [tail] ends the next step: what is known of the upload.
Map<String, Object?> _dataOf(
  Map<String, Object?> answer,
  String request,
  String tail,
) {
  final data = answer['data'];
  if (data is Map<String, Object?> && data['id'] is String) {
    return data;
  }
  throw WincodeException(
    ExitCode.failed,
    'upload-answer-invalid',
    "App Store Connect's answer to $request holds no resource with an id",
    why: 'upload follows the answers of the Build Uploads API, and cannot go on without the id.',
    next:
        'run the command again with --verbose --redact; if the answer comes again, report it with that output at '
        'https://github.com/wincode-org/wincode/issues. $tail',
  );
}

String _attribute(AscResource resource, String name) =>
    switch (resource['attributes']) {
      final Map<String, Object?> attributes when attributes[name] is String =>
        attributes[name]! as String,
      _ => '',
    };

/// [value] as Python's `json.dumps` writes it, which is how the spike's script shows what it sends and what Apple said:
/// `", "` and `": "` as separators, and with [ascii] every character above 126 as `\uXXXX`.
String _pyJson(Object? value, {bool ascii = true}) {
  String string(String s) {
    final encoded = jsonEncode(s);
    return ascii
        ? encoded.replaceAllMapped(
            RegExp(r'[^\x00-\x7e]'),
            (m) =>
                '\\u${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}',
          )
        : encoded;
  }

  return switch (value) {
    null => 'null',
    final bool b => '$b',
    final num n => '$n',
    final String s => string(s),
    final List<Object?> l =>
      '[${l.map((v) => _pyJson(v, ascii: ascii)).join(', ')}]',
    final Map<Object?, Object?> m =>
      '{${m.entries.map((e) => '${string('${e.key}')}: ${_pyJson(e.value, ascii: ascii)}').join(', ')}}',
    _ => string('$value'),
  };
}
