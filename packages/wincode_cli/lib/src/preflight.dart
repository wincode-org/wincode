import 'dart:io';

import 'package:wincode_asc/wincode_asc.dart';
import 'package:wincode_core/wincode_core.dart';

import 'config.dart';
import 'failure.dart';
import 'key_location.dart';
import 'redact.dart';

/// Makes the client that `wincode preflight` reads App Store Connect with, from a maker of tokens and the `--verbose`
/// log. Tests connect to a fake server.
typedef AscConnect = AscClient Function(
  String Function() token,
  void Function(String line)? log,
);

/// The [AscConnect] of a real run: App Store Connect over HTTPS.
AscClient connectToApple(
  String Function() token,
  void Function(String line)? log,
) => HttpAscClient(token: token, log: log);

/// What one check of `wincode preflight` found. A failure or a warning carries its [problem]: the id, the exit code, why
/// and the next step.
class Finding {
  const Finding.pass(this.check, this.what) : status = 'PASS', problem = null;

  const Finding.info(this.check, this.what) : status = 'INFO', problem = null;

  Finding.fail(this.check, WincodeException this.problem)
    : status = 'FAIL',
      what = problem.what;

  /// A problem that does not fail the run, such as a profile that expires soon.
  Finding.warn(this.check, WincodeException this.problem)
    : status = 'WARN',
      what = problem.what;

  /// The stable name of the check, such as `build-number`.
  final String check;

  /// `PASS`, `FAIL`, `WARN` or `INFO`.
  final String status;

  final String what;
  final WincodeException? problem;

  /// An object of the `checks` list of `--json`.
  Map<String, String> toJson() => {
    'check': check,
    'status': status,
    ...?problem?.toJson(),
    'what': what,
  };
}

/// `wincode preflight` (ADR-0013, phase 2): the read-only checks of spike C's `asc_preflight.py`, and the local checks
/// of the IPA and the profile.
///
/// - On this PC: the files of the key folder and the profile lie outside git working trees, unless git ignores them;
///   the profile in `wincode.yaml`; the IPA, with its bundle ID, version, build number and signature.
/// - In App Store Connect, with GET requests only: the key works, the app record exists, the build number is above
///   every existing build's, and the App ID has an active App Store profile.
class Preflight {
  Preflight({
    required this.config,
    required this.ipa,
    required this.environment,
    required this.redactor,
    required this.clock,
    this.connect = connectToApple,
    this.log,
  });

  final WincodeConfig config;

  /// The signed IPA.
  final File ipa;

  /// Where `WINCODE_ASC_KEY_DIR` is read.
  final Map<String, String> environment;

  final Redactor redactor;
  final DateTime Function() clock;
  final AscConnect connect;

  /// Gets one line per HTTP request with `--verbose`.
  final void Function(String line)? log;

  String get _bundleId => config.bundleId;
  String get _teamId => config.teamId;

  /// The `application-identifier` that the app is signed with: `<team ID>.<bundle ID>`.
  String get _appId => '$_teamId.$_bundleId';

  /// Runs every check, and returns what each found, in the order of the report.
  Future<List<Finding>> check() async {
    _registerIds();
    final now = clock().toUtc();
    final (build, ipaFindings) = _checkIpa(now);
    final (location, key, profileRefused) = await _locate(dryRun: false);
    const notChecked = Finding.info(
      'app-store-connect',
      'nothing was checked in App Store Connect',
    );
    final asc = <Finding>[];
    if (key == null) {
      asc.add(notChecked);
    } else {
      try {
        final ascKey = _loadKey(key);
        await _appStoreConnect(
          connect(() => _token(ascKey), log),
          asc,
          build,
          now,
        );
      } on WincodeException catch (e) {
        asc
          ..add(Finding.fail('api-key', e))
          ..add(notChecked);
      }
    }
    return [
      ...location,
      ...asc,
      _localProfile(now, refused: profileRefused),
      ...ipaFindings,
    ];
  }

  /// What `--dry-run` prints: the GET requests that [check] sends, in the order and form of `asc_preflight.py
  /// --dry-run`, and what would authorize them. Sends nothing. A key that may not or cannot be read is a failure
  /// instead, as is a key folder in a git working tree.
  Future<
    ({List<Finding> failures, List<String> requests, String authorization})
  >
  dryRun() async {
    _registerIds();
    final (location, key, _) = await _locate(dryRun: true);
    final failures = [
      for (final f in location)
        if (f.status == 'FAIL') f,
    ];
    var authorization = 'no token: WINCODE_ASC_KEY_DIR is not set';
    if (key != null && failures.isEmpty) {
      try {
        _token(_loadKey(key));
        authorization = 'token signed locally, not shown';
      } on WincodeException catch (e) {
        failures.add(Finding.fail('api-key', e));
      }
    }
    final requests = _Requests();
    if (failures.isEmpty) {
      await _appStoreConnect(requests, [], null, clock(), dryRun: true);
    }
    return (
      failures: failures,
      requests: requests.lines,
      authorization: authorization,
    );
  }

