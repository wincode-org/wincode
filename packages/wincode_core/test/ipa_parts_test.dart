import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wincode_core/testing.dart';
import 'package:wincode_core/wincode_core.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('wincode_core_'));
  tearDown(() => temp.deleteSync(recursive: true));

  File write(String name, List<int> bytes) =>
      File('${temp.path}${Platform.pathSeparator}$name')
        ..writeAsBytesSync(bytes);

  group('ZipArchive', () {
    final files = {
      'Payload/': <int>[],
      'Payload/Runner.app/Info.plist': writePlistBinary({
        'CFBundleVersion': '13',
      }),
      'Payload/Runner.app/Runner': List.generate(70000, (i) => i * 7 % 251),
    };

    test('reads deflated and stored entries by name', () {
      for (final deflate in [true, false]) {
        final zip = ZipArchive.open(
          write('$deflate.ipa', zipOf(files, deflate: deflate)),
        );
        addTearDown(zip.close);
        expect(zip.names, files.keys, reason: 'deflate: $deflate');
        for (final MapEntry(:key, :value) in files.entries) {
          expect(zip.read(key), value, reason: '$key, deflate: $deflate');
        }
      }
    });

    test('refuses what is not a zip archive, or is cut short or damaged', () {
      final good = zipOf(files);
      // A byte of the executable's compressed data, which follows its name in its local header.
      final runner =
          String.fromCharCodes(good).indexOf('Payload/Runner.app/Runner') + 25;
      final damaged = Uint8List.fromList(good)..[runner + 10] ^= 0xFF;
      for (final (what, bytes) in [
        ('not a zip', List.filled(100, 0x20)),
        ('empty', <int>[]),
        ('cut short', good.sublist(0, good.length - 30)),
      ]) {
        expect(
          () => ZipArchive.open(write('bad.ipa', bytes)),
          throwsA(isA<FormatException>()),
          reason: what,
        );
      }
      final zip = ZipArchive.open(write('damaged.ipa', damaged));
      addTearDown(zip.close);
      expect(
        () => zip.read('Payload/Runner.app/Runner'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('damaged'),
          ),
        ),
      );
      expect(() => zip.read('nothing'), throwsArgumentError);
    });

    test('refuses a Zip64 archive', () {
      final bytes = zipOf(files);
      // The end record's entry count, 0xFFFF, says that the Zip64 record holds the real one.
      bytes
        ..[bytes.length - 12] = 0xFF
        ..[bytes.length - 11] = 0xFF;
      expect(
        () => ZipArchive.open(write('zip64.ipa', bytes)),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Zip64'),
          ),
        ),
      );
    });
  });

  group('readProvisioningProfile', () {
    final expires = DateTime.utc(2027, 10, 30, 12);

    test(
      'reads the team, the application identifier, the expiry and the kind',
      () {
        final profile = readProvisioningProfile(
          profileOf(
            appStoreProfile(
              teamId: 'TEAM000000',
              bundleId: 'com.example.app',
              expires: expires,
            ),
          ),
        );
        expect(profile.teamId, 'TEAM000000');
        expect(profile.applicationIdentifier, 'TEAM000000.com.example.app');
        expect(profile.expirationDate, expires);
        expect(profile.isForAppStore, isTrue);
      },
    );

    test('a profile with devices, for all devices, or with get-task-allow is not for the App Store', () {
      final base = appStoreProfile(
        teamId: 'TEAM000000',
        bundleId: 'com.example.app',
        expires: expires,
      );
      for (final plist in [
        appStoreProfile(
          teamId: 'TEAM000000',
          bundleId: 'com.example.app',
          expires: expires,
          devices: true,
        ),
        appStoreProfile(
          teamId: 'TEAM000000',
          bundleId: 'com.example.app',
          expires: expires,
          debuggable: true,
        ),
        {...base, 'ProvisionsAllDevices': true},
      ]) {
        expect(
          readProvisioningProfile(profileOf(plist)).isForAppStore,
          isFalse,
        );
      }
    });

    test('refuses a file without a profile in it', () {
      final base = appStoreProfile(
        teamId: 'TEAM000000',
        bundleId: 'com.example.app',
        expires: expires,
      );
      for (final (what, bytes) in [
        ('no property list', Uint8List.fromList(List.filled(100, 0x30))),
        ('no team', profileOf({...base}..remove('TeamIdentifier'))),
        ('no expiry', profileOf({...base}..remove('ExpirationDate'))),
        ('no entitlements', profileOf({...base}..remove('Entitlements'))),
      ]) {
        expect(
          () => readProvisioningProfile(bytes),
          throwsFormatException,
          reason: what,
        );
      }
    });
  });

  group('readSignedEntitlements', () {
    test('reads the entitlements blob of the code signature', () {
      final entitlements = {
        'application-identifier': 'TEAM000000.com.example.app',
        'com.apple.developer.team-identifier': 'TEAM000000',
        'get-task-allow': false,
        'keychain-access-groups': ['TEAM000000.com.example.app'],
      };
      expect(
        readSignedEntitlements(executable(entitlements: entitlements)),
        entitlements,
      );
    });

    test('is empty for a signature without entitlements, and null for an unsigned file', () {
      expect(readSignedEntitlements(executable()), isEmpty);
      expect(readSignedEntitlements(executable(signed: false)), isNull);
    });

    test(
      'refuses a signature that is cut short or is not an embedded signature',
      () {
        final signed = executable(entitlements: {'get-task-allow': false});
        final notEmbedded = Uint8List.fromList(signed)..[64] = 0;
        for (final bytes in [signed.sublist(0, 80), notEmbedded]) {
          expect(() => readSignedEntitlements(bytes), throwsFormatException);
        }
      },
    );
  });
}
