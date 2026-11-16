import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_cli/src/build_project.dart';
import 'package:wincode_cli/src/init.dart';
import 'package:wincode_cli/src/init_workflow.dart';
import 'package:wincode_cli/src/workflow_template.g.dart';
import 'package:wincode_cli/wincode_cli.dart';
import 'package:wincode_core/wincode_core.dart' show RunProcess;
import 'package:yaml/yaml.dart';

/// ADR-0015, section 8: `init --workflow` writes the reference workflow to a new file, and updates an existing one after a
/// diff and a question, keeping the owner's three values and the old file as a `.bak`, and touching nothing else.
void main() {
  late Directory temp;
  late Directory project;
  final sep = Platform.pathSeparator;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('wincode_workflow_');
    project = Directory('${temp.path}${sep}project')..createSync();
    File('${project.path}${sep}pubspec.yaml').writeAsStringSync('name: demo\n');
    Directory('${project.path}${sep}ios').createSync();
  });
  tearDown(() => temp.deleteSync(recursive: true));

  File workflowFile() =>
      File('${project.path}$sep.github${sep}workflows${sep}wincode-ios.yml');
  File bakFile() => File('${workflowFile().path}.bak');
  File yamlFile() => File('${project.path}${sep}wincode.yaml');

  /// The contract 1 workflow of winCode 0.x, as a repository would have it, with the three values of its owner changed.
  final contract1 = _contract1
      .replaceFirst('runs-on: macos-26', 'runs-on: ubuntu-24.04')
      .replaceFirst('timeout-minutes: 45', 'timeout-minutes: 5')
      .replaceFirst('Xcode_26.6.app', 'Xcode_26.0.app')
      .replaceFirst('"3.47.7"', '"3.32.8"');

  void putWorkflow(String text) {
    workflowFile()
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  Future<(int, String, String)> init(
    List<String> args, {
    Map<String, String> environment = const {},
    bool terminal = false,
    List<String> answers = const [],
    RunProcess? run,
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final queue = [...answers];
    final code = await runWincode(
      ['init', ...args],
      out,
      err,
      environment: environment,
      workingDirectory: project,
      terminal: terminal,
      run:
          run ??
          (_, _, {workingDirectory}) => throw StateError('no program may run'),
      readLine: () {
        if (queue.isEmpty) return null;
        final line = queue.removeAt(0);
        out.writeln(line);
        return line;
      },
    );
    return (code, '$out', '$err');
  }

  Map<String, Object?> json(String out) =>
      jsonDecode(out) as Map<String, Object?>;

  /// Every file under the project, by path, with its bytes.
  Map<String, List<int>> tree() => {
    for (final f in project.listSync(recursive: true).whereType<File>())
      f.path.substring(project.path.length): f.readAsBytesSync(),
  };

  const flat = '''# My project
bundle_id: com.example.alpha   # the app that shipped
team_id: TEAM000001

output: out/alpha
''';

  const apps = '''# My apps. Do not reorder.
defaults:
  team_id: TEAM000001   # the team of all of them
  credentials: team-one

apps:
  alpha:
    bundle_id: com.example.alpha   # the first
  beta:
    bundle_id: com.example.beta
''';

  group('a workflow that is there', () {
    test('is updated: the template, with its XCODE_APP, runs-on and timeout-minutes', () async {
      putWorkflow(contract1);
      yamlFile().writeAsStringSync(flat);
      final (code, out, err) = await init(['--workflow', '--yes']);
      expect(code, 0, reason: err);
      final now = workflowFile().readAsStringSync();
      expect(now, contains('# wincode-workflow-contract: 2'));
      expect(now, contains('runs-on: ubuntu-24.04'));
      expect(now, contains('timeout-minutes: 5\n'));
      expect(now, contains('XCODE_APP: /Applications/Xcode_26.0.app'));
      expect(
        now,
        workflowTemplate
            .replaceFirst('runs-on: macos-26', 'runs-on: ubuntu-24.04')
            .replaceFirst('timeout-minutes: 45', 'timeout-minutes: 5')
            .replaceFirst('Xcode_26.6.app', 'Xcode_26.0.app'),
        reason: 'the template and three lines',
      );
      expect(bakFile().readAsStringSync(), contract1);
      expect(
        out,
        contains(
          'note: kept from the old file: XCODE_APP /Applications/Xcode_26.0.app, runs-on ubuntu-24.04, timeout-minutes 5.',
        ),
      );
      expect(out, contains('Kept the original as wincode-ios.yml.bak.'));
      expect(out, contains('init runs no git command'));
    });

    test('moves FLUTTER_VERSION into a flat wincode.yaml, and into the defaults of a file of apps, with the comments kept', () async {
      putWorkflow(contract1);
      yamlFile().writeAsStringSync(flat);
      var (code, out, err) = await init(['--workflow', '--yes']);
      expect(code, 0, reason: err);
      expect(yamlFile().readAsStringSync(), '${flat}flutter_version: 3.32.8\n');
      expect(
        out,
        contains('Wrote wincode.yaml: added flutter_version 3.32.8.'),
      );

      putWorkflow(contract1);
      bakFile().deleteSync();
      yamlFile().writeAsStringSync(apps);
      (code, out, err) = await init(['--workflow', '--yes']);
      expect(code, 0, reason: err);
      final after = yamlFile().readAsStringSync();
      expect(after, startsWith('# My apps. Do not reorder.\n'));
      expect(
        after,
        contains('team_id: TEAM000001   # the team of all of them'),
      );
      expect(after, contains('bundle_id: com.example.alpha   # the first'));
      expect(after, contains('  flutter_version: 3.32.8\n'));
      expect(
        (loadYaml(after) as Map)['defaults'],
        containsPair('flutter_version', '3.32.8'),
      );
    });

    test('leaves flutter_version alone when wincode.yaml has one, and says which wins when they differ', () async {
      putWorkflow(contract1);
      yamlFile().writeAsStringSync('${flat}flutter_version: 3.47.7\n');
      var (code, out, err) = await init(['--workflow', '--yes']);
      expect(code, 0, reason: err);
      expect(yamlFile().readAsStringSync(), '${flat}flutter_version: 3.47.7\n');
      expect(
        out,
        contains(
          'note: wincode.yaml already sets flutter_version 3.47.7, and the old workflow had 3.32.8: wincode.yaml wins.',
        ),
      );
      expect(out, isNot(contains('Wrote wincode.yaml')));

      putWorkflow(contract1.replaceFirst('"3.32.8"', '"3.47.7"'));
      bakFile().deleteSync();
      (code, out, err) = await init(['--workflow', '--yes']);
      expect(code, 0, reason: err);
      expect(out, isNot(contains('wins')));
    });

    test('without a wincode.yaml, says to set flutter_version by hand, and writes nothing else', () async {
      putWorkflow(contract1);
      final (code, out, err) = await init(['--workflow', '--yes']);
      expect(code, 0, reason: err);
      expect(yamlFile().existsSync(), isFalse);
      expect(
        out,
        contains(
          'note: the old file had FLUTTER_VERSION 3.32.8, which wincode.yaml holds now: set flutter_version: 3.32.8 there.',
        ),
      );
      expect(
        out,
        contains(
          'Before the first wincode build, add flutter_version and min_xcode_version to wincode.yaml',
        ),
      );
    });

    test('a value that is not well formed is not kept, and the output says what the file has instead', () async {
      putWorkflow(
        contract1
            .replaceFirst('ubuntu-24.04', '[self-hosted, macOS]')
            .replaceFirst('Xcode_26.0.app', r'Xcode ${{ matrix.x }}.app')
            .replaceFirst('timeout-minutes: 5', 'timeout-minutes: 0')
            .replaceFirst('"3.32.8"', '"stable"'),
      );
      final (code, out, err) = await init(['--workflow', '--yes']);
      expect(code, 0, reason: err);
      expect(workflowFile().readAsStringSync(), workflowTemplate);
      expect(
        out,
        contains(
          'note: XCODE_APP "/Applications/Xcode \${{ matrix.x }}.app" of the old file was not kept (it is not /Applications/<name>.app), so the new one has /Applications/Xcode_26.6.app.',
        ),
      );
      expect(
        out,
        contains(
          'note: runs-on "self-hosted, macOS" of the old file was not kept (it is not one runner label), so the new one has macos-26.',
        ),
      );
      expect(
        out,
        contains(
          'note: timeout-minutes "0" of the old file was not kept (it is not a whole number of 1 to 999), so the new one has 45.',
        ),
      );
      expect(
        out,
        contains(
          'note: FLUTTER_VERSION "stable" of the old file is not a Flutter release, so it was not moved to wincode.yaml.',
        ),
      );
    });

    test(
      'a FLAVOR that is not empty is named in a note, and moves nowhere',
      () async {
        putWorkflow(contract1.replaceFirst('FLAVOR: ""', 'FLAVOR: store'));
        yamlFile().writeAsStringSync(flat);
        final (_, out, _) = await init(['--workflow', '--yes']);
        expect(
          out,
          contains(
            'note: the old file builds the flavor "store" through FLAVOR, which the new one takes as an input: set flavor: store in wincode.yaml.',
          ),
        );
        expect(yamlFile().readAsStringSync(), isNot(contains('flavor')));
      },
    );

    test('the update, before and after, is test/goldens/init-workflow.txt (UPDATE_GOLDENS=1 rewrites it)', () async {
      putWorkflow(contract1);
      yamlFile().writeAsStringSync(flat);
      final (_, out, _) = await init(['--workflow', '--yes']);
      final report = StringBuffer()
        ..writeln('# before: wincode.yaml')
        ..write(flat)
        ..writeln('# wincode init --workflow --yes')
        ..write(out)
        ..writeln('# after: wincode.yaml')
        ..write(yamlFile().readAsStringSync())
        ..writeln(
          '# after: wincode-ios.yml.bak is the file before, byte for byte',
        )
        ..writeln(bakFile().readAsStringSync() == contract1);
      final golden = File('test/goldens/init-workflow.txt');
      if (Platform.environment['UPDATE_GOLDENS'] != null) {
        golden.writeAsStringSync('$report');
      }
      expect('$report', golden.readAsStringSync().replaceAll('\r\n', '\n'));
    });

    test('that equals what init would write is up to date: nothing is written, and no backup', () async {
      putWorkflow(workflowTemplate);
      yamlFile().writeAsStringSync(flat);
      final before = tree();
      final (code, out, err) = await init(['--workflow', '--yes', '--json']);
      expect(code, 0, reason: err);
      expect(json(out), containsPair('workflow', 'up-to-date'));
      expect(json(out), containsPair('written', false));
      expect(tree(), before);
      expect(err, contains('is already up to date.'));
    });

    test('with the template\'s own values under CRLF is up to date too; with other lines it is changed, and the backup keeps the old bytes', () async {
      putWorkflow(workflowTemplate);
      workflowFile().writeAsStringSync(
        workflowTemplate.replaceAll('\n', '\r\n'),
      );
      var (code, out, err) = await init(['--workflow', '--yes']);
      expect(code, 0, reason: err);
      expect(out, contains('already up to date'));
      expect(bakFile().existsSync(), isFalse);

      final crlf = utf8.encode(contract1.replaceAll('\n', '\r\n'));
      workflowFile().writeAsBytesSync(crlf);
      (code, out, err) = await init(['--workflow', '--yes']);
      expect(code, 0, reason: err);
      expect(bakFile().readAsBytesSync(), crlf);
      expect(workflowFile().readAsStringSync(), isNot(contains('\r')));
    });

    test('is not written without a yes where init cannot ask, and nothing is written', () async {
      putWorkflow(contract1);
      yamlFile().writeAsStringSync(flat);
      final before = tree();
      for (final args in [
        ['--workflow'],
        ['--workflow', '--json'],
        ['--workflow', '--force'],
      ]) {
        final (code, out, err) = await init(args);
        expect(code, 64, reason: '$args');
        if (args.contains('--json')) {
          expect(json(out)['error'], containsPair('id', 'init-input-missing'));
        } else {
          expect(
            err,
            contains(
              'init changes an existing workflow only after you confirm',
            ),
          );
        }
        expect(tree(), before, reason: '$args');
      }
      // The diff comes first, so that the next run is an informed one.
      final (_, out, err) = await init(['--workflow']);
      expect(
        out,
        contains(
          'Changes init would make to .github/workflows/wincode-ios.yml',
        ),
      );
      expect(err, contains('--force is not a yes'));
    });

    test('is asked at a terminal, and only y or yes writes it', () async {
      putWorkflow(contract1);
      yamlFile().writeAsStringSync(flat);
      final before = tree();
      for (final answer in ['', 'n', 'no', 'maybe']) {
        final (code, out, err) = await init(
          ['--workflow'],
          terminal: true,
          answers: [answer],
        );
        expect(code, 0, reason: '"$answer": $err');
        expect(
          out,
          contains(
            'Write .github/workflows/wincode-ios.yml and wincode.yaml? [y/N] ',
          ),
        );
        expect(out, contains('Nothing was written.'));
        expect(tree(), before, reason: '"$answer"');
      }
      for (final answer in ['y', 'YES']) {
        putWorkflow(contract1);
        if (bakFile().existsSync()) bakFile().deleteSync();
        yamlFile().writeAsStringSync(flat);
        final (code, _, err) = await init(
          ['--workflow'],
          terminal: true,
          answers: [answer],
        );
        expect(code, 0, reason: err);
        expect(bakFile().readAsStringSync(), contract1);
      }
    });

    test(
      '--json says what was done: the workflow, the backup, and the key moved',
      () async {
        putWorkflow(contract1);
        yamlFile().writeAsStringSync(flat);
        final (code, out, err) = await init(['--workflow', '--yes', '--json']);
        expect(code, 0, reason: err);
        expect(json(out), {
          'command': 'init',
          'app': null,
          'ok': true,
          'exitCode': 0,
          'dryRun': false,
          'written': true,
          'backup': 'wincode-ios.yml.bak',
          'config': {'flutter_version': '3.32.8'},
          'workflow': 'updated',
        });
      },
    );

    test(
      '--dry-run shows the changes and writes nothing, and asks nothing',
      () async {
        putWorkflow(contract1);
        yamlFile().writeAsStringSync(flat);
        final before = tree();
        final (code, out, err) = await init(['--workflow', '--dry-run']);
        expect(code, 0, reason: err);
        expect(
          out,
          contains(
            'Changes init would make to .github/workflows/wincode-ios.yml',
          ),
        );
        expect(out, contains('Changes init would make to wincode.yaml'));
        expect(out, contains('+ flutter_version: 3.32.8'));
        expect(
          out,
          contains('Dry run: nothing was written, and no backup was made.'),
        );
        expect(tree(), before);
        final (_, jsonOut, _) = await init([
          '--workflow',
          '--dry-run',
          '--json',
        ]);
        expect(json(jsonOut), containsPair('workflow', 'would-update'));
        expect(json(jsonOut), containsPair('written', false));
      },
    );

    test('stops at an existing backup, and replaces it with --force', () async {
      putWorkflow(contract1);
      bakFile().writeAsStringSync('an earlier backup');
      final before = tree();
      var (code, out, err) = await init(['--workflow', '--yes', '--json']);
      expect(code, 1);
      expect(json(out)['error'], containsPair('id', 'backup-exists'));
      expect(
        (json(out)['error']! as Map)['why'],
        'init keeps the original of the workflow as wincode-ios.yml.bak, and never replaces an earlier backup unasked.',
      );
      expect(tree(), before);
      (code, out, err) = await init(['--workflow', '--yes', '--force']);
      expect(code, 0, reason: err);
      expect(bakFile().readAsStringSync(), contract1);
    });

    test('that is not a workflow is refused: workflow-unreadable', () async {
      for (final bad in ['- a\n- b\n', 'on: [\n', 'just text']) {
        putWorkflow(bad);
        final (code, out, _) = await init(['--workflow', '--yes', '--json']);
        expect(code, 78, reason: bad);
        expect(json(out)['error'], containsPair('id', 'workflow-unreadable'));
        expect(workflowFile().readAsStringSync(), bad);
      }
      workflowFile().writeAsBytesSync([0xFF, 0xFE, 0x41]);
      final (code, out, _) = await init(['--workflow', '--yes', '--json']);
      expect(code, 78);
      expect(json(out)['error'], containsPair('id', 'workflow-unreadable'));
    });

    test('that says a newer contract is not downgraded', () async {
      putWorkflow('# wincode-workflow-contract: 3\n$contract1');
      final before = tree();
      final (code, out, _) = await init(['--workflow', '--yes', '--json']);
      expect(code, 78);
      expect(json(out)['error'], containsPair('id', 'workflow-contract'));
      expect(tree(), before);
    });

    test('with --app is refused: the update is a run of its own', () async {
      putWorkflow(contract1);
      final before = tree();
      final (code, out, _) = await init([
        '--app',
        'alpha',
        '--workflow',
        '--bundle-id',
        'com.example.alpha',
        '--credentials',
        'team-one',
        '--team-id',
        'TEAM000001',
        '--yes',
        '--json',
      ]);
      expect(code, 1);
      expect(json(out)['error'], containsPair('id', 'workflow-exists'));
      expect(
        (json(out)['error']! as Map)['next'],
        contains('wincode init --workflow alone'),
      );
      expect(tree(), before);
    });

    test(
      'is not told what describes wincode.yaml: those options are refused',
      () async {
        putWorkflow(contract1);
        yamlFile().writeAsStringSync(flat);
        final before = tree();
        for (final option in [
          ['--bundle-id', 'com.example.alpha'],
          ['--team-id', 'TEAM000001'],
          ['--profile', 'a.mobileprovision'],
          ['--profile-dir', 'p'],
          ['--entitlements', 'a.entitlements'],
          ['--workflow-ref', 'o/r/.github/workflows/wincode-ios.yml@main'],
          ['--output', 'out'],
          ['--flavor', 'alpha'],
          ['--configuration', 'Release-alpha'],
          ['--credentials', 'team-one'],
        ]) {
          final (code, out, _) = await init([
            '--workflow',
            '--yes',
            '--json',
            ...option,
          ]);
          expect(code, 64, reason: '$option');
          expect(json(out)['error'], containsPair('id', 'init-value-invalid'));
          expect(tree(), before, reason: '$option');
        }
      },
    );

    test('touches nothing but its three files, runs no program, and leaves the git folder alone', () async {
      putWorkflow(contract1);
      yamlFile().writeAsStringSync(flat);
      File('${project.path}${sep}lib${sep}main.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}\n');
      File('${project.path}$sep.gitignore').writeAsStringSync('build/\n');
      Directory('${project.path}$sep.git').createSync();
      File('${project.path}$sep.git${sep}HEAD').writeAsStringSync('ref: x\n');
      File('${project.path}$sep.github${sep}workflows${sep}other.yml')
          .writeAsStringSync('name: other\n');
      final before = tree();
      final (code, _, err) = await init(['--workflow', '--yes']);
      expect(code, 0, reason: err);
      final after = tree();
      final changed = {
        for (final k in {...before.keys, ...after.keys})
          if (before[k]?.join(',') != after[k]?.join(',')) k,
      };
      expect(changed, {
        '$sep.github${sep}workflows${sep}wincode-ios.yml',
        '$sep.github${sep}workflows${sep}wincode-ios.yml.bak',
        '${sep}wincode.yaml',
      });
    });
  });

  group('a workflow that is not there', () {
    test('is written byte for byte next to an existing wincode.yaml, which is not touched', () async {
      for (final text in [flat, apps]) {
        if (workflowFile().existsSync()) workflowFile().deleteSync();
        yamlFile().writeAsStringSync(text);
        final (code, out, err) = await init(['--workflow']);
        expect(code, 0, reason: err);
        expect(workflowFile().readAsStringSync(), workflowTemplate);
        expect(yamlFile().readAsStringSync(), text);
        expect(
          out,
          contains(
            'Copied the reference workflow to .github/workflows/wincode-ios.yml.',
          ),
        );
        expect(
          out,
          contains(
            'Before the first wincode build, add flutter_version and min_xcode_version to wincode.yaml',
          ),
        );
        expect(bakFile().existsSync(), isFalse);
      }
    });

    test(
      'with --dry-run is only said, and with --json is copied or would-copy',
      () async {
        yamlFile().writeAsStringSync(flat);
        var (code, out, _) = await init(['--workflow', '--dry-run', '--json']);
        expect(code, 0);
        expect(json(out), containsPair('workflow', 'would-copy'));
        expect(json(out), containsPair('written', false));
        expect(workflowFile().existsSync(), isFalse);
        (code, out, _) = await init(['--workflow', '--json']);
        expect(json(out), containsPair('workflow', 'copied'));
        expect(json(out), containsPair('written', true));
      },
    );

    test(
      'does not ask for the options of wincode.yaml: they are refused',
      () async {
        yamlFile().writeAsStringSync(flat);
        final (code, out, _) = await init([
          '--workflow',
          '--bundle-id',
          'com.example.alpha',
          '--json',
        ]);
        expect(code, 64);
        expect(json(out)['error'], containsPair('id', 'init-value-invalid'));
        expect(workflowFile().existsSync(), isFalse);
      },
    );

    test(
      'says what a wincode.yaml that does not load says, and writes nothing',
      () async {
        yamlFile().writeAsStringSync('bundle_id: [\n');
        final (code, out, _) = await init(['--workflow', '--json']);
        expect(code, isNot(0));
        expect(json(out)['error'], isNotNull);
        expect(workflowFile().existsSync(), isFalse);
      },
    );
  });

  group('a write that fails', () {
    Initializer initializer(
      void Function(File, String) writeFile, {
      bool force = false,
    }) => Initializer(
      options: InitOptions(yes: true, copyWorkflow: true, force: force),
      cwd: project,
      redactor: Redactor(active: false),
      report: StringBuffer(),
      readLine: () => null,
      interactive: false,
      clock: DateTime.now,
      writeFile: writeFile,
    );

    test('puts back the workflow, the backup and wincode.yaml', () async {
      putWorkflow(contract1);
      yamlFile().writeAsStringSync(flat);
      bakFile().writeAsStringSync('an earlier backup');
      final before = tree();
      final i = initializer((file, text) {
        if (file.path.endsWith('wincode-ios.yml')) {
          file.writeAsStringSync('half');
          throw const FileSystemException('disk full');
        }
        file.writeAsStringSync(text);
      }, force: true);
      await expectLater(
        i.execute(),
        throwsA(
          isA<WincodeException>().having(
            (e) => e.id,
            'id',
            'workflow-unwritable',
          ),
        ),
      );
      expect(tree(), before);
    });

    test('removes a backup that it made', () async {
      putWorkflow(contract1);
      final before = tree();
      final i = initializer(
        (file, text) => throw const FileSystemException('read-only'),
      );
      await expectLater(i.execute(), throwsA(isA<WincodeException>()));
      expect(tree(), before);
      expect(bakFile().existsSync(), isFalse);
    });
  });

  group('updateWorkflow', () {
    test('is the template when the old file has the template\'s values', () {
      final update = updateWorkflow(
        workflowTemplate,
        readWorkflow(workflowTemplate),
      );
      expect(update.text, workflowTemplate);
      expect(update.notes, isEmpty);
      expect(update.flutterVersion, isNull);
    });

    test('names each value that is missing, as one that was not kept', () {
      final update = updateWorkflow(
        workflowTemplate,
        readWorkflow('name: x\n'),
      );
      expect(update.text, workflowTemplate);
      expect(update.notes, hasLength(3));
      expect(
        update.notes.first,
        'the old file has no XCODE_APP that init can read, so the new one has /Applications/Xcode_26.6.app',
      );
    });
  });
}

/// The workflow of contract 1, which the reference workflow was before ADR-0015, part 5c.
const _contract1 = r'''# The reference workflow for `wincode build` (winCode ADR-0013): it builds the app's unsigned IPA with Xcode on a
# GitHub-hosted macOS runner. Copy it to .github/workflows/wincode-ios.yml in the app's repository, set the three values
# under env, and name it in wincode.yaml:
#   workflow: <owner>/<repository>/.github/workflows/wincode-ios.yml@<branch>
#
# What wincode build relies on, so keep these three:
#   - the request_id input, and the run name that carries it (winCode finds its run by that name);
#   - one artifact named unsigned-ipa that holds one .ipa with Payload/<name>.app inside;
#   - no signing: the runner holds no certificate, profile or App Store Connect key. winCode signs on Windows.
#
# Artifacts: in a public repository anyone who can read it can download the IPA until it expires, after 1 day.
name: wincode-ios
run-name: wincode ${{ inputs.request_id }}

on:
  workflow_dispatch:
    inputs:
      request_id:
        description: Set by wincode build, which finds this run by it
        required: true
        type: string

permissions:
  contents: read

jobs:
  unsigned-ipa:
    # macOS minutes cost the most: only a dispatch starts this job, never a push or a pull request.
    if: github.event_name == 'workflow_dispatch'
    runs-on: macos-26
    timeout-minutes: 45
    env:
      FLUTTER_VERSION: "3.47.7"                 # the app's Flutter release
      XCODE_APP: /Applications/Xcode_26.6.app   # a final Xcode 26 or later: App Store Connect refuses builds from others
      FLAVOR: ""                                # the flavor to build, or empty for an app without flavors
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: Xcode
        run: |
          sudo xcode-select -s "$XCODE_APP"
          xcodebuild -version

      - name: Flutter
        run: |
          git clone -q --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$RUNNER_TEMP/flutter"
          echo "$RUNNER_TEMP/flutter/bin" >> "$GITHUB_PATH"

      - name: Build the archive, unsigned
        run: |
          args=(--release --no-codesign)
          if [ -n "$FLAVOR" ]; then args+=(--flavor "$FLAVOR"); fi
          flutter build ipa "${args[@]}"

      - name: Package the app as an unsigned IPA
        run: |
          apps=(build/ios/archive/*.xcarchive/Products/Applications/*.app)
          if [ "${#apps[@]}" -ne 1 ] || [ ! -d "${apps[0]}" ]; then
            echo "expected one .app in the archive, found: ${apps[*]}"
            exit 1
          fi
          mkdir -p "$RUNNER_TEMP/ipa/Payload"
          cp -R "${apps[0]}" "$RUNNER_TEMP/ipa/Payload/"
          (cd "$RUNNER_TEMP/ipa" && zip -qry ../unsigned.ipa Payload)

      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
        with:
          name: unsigned-ipa
          path: ${{ runner.temp }}/unsigned.ipa
          if-no-files-found: error
          retention-days: 1
''';
