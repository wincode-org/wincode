import 'package:test/test.dart';
import 'package:wincode_cli/src/build_number.dart';
import 'package:wincode_cli/src/build_project.dart';

import 'fake_github.dart' show fakeRun, workflowText;

void main() {
  group('build numbers', () {
    test('are compared part by part as numbers, and a longer one with the same start is higher', () {
      expect(compareBuildNumbers('10', '9'), greaterThan(0));
      expect(compareBuildNumbers('1.0.1', '1.0'), greaterThan(0));
      expect(compareBuildNumbers('2', '10'), lessThan(0));
      expect(compareBuildNumbers('7', '7'), 0);
      expect(compareBuildNumbers('99999999999999999999', '1'), greaterThan(0));
    });

    test('highestNumber picks the highest, or none', () {
      expect(highestNumber(['9', '10', '8']), '10');
      expect(highestNumber(['57.1', '57']), '57.1');
      expect(highestNumber([]), isNull);
    });

    test('isDottedNumber takes one to three whole numbers', () {
      for (final ok in ['1', '58', '1.2', '1.2.3']) {
        expect(isDottedNumber(ok), isTrue, reason: ok);
      }
      for (final bad in [
        '',
        'a',
        '1.',
        '.1',
        '1.2.3.4',
        '1-2',
        ' 1',
        '1 ',
        '-1',
      ]) {
        expect(isDottedNumber(bad), isFalse, reason: bad);
      }
    });

    test('versions are compared with a missing part as zero', () {
      expect(compareVersions('26', '26.0.0'), 0);
      expect(compareVersions('26.4', '26.0'), greaterThan(0));
      expect(compareVersions('26.10', '26.9'), greaterThan(0));
      expect(compareVersions('16.4', '26.0'), lessThan(0));
      expect(compareVersions('26.0.1', '26.0'), greaterThan(0));
    });
  });

  group('the name of a run', () {
    test('carries the app tag, the version and the number', () {
      final tag = appTag('com.example.alpha');
      expect(tag, matches(r'^[0-9a-f]{12}$'));
      expect(
        appTag('COM.Example.Alpha'),
        tag,
        reason: 'the bundle ID in lower case',
      );
      expect(appTag('com.example.beta'), isNot(tag));
      final id = requestIdOf(
        tag: tag,
        version: '2.4.0',
        number: '58',
        random: '7c21e0aa',
      );
      expect(id, '$tag-2.4.0-58-7c21e0aa');
      expect(parseRunName('wincode $id'), (
        tag: tag,
        version: '2.4.0',
        number: '58',
      ));
    });

    test('is read back only in that shape', () {
      for (final name in [
        'wincode',
        'wincode ',
        'ci',
        'wincode 3f9a0c1d2b4e-2.4.0-58',
        'wincode 3F9A0C1D2B4E-2.4.0-58-7c21e0aa',
        'wincode 3f9a0c1d2b4e-2.4.0.1-58-7c21e0aa',
        'wincode 3f9a0c1d2b4e-2.4.0-58-7c21e0a',
        'xwincode 3f9a0c1d2b4e-2.4.0-58-7c21e0aa',
        'wincode abc-2.4.0-58-7c21e0aa',
      ]) {
        expect(parseRunName(name), isNull, reason: name);
      }
      expect(parseRunName('wincode 3f9a0c1d2b4e-1.2-3.4.5-00000000'), (
        tag: '3f9a0c1d2b4e',
        version: '1.2',
        number: '3.4.5',
      ));
    });

    test('randomHex is 8 hex digits and differs', () {
      expect(randomHex(), matches(r'^[0-9a-f]{8}$'));
      expect(
        {for (var i = 0; i < 20; i++) randomHex()}.length,
        greaterThan(15),
      );
    });
  });

  group('analyseRuns', () {
    final mine = appTag('com.example.alpha');
    final other = appTag('com.example.beta');
    String id(String tag, String number, {String version = '2.4.0'}) =>
        '$tag-$version-$number-0a0a0a0a';

    test(
      'a run that is going stops a build, and a success holds its number',
      () {
        final analysis = analyseRuns([
          fakeRun(
            1,
            id(mine, '57'),
            status: 'completed',
            conclusion: 'success',
          ),
          fakeRun(2, id(mine, '58'), status: 'in_progress', conclusion: null),
          fakeRun(3, id(other, '99'), status: 'in_progress', conclusion: null),
          fakeRun(
            4,
            id(mine, '12'),
            status: 'completed',
            conclusion: 'success',
          ),
        ], mine);
        expect([for (final r in analysis.active) r.id], ['2']);
        expect(analysis.active.single.number, '58');
        expect(analysis.active.single.url, contains('/runs/2'));
        expect(analysis.highestSuccessful, '57');
      },
    );

    test('a run that failed, was cancelled or never ran holds no number', () {
      final analysis = analyseRuns([
        fakeRun(1, id(mine, '60'), conclusion: 'failure'),
        fakeRun(2, id(mine, '61'), conclusion: 'cancelled'),
        fakeRun(3, id(mine, '62'), conclusion: 'skipped'),
        fakeRun(4, id(mine, '63'), conclusion: 'timed_out'),
      ], mine);
      expect(analysis.highestSuccessful, isNull);
      expect(analysis.active, isEmpty);
    });

    test('every status that has not ended counts as going', () {
      for (final status in [
        'queued',
        'in_progress',
        'waiting',
        'requested',
        'pending',
      ]) {
        final analysis = analyseRuns([
          fakeRun(1, id(mine, '5'), status: status, conclusion: null),
        ], mine);
        expect(analysis.active, hasLength(1), reason: status);
      }
    });

    test(
      'names of any other shape are ignored, and so is a run of another app',
      () {
        final analysis = analyseRuns([
          {
            'id': 9,
            'name': 'CI',
            'display_title': 'fix the build',
            'status': 'in_progress',
          },
          {
            'id': 10,
            'name': 'wincode ${id(mine, '70')}',
            'status': 'completed',
            'conclusion': 'success',
          },
          fakeRun(11, id(other, '71')),
        ], mine);
        expect(analysis.active, isEmpty);
        expect(
          analysis.highestSuccessful,
          '70',
          reason: 'the name is used when the title is missing',
        );
      },
    );
  });

  group('readWorkflow', () {
    test('reads the contract, the inputs, the runner and the Xcode', () {
      final facts = readWorkflow(workflowText);
      expect(facts.problem, isNull);
      expect(facts.contract, 2);
      expect(facts.inputs.keys, [
        'request_id',
        'build_name',
        'build_number',
        'flutter_version',
        'min_xcode_version',
        'flavor',
        'target',
      ]);
      expect(facts.inputs['request_id'], (required: true, hasDefault: false));
      expect(facts.inputs['flavor'], (required: false, hasDefault: true));
      expect(facts.runsOn, 'macos-26');
      expect(facts.timeoutMinutes, 45);
      expect(facts.xcodeApp, '/Applications/Xcode_26.6.app');
    });

    test('a workflow without the line is contract 1, and a number that is not one is none', () {
      expect(readWorkflow('name: x\non: workflow_dispatch\n').contract, isNull);
      expect(
        readWorkflow('# wincode-workflow-contract: two\nname: x\n').contract,
        isNull,
      );
      expect(
        readWorkflow('#wincode-workflow-contract:3\nname: x\n').contract,
        3,
      );
      expect(
        readWorkflow('  # wincode-workflow-contract: 2\nname: x\n').contract,
        isNull,
        reason: 'indented, so no contract line',
      );
    });

    test('on can be a name or a list, and a job can run on several labels', () {
      expect(readWorkflow('on: workflow_dispatch\njobs: {}\n').inputs, isEmpty);
      expect(readWorkflow('on: [push]\n').inputs, isEmpty);
      final facts = readWorkflow(
        'on:\n  workflow_dispatch:\njobs:\n  a:\n    runs-on: [self-hosted, macOS]\n    timeout-minutes: \${{ vars.T }}\n',
      );
      expect(facts.inputs, isEmpty);
      expect(facts.runsOn, 'self-hosted, macOS');
      expect(facts.timeoutMinutes, isNull);
    });

    test('XCODE_APP can be at the top or in a job, and the top wins', () {
      expect(
        readWorkflow(
          'env:\n  XCODE_APP: /Applications/Xcode_26.1.app\njobs:\n  a:\n    env:\n      XCODE_APP: /Applications/Xcode_26.2.app\n',
        ).xcodeApp,
        '/Applications/Xcode_26.1.app',
      );
      expect(
        readWorkflow(
          'jobs:\n  a:\n    env:\n      XCODE_APP: /Applications/Xcode_26.2.app\n',
        ).xcodeApp,
        '/Applications/Xcode_26.2.app',
      );
      expect(readWorkflow('jobs: {}\n').xcodeApp, isNull);
    });

    test('a file that is not YAML, or not a map, is a problem, with the contract still read', () {
      final bad = readWorkflow(
        '# wincode-workflow-contract: 2\n: : :\n  - [\n',
      );
      expect(bad.problem, isNotNull);
      expect(bad.contract, 2);
      expect(readWorkflow('- a\n- b\n').problem, 'it is not a map of keys');
    });

    test('xcodeVersionOf reads the version of the runner images\' path', () {
      expect(xcodeVersionOf('/Applications/Xcode_26.6.app'), '26.6');
      expect(xcodeVersionOf('/Applications/Xcode_26.app/'), '26');
      expect(xcodeVersionOf('/Applications/Xcode_16.4.1.app'), '16.4.1');
      expect(xcodeVersionOf('/Applications/Xcode.app'), isNull);
      expect(xcodeVersionOf('/Applications/Xcode_26.6_beta.app'), isNull);
      expect(xcodeVersionOf(r'${{ matrix.xcode }}'), isNull);
    });
  });

  group('readPubspec', () {
    test('reads the version and the Flutter constraint', () {
      final p = readPubspec(
        'name: demo\nversion: 2.3.0+57\nenvironment:\n  sdk: ^3.5.0\n  flutter: ">=3.27.0"\n',
      );
      expect(
        (p.name, p.number, p.flutterConstraint),
        ('2.3.0', '57', '>=3.27.0'),
      );
      expect(pubspecBuildNumber(p), '57');
    });

    test('a version without +N has no number, and one that Apple does not take is none', () {
      expect(readPubspec('version: 1.0.0\n').number, isNull);
      expect(pubspecBuildNumber(readPubspec('version: 1.0.0\n')), isNull);
      expect(pubspecBuildNumber(readPubspec('version: 1.0.0+abc\n')), isNull);
      expect(pubspecBuildNumber(readPubspec('version: 1.0.0+4.5\n')), '4.5');
      expect(readPubspec('name: x\n').name, isNull);
    });

    test('a version that YAML reads as a number is still read', () {
      expect(readPubspec('version: 1.5\n').name, '1.5');
    });

    test('a damaged file is a problem', () {
      expect(readPubspec('a: [\n').problem, isNotNull);
      expect(readPubspec('- x\n').problem, isNotNull);
    });
  });

  group('flutterAllows (pub\'s rules)', () {
    test('a release is allowed or not by the constraint', () {
      expect(flutterAllows('>=3.27.0', '3.47.7'), isTrue);
      expect(flutterAllows('>=3.27.0 <4.0.0', '3.47.7'), isTrue);
      expect(flutterAllows('>=3.50.0', '3.47.7'), isFalse);
      expect(flutterAllows('^3.27.0', '3.47.7'), isTrue);
      expect(flutterAllows('^3.27.0', '4.0.0'), isFalse);
      expect(flutterAllows('3.47.7', '3.47.7'), isTrue);
      expect(flutterAllows('any', '3.47.7'), isTrue);
    });

    test('a pre-release is allowed by a range that holds it', () {
      expect(flutterAllows('>=3.27.0 <4.0.0', '3.48.0-0.1.pre'), isTrue);
      expect(flutterAllows('>=3.48.0', '3.48.0-0.1.pre'), isFalse);
      expect(flutterAllows('>=3.48.0-0.0.pre', '3.48.0-0.1.pre'), isTrue);
    });

    test('a constraint or a version that does not parse is null', () {
      expect(flutterAllows('>= banana', '3.47.7'), isNull);
      expect(flutterAllows('>=3.27.0', 'main'), isNull);
    });
  });

  group('workflowDifferences', () {
    List<String> differences(String Function(String) change) =>
        workflowDifferences(change(workflowText), workflowText);

    test('the same file has none, and neither has one with CRLF line ends', () {
      expect(workflowDifferences(workflowText, workflowText), isEmpty);
      expect(
        workflowDifferences(
          workflowText.replaceAll('\n', '\r\n'),
          workflowText,
        ),
        isEmpty,
      );
    });

    test('the values of the owner are not differences: runs-on, timeout-minutes and XCODE_APP, at the top or in a job', () {
      expect(
        differences(
          (t) => t
              .replaceFirst('runs-on: macos-26', 'runs-on: [self-hosted, mac]')
              .replaceFirst('timeout-minutes: 45', 'timeout-minutes: 90')
              .replaceFirst('Xcode_26.6.app', 'Xcode_26.0.app'),
        ),
        isEmpty,
      );
      expect(
        differences(
          (t) => t
              .replaceFirst(
                '    env:\n      XCODE_APP: /Applications/Xcode_26.6.app   # a final Xcode 26 or later: App Store Connect refuses builds from others\n',
                '',
              )
              .replaceFirst(
                'permissions:',
                'env:\n  XCODE_APP: /Applications/Xcode_26.1.app\n\npermissions:',
              ),
        ),
        isEmpty,
        reason: 'XCODE_APP at the top of the file instead of the job',
      );
    });

    test('a comment, a blank line, the order of keys and the text of a description are not differences', () {
      expect(
        differences(
          (t) => t
              .replaceFirst(
                'name: wincode-ios\n',
                '# mine\n\n\nname: wincode-ios\n',
              )
              .replaceFirst(
                'description: The build number (CFBundleVersion)',
                'description: Das Build',
              )
              .replaceFirst('permissions:\n  contents: read\n\n', '')
              .replaceFirst(
                'name: wincode-ios\n',
                'permissions:\n  contents: read\nname: wincode-ios\n',
              )
              .replaceFirst(
                '        required: true\n        type: string\n      build_name:',
                '        type: string\n        required: true\n      build_name:',
              ),
        ),
        isEmpty,
      );
    });

    test('a changed step, input, pin or permission is named', () {
      expect(
        differences(
          (t) => t.replaceFirst(
            'xcodebuild -version\n',
            'xcodebuild -version -json\n',
          ),
        ),
        ['step "Xcode"'],
      );
      expect(
        differences((t) => t.replaceAll('required: false', 'required: true')),
        ['input flavor', 'input target'],
      );
      expect(
        differences(
          (t) => t
              .replaceFirst('v7.0.1', 'v7.0.1')
              .replaceFirst(
                '3d3c42e5aac5ba805825da76410c181273ba90b1',
                'a' * 40,
              ),
        ),
        ['step "actions/checkout"'],
        reason: 'a bumped pin names its step',
      );
      expect(
        differences((t) => t.replaceFirst('contents: read', 'contents: write')),
        ['permissions'],
      );
      expect(
        differences(
          (t) => t.replaceFirst('retention-days: 1', 'retention-days: 30'),
        ),
        ['step "actions/upload-artifact"'],
      );
      expect(
        differences(
          (t) => t.replaceFirst(
            'workflow_dispatch:',
            'push:\n  workflow_dispatch:',
          ),
        ),
        ['on'],
        reason: 'an added trigger is in on',
      );
      expect(
        differences(
          (t) => t.replaceFirst(
            "if: github.event_name == 'workflow_dispatch'",
            'if: true',
          ),
        ),
        ['job unsigned-ipa if'],
      );
    });

    test('an input or a step that was added or removed, a job that was added, and steps in another order are named', () {
      expect(
        differences(
          (t) => t.replaceFirst(
            '      target:\n',
            '      region:\n        required: false\n        type: string\n      target:\n',
          ),
        ),
        ['input region'],
      );
      expect(
        differences(
          (t) => t.replaceFirst(
            '      target:\n        description: The entry point, or empty for lib/main.dart\n        required: false\n        type: string\n        default: ""\n',
            '',
          ),
        ),
        ['input target'],
      );
      expect(
        differences(
          (t) => t.replaceFirst(
            '      - name: Flutter\n',
            '      - name: Lint\n        run: echo lint\n\n      - name: Flutter\n',
          ),
        ),
        ['step "Lint" (added)'],
      );
      expect(
        differences(
          (t) => t.replaceFirst(
            '      - name: Flutter\n        env:',
            '      - env:',
          ),
        ),
        ['step "Flutter" (missing)', 'step "step 3" (added)'],
      );
      expect(
        differences(
          (t) =>
              '$t\n  other:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo\n',
        ),
        ['job other'],
      );
    });

    test('a step without a name is named after its action', () {
      expect(
        differences(
          (t) => t.replaceFirst(
            'actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2',
            'actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2\n        id: up',
          ),
        ),
        ['step "actions/upload-artifact"'],
      );
    });

    test('steps in another order are named once', () {
      expect(
        differences((t) {
          // The Flutter step goes before the Xcode step.
          final flutterStep = t.substring(
            t.indexOf('      - name: Flutter\n'),
            t.indexOf('      - name: Build'),
          );
          return t
              .replaceFirst(flutterStep, '')
              .replaceFirst(
                '      - name: Xcode\n',
                '$flutterStep      - name: Xcode\n',
              );
        }),
        ['the order of the steps'],
      );
    });
  });
}
