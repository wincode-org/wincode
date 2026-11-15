import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_cli/wincode_cli.dart';

/// ADR-0015, section 2: the keys `build_name`, `target`, `flutter_version` and `min_xcode_version`.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('config_build'));
  tearDown(() => dir.deleteSync(recursive: true));

  final adr = File('../../docs/adr/0015-wincode-build.md')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  /// The first YAML block of the ADR: its worked example.
  final example = RegExp(
    r'```yaml\n(.*?)```',
    dotAll: true,
  ).firstMatch(adr)![1]!;

  WincodeSettings load(String yaml, {Redactor? redactor}) {
    final file = File('${dir.path}${Platform.pathSeparator}wincode.yaml')
      ..writeAsStringSync(yaml);
    return loadSettings(file.path, redactor: redactor);
  }

  WincodeException failure(String yaml) {
    try {
      load(yaml);
    } on WincodeException catch (e) {
      expect(e.exitCode, ExitCode.config, reason: e.what);
      expect(e.id, 'config-invalid');
      expect([e.why, e.next], everyElement(isNotEmpty), reason: e.what);
      return e;
    }
    fail('no failure for:\n$yaml');
  }

  /// A flat file with [extra] lines.
  String flat(String extra) =>
      'bundle_id: com.example.alpha\nteam_id: TEAM000001\n$extra';

  group('the worked example of the ADR', () {
    test('gives alpha its own target and the shared versions, and alpha-dev its own version', () {
      final settings = load(example);
      final alpha = settings.app('alpha')!;
      final dev = settings.app('alpha-dev')!;
      expect(
        (
          alpha.flutterVersion,
          alpha.minXcodeVersion,
          alpha.buildName,
          alpha.target,
          alpha.flavor,
        ),
        ('3.47.7', '26.0', '2.4.0', 'lib/main_store.dart', 'store'),
      );
      expect(
        (dev.flutterVersion, dev.minXcodeVersion, dev.buildName, dev.target),
        ('3.47.7', '26.0', '2.5.0', 'lib/main_dev.dart'),
      );
    });
  });

  group('the four keys', () {
    test('a flat file may hold all of them', () {
      final app = load(
        flat(
          'flavor: store\n'
          'build_name: 2.4.0\n'
          'target: lib/main_store.dart\n'
          'flutter_version: 3.47.7\n'
          'min_xcode_version: "26.0"\n',
        ),
      ).apps.single;
      expect(app.buildName, '2.4.0');
      expect(app.target, 'lib/main_store.dart');
      expect(app.flutterVersion, '3.47.7');
      expect(app.minXcodeVersion, '26.0');
    });

    test(
      'none of them is needed: sign, preflight, init and upload work without',
      () {
        final app = load(flat('')).apps.single;
        expect(
          (app.buildName, app.target, app.flutterVersion, app.minXcodeVersion),
          (null, null, null, null),
        );
      },
    );

    test('defaults share all four, and an app replaces a default whole', () {
      final settings = load(
        'defaults:\n'
        '  team_id: TEAM000001\n'
        '  credentials: team-one\n'
        '  build_name: 2.4.0\n'
        '  target: lib/main.dart\n'
        '  flutter_version: 3.47.7\n'
        '  min_xcode_version: "26.0"\n'
        'apps:\n'
        '  alpha:\n    bundle_id: com.example.alpha\n'
        '  beta:\n    bundle_id: com.example.beta\n    build_name: "3.0"\n'
        '    flutter_version: 3.48.0-0.1.pre\n    min_xcode_version: "26.4.1"\n',
      );
      final alpha = settings.app('alpha')!;
      final beta = settings.app('beta')!;
      expect(
        (
          alpha.buildName,
          alpha.target,
          alpha.flutterVersion,
          alpha.minXcodeVersion,
        ),
        ('2.4.0', 'lib/main.dart', '3.47.7', '26.0'),
      );
      expect(
        (
          beta.buildName,
          beta.target,
          beta.flutterVersion,
          beta.minXcodeVersion,
        ),
        ('3.0', 'lib/main.dart', '3.48.0-0.1.pre', '26.4.1'),
      );
    });

    test('a version that YAML reads as a number is refused, with a message that says to quote it', () {
      final xcode = failure(flat('min_xcode_version: 26.0\n'));
      expect(xcode.what, contains('min_xcode_version must be text'));
      expect(xcode.next, contains('in quotes'));
      final name = failure(flat('build_name: 2.4\n'));
      expect(name.what, contains('build_name must be text'));
      expect(name.why, contains('drops its zero'));
    });

    for (final (key, value, said) in [
      ('build_name', '"2.4.0.1"', 'build_name is not a version'),
      ('build_name', 'v2.4.0', 'build_name is not a version'),
      ('build_name', '""', 'build_name is not a version'),
      ('target', 'main.dart', 'target is not a Dart entry point'),
      ('target', 'lib/main', 'target is not a Dart entry point'),
      ('target', 'lib/../main.dart', 'target is not a Dart entry point'),
      ('target', 'lib//main.dart', 'target is not a Dart entry point'),
      ('target', '"lib/main one.dart"', 'target is not a Dart entry point'),
      ('target', r"'lib\main.dart'", 'target is not a Dart entry point'),
      ('target', 'lib/${'a' * 60}.dart', 'target is not a Dart entry point'),
      ('flutter_version', '"3.47"', 'flutter_version is not a Flutter release'),
      (
        'flutter_version',
        'v3.47.7',
        'flutter_version is not a Flutter release',
      ),
      (
        'flutter_version',
        '3.47.7-',
        'flutter_version is not a Flutter release',
      ),
      (
        'flutter_version',
        '3.47.7-${'a' * 30}',
        'flutter_version is not a Flutter release',
      ),
      ('flutter_version', 'main', 'flutter_version is not a Flutter release'),
      (
        'min_xcode_version',
        '"26.0.1.2"',
        'min_xcode_version is not an Xcode version',
      ),
      (
        'min_xcode_version',
        '"26.x"',
        'min_xcode_version is not an Xcode version',
      ),
    ]) {
      test('$key: $value is refused', () {
        final e = failure(flat('$key: $value\n'));
        expect(e.what, contains(said));
        expect(e.what, contains('line 3'));
      });
    }

    test('a refused value is never repeated in the message', () {
      final e = failure(flat('flutter_version: not-a-release-1.2.3\n'));
      expect(e.toJson().values.join('\n'), isNot(contains('not-a-release')));
    });

    test('a pre-release tag and the longest accepted values load', () {
      final app = load(
        flat(
          'flutter_version: 3.48.0-0.1.pre\n'
          'target: lib/${'a' * 55}.dart\n'
          'build_name: "1"\n'
          'min_xcode_version: "26"\n',
        ),
      ).apps.single;
      expect(app.flutterVersion, '3.48.0-0.1.pre');
      expect(app.target, hasLength(64));
      expect((app.buildName, app.minXcodeVersion), ('1', '26'));
    });

    test('flavor and configuration stay as they were', () {
      final app = load(flat('flavor: store\n')).apps.single;
      expect((app.flavor, app.configuration), ('store', 'Release-store'));
    });
  });

  group('workflow_inputs', () {
    test(
      'the names that build sets itself are refused, the four new ones too',
      () {
        for (final name in [
          'request_id',
          'flavor',
          'build_number',
          'build_name',
          'target',
          'flutter_version',
          'min_xcode_version',
        ]) {
          final e = failure(flat('workflow_inputs:\n  $name: x\n'));
          expect(e.what, contains('the workflow input "$name" is not allowed'));
          expect(e.why, contains('min_xcode_version'));
        }
      },
    );

    test('18 entries load and 19 are refused', () {
      String inputs(int n) =>
          'workflow_inputs:\n${[for (var i = 0; i < n; i++) '  input_$i: x\n'].join()}';
      expect(load(flat(inputs(18))).apps.single.workflowInputs, hasLength(18));
      final e = failure(flat(inputs(19)));
      expect(e.what, contains('workflow_inputs holds more than 18 inputs'));
      expect(e.why, contains('25'));
    });
  });

  group('redaction', () {
    test('the name of an app\'s token variable is hidden with the name', () {
      final redactor = Redactor(active: true);
      load(
        'defaults:\n  team_id: TEAM000001\n  credentials: team-one\n'
        'apps:\n'
        '  alpha:\n    bundle_id: com.example.alpha\n'
        '  alpha-dev:\n    bundle_id: com.example.alpha.dev\n',
        redactor: redactor,
      );
      expect(
        redactor.apply('WINCODE_GH_TOKEN_ALPHA_DEV and WINCODE_GH_TOKEN_ALPHA'),
        'WINCODE_GH_TOKEN_APP_2 and WINCODE_GH_TOKEN_APP_1',
      );
      expect(redactor.apply('alpha-dev builds'), 'app-2 builds');
    });
  });
}
