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