  void _registerIds() => redactor
    ..hide(_bundleId, '<bundle ID>')
    ..hide(_teamId, '<team ID>');

  // Key location.

  /// The key-location check (ADR-0013, section 2). Returns its findings, the key's files when they may be read (null
  /// without them), and whether the profile was refused.
  Future<(List<Finding>, _KeyFiles?, bool)> _locate({
    required bool dryRun,
  }) async {
    final findings = <Finding>[];
    _KeyFiles? key;
    try {
      key = await _keyFiles(dryRun: dryRun);
    } on WincodeException catch (e) {
      findings.add(Finding.fail('key-location', e));
    }
    final profile = config.profile;
    // A dry run does not read the profile.
    final profileChecked = !dryRun && profile != null && profile.existsSync();
    var profileRefused = false;
    if (profileChecked) {
      try {
        await requireOutsideGit(
          profile.path,
          source: 'profile in wincode.yaml',
        );
      } on WincodeException catch (e) {
        findings.add(Finding.fail('key-location', e));
        profileRefused = true;
      }
    }
    if (findings.isEmpty && key != null) {
      findings.add(
        Finding.pass(
          'key-location',
          'the files of WINCODE_ASC_KEY_DIR${profileChecked ? ' and the profile' : ''} lie outside git working '
              'trees, or git ignores them',
        ),
      );
    }
    return (findings, key, profileRefused);
  }

  /// The `.p8` files and the `issuer-id` file of the key folder, each checked with [requireOutsideGit] before anything
  /// reads it; null when a dry run has no key folder.
  Future<_KeyFiles?> _keyFiles({required bool dryRun}) async {
    final variable = environment['WINCODE_ASC_KEY_DIR'] ?? '';
    if (variable.isEmpty) {
      return dryRun ? null : throw _keyDirMissing;
    }
    // Only the absolute path is hidden: the value as set may be as short as `.`, and hiding it would hide every dot.
    // The files are listed from the absolute path, so their paths start with it.
    final folder = Directory(variable).absolute;
    redactor.secret(folder.path, '<WINCODE_ASC_KEY_DIR>');
    if (folder.path
        .split(RegExp(r'[\\/]'))
        .any((part) => part.toLowerCase().startsWith('onedrive'))) {
      throw _keyInOneDrive;
    }
    final List<File> files;
    try {
      files = folder.listSync().whereType<File>().toList();
    } on FileSystemException {
      throw _keyInvalid(
        'WINCODE_ASC_KEY_DIR does not name a folder that can be read',
        why:
            'it names the folder that holds AuthKey_<Key ID>.p8 and issuer-id.',
        next: 'set WINCODE_ASC_KEY_DIR to that folder.',
      );
    }
    final key = (
      p8: [
        for (final f in files)
          if (_name(f).toLowerCase().endsWith('.p8')) f,
      ],
      issuer: files.where((f) => _name(f) == 'issuer-id').firstOrNull,
    );
    for (final file in [...key.p8, ?key.issuer]) {
      await requireOutsideGit(file.path, source: 'WINCODE_ASC_KEY_DIR');
    }
    return key;
  }

