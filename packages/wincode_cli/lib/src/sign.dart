import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:wincode_asc/wincode_asc.dart';
import 'package:wincode_core/wincode_core.dart';

import 'config.dart';
import 'credentials.dart';
import 'failure.dart';
import 'key_location.dart';
import 'preflight.dart';
import 'redact.dart';
import 'zsign.dart';

// The entitlements, ported from the spike's sign.py (`permits`, `minimal_entitlements`), its oracle.

/// Whether the profile's entitlement [allowed] allows [value]: an equal value, a string that its trailing `*` matches,
/// or a list whose every item one of its own items allows. As sign.py's `permits`.
bool permits(Object? allowed, Object? value) {
  if (value is List<Object?>) {
    final options = allowed is List<Object?> ? allowed : [allowed];
    return value.every((v) => options.any((a) => permits(a, v)));
  }
  if (allowed is String && value is String && allowed.endsWith('*')) {
    return value.startsWith(allowed.substring(0, allowed.length - 1));
  }
  return _sameType(allowed, value) && _pythonEquals(allowed, value);
}

/// Python's `type(a) is type(b)` for property-list values.
bool _sameType(Object? a, Object? b) => switch (a) {
  bool() => b is bool,
  int() => b is int,
  double() => b is double,
  String() => b is String,
  Map<Object?, Object?>() => b is Map<Object?, Object?>,
  List<Object?>() => b is List<Object?>,
  null => b == null,
  _ => a.runtimeType == b.runtimeType,
};

/// Python's `==` for property-list values: inside a dictionary or list, `True == 1` and `1 == 1.0`.
bool _pythonEquals(Object? a, Object? b) {
  Object? number(Object? v) => v is bool ? (v ? 1 : 0) : v;
  return switch ((a, b)) {
    (final Map<Object?, Object?> x, final Map<Object?, Object?> y) =>
      x.length == y.length &&
          x.keys.every((k) => y.containsKey(k) && _pythonEquals(x[k], y[k])),
    (final List<Object?> x, final List<Object?> y) =>
      x.length == y.length &&
          Iterable<int>.generate(x.length)
              .every((i) => _pythonEquals(x[i], y[i])),
    _ => plistEquals(number(a), number(b)),
  };
}

/// The entitlements that the app's executable is signed with, and what the profile does not allow, as sign.py's
/// `minimal_entitlements`: the app's own [extra] entitlements, then the four of ADR-0011 rule 6 built from the
/// profile's team, which replace any of [extra] of the same name. Each problem is sign.py's sentence, with its key.
({PlistMap want, List<({String key, String problem})> problems})
signingEntitlements(
  ProvisioningProfile profile,
  String bundleId, [
  PlistMap extra = const {},
]) {
  final team = profile.teamId;
  final appId = '$team.$bundleId';
  final PlistMap want = {
    ...extra,
    'application-identifier': appId,
    'com.apple.developer.team-identifier': team,
    'get-task-allow': false,
    'keychain-access-groups': [appId],
  };
  final allowed = profile.entitlements;
  return (
    want: want,
    problems: [
      for (final MapEntry(:key, :value) in want.entries)
        if (!allowed.containsKey(key) || !permits(allowed[key], value))
          (
            key: key,
            problem: allowed.containsKey(key)
                ? 'the profile does not allow this $key'
                : 'the profile does not allow $key',
          ),
    ],
  );
}

/// The name of the signed IPA in the output folder.
const _signedName = 'signed.ipa';

/// `wincode sign` for one app (ADR-0013 phase 3a): checks the unsigned IPA, the profile, the distribution key and its
/// certificate, and the entitlements; signs with zsign in WSL2 into a temporary folder in the output folder; checks
/// every signature and runs preflight's local checks on the result; and only then moves it to `signed.ipa`.
class Signer {
  Signer({
    required this.config,
    required this.environment,
    required this.redactor,
    required this.clock,
    required this.connect,
    required this.run,
    ZsignRunner? runner,
    this.log,
  }) : runner = runner ?? ZsignRunner();

  final WincodeConfig config;
  final Map<String, String> environment;
  final Redactor redactor;
  final DateTime Function() clock;
  final AscConnect connect;
  final RunProcess run;

  /// Starts zsign. `verify` never does, so a caller that only verifies may leave it out.
  final ZsignRunner runner;

  /// Gets each step with `--verbose`.
  final void Function(String line)? log;

  String get _bundleId => config.bundleId;
  String get _teamId => config.teamId;

  /// Where the signed IPA goes.
  File get output =>
      File('${config.output.path}${Platform.pathSeparator}$_signedName');

  /// The unsigned IPA that `wincode build` downloads, when the command names none.
  File get defaultInput =>
      File('${config.output.path}${Platform.pathSeparator}unsigned.ipa');

