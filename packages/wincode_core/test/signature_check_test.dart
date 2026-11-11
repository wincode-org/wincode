import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wincode_core/testing.dart';
import 'package:wincode_core/wincode_core.dart';

const _team = 'TEAM000000';
const _bundleId = 'com.example.app';
final _expires = DateTime.utc(2030, 1, 1);

/// The entitlements of the app's executable, as `wincode sign` builds them.
final PlistMap _entitlements = {
  'application-identifier': '$_team.$_bundleId',
  'com.apple.developer.team-identifier': _team,
  'get-task-allow': false,
  'keychain-access-groups': ['$_team.$_bundleId'],
};

/// An unsigned app: its executable over two pages, a framework, a loose library and two resources.
Map<String, List<int>> _unsigned() => {
  'Payload/': [],
  'Payload/Runner.app/': [],
  'Payload/Runner.app/Info.plist': writePlistBinary({
    'CFBundleIdentifier': _bundleId,
    'CFBundleExecutable': 'Runner',
  }),
  'Payload/Runner.app/Runner': [
    ...executable(signed: false),
    ...List.filled(5000, 7),
  ],
  'Payload/Runner.app/PkgInfo': ascii.encode('APPL????'),
  'Payload/Runner.app/Frameworks/App.framework/Info.plist': writePlistBinary({
    'CFBundleIdentifier': 'io.flutter.flutter.app',
    'CFBundleExecutable': 'App',
  }),
  'Payload/Runner.app/Frameworks/App.framework/App': executable(signed: false),
  'Payload/Runner.app/Frameworks/App.framework/flutter_assets/a.txt': ascii
      .encode('a'),
  'Payload/Runner.app/Frameworks/libextra.dylib': executable(signed: false),
};