  /// The API key in [key], with its Key ID and Issuer ID registered with the redactor before anything can print them.
  AscKey _loadKey(_KeyFiles key) {
    if (key.p8.length != 1) {
      throw _keyInvalid(
        key.p8.isEmpty
            ? 'WINCODE_ASC_KEY_DIR holds no .p8 file'
            : 'WINCODE_ASC_KEY_DIR holds ${key.p8.length} .p8 files',
        why: 'preflight signs its requests with the one key in that folder.',
        next: 'keep exactly one key there: AuthKey_<Key ID>.p8, as App Store Connect delivered it.',
      );
    }
    final keyId = RegExp(r'^AuthKey_([A-Z0-9]{10})\.p8$')
        .firstMatch(_name(key.p8.single))?[1];
    if (keyId == null) {
      throw _keyInvalid(
        'the .p8 in WINCODE_ASC_KEY_DIR is not named AuthKey_<Key ID>.p8',
        why: 'every token names the Key ID, which winCode takes from the name App Store Connect gives the file.',
        next: 'name the file AuthKey_ followed by the 10 characters of its Key ID (Users and Access, Integrations).',
      );
    }
    redactor.secret(keyId, '<Key ID>');
    final issuer = _text(key.issuer)?.trim() ?? '';
    if (!RegExp(
      r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$',
      caseSensitive: false,
    ).hasMatch(issuer)) {
      throw _keyInvalid(
        'WINCODE_ASC_KEY_DIR has no file issuer-id with an Issuer ID in it',
        why: 'every token names the Issuer ID of the team.',
        next:
            'write the Issuer ID (Users and Access, Integrations) on one line in a file named issuer-id in that '
            'folder.',
      );
    }
    redactor.secret(issuer, '<Issuer ID>');
    final notAKey = _keyInvalid(
      'the .p8 in WINCODE_ASC_KEY_DIR is not an App Store Connect API key',
      why: 'an App Store Connect API key is an EC P-256 private key in PEM, as App Store Connect delivered it.',
      next:
          'use the .p8 as it was downloaded. App Store Connect delivers a key once: if the file is lost or damaged, '
          'revoke the key and make a new one (Users and Access, Integrations).',
    );
    try {
      return AscKey.parse(
        _text(key.p8.single) ?? (throw notAKey),
        keyId: keyId,
        issuerId: issuer,
      );
    } on FormatException {
      throw notAKey;
    }
  }

  /// A new token of [key], registered with the redactor before anything can print it.
  String _token(AscKey key) {
    final token = key.token(clock());
    redactor.secret(token, '<token>');
    return token;
  }

  // App Store Connect.

  /// The checks in App Store Connect, each finding added to [found] as it comes, in the order of the script's
  /// requests. Stops at the first request that fails.
  Future<void> _appStoreConnect(
    AscClient client,
    List<Finding> found,
    String? build,
    DateTime now, {
    bool dryRun = false,
  }) async {
    Future<List<AscResource>> get(String path, Map<String, String> query) =>
        client.getAll(path, {...query, 'limit': '200'});
    var check = 'api-key';
    try {
      // The first request is also the check of the key, as in the script: it needs read access to apps only.
      final apps = await get('/v1/apps', {
        'filter[bundleId]': _bundleId,
        'fields[apps]': 'bundleId',
      });
      found.add(
        const Finding.pass('api-key', 'App Store Connect accepts the API key'),
      );
      final app = apps
          .where((a) => _attribute(a, 'bundleId') == _bundleId)
          .map((a) => '${a['id']}')
          .firstOrNull;
      if (app != null) {
        redactor.hide(app, '{id of the app record}');
      }
      found.add(
        app != null
            ? Finding.pass(
                'app-record',
                'App Store Connect has the app record of $_bundleId',
              )
            : Finding.fail(
                'app-record',
                WincodeException(
                  ExitCode.failed,
                  'app-record-missing',
                  'App Store Connect has no app record for $_bundleId',
                  why: 'an upload goes to the app record of its bundle ID, and Apple refuses a build that has none.',
                  next:
                      'create the app record in App Store Connect (Apps, New App) with the bundle ID $_bundleId, or '
                      'correct bundle_id in wincode.yaml.',
                ),
              ),
      );

      check = 'build-number';
      if (app != null || dryRun) {
        final builds = await get(
          '/v1/apps/${app ?? '{id of the app record}'}/builds',
          {'fields[builds]': 'version,processingState'},
        );
        found.addAll(buildNumberFindings(builds, build));
      } else {
        found.add(
          const Finding.info(
            'build-number',
            'the build number was not compared: there is no app record',
          ),
        );
      }

      check = 'store-profile';
      final bundleIds = await get('/v1/bundleIds', {
        'filter[identifier]': _bundleId,
        'fields[bundleIds]': 'identifier,platform',
      });
      final appIds = [
        for (final b in bundleIds)
          if (_attribute(b, 'identifier') == _bundleId) '${b['id']}',
      ];
      final profiles = <AscResource>[];
      for (final id
          in appIds.isEmpty && dryRun ? ['{id of the App ID}'] : appIds) {
        redactor.hide(id, '{id of the App ID}');
        profiles.addAll(
          await get('/v1/bundleIds/$id/profiles', {
            'fields[profiles]': 'profileType,profileState,expirationDate',
          }),
        );
      }
      found.add(_storeProfile(appIds, profiles, now));
    } on AscException catch (e) {
      found
        ..add(Finding.fail(check, _ascProblem(e)))
        ..add(
          const Finding.info(
            'app-store-connect',
            'the checks in App Store Connect after this one were not run',
          ),
        );
    }
  }