  Preflight _preflight(File ipa) => Preflight(
    config: config,
    ipa: ipa,
    environment: environment,
    redactor: redactor,
    clock: clock,
    connect: connect,
    log: log,
    run: run,
  );

  /// Signs [input]. With [offline], App Store Connect is not asked about the certificate; with [dryRun], everything is
  /// checked that needs neither App Store Connect nor WSL2, and the zsign command is printed instead of run.
  Future<List<Finding>> sign(
    File input, {
    required bool offline,
    required bool dryRun,
  }) async {
    final findings = <Finding>[];
    bool failed() => findings.any((f) => f.status == 'FAIL');
    final now = clock().toUtc();
    redactor.hide(input.path, '<unsigned IPA>');
    findings.add(_checkInput(input));
    final inputs = await _identity(findings, now);
    if (inputs != null) {
      await _askAsc(findings, inputs.certificate, now, offline, dryRun);
    }
    if (failed() || inputs == null) {
      return findings;
    }
    if (dryRun) {
      final d = Wsl(environment, run).distro;
      findings.add(
        Finding.info(
          'zsign',
          'would run: wsl.exe ${d == null ? '' : '-d $d '}--cd <temporary folder> --exec <zsign> -k <distribution key> '
              '-c <certificate from the profile> -m ${config.profile!.path} -e <entitlements> -t <temporary folder> '
              '-z 9 -o <temporary folder>${Platform.pathSeparator}$_signedName ${input.path}; then check the signatures '
              'and move the IPA to ${output.path}',
        ),
      );
      return findings;
    }
    await _signAndCheck(findings, input, inputs);
    return findings;
  }

  /// `wincode sign --verify-only`: the checks that follow zsign, on [ipa], against the profile, the certificate that
  /// signed it (which must be one of the profile's) and the entitlements. It reads no private key. With [offline] or
  /// [dryRun], App Store Connect is not asked about the certificate.
  ///
  /// With [withPreflight] false, the profile line and preflight's local checks (`ipa`, `signature`, `profile-link`)
  /// are left out, for `wincode upload`, which ran them in its own preflight.
  Future<List<Finding>> verify(
    File ipa, {
    required bool offline,
    required bool dryRun,
    bool withPreflight = true,
  }) async {
    redactor.hide(ipa.path, '<signed IPA>');
    final findings = <Finding>[];
    if (!ipa.existsSync()) {
      return findings..add(
        Finding.fail(
          'code-signature',
          WincodeException(
            ExitCode.failed,
            'ipa-missing',
            '${ipa.path} does not exist',
            why: 'sign --verify-only checks a signed IPA.',
            next: 'name the IPA: wincode sign --verify-only <file>.ipa.',
          ),
        ),
      );
    }
    final now = clock().toUtc();
    final inputs = await _identity(
      findings,
      now,
      signed: ipa,
      profileLine: withPreflight,
    );
    if (inputs == null || findings.any((f) => f.status == 'FAIL')) {
      return findings;
    }
    await _askAsc(findings, inputs.certificate, now, offline, dryRun);
    if (findings.any((f) => f.status == 'FAIL')) {
      return findings;
    }
    findings.addAll(_checkSignatures(ipa, inputs));
    if (withPreflight) {
      findings.addAll(_preflight(ipa).localChecks());
    }
    return findings;
  }

  /// The `certificate-asc` step: asks App Store Connect about [certificate] unless [offline] or [dryRun] say not to,
  /// and only when nothing has failed.
  Future<void> _askAsc(
    List<Finding> findings,
    Certificate certificate,
    DateTime now,
    bool offline,
    bool dryRun,
  ) async {
    if (dryRun) {
      findings.add(
        const Finding.info(
          'certificate-asc',
          'App Store Connect was not asked about the certificate (--dry-run)',
        ),
      );
    } else if (offline) {
      findings.add(
        Finding.warn(
          'certificate-asc',
          const WincodeException(
            ExitCode.ok,
            'certificate-not-checked',
            'App Store Connect was not asked whether the certificate is still valid (--offline)',
            why: 'Apple refuses a build signed with a certificate that was revoked.',
            next: 'run the command again without --offline before an upload.',
          ),
        ),
      );
    } else if (!findings.any((f) => f.status == 'FAIL')) {
      findings.add(await _ascCertificate(certificate, now));
    }
  }

  // The unsigned IPA.

