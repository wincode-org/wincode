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

  /// Sets the 16 or 32 bit field of the central directory header of [name] in [zip], [at] bytes into the header.
  Uint8List patched(
    List<int> zip,
    String name,
    int at,
    int value, {
    int bytes = 4,
  }) {
    final out = Uint8List.fromList(zip);
    final wanted = name.codeUnits;
    for (var i = 0; i + 46 + wanted.length <= out.length; i++) {
      if (out[i] == 0x50 &&
          out[i + 1] == 0x4B &&
          out[i + 2] == 1 &&
          out[i + 3] == 2) {
        if (String.fromCharCodes(out.sublist(i + 46, i + 46 + wanted.length)) ==
            name) {
          for (var b = 0; b < bytes; b++) {
            out[i + at + b] = value >> (8 * b) & 0xFF;
          }
          return out;
        }
      }
    }
    throw StateError('no entry $name');
  }

  const compressedSize = 20, claimedSize = 24, localOffset = 42, nameField = 46;

  Matcher formatError(String part) => throwsA(
    isA<FormatException>().having((e) => e.message, 'message', contains(part)),
  );

  group('ZipArchive limits', () {
    final two = {
      'Payload/a.txt': [1, 2, 3],
      'Payload/b.txt': [4, 5, 6],
    };

    test(
      'an archive with too many entries or too large a directory is refused',
      () {
        final bytes = zipOf(two);
        expect(
          () => ZipArchive.open(
            write('e.ipa', bytes),
            limits: const ZipLimits(entries: 1),
          ),
          formatError('2 entries'),
        );
        expect(
          () => ZipArchive.open(
            write('d.ipa', bytes),
            limits: const ZipLimits(directoryBytes: 10),
          ),
          formatError('its directory'),
        );
      },
    );

    test('entries that claim more than the cap are refused to read, and in all when added up', () {
      final big = patched(zipOf(two), 'Payload/a.txt', claimedSize, 100 << 20);
      final zip = ZipArchive.open(write('big.ipa', big));
      addTearDown(zip.close);
      expect(
        () => zip.read('Payload/a.txt'),
        formatError('more than the 67108864 that are read'),
      );
      expect(
        () => zip.readRange('Payload/a.txt', 0, 100 << 20),
        formatError('more than the'),
      );
      expect(zip.read('Payload/b.txt'), [4, 5, 6]);
      expect(
        () => ZipArchive.open(
          write('total.ipa', zipOf(two)),
          limits: const ZipLimits(totalSize: 5),
        ),
        formatError('claim more than'),
      );
    });

    test(
      'an entry that holds more than its header says stops at the claim',
      () {
        final bomb = zipOf({'Payload/a.txt': List.filled(5 << 20, 0)});
        final lying = patched(bomb, 'Payload/a.txt', claimedSize, 10);
        final zip = ZipArchive.open(write('bomb.ipa', lying));
        addTearDown(zip.close);
        expect(
          () => zip.read('Payload/a.txt'),
          formatError('holds more than its header says'),
        );
      },
    );

    test('a header that claims more compressed data than the archive holds is refused', () {
      final long = patched(
        zipOf(two),
        'Payload/b.txt',
        compressedSize,
        0x7FFFFF00,
      );
      expect(
        () => ZipArchive.open(write('long.ipa', long)),
        formatError('overlap'),
      );
    });

    test('duplicate names and overlapping entries are refused', () {
      // The second name loses its b: Payload/a.txt twice.
      final twice = patched(
        zipOf(two),
        'Payload/b.txt',
        nameField + 8,
        0x61,
        bytes: 1,
      );
      expect(
        () => ZipArchive.open(write('twice.ipa', twice)),
        formatError('occurs twice'),
      );
      final sharing = patched(zipOf(two), 'Payload/b.txt', localOffset, 0);
      expect(
        () => ZipArchive.open(write('overlap.ipa', sharing)),
        formatError('overlap'),
      );
    });

    test('names that leave their folder are refused', () {
      for (final name in [
        'Payload/../evil',
        '../evil',
        '/etc/evil',
        r'Payload\evil',
        'C:evil',
      ]) {
        expect(
          () => ZipArchive.open(
            write(
              'name.ipa',
              zipOf({
                name: [1],
              }),
            ),
          ),
          formatError('leaves its folder'),
          reason: name,
        );
      }
    });

    test('a range is read from a stored or deflated entry without keeping the rest', () {
      final data = List.generate(300000, (i) => i * 13 % 251);
      for (final deflate in [true, false]) {
        final zip = ZipArchive.open(
          write('r$deflate.ipa', zipOf({'f': data}, deflate: deflate)),
        );
        addTearDown(zip.close);
        expect(
          zip.readRange('f', 299990, 10),
          data.sublist(299990),
          reason: '$deflate',
        );
        expect(
          zip.readRange('f', 65530, 20),
          data.sublist(65530, 65550),
          reason: '$deflate',
        );
        expect(zip.readRange('f', 0, 0), isEmpty);
        expect(
          () => zip.readRange('f', 299995, 10),
          formatError('shorter than expected'),
        );
      }
    });
  });

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
              uuid: '00000000-0000-0000-0000-000000000001',
            ),
          ),
        );
        expect(profile.uuid, '00000000-0000-0000-0000-000000000001');
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
        ('no uuid', profileOf({...base}..remove('UUID'))),
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

    test(
      'the signature is found from the head of the file and read on its own',
      () {
        final macho = executable(entitlements: {'get-task-allow': false});
        final at = codeSignatureOf(Uint8List.sublistView(macho, 0, 64))!;
        expect(at.offset, 64);
        expect(
          entitlementsOfSignature(
            Uint8List.sublistView(macho, at.offset, at.offset + at.size),
          ),
          {'get-task-allow': false},
        );
        expect(codeSignatureOf(executable(signed: false)), isNull);
        expect(() => codeSignatureOf(Uint8List(8)), throwsFormatException);
        expect(
          () => codeSignatureOf(Uint8List.sublistView(macho, 0, 36)),
          throwsFormatException,
        );
      },
    );

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
