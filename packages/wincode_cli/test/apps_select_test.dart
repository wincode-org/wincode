import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_asc/testing.dart';
import 'package:wincode_cli/wincode_cli.dart';
import 'package:wincode_core/wincode_core.dart' show RunProcess, runProcess;

/// ADR-0014, sections 3, 5 and 7: choosing the app with `--app`, `--all` for the commands that only read, and `init --app`.
void main() {
  late Directory temp;
  late String home;
  final sep = Platform.pathSeparator;
  final adr = File('../../docs/adr/0014-one-project-many-apps.md')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  const issuer = '00000000-0000-4000-8000-000000000001';
  final throwaway = ThrowawayKey();

  setUp(() {
    temp = Directory.systemTemp.createTempSync('wincode_apps_');
    home = '${temp.path}${sep}home';
    Directory(home).createSync();
  });
  tearDown(() => temp.deleteSync(recursive: true));

  String inside(String folder, String name) => '$folder$sep$name';
  String keysRoot() => '$home$sep.wincode${sep}keys';

  Map<String, String> env([Map<String, String> more = const {}]) => {
    'USERPROFILE': home,
    ...more,
  };

  /// A keys folder that passes: one `.p8` named like a key, and an `issuer-id`.
  void keys(String reference) {
    final folder = Directory(inside(keysRoot(), reference))
      ..createSync(recursive: true);
    File(inside(folder.path, 'AuthKey_ABCDE12345.p8'))
        .writeAsStringSync(throwaway.pem());
    File(inside(folder.path, 'issuer-id')).writeAsStringSync('$issuer\n');
  }

  String app(String name, String team, String reference) =>
      '  $name:\n    bundle_id: com.example.$name\n    team_id: $team\n    credentials: $reference\n';

  /// Three apps: alpha with team-one, beta with team-two, gamma with team-three.
  final three =
      'apps:\n${app('alpha', 'TEAM000001', 'team-one')}${app('beta', 'TEAM000002', 'team-two')}${app('gamma', 'TEAM000003', 'team-three')}';

  File config(String yaml) =>
      File(inside(temp.path, 'wincode.yaml'))..writeAsStringSync(yaml);

  String clean(String text) => text.replaceAll('${temp.path}$sep', '');

  Future<(int, String, String)> wincode(
    List<String> args, {
    Map<String, String>? environment,
    RunProcess run = runProcess,
    Directory? workingDirectory,
    bool terminal = false,
    String? Function()? readLine,
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runWincode(
      args,
      out,
      err,
      environment: environment ?? env(),
      run: run,
      workingDirectory: workingDirectory,
      terminal: terminal,
      readLine: readLine,
    );
    return (code, '$out', '$err');
  }

  Future<(int, String, String)> onConfig(
    String command,
    List<String> args, {
    Map<String, String>? environment,
    RunProcess run = runProcess,
  }) => wincode(
    [command, '--config', inside(temp.path, 'wincode.yaml'), ...args],
    environment: environment,
    run: run,
  );

  /// The message that the ADR prints under [heading], as `describe` gives it.
  String adrMessage(String heading) {
    final block = RegExp(
      '$heading.*?```\\n(.*?)```',
      dotAll: true,
    ).firstMatch(adr)![1]!;
    return block
        .split('\n')
        .map((l) => l.replaceFirst(RegExp('^   '), ''))
        .join('\n')
        .trim();
  }

  Map<String, Object?> json(String out) =>
      jsonDecode(out) as Map<String, Object?>;

  /// The summary table of a run of --all as rows of cells, and whether its last column starts at one place in every row.
  (List<List<String>>, bool) table(String out) {
    final lines = out.split('\n');
    final start = lines.indexWhere((l) => l.startsWith('app '));
    final rows = <String>[
      for (
        var i = start;
        i < lines.length &&
            lines[i].isNotEmpty &&
            !lines[i].startsWith('wincode');
        i++
      )
        lines[i],
    ];
    final lastStarts = {for (final r in rows) r.lastIndexOf(RegExp(r'\s'))};
    return (
      [for (final r in rows) r.split(RegExp(r'\s{2,}'))],
      lastStarts.length == 1,
    );
  }

  /// Fails the git of the folder that ends in [folder], so that its app fails with 69.
  RunProcess gitFailsIn(String folder) =>
      (executable, arguments, {workingDirectory}) async {
        if (arguments.length > 1 && arguments[1].endsWith(folder)) {
          throw ProcessException(executable, arguments);
        }
        return runProcess(
          executable,
          arguments,
          workingDirectory: workingDirectory,
        );
      };

  group('choosing the app', () {
    setUp(() => config(three));

    test('without --app, several apps are a usage error with the message of the ADR, for every command that reads or writes', () async {
      for (final command in ['preflight', 'doctor']) {
        final (code, _, err) = await onConfig(command, []);
        expect(code, 64, reason: command);
        final message = adrMessage(r'2\. \*\*Missing `--app`\*\*')
            .replaceFirst('wincode preflight:', 'wincode $command:');
        final expected = command == 'init'
            ? message.replaceFirst(', or --all to check every app', '')
            : message;
        expect(clean(err), startsWith('$expected\n'), reason: command);
      }
    });

    test(
      'an unknown app is the message of the ADR, and lists the names',
      () async {
        final (code, _, err) = await onConfig('preflight', ['--app', 'gama']);
        expect(code, 64);
        expect(
          clean(err),
          startsWith('${adrMessage(r'1\. \*\*Unknown app\*\*')}\n'),
        );
      },
    );

    test(
      '--json carries the names in file order in the error, and the exit code',
      () async {
        for (final args in [
          <String>[],
          ['--app', 'gama'],
        ]) {
          final (code, out, _) = await onConfig('doctor', [...args, '--json']);
          expect(code, 64);
          final doc = json(out);
          expect(doc['ok'], isFalse);
          expect(doc['exitCode'], 64);
          final error = doc['error']! as Map;
          expect(error['id'], args.isEmpty ? 'app-required' : 'app-unknown');
          expect(error['apps'], ['alpha', 'beta', 'gamma']);
        }
      },
    );

    test(
      '--redact and CI print placeholders, and never the name that was typed',
      () async {
        for (final extra in [
          (<String>['--redact'], <String, String>{}),
          (<String>[], {'CI': 'true'}),
        ]) {
          final (code, _, err) = await onConfig('preflight', [
            '--app',
            'gama',
            ...extra.$1,
          ], environment: env(extra.$2));
          expect(code, 64);
          expect(
            clean(err),
            contains('wincode.yaml has no app by the name that --app gives'),
          );
          expect(err, contains('next: use one of app-1, app-2, app-3.'));
          expect(err, isNot(contains('gama')));
          expect(err, isNot(contains('alpha')));
          final (_, out, _) = await onConfig('preflight', [
            '--redact',
            '--json',
          ]);
          expect(out, contains('"apps":["app-1","app-2","app-3"]'));
          expect(out, isNot(contains('alpha')));
        }
      },
    );

    test(
      '--app names the app: its own keys are read, and the others are not',
      () async {
        keys('team-one');
        final (code, out, _) = await onConfig('doctor', ['--app', 'alpha']);
        expect(code, 0, reason: out);
        expect(out, contains('PASS  wincode.yaml loads'));
        final (missing, report, _) = await onConfig('doctor', [
          '--app',
          'beta',
        ]);
        expect(missing, 78);
        expect(
          report,
          contains('FAIL  the credentials team-two of app beta are missing'),
        );
      },
    );

    test(
      '--json of one app has command and app, as the command alone prints them',
      () async {
        keys('team-one');
        final (code, out, _) = await onConfig('doctor', [
          '--app',
          'alpha',
          '--json',
        ]);
        expect(code, 0);
        final doc = json(out);
        expect(doc.keys, ['command', 'app', 'ok', 'exitCode', 'checks']);
        expect(doc['command'], 'doctor');
        expect(doc['app'], 'alpha');
      },
    );

    test('a file with one app needs no --app', () async {
      config('apps:\n${app('alpha', 'TEAM000001', 'team-one')}');
      keys('team-one');
      expect((await onConfig('doctor', [])).$1, 0);
      expect((await onConfig('doctor', ['--app', 'alpha'])).$1, 0);
    });

    test(
      'a flat file has no names: --app is refused, and its object has app null',
      () async {
        config(
          'bundle_id: com.example.alpha\nteam_id: TEAM000001\ncredentials: team-one\n',
        );
        keys('team-one');
        final (code, _, err) = await onConfig('doctor', ['--app', 'alpha']);
        expect(code, 64);
        expect(
          err,
          contains('describes one app without a name, and --app names an app'),
        );
        final (ok, out, _) = await onConfig('doctor', ['--json']);
        expect(ok, 0);
        expect(json(out)['app'], isNull);
      },
    );

    test('--app together with --all is a usage error', () async {
      final (code, _, err) = await onConfig('doctor', [
        '--app',
        'alpha',
        '--all',
      ]);
      expect(code, 64);
      expect(err, contains('--app and --all cannot be given together'));
    });

    test('the binary checks read no settings, so --app and --all are refused there', () async {
      for (final flag in [
        ['--app', 'alpha'],
        ['--all'],
      ]) {
        final (code, _, err) = await onConfig('doctor', [
          '--binary',
          'Runner',
          '--sdk',
          'sdk',
          ...flag,
        ]);
        expect(code, 64, reason: '$flag');
        expect(
          err,
          contains('--app and --all choose the app of the setup check'),
        );
      }
    });
  });

  group('--all', () {
    test(
      'runs every app in file order, prints a table, and exits 0 when all pass',
      () async {
        config(three);
        keys('team-one');
        keys('team-two');
        keys('team-three');
        final (code, out, _) = await onConfig('doctor', ['--all']);
        expect(code, 0, reason: out);
        expect(out.indexOf('== alpha =='), lessThan(out.indexOf('== beta ==')));
        expect(out.indexOf('== beta =='), lessThan(out.indexOf('== gamma ==')));
        final (rows, aligned) = table(out);
        expect(rows, [
          ['app', 'result', 'first failure', 'exit'],
          ['alpha', 'PASS', '0'],
          ['beta', 'PASS', '0'],
          ['gamma', 'PASS', '0'],
        ]);
        expect(aligned, isTrue);
        expect(
          out.trimRight(),
          endsWith('wincode doctor --all: 3 apps passed.'),
        );
      },
    );

    test('a failure does not stop the next app, and the exit code is that of the first failing app in file order', () async {
      config(three);
      keys('team-one');
      keys('team-three');
      // beta has no folder (78), and gamma's git fails (69): beta comes first.
      final (code, out, _) = await onConfig('doctor', [
        '--all',
      ], run: gitFailsIn('team-three'));
      expect(code, 78);
      final (rows, aligned) = table(out);
      expect(rows, [
        ['app', 'result', 'first failure', 'exit'],
        ['alpha', 'PASS', '0'],
        ['beta', 'FAIL', 'credentials-missing', '78'],
        ['gamma', 'FAIL', 'git-unavailable', '69'],
      ]);
      expect(aligned, isTrue);
      expect(
        clean(out).trimRight(),
        endsWith(
          'wincode doctor --all: 2 of 3 apps failed; exit 78, the first failure in wincode.yaml (beta).',
        ),
      );
      // Reorder the file: gamma first, so its code wins.
      config(
        'apps:\n${app('gamma', 'TEAM000003', 'team-three')}${app('alpha', 'TEAM000001', 'team-one')}${app('beta', 'TEAM000002', 'team-two')}',
      );
      final (reordered, _, _) = await onConfig('doctor', [
        '--all',
      ], run: gitFailsIn('team-three'));
      expect(reordered, 69);
    });

    test('--json is one document: each app as it would print alone, and the first failing app\'s error with app added', () async {
      config(three);
      keys('team-one');
      keys('team-three');
      final (code, out, _) = await onConfig('doctor', ['--all', '--json']);
      expect(code, 78);
      final doc = json(out);
      expect(doc.keys, ['command', 'all', 'ok', 'exitCode', 'apps', 'error']);
      expect(doc['command'], 'doctor');
      expect(doc['all'], isTrue);
      expect(doc['ok'], isFalse);
      expect(doc['exitCode'], 78);
      final apps = (doc['apps']! as List).cast<Map<String, Object?>>();
      expect(apps.map((a) => a['app']), ['alpha', 'beta', 'gamma']);
      expect(apps.map((a) => a['ok']), [true, false, true]);
      expect(apps.map((a) => a['exitCode']), [0, 78, 0]);
      expect(apps.every((a) => !a.containsKey('command')), isTrue);
      expect(apps[1]['error'], isA<Map<String, Object?>>());
      final error = doc['error']! as Map;
      expect(error['app'], 'beta');
      expect(error['id'], 'credentials-missing');
      expect(error.keys, ['app', 'id', 'what', 'why', 'next']);
    });

    test('the --json documents are test/goldens/apps-json.txt (UPDATE_GOLDENS=1 rewrites it)', () async {
      config(three);
      keys('team-one');
      keys('team-three');
      final report = StringBuffer();
      for (final (label, args) in [
        ('one app, passing', ['--app', 'alpha']),
        ('one app, failing', ['--app', 'beta']),
        ('every app', ['--all']),
        ('every app, redacted', ['--all', '--redact']),
      ]) {
        final (code, out, _) = await onConfig('doctor', [...args, '--json']);
        report
          ..writeln('# $label: wincode doctor ${args.join(' ')} --json')
          ..writeln(const JsonEncoder.withIndent('  ').convert(json(out)))
          ..writeln('exit $code')
          ..writeln();
      }
      final golden = File('test/goldens/apps-json.txt');
      if (Platform.environment['UPDATE_GOLDENS'] != null) {
        golden.writeAsStringSync('$report');
      }
      expect('$report', golden.readAsStringSync().replaceAll('\r\n', '\n'));
    });

    test('preflight --all --dry-run runs each app, and a failing key stops only its own app', () async {
      config(three);
      keys('team-one');
      Directory(inside(keysRoot(), 'team-two')).createSync(recursive: true);
      keys('team-three');
      final (code, out, _) = await onConfig('preflight', [
        '--all',
        '--dry-run',
      ], run: gitFailsIn('team-three'));
      expect(code, 78);
      expect(out, contains('== alpha =='));
      expect(
        out,
        contains('GET https://api.appstoreconnect.apple.com/v1/apps?'),
      );
      expect(out, matches(RegExp(r'alpha\s+PASS\s+0')));
      expect(out, matches(RegExp(r'beta\s+FAIL\s+asc-key-invalid\s+78')));
      expect(out, matches(RegExp(r'gamma\s+FAIL\s+git-unavailable\s+69')));
    });

    test('preflight --all takes no IPA', () async {
      config(three);
      final (code, _, err) = await onConfig('preflight', [
        '--all',
        'signed.ipa',
      ]);
      expect(code, 64);
      expect(err, contains('do not name an IPA'));
    });

    test('for a flat file it is its one app', () async {
      config(
        'bundle_id: com.example.alpha\nteam_id: TEAM000001\ncredentials: team-one\n',
      );
      keys('team-one');
      final (code, out, _) = await onConfig('doctor', ['--all']);
      expect(code, 0, reason: out);
      expect(out, contains('wincode doctor --all: 1 app passed.'));
    });

    test(
      'is refused by the commands that write, with the reason of the ADR',
      () async {
        config(three);
        for (final command in ['sign', 'upload', 'build', 'init']) {
          final (code, out, err) = await onConfig(command, ['--all']);
          expect(code, 64, reason: command);
          expect(out, isEmpty);
          expect(
            err,
            startsWith('wincode $command: --all is not allowed for $command\n'),
          );
          expect(err, contains('nothing that records which'));
          expect(
            err,
            contains(
              'next: run it once for each app: wincode $command --app <name>.',
            ),
          );
          final (_, jsonOut, _) = await onConfig(command, ['--all', '--json']);
          expect((json(jsonOut)['error']! as Map)['id'], 'all-not-allowed');
        }
      },
    );

    test('status, which will only read, accepts --all and says it is not implemented', () async {
      final (code, _, err) = await onConfig('status', ['--all']);
      expect(code, 64);
      expect(err, contains('not implemented yet'));
    });

    test('the commands that are not built accept --app', () async {
      for (final command in ['upload', 'build', 'status']) {
        final (code, _, err) = await onConfig(command, ['--app', 'alpha']);
        expect(code, 64, reason: command);
        expect(err, contains('not implemented yet'), reason: command);
      }
    });
  });

  group('redaction of names in --all and --json', () {
    setUp(() {
      config(three);
      keys('team-one');
      keys('team-three');
    });

    for (final (label, args, environment) in [
      ('--redact', ['--redact'], <String, String>{}),
      ('CI', <String>[], {'CI': 'true'}),
    ]) {
      test('$label hides names, credentials, the table and the JSON', () async {
        final (code, out, err) = await onConfig('doctor', [
          '--all',
          ...args,
        ], environment: env(environment));
        expect(code, 78);
        final (rows, aligned) = table(out);
        expect(rows, [
          ['app', 'result', 'first failure', 'exit'],
          ['app-1', 'PASS', '0'],
          ['app-2', 'FAIL', 'credentials-missing', '78'],
          ['app-3', 'PASS', '0'],
        ]);
        expect(aligned, isTrue);
        expect(out, contains('== app-2 =='));
        expect(
          clean(out),
          contains('the first failure in wincode.yaml (app-2).'),
        );
        expect(out, contains('credentials credentials-2 of app app-2'));
        for (final word in [
          'alpha',
          'beta',
          'gamma',
          'team-one',
          'team-two',
          'team-three',
        ]) {
          expect('$out$err', isNot(contains(word)), reason: '$label: $word');
        }
        final (_, jsonOut, _) = await onConfig('doctor', [
          '--all',
          '--json',
          ...args,
        ], environment: env(environment));
        final doc = json(jsonOut);
        expect((doc['apps']! as List).map((a) => (a as Map)['app']), [
          'app-1',
          'app-2',
          'app-3',
        ]);
        expect((doc['error']! as Map)['app'], 'app-2');
        for (final word in ['alpha', 'beta', 'gamma', 'team-two']) {
          expect(jsonOut, isNot(contains(word)), reason: '$label json: $word');
        }
      });
    }
  });

  group('init --app', () {
    late Directory project;
    String yaml() =>
        File(inside(project.path, 'wincode.yaml')).readAsStringSync();
    File yamlFile() => File(inside(project.path, 'wincode.yaml'));

    setUp(() {
      project = Directory(inside(temp.path, 'project'))..createSync();
      File(inside(project.path, 'pubspec.yaml'))
          .writeAsStringSync('name: demo\n');
      Directory(inside(project.path, 'ios')).createSync();
    });

    Future<(int, String, String)> init(
      List<String> args, {
      Map<String, String>? environment,
      bool terminal = false,
      List<String> answers = const [],
    }) {
      final queue = [...answers];
      return wincode(
        ['init', ...args],
        environment: environment,
        workingDirectory: project,
        terminal: terminal,
        readLine: () => queue.isEmpty ? null : queue.removeAt(0),
      );
    }

    List<String> values(
      String name,
      String team,
      String reference, [
      String? flavor,
    ]) => [
      '--app',
      name,
      '--bundle-id',
      'com.example.$name',
      '--team-id',
      team,
      '--credentials',
      reference,
      if (flavor != null) ...['--flavor', flavor],
    ];

    test(
      'starts a file of apps with the one app, after the file is shown',
      () async {
        final (code, out, err) = await init([
          ...values('alpha', 'TEAM000001', 'team-one', 'alpha'),
          '--yes',
        ]);
        expect(code, 0, reason: err);
        expect(out, contains('--- wincode.yaml'));
        final loaded = loadSettings(yamlFile().path);
        expect(loaded.isFlat, isFalse);
        final alpha = loaded.app('alpha')!;
        expect(alpha.bundleId, 'com.example.alpha');
        expect(alpha.flavor, 'alpha');
        expect(alpha.credentials, 'team-one');
        expect(out, contains('wincode preflight --app alpha --dry-run'));
        expect(out, contains('the folder team-one of your keys folder'));
      },
    );

    test('adds a second app only after a diff and a confirmation', () async {
      await init([...values('alpha', 'TEAM000001', 'team-one'), '--yes']);
      final before = yaml();
      // Without a terminal and without --yes it cannot confirm: nothing is written.
      final (code, out, err) = await init(
        values('beta', 'TEAM000002', 'team-two'),
      );
      expect(code, 64);
      expect(err, contains('only after you confirm'));
      expect(out, contains('Changes init would make to wincode.yaml'));
      expect(out, contains('+     bundle_id: com.example.beta'));
      expect(yaml(), before);
      final (ok, _, err2) = await init([
        ...values('beta', 'TEAM000002', 'team-two'),
        '--yes',
      ]);
      expect(ok, 0, reason: err2);
      expect(loadSettings(yamlFile().path).apps.map((a) => a.name), [
        'alpha',
        'beta',
      ]);
    });

    test('at a terminal it asks, and no answers nothing', () async {
      await init([...values('alpha', 'TEAM000001', 'team-one'), '--yes']);
      final before = yaml();
      final (code, out, _) = await init(
        values('beta', 'TEAM000002', 'team-two'),
        terminal: true,
        // The profile folder and the entitlements file are skipped, then the confirmation.
        answers: ['', '', 'n'],
      );
      expect(code, 0);
      expect(out, contains('Write wincode.yaml? [Y/n]'));
      expect(out, contains('Nothing was written.'));
      expect(yaml(), before);
      final (yes, _, _) = await init(
        values('beta', 'TEAM000002', 'team-two'),
        terminal: true,
        answers: ['', '', ''],
      );
      expect(yes, 0);
      expect(loadSettings(yamlFile().path).apps, hasLength(2));
    });

    test('keeps defaults, comments and the other apps, and leaves out a value the entry inherits', () async {
      yamlFile().writeAsStringSync(
        '# my notes\ndefaults:\n  team_id: TEAM000001\n  credentials: team-one\n'
        'apps:\n  alpha:\n    bundle_id: com.example.alpha\n    flavor: alpha\n',
      );
      final (code, out, err) = await init([
        ...values('beta', 'TEAM000001', 'team-one', 'beta'),
        '--yes',
      ]);
      expect(code, 0, reason: err);
      final loaded = loadSettings(yamlFile().path);
      expect(loaded.app('beta')!.teamId, 'TEAM000001');
      expect(loaded.app('beta')!.credentials, 'team-one');
      final text = yaml();
      expect(
        text,
        contains('defaults:\n  team_id: TEAM000001\n  credentials: team-one\n'),
      );
      expect(
        text,
        contains(
          '  alpha:\n    bundle_id: com.example.alpha\n    flavor: alpha\n',
        ),
      );
      // beta writes neither team_id nor credentials: it inherits them.
      final beta = text.substring(text.indexOf('  beta:'));
      expect(beta, isNot(contains('team_id')));
      expect(beta, isNot(contains('credentials')));
      // The file is edited in place: the comment stays, and the diff lists added lines only.\n      expect(text, startsWith('# my notes\n'));\n      expect(out, isNot(contains('- ')));
    });

    test(
      'updates an entry only with --force when it has other values',
      () async {
        await init([
          ...values('alpha', 'TEAM000001', 'team-one', 'alpha'),
          '--yes',
        ]);
        final before = yaml();
        final (code, out, err) = await init([
          ...values('alpha', 'TEAM000009', 'team-one', 'alpha'),
          '--yes',
        ]);
        expect(code, 1);
        expect(
          err,
          contains(
            'wincode init: the app already has team_id in wincode.yaml, with other values',
          ),
        );
        expect(out, contains('Changes init would make'));
        expect(yaml(), before);
        final (forced, _, _) = await init([
          ...values('alpha', 'TEAM000009', 'team-one', 'alpha'),
          '--yes',
          '--force',
        ]);
        expect(forced, 0);
        expect(
          loadSettings(yamlFile().path).app('alpha')!.teamId,
          'TEAM000009',
        );
      },
    );

    test('the same values again change nothing', () async {
      await init([
        ...values('alpha', 'TEAM000001', 'team-one', 'alpha'),
        '--yes',
      ]);
      final before = yaml();
      final (code, out, _) = await init([
        ...values('alpha', 'TEAM000001', 'team-one', 'alpha'),
        '--yes',
      ]);
      expect(code, 0);
      expect(
        out,
        contains('wincode.yaml already holds these values for the app.'),
      );
      expect(yaml(), before);
    });

    test('--dry-run shows the changes and writes nothing', () async {
      await init([...values('alpha', 'TEAM000001', 'team-one'), '--yes']);
      final before = yaml();
      final (code, out, _) = await init([
        ...values('beta', 'TEAM000002', 'team-two'),
        '--dry-run',
      ]);
      expect(code, 0);
      expect(out, contains('Dry run: nothing was written.'));
      expect(yaml(), before);
    });

    test('a bundle ID that another app has is refused by the loader before anything is written', () async {
      await init([...values('alpha', 'TEAM000001', 'team-one'), '--yes']);
      final before = yaml();
      final (code, _, err) = await init([
        '--app',
        'beta',
        '--bundle-id',
        'com.example.alpha',
        '--team-id',
        'TEAM000001',
        '--credentials',
        'team-one',
        '--yes',
      ]);
      expect(code, 78);
      expect(err, contains('apps beta and alpha have the same bundle_id'));
      expect(yaml(), before);
    });

    test('an apps file without --app is app-required', () async {
      yamlFile().writeAsStringSync(three);
      final (code, _, err) = await init(['--yes']);
      expect(code, 64);
      expect(
        err,
        contains('has 3 apps, and the command does not say which one'),
      );
      expect(err, isNot(contains('--all')));
    });

    test(
      'the app name and the credentials follow the rules of every name',
      () async {
        for (final bad in ['ab', 'Alpha_One', 'build']) {
          final (code, _, err) = await init(['--app', bad, '--yes']);
          expect(code, 64, reason: bad);
          expect(err, contains('--app: the app name'));
          expect(err, isNot(contains(bad == 'build' ? 'zzz' : bad)));
        }
      },
    );

    test(
      'the credentials are asked for, and listed when init cannot ask',
      () async {
        final (code, _, err) = await init([
          '--app',
          'alpha',
          '--bundle-id',
          'com.example.alpha',
          '--team-id',
          'TEAM000001',
          '--yes',
        ]);
        expect(code, 64);
        expect(err, contains('credentials: not detected; pass --credentials'));
      },
    );

    test('--json names the app and what was written; --redact and CI print placeholders', () async {
      final (code, out, _) = await init([
        ...values('alpha', 'TEAM000001', 'team-one', 'alpha'),
        '--yes',
        '--json',
      ]);
      expect(code, 0);
      final doc = json(out);
      expect(doc['app'], 'alpha');
      expect(doc['written'], isTrue);
      expect((doc['config']! as Map)['credentials'], 'team-one');
      yamlFile().deleteSync();
      for (final (args, environment) in [
        (['--redact'], <String, String>{}),
        (<String>[], {'CI': 'true'}),
      ]) {
        final (c, report, err) = await init([
          ...values('alpha', 'TEAM000001', 'team-one', 'alpha'),
          '--yes',
          ...args,
        ], environment: env(environment));
        expect(c, 0, reason: err);
        for (final word in ['alpha', 'team-one', 'TEAM000001']) {
          expect('$report$err', isNot(contains(word)), reason: '$args: $word');
        }
        expect(report, contains('app-1'));
        expect(report, contains('<bundle ID 1>'));
        yamlFile().deleteSync();
      }
    });
  });
}