  /// The `store-profile` check: the App ID [appIds] exists, and the latest of its active App Store [profiles] has not
  /// expired.
  Finding _storeProfile(
    List<String> appIds,
    List<AscResource> profiles,
    DateTime now,
  ) {
    if (appIds.isEmpty) {
      return Finding.fail(
        'store-profile',
        WincodeException(
          ExitCode.failed,
          'app-id-missing',
          'the developer portal has no App ID for $_bundleId',
          why: 'an App Store profile, and so a signed build, is made for an App ID.',
          next:
              'register the App ID $_bundleId in the developer portal (Identifiers), then make its App Store '
              'profile.',
        ),
      );
    }
    final expiries = [
      for (final p in profiles)
        if (_attribute(p, 'profileType') == 'IOS_APP_STORE' &&
            _attribute(p, 'profileState') == 'ACTIVE')
          ?DateTime.tryParse(_attribute(p, 'expirationDate'))?.toUtc(),
    ]..sort();
    if (expiries.isEmpty) {
      return Finding.fail(
        'store-profile',
        WincodeException(
          ExitCode.failed,
          'profile-missing',
          'App Store Connect has no active App Store profile for $_bundleId',
          why: 'a build for the App Store is signed with an App Store profile of its App ID.',
          next:
              'make an App Store profile for $_bundleId in the developer portal (Profiles, Distribution), download '
              'it, point profile in wincode.yaml at it, and sign the IPA again.',
        ),
      );
    }
    return _expiry(
      'store-profile',
      'the App Store profile of $_bundleId in App Store Connect',
      expiries.last,
      now,
      passed:
          'App Store Connect has an active App Store profile for $_bundleId',
    );
  }

  /// The failure of a request, with Apple's own words as sent (ADR-0013, section 6).
  WincodeException _ascProblem(AscException e) {
    final said = [
      for (final error in e.errors)
        [error['code'], error['detail'] ?? error['title']].nonNulls.join(': '),
    ].join('; ');
    final answer = said.isEmpty ? e.message : '${e.message} $said';
    return switch (e.failure) {
      AscFailure.unauthorized => WincodeException(
        ExitCode.permission,
        'asc-unauthorized',
        'App Store Connect refused the API key: $answer',
        why:
            "the key was revoked, the Key ID or the Issuer ID does not belong to the .p8, or this PC's clock is off "
            'by minutes (the token carries the time).',
        next:
            'check that WINCODE_ASC_KEY_DIR holds AuthKey_<Key ID>.p8 as downloaded and issuer-id with the Issuer '
            'ID (Users and Access, Integrations); set the clock right; make a new key if this one was revoked.',
      ),
      AscFailure.forbidden => WincodeException(
        ExitCode.permission,
        'asc-forbidden',
        'App Store Connect refused ${e.request} to the API key: $answer',
        why: "the key's role may not do this, or an agreement waits to be accepted in App Store Connect.",
        next:
            'accept the agreements in App Store Connect (Business), or use a key whose role may read apps, builds '
            'and profiles (Users and Access, Integrations).',
      ),
      AscFailure.offline => WincodeException(
        ExitCode.unavailable,
        'offline',
        'cannot reach api.appstoreconnect.apple.com: ${e.message}',
        why: "there is no network, a proxy or a firewall is in the way, or Apple's service is down.",
        next:
            "check the connection (and HTTPS_PROXY, if you use one) and Apple's system status page, then run the "
            'command again. Nothing was sent.',
      ),
      AscFailure.unavailable => WincodeException(
        ExitCode.unavailable,
        'asc-unavailable',
        'App Store Connect kept answering ${e.request} with $answer',
        why: "Apple's service is down or overloaded.",
        next: "check Apple's system status page, then run the command again.",
      ),
      AscFailure.refused => WincodeException(
        ExitCode.failed,
        'asc-error',
        "App Store Connect's answer to ${e.request} is not what preflight expects: $answer",
        why: 'preflight sends only read requests that Apple documents, so this answer is unexpected.',
        next:
            'run the command again with --verbose --redact; if the answer comes again, report it with that output '
            'at https://github.com/wincode-org/wincode/issues.',
      ),
    };
  }

  // The profile in wincode.yaml.