  Finding _checkInput(File input) {
    WincodeException problem(String id, String what, String why, String next) =>
        WincodeException(ExitCode.failed, id, what, why: why, next: next);
    if (!input.existsSync()) {
      return Finding.fail(
        'input',
        problem(
          'ipa-missing',
          '${input.path} does not exist',
          'wincode sign signs the unsigned IPA that wincode build downloads into the output folder as unsigned.ipa.',
          'name the IPA: wincode sign <file>.ipa.',
        ),
      );
    }
    ZipArchive? zip;
    try {
      zip = ZipArchive.open(input);
      final outside = zip.names.where((n) => !n.startsWith('Payload/')).length;
      final apps = [
        for (final n in zip.names)
          if (RegExp(r'^Payload/[^/]+\.app/Info\.plist$').hasMatch(n))
            n.substring(0, n.length - 'Info.plist'.length),
      ];
      if (apps.length != 1) {
        return Finding.fail(
          'input',
          problem(
            'ipa-unreadable',
            '${_name(input)} is not an IPA of one app: it holds ${apps.isEmpty ? 'no Payload/<name>.app with an Info.plist' : '${apps.length} apps in Payload/'}',
            'an IPA is a zip archive that holds the app in Payload/<name>.app.',
            'build the IPA again, and check that it was copied or downloaded whole.',
          ),
        );
      }
      if (outside > 0) {
        return Finding.fail(
          'input',
          problem(
            'ipa-outside-payload',
            '${_name(input)} holds $outside entries outside Payload/',
            'App Store Connect takes an IPA that holds Payload/ only, and zsign would sign and keep the rest.',
            'build the IPA again with the reference workflow, which packs only Payload/.',
          ),
        );
      }
      final nested = nestedCodeOf(zip.names, apps.single);
      if (nested.isNotEmpty) {
        return Finding.fail(
          'input',
          problem(
            'extensions-unsupported',
            'the app holds ${nested.join(', ')}: app extensions and watch apps are not supported yet',
            'each one is signed with its own profile and entitlements, which wincode sign does not handle yet (ADR-0013, '
                "phase 3a); signing it with the app's profile would make an IPA that Apple refuses.",
            'sign this app another way for now, or build it without the extension or watch app.',
          ),
        );
      }
      final info = parsePlistBytes(zip.read('${apps.single}Info.plist'));
      final bundleId = info is PlistMap && info['CFBundleIdentifier'] is String
          ? info['CFBundleIdentifier']! as String
          : '';
      if (bundleId != _bundleId) {
        if (bundleId.contains(RegExp('[A-Za-z0-9]'))) {
          redactor.hide(bundleId, '<other bundle ID>');
        }
        return Finding.fail(
          'input',
          problem(
            'bundle-id-mismatch',
            "the IPA's bundle ID is ${bundleId.isEmpty ? 'missing' : bundleId}, but wincode.yaml says $_bundleId",
            'winCode signs and uploads only the app that wincode.yaml names, so a build of another flavor or app '
                'cannot reach this app record.',
            'build the flavor whose bundle ID is $_bundleId, or use the wincode.yaml of that app (--config).',
          ),
        );
      }
      return Finding.pass(
        'input',
        '${_name(input)} holds $_bundleId in Payload/ only, without extensions',
      );
    } on FormatException catch (e) {
      return Finding.fail(
        'input',
        problem(
          'ipa-unreadable',
          '${_name(input)} cannot be read as an IPA: ${e.message}',
          'an IPA is a zip archive that holds the app in Payload/<name>.app.',
          'build the IPA again, and check that it was copied or downloaded whole.',
        ),
      );
    } on FileSystemException catch (e) {
      return Finding.fail(
        'input',
        problem(
          'ipa-unreadable',
          '${_name(input)} cannot be read: ${e.osError?.message ?? e.message}',
          'wincode sign reads the unsigned IPA.',
          'check the file and its permissions.',
        ),
      );
    } finally {
      zip?.close();
    }
  }

  // The profile, the key, the certificate and the entitlements.

  /// Checks the profile, the certificate and the entitlements, adding a finding for each, and returns them when none
  /// failed. The certificate is the profile's certificate of the distribution key, or, for the [signed] IPA of
  /// `--verify-only`, the one that signed it, which no key is read for.
  Future<_Identity?> _identity(
    List<Finding> findings,
    DateTime now, {
    File? signed,
    bool profileLine = true,
  }) async {
    final profileFile = config.profile;
    if (profileFile == null) {
      findings.add(
        Finding.fail(
          'local-profile',
          WincodeException(
            ExitCode.config,
            'profile-not-configured',
            'wincode.yaml names no profile',
            why: 'wincode sign signs with the App Store profile that profile names, and takes the certificate from it.',
            next:
                'download the App Store profile for $_bundleId from the developer portal (Profiles, Distribution) and '
                'add profile: <file> to wincode.yaml.',
          ),
        ),
      );
      return null;
    }
    if (profileFile.existsSync()) {
      try {
        await requireOutsideGit(
          profileFile.path,
          source: 'profile in wincode.yaml',
          run: run,
        );
      } on WincodeException catch (e) {
        findings.add(Finding.fail('key-location', e));
        return null;
      }
    }
    final pre = _preflight(output);
    final profileFinding = pre.profileCheck();
    if (profileLine || profileFinding.status == 'FAIL') {
      findings.add(profileFinding);
    }
    final profile = pre.profile;
    final key = signed == null ? await _key(findings) : null;
    if (profile == null || (signed == null && key == null)) {
      return null;
    }
    final certificate = key != null
        ? _certificate(findings, profile, now, key: key.public)
        : _certificate(findings, profile, now, signedIpa: signed);
    final entitlements = _entitlements(findings, profile);
    if (certificate == null || entitlements == null) {
      return null;
    }
    return (
      profile: profile,
      profileBytes: profileFile.readAsBytesSync(),
      keyFile: key?.file,
      certificate: certificate,
      entitlements: entitlements,
    );
  }

