import 'dart:convert';
import 'dart:io';

import 'package:wincode_core/wincode_core.dart';

import 'events.dart';
import 'failure.dart';
import 'github.dart';
import 'preflight.dart' show Finding;
import 'redact.dart';

/// The artifact that the workflow uploads, and the two files in it (ADR-0015, section 6).
const artifactName = 'unsigned-ipa';
const _ipaEntry = 'unsigned.ipa';
const _hashEntry = 'unsigned.ipa.sha256';

/// What the IPA of a build must say, as the build asked for it.
typedef IpaExpectation = ({String bundleId, String version, String number});

/// The IPA that passed every check: where it is now, and what it holds.
typedef IpaFacts = ({
  String path,
  int size,
  String sha256,
  String bundleId,
  String version,
  String build,
});

/// The artifact of a finished run, downloaded and checked (ADR-0015, section 6).
///
/// 1. The run has one artifact named `unsigned-ipa`, and it has not expired.
/// 2. It is downloaded into a folder `.wincode-build-<random>` of the output folder, which is deleted at the end whatever
///    happens.
/// 3. The zip's SHA-256 is the `digest` that GitHub reports, when it reports one.
/// 4. The zip holds `unsigned.ipa` and `unsigned.ipa.sha256` and nothing else, and the IPA's SHA-256 is the recorded one.
/// 5. The IPA holds one app, with the bundle ID, the version and the build number that were asked for, and no profile.
/// 6. The IPA replaces `unsigned.ipa` in the output folder, and only now: a check that failed leaves the old file alone.
///
/// Each check adds its finding. A check that fails throws a [WincodeException]; a failed request throws a
/// [GithubException], which the caller turns into a message.
class ArtifactFetcher {
  ArtifactFetcher({
    required this.client,
    required this.repository,
    required this.runId,
    required this.runUrl,
    required this.conclusion,
    required this.collect,
    required this.expect,
    required this.output,
    required this.redactor,
    required this.findings,
    this.deleteAfter = false,
    this.events,
    this.say,
    this.stop,
  });

  final GithubClient client;
  final String repository;
  final int runId;
  final String runUrl;

  /// How the run ended, for the message when it has no artifact.
  final String conclusion;

  /// The command that downloads this run again, such as `wincode build --app alpha --run 7`.
  final String collect;
  final IpaExpectation expect;

  /// The app's output folder.
  final Directory output;
  final Redactor redactor;
  final List<Finding> findings;

  /// Delete the artifact once the IPA is in place: the repository is public, and `--allow-public` was given.
  final bool deleteAfter;
  final EventWriter? events;
  final void Function(String line)? say;

  /// Completes when the person interrupts: the download stops.
  final Future<void>? stop;

  String get _sep => Platform.pathSeparator;

  File get _target => File('${output.path}$_sep$_ipaEntry');

  WincodeException _problem(
    String id,
    String what, {
    required String why,
    required String next,
  }) => WincodeException(ExitCode.failed, id, what, why: why, next: next);

  /// Downloads the artifact of the run, checks it, and puts its IPA in the output folder.
  Future<IpaFacts> fetch() async {
    redactor.hide(_target.path, '<unsigned IPA>');
    final artifact = await _artifact();
    final id = artifact['id'];
    final Directory work;
    try {
      output.createSync(recursive: true);
      work = output.createTempSync('.wincode-build-');
    } on FileSystemException catch (e) {
      throw _unwritable(e);
    }
    try {
      final zip = File('${work.path}${_sep}artifact.zip');
      final size = await _download(id, zip, artifact);
      events?.emit('artifact', {
        'name': artifactName,
        'size': size,
        'digest': artifact['digest'],
        'expiresAt': artifact['expires_at'],
      });
      await _transfer(zip, artifact);
      final ipa = File('${work.path}$_sep$_ipaEntry');
      final sha256 = await _content(zip, ipa);
      final identity = _inspect(ipa);
      final ipaSize = ipa.lengthSync();
      _move(ipa);
      final done = (
        path: _target.path,
        size: ipaSize,
        sha256: sha256,
        bundleId: identity.bundleId,
        version: identity.version,
        build: identity.build,
      );
      findings.add(
        Finding.pass(
          'ipa',
          '$_ipaEntry holds ${done.bundleId} ${done.version} (build ${done.build}) in Payload/, without a profile: '
              '${done.size} bytes, SHA-256 ${done.sha256}',
        ),
      );
      events?.emit('ipa', {
        'path': done.path,
        'size': done.size,
        'sha256': done.sha256,
        'bundleId': done.bundleId,
        'version': done.version,
        'build': done.build,
      });
      if (deleteAfter) {
        await _delete(id);
      }
      return done;
    } finally {
      try {
        work.deleteSync(recursive: true);
      } on FileSystemException {
        // A folder that cannot be deleted is left; it holds nothing the next build needs.
      }
    }
  }

