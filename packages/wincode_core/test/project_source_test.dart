import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

final iosDir = Directory('test/fixtures/flavored_sample/ios');

/// Every text file of the fixture project, by its path from `ios/`, as a commit's files would be read.
Map<String, String> filesOf(Directory dir) => {
  for (final entity in dir.listSync(recursive: true))
    if (entity is File &&
        RegExp(r'\.(pbxproj|xcconfig|plist)$').hasMatch(entity.path))
      entity.path.substring(dir.path.length + 1).replaceAll(r'\', '/'): entity
          .readAsStringSync(),
};

void main() {
  group('a project read through ReadProjectFile', () {
    final files = filesOf(iosDir);
    String? read(String path) => files[path];

    test('gives the settings that the disk gives, for every configuration', () {
      final pbxproj = files['Runner.xcodeproj/project.pbxproj']!;
      final names = buildConfigurationNames(pbxproj);
      expect(names, containsAll(['Release', 'Release-alpha', 'Release-beta']));
      for (final name in names) {
        final generated = flutterGeneratedSettings(
          buildName: '1.2.3',
          buildNumber: '45',
        );
        final disk = resolveBuildSettings(
          iosDir: iosDir,
          configuration: name,
          generated: generated,
        );
        final remote = resolveBuildSettings(
          iosDir: iosDir,
          configuration: name,
          generated: generated,
          read: read,
        );
        expect(remote.keys.toSet(), disk.keys.toSet(), reason: name);
        for (final key in disk.keys) {
          expect(remote[key], disk[key], reason: '$key of $name');
        }
      }
    });

    test('reads nothing from the disk', () {
      final settings = resolveBuildSettings(
        iosDir: Directory('does/not/exist'),
        configuration: 'Release-alpha',
        read: read,
      );
      expect(settings['PRODUCT_BUNDLE_IDENTIFIER'], 'org.example.demo.alpha');
    });

    test(
      'a project file that the source lacks is a FormatException that names it',
      () {
        expect(
          () => resolveBuildSettings(
            iosDir: iosDir,
            configuration: 'Release',
            read: (_) => null,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'Runner.xcodeproj/project.pbxproj does not exist',
            ),
          ),
        );
      },
    );

    test('an xcconfig that the pbxproj names and the source lacks is a FormatException', () {
      expect(
        () => resolveBuildSettings(
          iosDir: iosDir,
          configuration: 'Release-alpha',
          read: (path) => path.endsWith('.xcconfig') ? null : files[path],
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            endsWith('does not exist'),
          ),
        ),
      );
    });
  });

  group('readXcconfigIn', () {
    String? read(Map<String, String> files, String path) => files[path];
    List<String> shown(List<XcconfigEntry> entries) => [
      for (final e in entries) '${e.key}=${e.value}',
    ];

    test(
      'includes are looked up from the including file, with . and .. resolved',
      () {
        final files = {
          'Flutter/Release.xcconfig':
              '#include "../Shared/common.xcconfig"\n'
              '#include? "Missing.xcconfig"\n'
              'ID = \$(BASE).alpha // a comment\n',
          'Shared/common.xcconfig': 'BASE = com.example.app\n',
        };
        expect(
          shown(
            readXcconfigIn((p) => read(files, p), 'Flutter/Release.xcconfig'),
          ),
          ['BASE=com.example.app', r'ID=$(BASE).alpha'],
        );
      },
    );

    test('a path with backslashes or a leading ./ names the same file', () {
      final files = {'Flutter/a.xcconfig': 'A = 1\n'};
      expect(
        shown(readXcconfigIn((p) => read(files, p), r'.\Flutter\a.xcconfig')),
        ['A=1'],
      );
    });

    test('a virtual file stands in for Generated.xcconfig, whatever folder it is named in', () {
      final files = {
        'Flutter/Debug.xcconfig': '#include "Generated.xcconfig"\n',
      };
      expect(
        shown(
          readXcconfigIn(
            (p) => read(files, p),
            'Flutter/Debug.xcconfig',
            virtualFiles: {
              'Generated.xcconfig': 'FLUTTER_TARGET=lib/main.dart',
            },
          ),
        ),
        ['FLUTTER_TARGET=lib/main.dart'],
      );
    });

    test('a file that includes itself, through another, fails with the circular message', () {
      final files = {
        'a.xcconfig': '#include "b.xcconfig"\n',
        'b.xcconfig': '#include "a.xcconfig"\n',
      };
      expect(
        () => readXcconfigIn((p) => read(files, p), 'a.xcconfig'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            startsWith('a.xcconfig: #include is circular'),
          ),
        ),
      );
    });

    test('includes nest at most 16 deep', () {
      final files = {
        for (var i = 0; i <= 18; i++)
          'f$i.xcconfig': i == 18
              ? 'END = 1\n'
              : '#include "f${i + 1}.xcconfig"\n',
      };
      expect(
        () => readXcconfigIn((p) => read(files, p), 'f0.xcconfig'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('#include nests too deeply'),
          ),
        ),
      );
      expect(shown(readXcconfigIn((p) => read(files, p), 'f2.xcconfig')), [
        'END=1',
      ]);
    });

    test(
      'a missing include fails with the line, and a missing file with its path',
      () {
        final files = {'a.xcconfig': 'X = 1\n#include "gone.xcconfig"\n'};
        expect(
          () => readXcconfigIn((p) => read(files, p), 'a.xcconfig'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'a.xcconfig:2: the included file gone.xcconfig does not exist',
            ),
          ),
        );
        expect(
          () => readXcconfigIn((p) => read(files, p), 'nowhere.xcconfig'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'nowhere.xcconfig does not exist',
            ),
          ),
        );
      },
    );

    test('a line that is no setting fails with its line number', () {
      final files = {'a.xcconfig': 'X = 1\nnot a setting\n'};
      expect(
        () => readXcconfigIn((p) => read(files, p), 'a.xcconfig'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'a.xcconfig:2: not a setting: not a setting',
          ),
        ),
      );
    });
  });

  group('normalizeProjectPath', () {
    test('resolves . and .., and leaves a .. that leaves the project', () {
      expect(
        normalizeProjectPath('Flutter/../Shared/./a.xcconfig'),
        'Shared/a.xcconfig',
      );
      expect(normalizeProjectPath(r'Flutter\a.xcconfig'), 'Flutter/a.xcconfig');
      expect(normalizeProjectPath('../a.xcconfig'), '../a.xcconfig');
      expect(normalizeProjectPath('a//b/'), 'a/b');
    });
  });

  group('flutterBuildChoice (the rules of flutter_tools 3.47)', () {
    FlutterBuildChoice choose(
      String? flavor, {
      List<String> schemes = const ['Runner', 'Store', 'Dev'],
      List<String> configurations = const [
        'Debug',
        'Profile',
        'Release',
        'Debug-store',
        'Release-store',
        'Release-dev',
      ],
    }) => flutterBuildChoice(
      flavor: flavor,
      schemes: schemes,
      configurations: configurations,
    );

    test('without a flavor it builds the scheme Runner and the configuration Release', () {
      final c = choose(null);
      expect((c.scheme, c.configuration), ('Runner', 'Release'));
      expect(c.fellBack, isFalse);
    });

    test('a flavor names the scheme with its first letter in capitals, and Release-<scheme> ignoring case', () {
      final c = choose('store');
      expect(c.expectedScheme, 'Store');
      expect((c.scheme, c.expectedConfiguration), ('Store', 'Release-Store'));
      expect(c.configuration, 'Release-store');
      expect(c.fellBack, isFalse);
    });

    test('a scheme that matches only ignoring case is taken when it is the only one', () {
      final c = choose('store', schemes: const ['Runner', 'STORE']);
      expect(c.scheme, 'STORE');
      final two = choose('store', schemes: const ['Runner', 'STORE', 'sTore']);
      expect(two.scheme, isNull);
      expect(two.configuration, isNull);
    });

    test('no scheme of that name gives no scheme', () {
      final c = choose('beta');
      expect(
        (c.expectedScheme, c.scheme, c.configuration),
        ('Beta', null, null),
      );
    });

    test('a configuration that holds Release and the scheme is taken when it is the only one', () {
      final c = choose(
        'store',
        configurations: const ['Debug', 'Release', 'Release Store App'],
      );
      expect(c.configuration, 'Release Store App');
      expect(c.fellBack, isFalse);
      expect(c.ambiguous, isFalse);
    });

    test('several that fit stop Flutter', () {
      final c = choose(
        'store',
        configurations: const ['Release', 'Release Store A', 'Release-B-Store'],
      );
      expect(c.configuration, isNull);
      expect(c.ambiguous, isTrue);
      expect(c.fellBack, isFalse);
    });

    test('none that fits falls back to Release without an error', () {
      final c = choose(
        'store',
        configurations: const ['Debug', 'Profile', 'Release'],
      );
      expect(c.configuration, 'Release');
      expect(c.fellBack, isTrue);
      expect(c.expectedConfiguration, 'Release-Store');
    });
  });

  group('buildConfigurationNames', () {
    test('lists the project\'s configurations in file order', () {
      final text = File('${iosDir.path}/Runner.xcodeproj/project.pbxproj')
          .readAsStringSync();
      expect(
        buildConfigurationNames(text).first,
        isIn(['Debug', 'Profile', 'Release']),
      );
    });

    test('a file with no configuration list is a FormatException', () {
      expect(
        () => buildConfigurationNames('{ objects = {}; rootObject = X; }'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => buildConfigurationNames('nonsense ='),
        throwsFormatException,
      );
    });
  });
}