  /// The `local-profile` check of the profile that `wincode.yaml` names; [refused] when where it lies forbids reading
  /// it.
  Finding _localProfile(DateTime now, {required bool refused}) {
    const subject = 'the profile in wincode.yaml';
    final file = config.profile;
    if (file == null) {
      return const Finding.info(
        'local-profile',
        'wincode.yaml names no profile, so none was checked',
      );
    }
    if (refused) {
      return const Finding.info(
        'local-profile',
        '$subject was not read, because of where it lies (key-location)',
      );
    }
    final ProvisioningProfile profile;
    try {
      profile = readProvisioningProfile(file.readAsBytesSync());
    } on FileSystemException catch (e) {
      return Finding.fail(
        'local-profile',
        _profileUnreadable(
          '$subject cannot be read: ${e.osError?.message ?? e.message}',
        ),
      );
    } on FormatException catch (e) {
      return Finding.fail(
        'local-profile',
        _profileUnreadable(
          '$subject is not a provisioning profile: ${e.message}',
        ),
      );
    }
    final problem = _profileProblem(subject, profile);
    return problem != null
        ? Finding.fail('local-profile', problem)
        : _expiry(
            'local-profile',
            subject,
            profile.expirationDate,
            now,
            passed:
                '$subject is an App Store profile of team $_teamId for $_bundleId',
          );
  }

  WincodeException _profileUnreadable(String what) => WincodeException(
    ExitCode.failed,
    'profile-unreadable',
    what,
    why: 'wincode sign signs with this profile, and preflight checks it first.',
    next:
        'download the App Store profile for $_bundleId from the developer portal (Profiles) and point profile in '
        'wincode.yaml at it.',
  );

  /// Why [profile] cannot sign an App Store build of this app, or null when it can, whatever its expiry date.
  WincodeException? _profileProblem(
    String subject,
    ProvisioningProfile profile,
  ) {
    const andSign =
        ', point profile in wincode.yaml at it, and sign the IPA again.';
    if (profile.teamId != _teamId) {
      _hideOther(profile.teamId, '<other team ID>');
      return WincodeException(
        ExitCode.failed,
        'profile-team-mismatch',
        '$subject belongs to team ${profile.teamId}, but wincode.yaml says $_teamId',
        why: 'a build is signed with a profile of the team that uploads it.',
        next:
            'download the App Store profile that team $_teamId made for $_bundleId$andSign',
      );
    }
    if (profile.applicationIdentifier != _appId) {
      _hideApplicationIdentifier(profile.applicationIdentifier);
      return WincodeException(
        ExitCode.failed,
        'bundle-id-mismatch',
        '$subject is for ${profile.applicationIdentifier}, but wincode.yaml says $_appId',
        why:
            'winCode signs and uploads only the app that wincode.yaml names, so a build of another flavor or app '
            'cannot reach this app record.',
        next:
            'download the App Store profile made for $_bundleId (developer portal, Profiles)$andSign',
      );
    }
    if (!profile.isForAppStore) {
      return WincodeException(
        ExitCode.failed,
        'profile-not-app-store',
        '$subject is not an App Store profile: it is for development, ad hoc or in-house distribution',
        why: 'App Store Connect accepts only builds signed with an App Store distribution profile.',
        next:
            'download the App Store profile for $_bundleId (developer portal, Profiles, Distribution)$andSign',
      );
    }
    return null;
  }

  /// PASS when [expires] is 30 days away or more, WARN when it is closer, FAIL when it has passed.
  Finding _expiry(
    String check,
    String subject,
    DateTime expires,
    DateTime now, {
    required String passed,
  }) {
    final date = _day(expires);
    if (!expires.isAfter(now)) {
      return Finding.fail(
        check,
        WincodeException(
          ExitCode.failed,
          'profile-expired',
          '$subject expired on $date',
          why: 'Apple refuses a build signed with an expired profile.',
          next:
              'make a new App Store profile for $_bundleId in the developer portal (Profiles), download it, point '
              'profile in wincode.yaml at it, and sign the IPA again.',
        ),
      );
    }
    final days = expires.difference(now).inDays;
    if (days < 30) {
      return Finding.warn(
        check,
        WincodeException(
          ExitCode.ok,
          'profile-expires-soon',
          '$subject expires on $date, '
              '${days == 0 ? 'within a day' : 'in $days day${days == 1 ? '' : 's'}'}',
          why:
              'Apple refuses a build signed with an expired profile, so a build signed with this one must be uploaded '
              'before then.',
          next:
              'make a new App Store profile for $_bundleId in the developer portal (Profiles) before $date, '
              'download it, and point profile in wincode.yaml at it.',
        ),
      );
    }
    return Finding.pass(check, '$passed, valid until $date');
  }

  // The IPA.

