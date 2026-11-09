import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_cli/src/workflow_template.g.dart';

import '../tool/embed_template.dart' show embeddedTemplateSource;

void main() {
  final file = File('templates/wincode-ios.yml');

  test('the embedded workflow is templates/wincode-ios.yml, byte for byte', () {
    expect(
      utf8.encode(workflowTemplate),
      file.readAsBytesSync(),
      reason: 'run `dart run tool/embed_template.dart` in packages/wincode_cli after changing the template',
    );
  });

  test(
    'lib/src/workflow_template.g.dart is what tool/embed_template.dart writes',
    () {
      final generated = File('lib/src/workflow_template.g.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      expect(
        generated,
        embeddedTemplateSource(file.readAsStringSync()),
        reason:
            'run `dart run tool/embed_template.dart` in packages/wincode_cli',
      );
    },
  );

  test(
    'the generator refuses text that a raw string cannot hold byte for byte',
    () {
      expect(() => embeddedTemplateSource("a ''' b"), throwsFormatException);
      expect(() => embeddedTemplateSource('a\r\nb'), throwsFormatException);
      expect(embeddedTemplateSource('a: 1\n'), contains("r'''\na: 1\n''';"));
    },
  );
}
