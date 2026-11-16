import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_cli/src/build_project.dart';
import 'package:wincode_cli/src/init_workflow.dart' show workflowOwnerPatterns;
import 'package:wincode_cli/src/workflow_template.g.dart';
import 'package:yaml/yaml.dart';

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

  group('contract 2', () {
    final root = loadYaml(workflowTemplate) as YamlMap;
    final job = (root['jobs'] as YamlMap)['unsigned-ipa'] as YamlMap;
    final steps = [for (final s in job['steps'] as YamlList) s as YamlMap];
    YamlMap step(String name) => steps.firstWhere((s) => s['name'] == name);

    test('declares the contract and the seven inputs of wincode build', () {
      final facts = readWorkflow(workflowTemplate);
      expect(facts.problem, isNull);
      expect(facts.contract, workflowContract);
      expect(facts.inputs, {
        'request_id': (required: true, hasDefault: false),
        'build_name': (required: true, hasDefault: false),
        'build_number': (required: true, hasDefault: false),
        'flutter_version': (required: true, hasDefault: false),
        'min_xcode_version': (required: true, hasDefault: false),
        'flavor': (required: false, hasDefault: true),
        'target': (required: false, hasDefault: true),
      });
      expect(facts.runsOn, 'macos-26');
      expect(facts.timeoutMinutes, 45);
      expect(facts.xcodeApp, '/Applications/Xcode_26.6.app');
      expect(
        facts.flutterVersion,
        isNull,
        reason: 'the Flutter release is an input',
      );
      expect(facts.flavor, isNull, reason: 'the flavor is an input');
      expect(
        workflowTemplate.split('\n').first,
        '# wincode-workflow-contract: 2',
      );
      expect(root['run-name'], r'wincode ${{ inputs.request_id }}');
    });

    test('every input is a string', () {
      final inputs =
          ((root['on'] as YamlMap)['workflow_dispatch'] as YamlMap)['inputs']
              as YamlMap;
      for (final MapEntry(:key, :value) in inputs.entries) {
        expect((value as YamlMap)['type'], 'string', reason: '$key');
      }
    });

    test('exactly two actions, each pinned to a commit, with its release in a comment', () {
      final uses = RegExp(
        r'^\s*-?\s*uses: (\S+)(.*)$',
        multiLine: true,
      ).allMatches(workflowTemplate).toList();
      expect(uses.map((m) => m[1]!.split('@').first), [
        'actions/checkout',
        'actions/upload-artifact',
      ]);
      for (final m in uses) {
        expect(m[1], matches(RegExp(r'^[\w.\-]+/[\w.\-]+@[0-9a-f]{40}$')));
        expect(m[2], matches(RegExp(r'^ # v\d+\.\d+\.\d+$')));
      }
    });

    test('an input is never read inside a run: block, only through env', () {
      for (final s in steps) {
        final run = s['run'];
        if (run == null) continue;
        expect(run, isNot(contains(r'${{')), reason: '${s['name']}');
      }
      final env = <String, Object?>{
        for (final s in steps)
          if (s['env'] is YamlMap)
            for (final e in (s['env'] as YamlMap).entries) '${e.key}': e.value,
      };
      expect(
        env.keys,
        containsAll([
          'MIN_XCODE_VERSION',
          'FLUTTER_VERSION',
          'BUILD_NAME',
          'BUILD_NUMBER',
          'FLAVOR',
          'TARGET',
        ]),
      );
      expect(env['BUILD_NUMBER'], r'${{ inputs.build_number }}');
    });

    test('no secret reaches the runner: read-only contents, no credentials kept, no token', () {
      expect(root['permissions'], {'contents': 'read'});
      final uncommented = workflowTemplate
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('#'))
          .join('\n');
      expect(uncommented, isNot(contains('secrets')));
      expect(uncommented, isNot(contains('github.token')));
      expect(uncommented, isNot(contains('GITHUB_TOKEN')));
      expect((steps.first['with'] as YamlMap)['persist-credentials'], false);
    });

    test('the artifact holds the IPA and its hash, for one day, and fails when empty', () {
      final input = steps.last['with'] as YamlMap;
      expect(input['name'], 'unsigned-ipa');
      expect(input['retention-days'], 1);
      expect(input['if-no-files-found'], 'error');
      expect(
        (input['path'] as String).trim().split('\n').map((l) => l.trim()),
        [
          r'${{ runner.temp }}/unsigned.ipa',
          r'${{ runner.temp }}/unsigned.ipa.sha256',
        ],
      );
      final package =
          step('Package the app as an unsigned IPA')['run'] as String;
      expect(
        package,
        contains('shasum -a 256 unsigned.ipa | tee unsigned.ipa.sha256'),
      );
      expect(package, contains(r'>> "$GITHUB_STEP_SUMMARY"'));
    });

    test(
      'the Flutter release is cloned shallow from its tag, with no action',
      () {
        expect(
          step('Flutter')['run'],
          contains(
            r'git clone -q --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git',
          ),
        );
      },
    );

    test('the build passes the version and number, and the flavor and target when set', () {
      final run = step('Build the archive, unsigned')['run'] as String;
      expect(
        run,
        contains(r'--build-name "$BUILD_NAME" --build-number "$BUILD_NUMBER"'),
      );
      expect(
        run,
        contains(r'if [ -n "$FLAVOR" ]; then args+=(--flavor "$FLAVOR"); fi'),
      );
      expect(
        run,
        contains(r'if [ -n "$TARGET" ]; then args+=(--target "$TARGET"); fi'),
      );
    });

    test(
      'the three values the owner sets each match one line of the template',
      () {
        expect(workflowOwnerPatterns.keys, [
          'runs-on',
          'timeout-minutes',
          'XCODE_APP',
        ]);
        for (final MapEntry(:key, :value) in workflowOwnerPatterns.entries) {
          expect(value.allMatches(workflowTemplate), hasLength(1), reason: key);
        }
      },
    );
  });

  group('the Xcode step, run by sh with stubs for sudo and xcodebuild', () {
    // The step must say the same under GNU and BSD awk, so it is run with every awk this machine has. macOS's own awk
    // (the BSD one) is not among them on Linux: the first real run on a macOS runner is the test of it.
    final steps =
        ((loadYaml(workflowTemplate) as YamlMap)['jobs']
                as YamlMap)['unsigned-ipa']['steps']
            as YamlList;
    final run = steps.firstWhere((s) => s['name'] == 'Xcode')['run'] as String;

    String? find(String name) {
      // WINCODE_TEST_AWK_DIRS: more folders to look in, such as one that holds an unpacked original-awk or busybox.
      for (final dir in [
        '/usr/bin',
        '/bin',
        '/usr/local/bin',
        ...?Platform.environment['WINCODE_TEST_AWK_DIRS']?.split(':'),
      ]) {
        if (File('$dir/$name').existsSync()) return '$dir/$name';
      }
      return null;
    }

    final awks = <String, List<String>>{
      for (final name in ['awk', 'mawk', 'gawk', 'original-awk', 'nawk'])
        if (find(name) != null) name: [find(name)!],
      if (find('busybox') != null) 'busybox awk': [find('busybox')!, 'awk'],
    };
    final skip = Platform.isWindows ? 'needs sh and awk: runs on Linux' : null;

    Future<(int, String)> runStep(
      List<String> awk,
      String have,
      String min,
    ) async {
      final dir = Directory.systemTemp.createTempSync('wincode-xcode');
      try {
        void script(String name, String body) {
          final f = File('${dir.path}/$name')
            ..writeAsStringSync('#!/bin/sh\n$body\n');
          Process.runSync('chmod', ['+x', f.path]);
        }

        script('sudo', 'exit 0');
        script(
          'xcodebuild',
          r'printf "Xcode %s\nBuild version 17F113\n" "$STUB_XCODE"',
        );
        script('awk', 'exec ${awk.map((a) => "'$a'").join(' ')} "\$@"');
        final result = await Process.run(
          'sh',
          ['-c', run],
          environment: {
            'PATH': '${dir.path}:/usr/bin:/bin',
            'XCODE_APP': '/Applications/Xcode_26.6.app',
            'MIN_XCODE_VERSION': min,
            'STUB_XCODE': have,
          },
          includeParentEnvironment: false,
        );
        return (result.exitCode, '${result.stdout}${result.stderr}');
      } finally {
        dir.deleteSync(recursive: true);
      }
    }

    test(
      'there is an awk to test with',
      () => expect(awks, isNotEmpty),
      skip: skip,
    );

    for (final MapEntry(key: name, value: awk) in awks.entries) {
      test('compares the versions number by number, with $name', () async {
        for (final (have, min, ok) in [
          ('26.6', '26.0', true),
          ('26.6', '26.6', true),
          ('26.6', '26.7', false),
          ('26.10', '26.9', true),
          ('26.9', '26.10', false),
          ('26.4.1', '26.4', true),
          ('26.4', '26.4.1', false),
          ('26.0', '26.0.0', true),
          ('26', '26.0', true),
          ('26', '26.0.1', false),
          ('27.0', '26.99', true),
          ('25.99', '26', false),
          ('100.0', '9.5', true),
          ('9.5', '100.0', false),
          ('26.1', '26', true),
        ]) {
          final (code, output) = await runStep(awk, have, min);
          expect(code == 0, ok, reason: 'Xcode $have against $min: $output');
          if (!ok) {
            expect(
              output,
              contains(
                '::error::Xcode $have is older than $min, the oldest that wincode.yaml allows',
              ),
            );
          }
        }
      }, skip: skip);
    }

    test('an Xcode that prints no version is older than any minimum', () async {
      final (code, output) = await runStep(awks.values.first, '', '26.0');
      expect(code, 1, reason: output);
      expect(output, contains('::error::'));
    }, skip: skip);
  });
}