  /// The `ipa` and `signature` checks. Returns the IPA's build number when it is one, and the findings.
  (String?, List<Finding>) _checkIpa(DateTime now) {
    if (!ipa.existsSync()) {
      return (
        null,
        [
          Finding.fail(
            'ipa',
            WincodeException(
              ExitCode.failed,
              'ipa-missing',
              '${ipa.path} does not exist',
              why: 'preflight checks the signed IPA that wincode upload sends.',
              next:
                  'name the IPA: wincode preflight <file>.ipa. Without one, preflight checks signed.ipa in the '
                  'output folder of wincode.yaml.',
            ),
          ),
        ],
      );
    }
    Finding unreadable(String why) => Finding.fail(
      'ipa',
      WincodeException(
        ExitCode.failed,
        'ipa-unreadable',
        '${_name(ipa)} cannot be read as an IPA: $why',
        why:
            'an IPA is a zip archive that holds the app in Payload/<name>.app.',
        next: 'build and sign the IPA again, and check that it was copied or downloaded whole.',
      ),
    );
    ZipArchive? zip;
    try {
      zip = ZipArchive.open(ipa);
      final plists = [
        for (final name in zip.names)
          if (_infoPlist.hasMatch(name)) name,
      ];
      if (plists.length != 1) {
        return (
          null,
          [
            unreadable(
              plists.isEmpty
                  ? 'it holds no Payload/<name>.app with an Info.plist'
                  : 'it holds ${plists.length} apps in Payload/',
            ),
          ],
        );
      }
      final app = plists.single.substring(
        0,
        plists.single.length - 'Info.plist'.length,
      );
      final info = parsePlistBytes(zip.read(plists.single));
      if (info is! PlistMap) {
        return (null, [unreadable('its Info.plist is not a dictionary')]);
      }
      String? text(String key) => switch (info[key]) {
        final String value => value,
        _ => null,
      };
      final bundleId = text('CFBundleIdentifier') ?? '';
      final version = text('CFBundleShortVersionString');
      final build = text('CFBundleVersion');
      _hideOther(bundleId, '<other bundle ID>');
      final findings = [
        if (bundleId != _bundleId)
          Finding.fail(
            'ipa',
            WincodeException(
              ExitCode.failed,
              'bundle-id-mismatch',
              "the IPA's bundle ID is ${bundleId.isEmpty ? 'missing' : bundleId}, but wincode.yaml says $_bundleId",
              why:
                  'winCode signs and uploads only the app that wincode.yaml names, so a build of another flavor or '
                  'app cannot reach this app record.',
              next:
                  'build the flavor whose bundle ID is $_bundleId, or use the wincode.yaml of that app (--config).',
            ),
          ),
        if (version == null || !_isDottedNumber(version))
          Finding.fail(
            'ipa',
            WincodeException(
              ExitCode.failed,
              'version-invalid',
              version == null
                  ? "the IPA's Info.plist has no CFBundleShortVersionString"
                  : "the IPA's version is $version, which is not one to three numbers joined by dots",
              why: 'App Store Connect files each build under its version, such as 1.2.3.',
              next: 'set the version in pubspec.yaml (version: 1.2.3+N), then build and sign again.',
            ),
          ),
        if (build == null || !_isDottedNumber(build))
          Finding.fail(
            'ipa',
            WincodeException(
              ExitCode.failed,
              'build-number-invalid',
              build == null
                  ? "the IPA's Info.plist has no CFBundleVersion"
                  : "the IPA's build number is $build, which is not one to three numbers joined by dots",
              why:
                  'App Store Connect tells builds apart by CFBundleVersion, one to three numbers joined by dots, '
                  'such as 13 or 1.2.3.',
              next: 'set the build number (version: x.y.z+N in pubspec.yaml), then build and sign again.',
            ),
          ),
      ];
      if (findings.isEmpty) {
        findings.add(
          Finding.pass(
            'ipa',
            'the IPA holds $bundleId, version $version, build $build',
          ),
        );
      }
      findings.add(_signature(zip, app, text('CFBundleExecutable'), now));
      return (build != null && _isDottedNumber(build) ? build : null, findings);
    } on FormatException catch (e) {
      return (null, [unreadable(e.message)]);
    } on FileSystemException catch (e) {
      return (null, [unreadable(e.osError?.message ?? e.message)]);
    } finally {
      zip?.close();
    }
  }