  String get _keySource => config.credentials == null
      ? 'WINCODE_DIST_KEY'
      : 'the credentials ${config.credentials}';

  Future<({File file, RsaPublicKey public})?> _key(
    List<Finding> findings,
  ) async {
    void fail(ExitCode code, String id, String what, String why, String next) =>
        findings.add(
          Finding.fail(
            'dist-key',
            WincodeException(code, id, what, why: why, next: next),
          ),
        );
    final reference = config.credentials;
    final whereNext = reference == null
        ? 'set WINCODE_DIST_KEY to the distribution key, a PEM file on a local drive outside git working trees and '
              'OneDrive'
        : 'put dist.key in the folder $reference of the keys folder, or set ${distOverrideVariable(reference)} to the '
              'file';
    final File? file;
    try {
      file = await resolveDistKey(
        config,
        environment: environment,
        redactor: redactor,
        run: run,
      );
    } on WincodeException catch (e) {
      findings.add(Finding.fail('dist-key', e));
      return null;
    }
    if (file == null) {
      fail(
        ExitCode.config,
        'dist-key-missing',
        'WINCODE_DIST_KEY is not set',
        'wincode sign signs with the distribution private key that WINCODE_DIST_KEY names, for a wincode.yaml without '
            'credentials.',
        '$whereNext; or add credentials: to wincode.yaml (ADR-0014).',
      );
      return null;
    }
    // The key's path is a secret wherever it is printed.
    redactor.secret(file.path, '<distribution key>');
    if (!file.existsSync()) {
      fail(
        ExitCode.config,
        'dist-key-missing',
        'the distribution key of $_keySource does not exist',
        'wincode sign signs with it, and finds it only there (ADR-0014, section 2).',
        '$whereNext.',
      );
      return null;
    }
    final Uint8List bytes;
    try {
      bytes = file.readAsBytesSync();
    } on FileSystemException {
      fail(
        ExitCode.config,
        'dist-key-unreadable',
        'the distribution key of $_keySource cannot be read',
        'wincode sign reads it to find its certificate in the profile.',
        'check the permissions of the file; $whereNext.',
      );
      return null;
    }
    try {
      final public = readRsaPrivateKey(bytes);
      findings.add(
        Finding.pass(
          'dist-key',
          'the distribution key of $_keySource is an unencrypted RSA key',
        ),
      );
      return (file: file, public: public);
    } on PrivateKeyException catch (e) {
      switch (e.problem) {
        case PrivateKeyProblem.encrypted:
          fail(
            ExitCode.config,
            'key-encrypted',
            '${e.message}: wincode sign takes an unencrypted PEM key',
            'zsign takes a password only as a command-line argument, which other programs can read, so wincode sign '
                'never gives it one. Encrypted keys come in phase 3b (ADR-0013).',
            'keep the working key unencrypted and the encrypted backup elsewhere, as '
                'spikes/c-store-acceptance/dist-key.sh makes them: openssl pkey -in <backup> -out dist.key.',
          );
        case PrivateKeyProblem.notRsa:
          fail(
            ExitCode.failed,
            'key-not-rsa',
            e.message,
            "Apple's distribution certificates are RSA, so their key is one.",
            'use the RSA key whose certificate signing request made the distribution certificate.',
          );
        case PrivateKeyProblem.unreadable:
          fail(
            ExitCode.config,
            'key-invalid',
            e.message,
            'wincode sign takes the distribution key as an unencrypted PEM file (PKCS #8 or PKCS #1).',
            'use the key as dist-key.sh wrote it; $whereNext.',
          );
      }
      return null;
    }
  }

