import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

void main() {
  late Directory sdk;
  setUp(() => sdk = Directory.systemTemp.createTempSync('doctor_test'));
  tearDown(() => sdk.deleteSync(recursive: true));

  group('Flutter SDK line endings', () {
    test('an SDK with LF endings passes', () {
      File('${sdk.path}/LICENSE').writeAsStringSync('Copyright\nBSD license\n');
      expect(checkFlutterSdkLineEndings(sdk), isNull);
    });

    test('CRLF endings are reported, with the cause and the fix', () {
      File('${sdk.path}/LICENSE')
          .writeAsStringSync('Copyright\r\nBSD license\r\n');
      final finding = checkFlutterSdkLineEndings(sdk)!;
      expect(finding.id, 'flutter-sdk-line-endings');
      expect(finding.message, contains(sdk.path));
      expect(finding.message, contains('core.autocrlf'));
      expect(finding.message, contains('core.eol'));
      expect(finding.message, contains('NOTICES.Z'));
    });

    test('a lone carriage return is not a Windows line ending', () {
      File('${sdk.path}/LICENSE').writeAsStringSync('a\rb\n');
      expect(checkFlutterSdkLineEndings(sdk), isNull);
    });

    test(
      'an SDK without a LICENSE file (not a git checkout) is not reported',
      () {
        expect(checkFlutterSdkLineEndings(sdk), isNull);
      },
    );
  });
}