  /// The `signature` check of the app at [app] (`Payload/<name>.app/`) in [zip], whose executable is [executable].
  Finding _signature(
    ZipArchive zip,
    String app,
    String? executable,
    DateTime now,
  ) {
    const subject = "the IPA's embedded profile";
    if (!zip.names.contains('${app}embedded.mobileprovision')) {
      return const Finding.info(
        'signature',
        'the IPA holds no embedded.mobileprovision, so it is not signed for a device and its signature was not '
            'checked',
      );
    }
    Finding invalid(String what) => Finding.fail(
      'signature',
      WincodeException(
        ExitCode.failed,
        'signature-invalid',
        what,
        why: 'Apple refuses an app whose signature does not carry the identity of its App Store profile.',
        next: 'sign the IPA again with the App Store profile of $_bundleId.',
      ),
    );
    final ProvisioningProfile profile;
    try {
      profile = readProvisioningProfile(
        zip.read('${app}embedded.mobileprovision'),
      );
    } on FormatException catch (e) {
      return invalid('$subject is not a provisioning profile: ${e.message}');
    }
    final problem = _profileProblem(subject, profile);
    if (problem != null) {
      return Finding.fail('signature', problem);
    }
    if (executable == null || !zip.names.contains('$app$executable')) {
      return invalid(
        "the IPA's Info.plist names no executable that the IPA holds",
      );
    }
    final PlistMap? entitlements;
    try {
      entitlements = readSignedEntitlements(zip.read('$app$executable'));
    } on FormatException catch (e) {
      return invalid(
        "the signature of the IPA's executable cannot be read: ${e.message}",
      );
    }
    final signedAs = entitlements?['application-identifier'];
    if (signedAs != _appId) {
      if (signedAs is String) {
        _hideApplicationIdentifier(signedAs);
      }
      return invalid(switch (signedAs) {
        _ when entitlements == null =>
          'the IPA holds a profile, but its executable is not signed',
        final String other =>
          "the IPA's executable is signed as $other, but wincode.yaml says $_appId",
        _ => "the IPA's executable is signed without the application-identifier entitlement",
      });
    }
    return _expiry(
      'signature',
      subject,
      profile.expirationDate,
      now,
      passed: 'the IPA is signed as $_appId with an App Store profile',
    );
  }

  /// Registers the team ID and bundle ID of [applicationIdentifier], `<team ID>.<bundle ID>`, with the redactor. Those
  /// that are the configured ones keep their placeholders.
  void _hideApplicationIdentifier(String applicationIdentifier) {
    final dot = applicationIdentifier.indexOf('.');
    if (dot > 0) {
      _hideOther(applicationIdentifier.substring(0, dot), '<other team ID>');
      _hideOther(applicationIdentifier.substring(dot + 1), '<other bundle ID>');
    }
  }

  /// Registers [value], an ID that a file or Apple gave, with the redactor. A wildcard such as `*` is not an ID, and
  /// hiding it would hide every `*`.
  void _hideOther(String value, String placeholder) {
    if (value.contains(RegExp('[A-Za-z0-9]'))) {
      redactor.hide(value, placeholder);
    }
  }
}

/// The two findings of the build-number check: how many builds the app has and the highest number (INFO), then whether
/// [build], the IPA's `CFBundleVersion` when it is a build number (else null), is higher than every one of them.
///
/// As in the spike's preflight (PR #11): numbers are compared part by part as numbers, a longer number with the same
/// start is higher, and an existing build whose number is not one is left out. Unlike it, a malformed build number of
/// the IPA always fails, in the `ipa` check, even when the app has no builds yet.
List<Finding> buildNumberFindings(List<AscResource> builds, String? build) {
  final numbers =
      builds
          .map((b) => _attribute(b, 'version'))
          .where(_isDottedNumber)
          .toList()
        ..sort(_compareBuildNumbers);
  final highest = numbers.lastOrNull;
  return [
    Finding.info(
      'builds',
      '${builds.length} existing builds, highest build number ${highest ?? 'none'}',
    ),
    if (build == null)
      const Finding.info(
        'build-number',
        'the build number was not compared: the IPA has none that can be read (ipa)',
      )
    else if (highest == null)
      Finding.pass(
        'build-number',
        'build $build is the first build of this app',
      )
    else if (_compareBuildNumbers(build, highest) > 0)
      Finding.pass(
        'build-number',
        'build $build is higher than $highest, the highest existing build',
      )
    else
      Finding.fail(
        'build-number',
        WincodeException(
          ExitCode.failed,
          'build-number-not-higher',
          'build $build is not higher than $highest, the highest build App Store Connect has for this app',
          why:
              'Apple refuses a build number it has already seen, and a used number stays used even when its build '
              'failed.',
          next:
              'raise the build number above $highest (version: x.y.z+N in pubspec.yaml), then build and sign again.',
        ),
      ),
  ];
}

bool _isDottedNumber(String text) =>
    RegExp(r'^\d+(\.\d+){0,2}$').hasMatch(text);