  /// The certificate to check the signature against: the profile's certificate whose public key is [key], or the one
  /// that signed [signedIpa], which must be one of the profile's. Either is checked: an Apple distribution certificate
  /// of the team, not expired.
  Certificate? _certificate(
    List<Finding> findings,
    ProvisioningProfile profile,
    DateTime now, {
    RsaPublicKey? key,
    File? signedIpa,
  }) {
    void fail(String id, String what, String why, String next) => findings.add(
      Finding.fail(
        'certificate',
        WincodeException(ExitCode.failed, id, what, why: why, next: next),
      ),
    );
    final whose = signedIpa == null
        ? "the key's certificate"
        : "the IPA's signing certificate";
    final remake =
        'make the App Store profile for $_bundleId again in the developer portal (Profiles) with the distribution '
        'certificate of this key, download it, and point profile in wincode.yaml at it';
    Certificate? found;
    if (signedIpa != null) {
      ZipArchive? zip;
      try {
        zip = ZipArchive.open(signedIpa);
        found = signerCertificateOf(zip);
      } on FormatException catch (e) {
        fail(
          'signature-invalid',
          '${_name(signedIpa)} has no signing certificate to check: ${e.message}',
          "sign --verify-only checks the IPA against the certificate in the signature of the app's executable.",
          'sign the IPA again with wincode sign.',
        );
        return null;
      } on FileSystemException catch (e) {
        fail(
          'signature-invalid',
          '${_name(signedIpa)} cannot be read: ${e.osError?.message ?? e.message}',
          'sign --verify-only reads the signed IPA.',
          'check the file and its permissions.',
        );
        return null;
      } finally {
        zip?.close();
      }
      // A certificate is plist data in the profile, so plistEquals compares it byte for byte.
      final signer = found;
      if (!profile.developerCertificates.any(
        (der) => plistEquals(der, signer.der),
      )) {
        fail(
          'certificate-not-in-profile',
          'the IPA is signed with a certificate that the profile does not list',
          'Apple refuses a build whose certificate the profile does not list.',
          'sign the IPA again with wincode sign, with the profile in wincode.yaml; or point profile in wincode.yaml at '
              'the profile it was signed with.',
        );
        return null;
      }
    } else {
      for (final der in profile.developerCertificates) {
        try {
          final c = readCertificate(der);
          if (c.rsa == key) {
            found = c;
            break;
          }
        } on FormatException {
          // A certificate that cannot be read is not the key's.
        }
      }
      if (found == null) {
        fail(
          'certificate-not-in-profile',
          'the distribution key of $_keySource matches no certificate in the profile',
          'zsign signs with the certificate of the key, and Apple refuses a build whose certificate the profile does '
              'not list.',
          '$remake; or use the key of a certificate that the profile lists.',
        );
        return null;
      }
    }
    final name = found.commonName ?? '';
    final kind = name.split(':').first;
    if (!name.startsWith('Apple Distribution:') &&
        !name.startsWith('iPhone Distribution:')) {
      fail(
        'certificate-not-distribution',
        '$whose is not a distribution certificate ($kind)',
        'App Store Connect accepts only builds signed with an Apple Distribution certificate.',
        'make an Apple Distribution certificate (Certificates, +) with this key, then $remake.',
      );
      return null;
    }
    final ou = found.organizationalUnit ?? '';
    if (ou != _teamId) {
      if (ou.contains(RegExp('[A-Za-z0-9]'))) {
        redactor.hide(ou, '<other team ID>');
      }
      fail(
        'certificate-team-mismatch',
        'the certificate belongs to team ${ou.isEmpty ? '(none)' : ou}, but wincode.yaml says $_teamId',
        'a build is signed with a certificate of the team that uploads it.',
        'use the distribution key and profile of team $_teamId.',
      );
      return null;
    }
    final date = found.notAfter.toIso8601String().substring(0, 10);
    if (!found.notAfter.isAfter(now)) {
      fail(
        'certificate-expired',
        'the distribution certificate expired on $date',
        'Apple refuses a build signed with an expired certificate.',
        'make a new Apple Distribution certificate (Certificates, +) with a new key, then $remake.',
      );
      return null;
    }
    findings.add(
      Finding.pass(
        'certificate',
        '$whose in the profile is an $kind certificate of team $_teamId, valid until $date',
      ),
    );
    return found;
  }

