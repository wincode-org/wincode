import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

/// `plistlib.dumps(d, fmt=FMT_BINARY)` for the dictionary in the test below.
const _bplist =
    '62706c6973743030d80102030405060708090a0b0e0f13141551615166516c516e566e6573746564517251745175547465787408a20c0d5178100111012cd11011516ba20d121002233ff8000000000000096400630061006600e908191b1d1f21282a2c2e333437393b3e414346485152000000000000010100000000000000160000000000000000000000000000005b';

void main() {
  group('XML property lists', () {
    test('every value type survives a write and a read', () {
      final value = <String, Object?>{
        'text': 'a < b & c',
        'number': 7,
        'real': 1.5,
        'yes': true,
        'no': false,
        'list': <Object?>['x', 2, <String, Object?>{}],
        'empty': <Object?>[],
        'when': DateTime.utc(2026, 10, 25, 8, 20),
        'bytes': Uint8List.fromList([1, 2, 3]),
      };
      expect(parsePlist(writePlist(value)), value);
    });

    test('keys are written sorted, so the same data gives the same bytes', () {
      expect(writePlist({'b': 1, 'a': 2}), writePlist({'a': 2, 'b': 1}));
    });

    test('a binary plist (made with Python plistlib) is read, and so is an XML one through the same call', () {
      final binary = Uint8List.fromList([
        for (var i = 0; i < _bplist.length; i += 2)
          int.parse(_bplist.substring(i, i + 2), radix: 16),
      ]);
      final expected = {
        'a': 'text',
        'n': 300,
        'r': 1.5,
        't': true,
        'f': false,
        'l': ['x', 1],
        'u': 'café',
        'nested': {
          'k': [1, 2],
        },
      };
      expect(parsePlistBytes(binary), expected);
      expect(
        parsePlistBytes(Uint8List.fromList(utf8.encode(writePlist(expected)))),
        expected,
      );
    });

    test('a file that is not a plist is refused', () {
      expect(() => parsePlist('<foo/>'), throwsFormatException);
    });

    test(
      'a damaged plist of either form is refused with a FormatException',
      () {
        final binary = writePlistBinary({'CFBundleVersion': '13'});
        for (final (what, bytes) in [
          ('binary, cut short', binary.sublist(0, binary.length - 10)),
          (
            'binary, offsets past the end',
            Uint8List.fromList(binary)..[binary.length - 1] = 0xFF,
          ),
          ('XML, two values', utf8.encode('<plist><dict/><dict/></plist>')),
        ]) {
          expect(
            () => parsePlistBytes(Uint8List.fromList(bytes)),
            throwsFormatException,
            reason: what,
          );
        }
      },
    );
  });

  group('binary property lists (written)', () {
    /// The `Info.plist` Xcode 26.6 wrote for the resource bundle of `url_launcher_ios` 6.4.2.
    const xcode =
        '62706c6973743030df10120102030405060708090a0b0c0d0e0f101112131415161718191b1c1d1e1c1f20212223265f10134275696c644d616368696e654f534275696c645f1019434642756e646c65446576656c6f706d656e74526567696f6e5f1012434642756e646c654964656e7469666965725f101d434642756e646c65496e666f44696374696f6e61727956657273696f6e5c434642756e646c654e616d655f1013434642756e646c655061636b616765547970655f101a434642756e646c65537570706f72746564506c6174666f726d735a4454436f6d70696c65725f100f4454506c6174666f726d4275696c645e4454506c6174666f726d4e616d655f10114454506c6174666f726d56657273696f6e5a445453444b4275696c6459445453444b4e616d6557445458636f64655c445458636f64654275696c645f10104d696e696d756d4f5356657273696f6e5e554944657669636546616d696c795f101c554952657175697265644465766963654361706162696c697469657355323547383352656e5f103175726c2d6c61756e636865722d696f732d362e342e322e75726c2d6c61756e636865722d696f732e7265736f757263657353362e305f102175726c5f6c61756e636865725f696f735f75726c5f6c61756e636865725f696f7354424e444ca11a586950686f6e654f535f1022636f6d2e6170706c652e636f6d70696c6572732e6c6c766d2e636c616e672e315f3056323346383161586970686f6e656f735432362e355c6970686f6e656f7332362e355432363630563137463131335431332e30a2242510011002a1275561726d36340008002f004500610076009600a300b900d600e100f3010201160121012b013301400153016201810187018a01be01c201e601eb01ed01f6021b0222022b0230023d02420249024e0251025302550257000000000000020100000000000000280000000000000000000000000000025d';
    final xcodeInfo = <String, Object?>{
      'BuildMachineOSBuild': '25G83',
      'CFBundleDevelopmentRegion': 'en',
      'CFBundleIdentifier': 'url-launcher-ios-6.4.2.url-launcher-ios.resources',
      'CFBundleInfoDictionaryVersion': '6.0',
      'CFBundleName': 'url_launcher_ios_url_launcher_ios',
      'CFBundlePackageType': 'BNDL',
      'CFBundleSupportedPlatforms': ['iPhoneOS'],
      'DTCompiler': 'com.apple.compilers.llvm.clang.1_0',
      'DTPlatformBuild': '23F81a',
      'DTPlatformName': 'iphoneos',
      'DTPlatformVersion': '26.5',
      'DTSDKBuild': '23F81a',
      'DTSDKName': 'iphoneos26.5',
      'DTXcode': '2660',
      'DTXcodeBuild': '17F113',
      'MinimumOSVersion': '13.0',
      'UIDeviceFamily': [1, 2],
      'UIRequiredDeviceCapabilities': ['arm64'],
    };

    String hex(Uint8List bytes) =>
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    test('Xcode\'s own bytes come back, byte for byte', () {
      expect(hex(writePlistBinary(xcodeInfo)), xcode);
    });

    test('every value type survives a write and a read', () {
      final value = <String, Object?>{
        'text': 'a < b & c',
        'accent': 'café ☕',
        'long': 'x' * 300,
        'small': 7,
        'byte': 255,
        'wide': 256,
        'huge': 5000000000,
        'negative': -3,
        'real': 1.5,
        'yes': true,
        'no': false,
        'list': <Object?>['x', 2, <String, Object?>{}, <Object?>[]],
        'when': DateTime.utc(2026, 10, 25, 8, 20),
        'bytes': Uint8List.fromList([1, 2, 3]),
        'many': [for (var i = 0; i < 40; i++) 'item $i'],
      };
      expect(parsePlistBytes(writePlistBinary(value)), value);
    });

    test('bytes stay data and are not turned into an array', () {
      final back = parsePlistBytes(
        writePlistBinary({
          'd': Uint8List.fromList([1, 2, 3]),
        }),
      ) as Map<String, Object?>;
      expect(back['d'], isA<Uint8List>());
    });

    test('a value that occurs again is written once', () {
      final twice = writePlistBinary({
        'a': 'same text here',
        'b': 'same text here',
      });
      final different = writePlistBinary({
        'a': 'same text here',
        'b': 'other text here',
      });
      expect(twice.length, lessThan(different.length));
    });

    test('a value that is not a property-list type is refused', () {
      expect(() => writePlistBinary({'a': null}), throwsArgumentError);
      expect(() => writePlistBinary({'a': Object()}), throwsArgumentError);
    });
  });

  group('project files (OpenStep)', () {
    test('dictionaries, arrays, quoted strings and comments', () {
      const text = '''
// !\$*UTF8*\$!
{
	/* a comment */ a = 1;
	"b c" = "x\\"y";
	list = (
		one,
		"two words", /* trailing comma and comment */
	);
	nested = { k = v; };
}
''';
      expect(parseOpenStep(text), {
        'a': '1',
        'b c': 'x"y',
        'list': ['one', 'two words'],
        'nested': {'k': 'v'},
      });
    });

    test('an unclosed dictionary names the line', () {
      expect(
        () => parseOpenStep('{\n a = 1;\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('line 3'),
          ),
        ),
      );
    });
  });
}