  // 1. The artifact.

  Future<Map<String, Object?>> _artifact() async {
    final answer = await client.getJson(
      '/repos/$repository/actions/runs/$runId/artifacts',
      const {'per_page': '100'},
    );
    final list = answer['artifacts'];
    final named = [
      if (list is List<Object?>)
        for (final a in list)
          if (a is Map<String, Object?> && a['name'] == artifactName) a,
    ];
    if (named.length > 1) {
      throw _problem(
        'artifact-content',
        'run $runUrl has ${named.length} artifacts named $artifactName',
        why: 'winCode takes the one artifact of that name, and cannot tell which of several is the IPA of this build.',
        next:
            'compare the workflow with the reference one that wincode init writes, which uploads one artifact, then run '
            'wincode build again.',
      );
    }
    final found = named.firstOrNull;
    if (found == null || found['id'] is! int) {
      throw _problem(
        'artifact-missing',
        'run $runUrl ended ($conclusion) without an artifact named $artifactName',
        why:
            'the workflow failed before its upload step, uploaded the IPA under another name, or the artifact has '
            'expired.',
        next:
            "read the run's log at $runUrl, compare the workflow with the reference one that wincode init writes, then "
            'run wincode build again.',
      );
    }
    if (found['expired'] == true) {
      throw _problem(
        'artifact-missing',
        'the artifact $artifactName of run $runUrl expired${found['expires_at'] is String ? ' at ${found['expires_at']}' : ''}',
        why:
            'GitHub deletes an artifact when its retention ends, which is 1 day in the reference workflow, and the '
            'IPA is not kept anywhere else.',
        next: 'run wincode build again to build it afresh; with auto, the build number is above the one of this run.',
      );
    }
    findings.add(
      Finding.pass(
        'artifact',
        'run $runId has one artifact named $artifactName${found['size_in_bytes'] is int ? ', ${found['size_in_bytes']} bytes' : ''}${found['expires_at'] is String ? ', kept until ${found['expires_at']}' : ''}',
      ),
    );
    return found;
  }

  // 2. The download.

  Future<int> _download(
    Object? id,
    File zip,
    Map<String, Object?> artifact,
  ) async {
    say?.call(
      'downloading the artifact${artifact['size_in_bytes'] is int ? ' (${artifact['size_in_bytes']} bytes)' : ''}',
    );
    try {
      return await client.download(
        '/repos/$repository/actions/artifacts/$id/zip',
        zip,
        hide: (link) => redactor.secret(link, '<download link>'),
        stop: stop,
      );
    } on FileSystemException catch (e) {
      throw _unwritable(e);
    }
  }

  WincodeException _unwritable(FileSystemException e) => WincodeException(
    ExitCode.failed,
    'output-unwritable',
    'cannot write in ${output.path}: ${e.osError?.message ?? e.message}',
    why: 'wincode build downloads the artifact into the output folder of the app and puts unsigned.ipa there.',
    next:
        'check that the folder can be written (output in wincode.yaml), then collect the run again with $collect.',
  );

  // 3. The transfer.