  PlistMap? _entitlements(List<Finding> findings, ProvisioningProfile profile) {
    var extra = const <String, Object?>{};
    final file = config.entitlements;
    if (file != null) {
      String? why;
      try {
        final parsed = parsePlistBytes(file.readAsBytesSync());
        if (parsed is PlistMap) {
          extra = parsed;
        } else {
          why = 'it is not a dictionary';
        }
      } on FormatException catch (e) {
        why = e.message;
      } on FileSystemException catch (e) {
        why = e.osError?.message ?? e.message;
      }
      if (why != null) {
        findings.add(
          Finding.fail(
            'entitlements',
            WincodeException(
              ExitCode.config,
              'entitlements-unreadable',
              'the entitlements file in wincode.yaml cannot be read: $why',
              why: "wincode sign signs the app's executable with the keys of that file.",
              next: 'point entitlements in wincode.yaml at the .entitlements file of the app (ios/Runner).',
            ),
          ),
        );
        return null;
      }
    }
    final (:want, :problems) = signingEntitlements(profile, _bundleId, extra);
    for (final p in problems) {
      findings.add(
        Finding.fail(
          'entitlements',
          WincodeException(
            ExitCode.failed,
            'entitlement-not-allowed',
            p.problem.contains('this ')
                ? "the app's entitlements ask for a value of ${p.key} that the profile does not allow"
                : "the app's entitlements ask for ${p.key}, which the profile does not allow",
            why:
                "iOS and Apple's checks refuse an app whose signature claims an entitlement that its profile does not "
                'grant.',
            next:
                'turn on the capability for the App ID $_bundleId in the developer portal (Identifiers), then make and '
                'download the App Store profile again; or remove ${p.key} from the entitlements file if the app does '
                'not use it.',
          ),
        ),
      );
    }
    if (problems.isNotEmpty) {
      return null;
    }
    if (log case final log?) {
      log('the entitlements of the app\'s executable:');
      writePlist(want).trimRight().split('\n').forEach(log);
    }
    findings.add(
      Finding.pass(
        'entitlements',
        "the app's executable gets ${want.length} entitlements, each allowed by the profile: "
            '${(want.keys.toList()..sort()).join(', ')}',
      ),
    );
    return want;
  }

  /// The `certificate-asc` check: App Store Connect lists [certificate] as a distribution certificate that has not
  /// expired. The request is signed with the App Store Connect key of the same credentials.
  Future<Finding> _ascCertificate(Certificate certificate, DateTime now) async {
    const check = 'certificate-asc';
    var keySource = 'WINCODE_ASC_KEY_DIR';
    try {
      final files = await locateAscKeyFiles(
        config,
        environment: environment,
        redactor: redactor,
        run: run,
      );
      if (files == null) {
        return Finding.fail(
          check,
          WincodeException(
            ExitCode.config,
            'asc-key-dir-missing',
            'WINCODE_ASC_KEY_DIR is not set, so the certificate cannot be checked in App Store Connect',
            why:
                'wincode sign asks App Store Connect whether the certificate is still a valid distribution '
                'certificate, with the App Store Connect key.',
            next: 'set WINCODE_ASC_KEY_DIR to the folder of AuthKey_<Key ID>.p8 and issuer-id; or give --offline.',
          ),
        );
      }
      keySource = files.source;
      final key = loadAscKey(files, redactor);
      final client = connect(() => ascToken(key, clock, redactor), log);
      final listed = await client.getAll('/v1/certificates', {
        'fields[certificates]': 'serialNumber,certificateType,expirationDate',
        'limit': '200',
      });
      String attribute(AscResource r, String name) => switch (r['attributes']) {
        final Map<String, Object?> a => '${a[name] ?? ''}',
        _ => '',
      };
      String normal(String serial) =>
          serial.trim().toUpperCase().replaceFirst(RegExp('^0+'), '');
      final match = listed
          .where(
            (r) =>
                normal(attribute(r, 'serialNumber')) == certificate.serialHex,
          )
          .firstOrNull;
      WincodeException problem(
        String id,
        String what,
        String why,
      ) => WincodeException(
        ExitCode.failed,
        id,
        what,
        why: why,
        next:
            'make an Apple Distribution certificate (Certificates, +), then the App Store profile for $_bundleId with '
            'it, download the profile, and point profile in wincode.yaml at it.',
      );
      if (match == null) {
        return Finding.fail(
          check,
          problem(
            'certificate-not-in-asc',
            'App Store Connect does not list the certificate',
            'it was revoked or belongs to another team, and Apple refuses a build signed with it.',
          ),
        );
      }
      final type = attribute(match, 'certificateType');
      if (type != 'DISTRIBUTION' && type != 'IOS_DISTRIBUTION') {
        return Finding.fail(
          check,
          problem(
            'certificate-not-distribution',
            'App Store Connect lists the certificate as $type, not as a distribution certificate',
            'App Store Connect accepts only builds signed with a distribution certificate.',
          ),
        );
      }
      final expires = DateTime.tryParse(attribute(match, 'expirationDate'))
          ?.toUtc();
      if (expires == null || !expires.isAfter(now)) {
        return Finding.fail(
          check,
          problem(
            'certificate-expired',
            expires == null
                ? 'App Store Connect gives no expiry date for the certificate'
                : 'App Store Connect says the certificate expired on ${expires.toIso8601String().substring(0, 10)}',
            'Apple refuses a build signed with an expired certificate.',
          ),
        );
      }
      return Finding.pass(
        check,
        'App Store Connect lists the certificate as $type, valid until ${expires.toIso8601String().substring(0, 10)}',
      );
    } on WincodeException catch (e) {
      return Finding.fail(check, e);
    } on AscException catch (e) {
      return Finding.fail(
        check,
        ascProblem(e, keySource: keySource, command: 'sign'),
      );
    }
  }