int _compareBuildNumbers(String a, String b) {
  final x = a.split('.').map(BigInt.parse).toList();
  final y = b.split('.').map(BigInt.parse).toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    if (x[i] != y[i]) {
      return x[i].compareTo(y[i]);
    }
  }
  return x.length.compareTo(y.length);
}

final _infoPlist = RegExp(r'^Payload/[^/]+\.app/Info\.plist$');

/// An attribute of [resource] as text, or an empty string.
String _attribute(AscResource resource, String name) =>
    switch (resource['attributes']) {
      final Map<String, Object?> attributes => switch (attributes[name]) {
        final String value => value,
        _ => '',
      },
      _ => '',
    };

String _day(DateTime date) => date.toUtc().toIso8601String().substring(0, 10);

String _name(File file) => file.uri.pathSegments.last;

typedef _KeyFiles = ({List<File> p8, File? issuer});

/// The text of [file] without a byte order mark, or null when it cannot be read.
String? _text(File? file) {
  try {
    final text = file?.readAsStringSync();
    return text != null && text.startsWith('﻿') ? text.substring(1) : text;
  } on FileSystemException {
    return null;
  }
}

/// The [AscClient] of `--dry-run`: it writes each request down as the script prints it, and answers nothing.
class _Requests implements AscClient {
  final lines = <String>[];

  @override
  Future<List<AscResource>> getAll(
    String path,
    Map<String, String> query,
  ) async {
    lines.add(
      'GET https://api.appstoreconnect.apple.com$path?'
      '${[for (final MapEntry(:key, :value) in query.entries) '$key=$value'].join('&')}',
    );
    return const [];
  }
}

const _keyDirMissing = WincodeException(
  ExitCode.config,
  'asc-key-dir-missing',
  'WINCODE_ASC_KEY_DIR is not set',
  why: 'preflight reads the App Store Connect API key from that folder: AuthKey_<Key ID>.p8 and issuer-id.',
  next:
      'put AuthKey_<Key ID>.p8, as App Store Connect delivered it, and a file issuer-id with the Issuer ID (Users and '
      'Access, Integrations) in a folder outside every project and outside OneDrive, such as '
      r'%USERPROFILE%\.wincode\asc, and set WINCODE_ASC_KEY_DIR to it.',
);

const _keyInOneDrive = WincodeException(
  ExitCode.config,
  'key-in-onedrive',
  'WINCODE_ASC_KEY_DIR points into OneDrive',
  why: 'OneDrive copies the folder, and the key in it, to the cloud and to other PCs.',
  next: r'move the folder outside OneDrive, such as %USERPROFILE%\.wincode\asc, and point WINCODE_ASC_KEY_DIR at it.',
);

WincodeException _keyInvalid(
  String what, {
  required String why,
  required String next,
}) => WincodeException(
  ExitCode.config,
  'asc-key-invalid',
  what,
  why: why,
  next: next,
);

/// Writes the report of [findings] for people: a line each, why and the next step under a failure or a warning, and a
/// last line with the outcome.
void writeReport(List<Finding> findings, StringSink sink) {
  for (final f in findings) {
    sink.writeln('${f.status}  ${f.what}');
    if (f.problem?.why case final why?) {
      sink.writeln('  why: $why');
    }
    if (f.problem?.next case final next?) {
      sink.writeln('  next: $next');
    }
  }
  final failed = findings.where((f) => f.status == 'FAIL').length;
  final warned = findings.where((f) => f.status == 'WARN').length;
  sink.writeln(
    'wincode preflight: ${failed > 0
        ? '$failed check${failed == 1 ? '' : 's'} failed'
        : warned > 0
        ? 'passed, with $warned warning${warned == 1 ? '' : 's'}'
        : 'passed'}',
  );
}

/// The exit code of a run that found [findings]: that of the first failure, else 0. A warning does not fail.
ExitCode exitCodeOf(List<Finding> findings) =>
    findings.where((f) => f.status == 'FAIL').firstOrNull?.problem?.exitCode ??
    ExitCode.ok;

/// The object that `--json` prints: `command`, `ok`, `exitCode`, every finding in `checks`, and the first failure in
/// `error`.
Map<String, Object?> jsonOf(List<Finding> findings) {
  final code = exitCodeOf(findings);
  return {
    'command': 'preflight',
    'ok': code == ExitCode.ok,
    'exitCode': code.code,
    'checks': [for (final f in findings) f.toJson()],
    'error': ?findings
        .where((f) => f.status == 'FAIL')
        .firstOrNull
        ?.problem
        ?.toJson(),
  };
}