void main() {
  late Directory temp;
  final key = TestRsaKey();
  final certificate = testCertificate(key, notAfter: _expires);
  final profile = profileOf({
    ...appStoreProfile(teamId: _team, bundleId: _bundleId, expires: _expires),
    'DeveloperCertificates': [certificate],
  });

  setUp(() => temp = Directory.systemTemp.createTempSync('wincode_signature_'));
  tearDown(() => temp.deleteSync(recursive: true));

  Map<String, List<int>> signed({
    bool der = true,
    TestRsaKey? by,
    Uint8List? withCertificate,
  }) => signTestIpa(
    _unsigned(),
    teamId: _team,
    entitlements: _entitlements,
    key: by ?? key,
    certificate: withCertificate ?? certificate,
    profile: profile,
    derEntitlements: der,
  );

  SignatureCheck check(
    Map<String, List<int>> files, {
    String team = _team,
    PlistMap? entitlements,
    Uint8List? chosen,
    List<int>? configured,
  }) {
    final file = File('${temp.path}/app.ipa')..writeAsBytesSync(zipOf(files));
    final zip = ZipArchive.open(file);
    try {
      return checkSignedIpa(
        zip,
        teamId: team,
        entitlements: entitlements ?? _entitlements,
        certificate: readCertificate(chosen ?? certificate),
        profile: Uint8List.fromList(configured ?? profile),
      );
    } finally {
      zip.close();
    }
  }

  test('an app signed as zsign signs it passes every check', () {
    final result = check(signed());
    expect(result.failures, isEmpty);
    expect(result.warnings, isEmpty);
    expect(result.machOs, 3);
    expect(result.bundles, 2);
  });

  test('a signature without DER entitlements is a warning, not a failure', () {
    final result = check(signed(der: false));
    expect(result.failures, isEmpty);
    expect(
      result.warnings.single,
      contains('Runner.app/Runner: the signature has no DER entitlements'),
    );
  });

  group('a change after signing is found', () {
    test('a byte of the executable', () {
      final files = signed();
      final runner = Uint8List.fromList(files['Payload/Runner.app/Runner']!)
        ..[4200] ^= 1;
      files['Payload/Runner.app/Runner'] = runner;
      expect(check(files).failures, [
        'Runner.app/Runner: the SHA-256 hash of page 1 does not match the page',
      ]);
    });

    test('a resource', () {
      final files = signed()
        ..['Payload/Runner.app/Frameworks/App.framework/flutter_assets/a.txt'] =
            ascii.encode('b');
      expect(check(files).failures, [
        'Runner.app: the hash in CodeResources of Frameworks/App.framework/flutter_assets/a.txt does not match the file',
        'Runner.app/Frameworks/App.framework: the hash in CodeResources of flutter_assets/a.txt does not match the file',
      ]);
    });

    test('a file added', () {
      final files = signed()
        ..['Payload/Runner.app/extra.txt'] = ascii.encode('x');
      expect(check(files).failures, [
        'Runner.app: CodeResources files does not seal extra.txt',
        'Runner.app: CodeResources files2 does not seal extra.txt',
      ]);
    });

    test('the Info.plist', () {
      final files = signed()
        ..['Payload/Runner.app/Info.plist'] = writePlistBinary({
          'CFBundleIdentifier': _bundleId,
          'CFBundleExecutable': 'Runner',
          'CFBundleVersion': '2',
        });
      expect(check(files).failures, [
        'Runner.app/Runner: the SHA-256 hash of the Info.plist does not match it',
        'Runner.app: the hash in CodeResources of Info.plist does not match the file',
      ]);
    });

    test('a Mach-O file replaced by an unsigned one', () {
      final files = signed()
        ..['Payload/Runner.app/Frameworks/libextra.dylib'] = executable(
          signed: false,
        );
      expect(check(files).failures, [
        'Runner.app/Frameworks/libextra.dylib: not signed',
        'Runner.app: the hash in CodeResources of Frameworks/libextra.dylib does not match the file',
      ]);
    });

    test('an entry outside Payload/', () {
      final files = signed()..['Symbols/x'] = [1];
      expect(check(files).failures, [
        'the IPA holds 1 entries outside Payload/',
      ]);
    });
  });

  group('a signature that is not the expected one is found', () {
    test('another team', () {
      expect(check(signed(), team: 'OTHER00000').failures, hasLength(3));
      expect(
        check(signed(), team: 'OTHER00000').failures.first,
        'Runner.app/Runner: signed for team $_team, not OTHER00000',
      );
    });

    test('other entitlements', () {
      expect(
        check(
          signed(),
          entitlements: {..._entitlements, 'get-task-allow': true},
        ).failures,
        [
          'Runner.app/Runner: signed with the entitlements application-identifier, com.apple.developer.team-identifier, '
              'get-task-allow, keychain-access-groups, not application-identifier, com.apple.developer.team-identifier, '
              'get-task-allow, keychain-access-groups',
        ],
      );
    });

    test('another certificate', () {
      final other = TestRsaKey();
      final otherCertificate = testCertificate(
        other,
        notAfter: _expires,
        serial: BigInt.from(7),
      );
      final failures = check(
        signed(by: other, withCertificate: otherCertificate),
      ).failures;
      expect(
        failures,
        contains(
          'Runner.app/Runner: the CMS signature does not carry the chosen certificate',
        ),
      );
      expect(
        failures,
        contains(
          'Runner.app/Runner: the CMS signer is not the chosen certificate',
        ),
      );
    });

    test('the chosen certificate with a signature by another key', () {
      expect(
        check(signed(by: TestRsaKey())).failures,
        everyElement(
          endsWith(
            "the CMS signature does not verify with the chosen certificate's key",
          ),
        ),
      );
    });

    test('another profile', () {
      final other = profileOf(
        appStoreProfile(teamId: _team, bundleId: _bundleId, expires: _expires),
      );
      expect(check(signed(), configured: other).failures, [
        'the embedded profile is not the configured profile',
      ]);
    });
  });

  test('app extensions and watch apps are refused, not checked', () {
    final files = signed()
      ..['Payload/Runner.app/PlugIns/Share.appex/Share'] = executable(
        signed: false,
      )
      ..['Payload/Runner.app/Watch/W.app/W'] = executable(signed: false);
    expect(check(files).failures, [
      'the app holds PlugIns/Share.appex, Watch/W.app, which needs its own profile: not supported yet',
    ]);
    expect(
      nestedCodeOf([
        'Payload/',
        'Payload/Runner.app/PlugIns/A.appex/B.appex/x',
      ], 'Payload/Runner.app/'),
      ['PlugIns/A.appex', 'PlugIns/A.appex/B.appex'],
    );
  });

  group('keys and certificates', () {
    test('a certificate is read: names, serial, expiry and RSA key', () {
      final c = readCertificate(
        testCertificate(
          key,
          notAfter: _expires,
          serial: BigInt.parse('00F1', radix: 16),
        ),
      );
      expect(c.commonName, 'Apple Distribution: Example (TEAM000000)');
      expect(c.organizationalUnit, _team);
      expect(c.notAfter, _expires);
      expect(c.serialHex, 'F1');
      expect(c.rsa, key.public);
    });

    test('an unencrypted RSA key is read as PKCS #8 and PKCS #1', () {
      expect(readRsaPrivateKey(utf8.encode(key.pem())), key.public);
      expect(readRsaPrivateKey(utf8.encode(key.pem(pkcs8: false))), key.public);
    });

    test('an encrypted key, a .p12, another kind of key and anything else are refused with their reason', () {
      PrivateKeyProblem? problem(List<int> bytes) {
        try {
          readRsaPrivateKey(Uint8List.fromList(bytes));
          return null;
        } on PrivateKeyException catch (e) {
          expect(e.message, isNot(contains('MII')));
          return e.problem;
        }
      }

      expect(
        problem(utf8.encode(pemOf('ENCRYPTED PRIVATE KEY', [0x30, 0]))),
        PrivateKeyProblem.encrypted,
      );
      expect(
        problem(
          utf8.encode(
            key
                .pem(pkcs8: false)
                .replaceFirst('\n', '\nProc-Type: 4,ENCRYPTED\n'),
          ),
        ),
        PrivateKeyProblem.encrypted,
      );
      expect(problem([0x30, 3, 0x02, 1, 3]), PrivateKeyProblem.encrypted);
      expect(
        problem(utf8.encode(pemOf('EC PRIVATE KEY', [0x30, 0]))),
        PrivateKeyProblem.notRsa,
      );
      // PKCS #8 with the OID of an EC key (1.2.840.10045.2.1).
      const ec = [
        0x30,
        16,
        0x02,
        1,
        0,
        0x30,
        9,
        0x06,
        7,
        0x2A,
        0x86,
        0x48,
        0xCE,
        0x3D,
        0x02,
        0x01,
        0x04,
        0,
      ];
      expect(
        problem(utf8.encode(pemOf('PRIVATE KEY', ec))),
        PrivateKeyProblem.notRsa,
      );
      expect(problem(utf8.encode('not a key')), PrivateKeyProblem.unreadable);
      expect(
        problem(utf8.encode(pemOf('PRIVATE KEY', [1, 2, 3]))),
        PrivateKeyProblem.unreadable,
      );
    });

    test(
      'an RSA signature verifies with its key only, over its message only',
      () {
        final signature = key.sign([1, 2, 3]);
        expect(verifyRsaSha256(key.public, [1, 2, 3], signature), isTrue);
        expect(verifyRsaSha256(key.public, [1, 2, 4], signature), isFalse);
        expect(
          verifyRsaSha256(TestRsaKey().public, [1, 2, 3], signature),
          isFalse,
        );
      },
    );
  });
}