  // Signing.

  Future<void> _signAndCheck(
    List<Finding> findings,
    File input,
    _Identity inputs,
  ) async {
    final wsl = Wsl(environment, run, log: log);
    final String zsign;
    try {
      zsign = await requirePinnedZsign(environment, wsl);
    } on WincodeException catch (e) {
      findings.add(Finding.fail('zsign', e));
      return;
    }
    findings.add(
      Finding.pass(
        'zsign',
        'zsign $zsignVersion (${zsignCommit.substring(0, 8)}) in ${wsl.name}, with the SHA-256 that doctor recorded',
      ),
    );
    final folder = config.output..createSync(recursive: true);
    final random = Random.secure();
    final temp = Directory(
      '${folder.path}${Platform.pathSeparator}.wincode-sign-'
      '${[for (var i = 0; i < 8; i++) random.nextInt(16).toRadixString(16)].join()}',
    )..createSync();
    String inTemp(String name) => '${temp.path}${Platform.pathSeparator}$name';
    try {
      final certificate = File(inTemp('certificate.pem'))
        ..writeAsStringSync(_pem(inputs.certificate.der));
      final entitlements = File(inTemp('entitlements.plist'))
        ..writeAsStringSync(writePlist(inputs.entitlements));
      final work = Directory(inTemp('zsign'))..createSync();
      final signed = File(inTemp(_signedName));

      final keyPath = await wsl.translate(inputs.keyFile!.absolute.path);
      if (keyPath != null) {
        redactor.secret(keyPath, '<distribution key>');
      }
      final readable =
          keyPath != null &&
          (await wsl.exec(['test', '-r', keyPath]))?.exitCode == 0;
      if (!readable) {
        findings.add(
          Finding.fail(
            'dist-key',
            WincodeException(
              ExitCode.config,
              'dist-key-unreachable',
              'the distribution key of $_keySource lies where WSL2 cannot read it',
              why:
                  'zsign runs inside WSL2 and reads the key in place, at the path that wslpath gives; a network share '
                  'or a drive that WSL2 does not mount has none.',
              next: config.credentials == null
                  ? 'set WINCODE_DIST_KEY to a file on a local drive.'
                  : 'move the keys root to a local drive, or set ${distOverrideVariable(config.credentials!)} to a '
                        'file on one.',
            ),
          ),
        );
        return;
      }
      final paths = <String, String>{};
      for (final (what, path) in [
        ('certificate', certificate.path),
        ('profile', config.profile!.absolute.path),
        ('entitlements', entitlements.path),
        ('work', work.path),
        ('signed', signed.path),
        ('input', input.absolute.path),
        ('temp', temp.path),
      ]) {
        final translated = await wsl.translate(path);
        if (translated == null) {
          findings.add(
            Finding.fail(
              'zsign',
              WincodeException(
                ExitCode.config,
                'path-unreachable',
                '$path lies where WSL2 cannot reach it',
                why: 'zsign runs inside WSL2 and reads and writes the files of the signing through wslpath.',
                next: 'keep the project, its output folder and the IPA on a local drive.',
              ),
            ),
          );
          return;
        }
        if (redactor.active) {
          final shown = redactor.apply(path);
          if (shown != path) {
            redactor.hide(translated, shown);
          }
        }
        paths[what] = translated;
      }
      final arguments = wsl.arguments([
        zsign,
        '-k',
        keyPath,
        '-c',
        paths['certificate']!,
        '-m',
        paths['profile']!,
        '-e',
        paths['entitlements']!,
        '-t',
        paths['work']!,
        '-z',
        '9',
        '-o',
        paths['signed']!,
        paths['input']!,
      ], cd: paths['temp']);
      log?.call('wsl.exe ${arguments.join(' ')}');
      final outcome = await runner.run(arguments, work: temp);
      if (log case final log?) {
        outcome.said.forEach(log);
      }
      final last = outcome.said.where((l) => l.trim().isNotEmpty).lastOrNull;
      WincodeException zsignFailed(String id, String what) => WincodeException(
        ExitCode.failed,
        id,
        what,
        why: last == null
            ? 'zsign printed nothing.'
            : 'zsign said: ${redactor.forReport(last.trim())}',
        next: 'run the command again with --verbose to see what zsign printed. Nothing was written to the output folder.',
      );
      switch (outcome.end) {
        case ZsignEnd.timedOut:
          findings.add(
            Finding.fail(
              'zsign',
              zsignFailed(
                'zsign-timeout',
                'zsign was stopped after ${runner.timeout.inMinutes} minutes',
              ),
            ),
          );
          return;
        case ZsignEnd.tooBig:
          findings.add(
            Finding.fail(
              'zsign',
              zsignFailed(
                'zsign-too-big',
                'zsign was stopped: its files passed 1 GB',
              ),
            ),
          );
          return;
        case ZsignEnd.failed:
          findings.add(
            Finding.fail(
              'zsign',
              zsignFailed(
                'zsign-failed',
                outcome.exitCode == null
                    ? 'zsign could not be started'
                    : 'zsign failed with exit code ${outcome.exitCode}',
              ),
            ),
          );
          return;
        case ZsignEnd.ok:
          if (!signed.existsSync()) {
            findings.add(
              Finding.fail(
                'zsign',
                zsignFailed(
                  'zsign-failed',
                  'zsign ended without writing the signed IPA',
                ),
              ),
            );
            return;
          }
      }
      findings.add(const Finding.pass('zsign', 'zsign signed the IPA'));
      final checked = [
        ..._checkSignatures(signed, inputs),
        ..._preflight(signed).localChecks(),
      ];
      findings.addAll(checked);
      if (checked.any((f) => f.status == 'FAIL')) {
        return;
      }
      signed.renameSync(output.path);
      findings.add(Finding.pass('output', 'wrote ${output.path}'));
    } finally {
      _delete(temp);
    }
  }

