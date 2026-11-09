import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('xcconfig_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String name, String text) =>
      File('${dir.path}/$name')..writeAsStringSync(text);

  group('#include', () {
    test('entries of an included file stand where the include stood; a missing #include? is skipped', () {
      write('common.xcconfig', 'BASE = com.example.app\n');
      final entries = readXcconfig(
        write(
          'alpha.xcconfig',
          '#include "common.xcconfig"\n#include? "local.xcconfig"\nID = \$(BASE).alpha // trailing comment\n',
        ),
      );
      expect(
        [for (final e in entries) '${e.key}=${e.value}'],
        ['BASE=com.example.app', r'ID=$(BASE).alpha'],
      );
    });

    test(
      'a file that is included twice, not inside itself, is not a cycle',
      () {
        write('d.xcconfig', 'D = 1\n');
        write('b.xcconfig', '#include "d.xcconfig"\nB = 2\n');
        write('c.xcconfig', '#include "d.xcconfig"\nC = 3\n');
        final entries = readXcconfig(
          write('a.xcconfig', '#include "b.xcconfig"\n#include "c.xcconfig"\n'),
        );
        expect([for (final e in entries) e.key], ['D', 'B', 'D', 'C']);
      },
    );

    test('a file that includes itself, directly or through others, fails at once and names the file', () {
      write('b.xcconfig', '#include "a.xcconfig"\n');
      write('self.xcconfig', '#include "self.xcconfig"\n');
      for (final (name, text) in [
        ('a.xcconfig', '#include "b.xcconfig"\n'),
        ('self.xcconfig', null),
      ]) {
        final file = text == null
            ? File('${dir.path}/$name')
            : write(name, text);
        expect(
          () => readXcconfig(file),
          throwsA(
            isA<FormatException>()
                .having((e) => e.message, 'message', startsWith(name))
                .having(
                  (e) => e.message,
                  'message',
                  contains('#include is circular'),
                ),
          ),
          reason: name,
        );
      }
    });

    test('includes nest at most 16 deep', () {
      for (var i = 0; i < 20; i++) {
        write('f$i.xcconfig', '#include "f${i + 1}.xcconfig"\n');
      }
      write('f20.xcconfig', 'END = 1\n');
      expect(
        () => readXcconfig(File('${dir.path}/f0.xcconfig')),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('nests too deeply'),
          ),
        ),
      );
      expect(readXcconfig(File('${dir.path}/f10.xcconfig')).single.key, 'END');
    });
  });

  group('BuildSettings.unresolved', () {
    final settings = BuildSettings({
      'ID': r'$(BASE).$(FLAVOR)',
      'BASE': r'$(PREFIX).app',
      'FLAVOR': 'alpha',
      'PLAIN': 'com.example.app',
      'A': r'$(B)',
      'B': r'${A}',
    });

    test('lists the variables that nothing defines, through nested references, and nothing for what is defined', () {
      expect(settings.unresolved('ID'), {'PREFIX'});
      expect(settings.unresolved('PLAIN'), isEmpty);
      expect(settings.unresolved('NOT_SET'), isEmpty);
      expect(settings['ID'], '.app.alpha');
    });

    test('a loop gives no names and does not hang; expanding it fails', () {
      expect(settings.unresolved('A'), isEmpty);
      expect(() => settings['A'], throwsFormatException);
    });
  });
}