  Future<void> _transfer(File zip, Map<String, Object?> artifact) async {
    final digest = artifact['digest'];
    final expected = digest is String && digest.startsWith('sha256:')
        ? digest.substring('sha256:'.length).toLowerCase()
        : null;
    if (expected == null) {
      findings.add(
        const Finding.info(
          'artifact-digest',
          'GitHub reports no SHA-256 digest for the artifact, so the transfer was not compared with one',
        ),
      );
      return;
    }
    final actual = (await digestsOfFile(zip)).sha256;
    if (actual != expected) {
      throw _problem(
        'artifact-integrity',
        'the artifact that was downloaded does not match the SHA-256 that GitHub reports for it',
        why:
            "the zip changed between GitHub's storage and this disk, and winCode does not use bytes that it cannot trace "
            'to the run.',
        next:
            'download it again with $collect; if the digests still differ, build again.',
      );
    }
    findings.add(
      const Finding.pass(
        'artifact-digest',
        "the SHA-256 of the downloaded zip is the digest that GitHub reports (the transfer from GitHub's storage)",
      ),
    );
  }

  // 4. The content.

  /// Extracts the IPA of [zip] into [ipa], checks it against the hash the build job recorded, and returns its SHA-256.
  Future<String> _content(File zip, File ipa) async {
    final String recorded;
    ZipArchive? archive;
    try {
      archive = ZipArchive.open(zip);
      final names = archive.names.toSet();
      if (names.length != 2 ||
          !names.contains(_ipaEntry) ||
          !names.contains(_hashEntry)) {
        throw _problem(
          'artifact-content',
          'the artifact holds ${names.isEmpty ? 'nothing' : names.map((n) => '"$n"').join(', ')}, and not just $_ipaEntry and $_hashEntry',
          why:
              'the reference workflow uploads the IPA and the SHA-256 that the build job computed for it, and winCode '
              'checks one against the other.',
          next: 'compare the workflow with the reference one that wincode init writes, then run wincode build again.',
        );
      }
      if (archive.sizeOf(_hashEntry) > 1024) {
        throw _problem(
          'artifact-content',
          '$_hashEntry is ${archive.sizeOf(_hashEntry)} bytes, and a SHA-256 line is far shorter',
          why: 'it is written by shasum -a 256 in the build job.',
          next: 'compare the workflow with the reference one that wincode init writes, then run wincode build again.',
        );
      }
      final line = utf8.decode(archive.read(_hashEntry), allowMalformed: true);
      final match = RegExp(r'^\s*([0-9a-fA-F]{64})(\s|$)').firstMatch(line);
      if (match == null) {
        throw _problem(
          'artifact-content',
          '$_hashEntry does not start with a SHA-256',
          why: 'it is written by shasum -a 256 in the build job: 64 hexadecimal digits, then the file name.',
          next: 'compare the workflow with the reference one that wincode init writes, then run wincode build again.',
        );
      }
      recorded = match[1]!.toLowerCase();
      archive.extractTo(_ipaEntry, ipa);
    } on FormatException catch (e) {
      throw _problem(
        'artifact-content',
        'the artifact cannot be read as a zip archive: ${e.message}',
        why: 'GitHub gives an artifact as a zip archive, and winCode opens it to take the IPA out.',
        next:
            'download it again with $collect; if it fails again, build again.',
      );
    } on FileSystemException catch (e) {
      throw _unwritable(e);
    } finally {
      archive?.close();
    }
    findings.add(
      const Finding.pass(
        'artifact-content',
        'the artifact holds $_ipaEntry and $_hashEntry, and nothing else',
      ),
    );
    final actual = (await digestsOfFile(ipa)).sha256;
    if (actual != recorded) {
      throw _problem(
        'artifact-integrity',
        'the IPA in the artifact does not match the SHA-256 that the run recorded',
        why:
            'the file changed between the build job and this disk, and winCode does not sign an IPA it cannot trace to '
            'its run.',
        next:
            'download it again with $collect; if the hashes still differ, build again.',
      );
    }
    findings.add(
      const Finding.pass(
        'artifact-hash',
        'the IPA has the SHA-256 that the build job recorded (from the build job to this disk)',
      ),
    );
    return actual;
  }

  // 5. The IPA.