  List<Finding> _checkSignatures(File ipa, _Identity inputs) {
    const check = 'code-signature';
    ZipArchive? zip;
    try {
      zip = ZipArchive.open(ipa);
      final result = checkSignedIpa(
        zip,
        teamId: _teamId,
        entitlements: inputs.entitlements,
        certificate: inputs.certificate,
        profile: inputs.profileBytes,
      );
      return [
        for (final f in result.failures)
          Finding.fail(
            check,
            WincodeException(
              ExitCode.failed,
              'signature-invalid',
              f,
              why: 'Apple refuses an app whose signatures do not match its files, its profile and its certificate.',
              next:
                  'sign the IPA again with wincode sign; if this comes again, report it with the output of '
                  '--verbose --redact at https://github.com/wincode-org/wincode/issues.',
            ),
          ),
        for (final w in result.warnings)
          Finding.warn(
            check,
            WincodeException(
              ExitCode.ok,
              'der-entitlements-missing',
              w,
              why: 'iOS 15 and later read the DER entitlements; an app without them may not start.',
              next: 'sign the IPA with wincode sign, which writes them.',
            ),
          ),
        if (result.failures.isEmpty)
          Finding.pass(
            check,
            'every signature checks out: ${result.machOs} Mach-O files and ${result.bundles} bundles, signed for team '
            '$_teamId with the certificate checked above and the profile in wincode.yaml',
          ),
      ];
    } on FormatException catch (e) {
      return [
        Finding.fail(
          check,
          WincodeException(
            ExitCode.failed,
            'signature-invalid',
            '${_name(ipa)} cannot be read as an IPA: ${e.message}',
            why: 'the signed IPA is a zip archive that holds the app in Payload/<name>.app.',
            next: 'sign the IPA again with wincode sign.',
          ),
        ),
      ];
    } on FileSystemException catch (e) {
      return [
        Finding.fail(
          check,
          WincodeException(
            ExitCode.failed,
            'signature-invalid',
            '${_name(ipa)} cannot be read: ${e.osError?.message ?? e.message}',
            why: 'the signed IPA is checked before it is kept.',
            next: 'sign the IPA again with wincode sign.',
          ),
        ),
      ];
    } finally {
      zip?.close();
    }
  }
}

typedef _Identity = ({
  ProvisioningProfile profile,
  Uint8List profileBytes,
  File? keyFile,
  Certificate certificate,
  PlistMap entitlements,
});

String _pem(Uint8List der) {
  final text = base64.encode(der);
  return [
    '-----BEGIN CERTIFICATE-----',
    for (var i = 0; i < text.length; i += 64)
      text.substring(i, min(i + 64, text.length)),
    '-----END CERTIFICATE-----',
    '',
  ].join('\n');
}

/// Deletes [folder], trying again for a few seconds while a process that was stopped still holds a file in it.
void _delete(Directory folder) {
  for (var i = 0; i < 20 && folder.existsSync(); i++) {
    try {
      folder.deleteSync(recursive: true);
    } on FileSystemException {
      sleep(const Duration(milliseconds: 250));
    }
  }
}

String _name(File file) => file.uri.pathSegments.last;