  /// The bundle ID, version and build number of the app in [ipa], after the checks that it is the IPA that was asked for.
  ({String bundleId, String version, String build}) _inspect(File ipa) {
    ZipArchive? zip;
    try {
      zip = ZipArchive.open(ipa);
      final apps = [
        for (final n in zip.names)
          if (RegExp(r'^Payload/[^/]+\.app/Info\.plist$').hasMatch(n))
            n.substring(0, n.length - 'Info.plist'.length),
      ];
      if (apps.length != 1) {
        throw _problem(
          'ipa-unreadable',
          '$_ipaEntry is not an IPA of one app: it holds ${apps.isEmpty ? 'no Payload/<name>.app with an Info.plist' : '${apps.length} apps in Payload/'}',
          why: 'an IPA is a zip archive that holds the app in Payload/<name>.app.',
          next:
              "read the run's log at $runUrl, and compare the workflow with the reference one that wincode init writes.",
        );
      }
      final app = apps.single;
      final info = parsePlistBytes(zip.read('${app}Info.plist'));
      String text(String key) => switch (info) {
        final PlistMap m when m[key] is String => m[key]! as String,
        _ => '',
      };
      final bundleId = text('CFBundleIdentifier');
      final version = text('CFBundleShortVersionString');
      final build = text('CFBundleVersion');
      if (bundleId != expect.bundleId) {
        if (bundleId.contains(RegExp('[A-Za-z0-9]'))) {
          redactor.hide(bundleId, '<other bundle ID>');
        }
        throw _problem(
          'bundle-id-mismatch',
          "the IPA's bundle ID is ${bundleId.isEmpty ? 'missing' : bundleId}, but wincode.yaml says ${expect.bundleId}",
          why:
              'winCode signs and uploads only the app that wincode.yaml names, so an IPA of another flavor or app '
              'cannot reach this app record.',
          next:
              "check the flavor and the configuration of the app against the run's log at $runUrl.",
        );
      }
      if (zip.names.contains('${app}embedded.mobileprovision')) {
        throw _problem(
          'ipa-signed',
          'the IPA holds embedded.mobileprovision, so it is signed',
          why:
              'the build runs with --no-codesign and holds no Apple secret; winCode signs the IPA itself afterwards, and '
              'does not take a signature it did not make.',
          next: 'compare the workflow with the reference one that wincode init writes, and remove any signing from it.',
        );
      }
      if (version != expect.version || build != expect.number) {
        throw _problem(
          'ipa-version-mismatch',
          'the IPA holds version ${version.isEmpty ? 'none' : version} (build ${build.isEmpty ? 'none' : build}), and the build asked for ${expect.version} (build ${expect.number})',
          why:
              'the workflow gives --build-name and --build-number to flutter build ipa, which writes them into '
              'Info.plist; upload reads the version and the number from the IPA, so one that differs would reach Apple '
              'under another number.',
          next:
              'check that the project takes CFBundleShortVersionString and CFBundleVersion from Flutter ('
              r'$(FLUTTER_BUILD_NAME) and $(FLUTTER_BUILD_NUMBER)'
              '), and compare the workflow with the reference one.',
        );
      }
      return (bundleId: bundleId, version: version, build: build);
    } on FormatException catch (e) {
      throw _problem(
        'ipa-unreadable',
        '$_ipaEntry cannot be read as an IPA: ${e.message}',
        why:
            'an IPA is a zip archive that holds the app in Payload/<name>.app.',
        next:
            "read the run's log at $runUrl, and compare the workflow with the reference one that wincode init writes.",
      );
    } finally {
      zip?.close();
    }
  }

  // 6. Move.

  void _move(File ipa) {
    try {
      ipa.renameSync(_target.path);
    } on FileSystemException catch (e) {
      throw _unwritable(e);
    }
  }

  // The public repository.

  Future<void> _delete(Object? id) async {
    try {
      await client.delete('/repos/$repository/actions/artifacts/$id');
      findings.add(
        const Finding.pass(
          'artifact-delete',
          'the artifact was deleted from the public repository: the IPA was downloadable only for the time of this build',
        ),
      );
    } on GithubException catch (e) {
      findings.add(
        Finding.warn(
          'artifact-delete',
          WincodeException(
            ExitCode.ok,
            'artifact-not-deleted',
            'the artifact could not be deleted from the public repository: ${e.message}',
            why:
                'anyone with a GitHub account can download it from the run until it expires, which is 1 day in the '
                'reference workflow.',
            next:
                'delete it on the run\'s page, $runUrl, if the IPA must not be public.',
          ),
        ),
      );
    }
  }
}
