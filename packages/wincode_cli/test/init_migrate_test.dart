import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_cli/src/init.dart';
import 'package:wincode_cli/wincode_cli.dart';

/// ADR-0014, section 5: `init --app` edits a file of apps in place, moves a flat file under `apps:` with a backup, and
/// never leaves a file that does not load.
void main() {
  late Directory temp;
  late Directory project;
  final sep = Platform.pathSeparator;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('wincode_migrate_');
    project = Directory('${temp.path}${sep}project')..createSync();
    File('${project.path}${sep}pubspec.yaml').writeAsStringSync('name: demo\n');
    Directory('${project.path}${sep}ios').createSync();
  });
  tearDown(() => temp.deleteSync(recursive: true));

  File yamlFile() => File('${project.path}${sep}wincode.yaml');
  File bakFile() => File('${project.path}${sep}wincode.yaml.bak');
  String yaml() => yamlFile().readAsStringSync();

  Future<(int, String, String)> init(
    List<String> args, {
    Map<String, String> environment = const {},
    bool terminal = false,
    List<String> answers = const [],
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
      readLine: () => queue.isEmpty ? null : queue.removeAt(0),
    );
    return (code, '$out', '$err');
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
    ?(flavor == null ? null : '--flavor'),
    ?flavor,
  ];

  /// A hand-kept file of apps: comments in every place, blank lines, and a key order of its own.
  const handKept = '''# My apps. Do not reorder.
defaults:
  team_id: TEAM000001   # the team of all of them
  credentials: team-one

# alpha is the first one that shipped.
apps:
  alpha:
    # the flavor comes first on purpose
    flavor: alpha
    bundle_id: com.example.alpha

  beta:
    bundle_id: com.example.beta   # beta's id
    flavor: beta

# Nothing below this line.
''';

  /// A flat file with comments, as people write it.
  const flat = '''# My project
bundle_id: com.example.alpha   # the app that shipped
team_id: TEAM000001

profile: signing/alpha.mobileprovision
output: out/alpha
''';

  List<String> migrateArgs() => [
    '--app',
    'alpha',
    '--bundle-id',
    'com.example.alpha',
    '--credentials',
    'team-one',
    '--flavor',
    'alpha',
  ];

  group('in-place edits of a file of apps', () {
    test('adding an entry keeps comments, blank lines and key order, and only the new lines differ', () async {
      yamlFile().writeAsStringSync(handKept);
      final (code, out, err) = await init([
        ...values('gamma', 'TEAM000001', 'team-one', 'gamma'),
        '--yes',
      ]);
      expect(code, 0, reason: err);
      final before = handKept.split('\n');
      final after = yaml().split('\n');
      // Every line of the old file is still there, in order.
      var at = 0;
      for (final line in before) {
        final found = after.indexOf(line, at);
        expect(found, greaterThanOrEqualTo(at), reason: 'lost: $line');
        at = found + 1;
      }
      expect(after.length, greaterThan(before.length));
      expect(out, isNot(contains('\n- ')));
      expect(out, contains('+   gamma:'));
      final loaded = loadSettings(yamlFile().path);
      expect(loaded.apps.map((a) => a.name), ['alpha', 'beta', 'gamma']);
      expect(loaded.app('gamma')!.teamId, 'TEAM000001');
    });

    test('updating an entry changes its lines and nothing else', () async {
      yamlFile().writeAsStringSync(handKept);
      final (code, out, err) = await init([
        '--app',
        'beta',
        '--bundle-id',
        'com.example.beta',
        '--team-id',
        'TEAM000002',
        '--credentials',
        'team-two',
        '--yes',
        '--force',
      ]);
      expect(code, 0, reason: err);
      final loaded = loadSettings(yamlFile().path).app('beta')!;
      expect(loaded.teamId, 'TEAM000002');
      expect(loaded.credentials, 'team-two');
      expect(loaded.flavor, 'beta');
      // Comments and the other app are as they were.
      for (final kept in [
        '# My apps. Do not reorder.',
        '  team_id: TEAM000001   # the team of all of them',
        '    # the flavor comes first on purpose',
        '    flavor: alpha',
        "    bundle_id: com.example.beta   # beta's id",
        '# Nothing below this line.',
      ]) {
        expect(yaml(), contains(kept));
      }
      expect(RegExp(r'^\+', multiLine: true).allMatches(out).length, 2);
    });

    test('an entry that already holds these values writes nothing', () async {
      yamlFile().writeAsStringSync(handKept);
      final before = yamlFile().readAsBytesSync();
      final (code, out, _) = await init([
        '--app',
        'beta',
        '--bundle-id',
        'com.example.beta',
        '--flavor',
        'beta',
        '--credentials',
        'team-one',
        '--team-id',
        'TEAM000001',
        '--yes',
      ]);
      expect(code, 0);
      expect(
        out,
        contains('wincode.yaml already holds these values for the app.'),
      );
      expect(yamlFile().readAsBytesSync(), before);
    });

    test('the before and after of the edits are test/goldens/init-edit.txt (UPDATE_GOLDENS=1 rewrites it)', () async {
      final report = StringBuffer()
        ..writeln('# before')
        ..write(handKept);
      yamlFile().writeAsStringSync(handKept);
      await init([
        ...values('gamma', 'TEAM000001', 'team-one', 'gamma'),
        '--yes',
      ]);
      report
        ..writeln('# after adding gamma (team and credentials inherited)')
        ..write(yaml());
      final (code, _, err) = await init([
        '--app',
        'beta',
        '--bundle-id',
        'com.example.beta',
        '--team-id',
        '0123456789',
        '--credentials',
        'team-two',
        '--yes',
        '--force',
      ]);
      expect(code, 0, reason: err);
      report
        ..writeln(
          '# after giving beta a team of digits only, and its own credentials',
        )
        ..write(yaml());
      final golden = File('test/goldens/init-edit.txt');
      if (Platform.environment['UPDATE_GOLDENS'] != null) {
        golden.writeAsStringSync('$report');
      }
      expect('$report', golden.readAsStringSync().replaceAll('\r\n', '\n'));
    });

    test('a byte order mark and CRLF line endings are kept', () async {
      yamlFile().writeAsBytesSync(
        utf8.encode('﻿${handKept.replaceAll('\n', '\r\n')}'),
      );
      final (code, _, err) = await init([
        ...values('gamma', 'TEAM000001', 'team-one', 'gamma'),
        '--yes',
      ]);
      expect(code, 0, reason: err);
      final bytes = yamlFile().readAsBytesSync();
      expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
      final text = utf8.decode(bytes);
      expect(text.replaceAll('\r\n', ''), isNot(contains('\n')));
      expect(text, contains('  gamma:\r\n'));
      expect(loadSettings(yamlFile().path).apps, hasLength(3));
    });

    test(
      'a layout the editor cannot change is reported, and nothing is written',
      () async {
        // An anchor-and-alias layout that the loader refuses anyway would not get here; a flow map is edited, too.
        yamlFile().writeAsStringSync(
          'apps: {alpha: {bundle_id: com.example.alpha, team_id: TEAM000001, credentials: team-one}}\n',
        );
        final (code, _, err) = await init([
          ...values('beta', 'TEAM000002', 'team-two'),
          '--yes',
        ]);
        // Either the flow map is edited and loads, or init says it cannot: never a broken file.
        if (code == 0) {
          expect(loadSettings(yamlFile().path).apps, hasLength(2));
        } else {
          expect(err, contains('init cannot edit'));
          expect(
            yaml(),
            'apps: {alpha: {bundle_id: com.example.alpha, team_id: TEAM000001, credentials: team-one}}\n',
          );
        }
      },
    );
  });

  group('migrating a flat file', () {
    setUp(() => yamlFile().writeAsStringSync(flat));

    test('shows the diff, needs a yes, keeps the original as wincode.yaml.bak, and writes', () async {
      final original = yamlFile().readAsBytesSync();
      final (code, out, err) = await init([...migrateArgs(), '--yes']);
      expect(code, 0, reason: err);
      expect(out, contains('Moving wincode.yaml under apps:'));
      expect(
        out,
        contains('- bundle_id: com.example.alpha   # the app that shipped'),
      );
      expect(out, contains('+   alpha:'));
      expect(out, contains('Kept the original as wincode.yaml.bak.'));
      expect(bakFile().readAsBytesSync(), original);
      final loaded = loadSettings(yamlFile().path);
      expect(loaded.isFlat, isFalse);
      final alpha = loaded.app('alpha')!;
      // Every value of the flat file, unchanged, and the three that init adds.
      expect(alpha.bundleId, 'com.example.alpha');
      expect(alpha.teamId, 'TEAM000001');
      expect(
        alpha.profile!.path,
        endsWith('signing${sep}alpha.mobileprovision'.replaceAll(sep, '/')),
      );
      expect(alpha.output.path, endsWith('out/alpha'));
      expect(alpha.flavor, 'alpha');
      expect(alpha.credentials, 'team-one');
    });

    test('a flat file without output keeps the IPAs where they were: output build/wincode is written', () async {
      yamlFile().writeAsStringSync(
        'bundle_id: com.example.alpha\nteam_id: TEAM000001\n',
      );
      final (code, _, err) = await init([...migrateArgs(), '--yes']);
      expect(code, 0, reason: err);
      expect(
        loadSettings(yamlFile().path).app('alpha')!.output.path,
        endsWith('build/wincode'),
      );
      expect(yaml(), contains('    output: build/wincode\n'));
    });

    test('without a yes it cannot ask here (CI, --json): nothing is written and no backup is made', () async {
      final original = yaml();
      for (final (args, environment) in [
        (<String>[], <String, String>{}),
        (['--json'], <String, String>{}),
        (<String>[], {'CI': 'true'}),
      ]) {
        final (code, out, err) = await init(
          migrateArgs() + args,
          environment: environment,
        );
        expect(code, 64, reason: '$args');
        expect('$out$err', contains('only after you confirm'), reason: '$args');
        expect(yaml(), original);
        expect(bakFile().existsSync(), isFalse);
      }
    });

    test('--force is not a yes', () async {
      final (code, _, err) = await init([...migrateArgs(), '--force']);
      expect(code, 64);
      expect(err, contains('--force is not a yes'));
      expect(bakFile().existsSync(), isFalse);
    });

    test('at a terminal it asks, and no leaves everything as it was', () async {
      final original = yaml();
      final (code, out, _) = await init(
        migrateArgs(),
        terminal: true,
        answers: ['n'],
      );
      expect(code, 0);
      expect(out, contains('Write wincode.yaml? [Y/n]'));
      expect(out, contains('Nothing was written.'));
      expect(yaml(), original);
      expect(bakFile().existsSync(), isFalse);
    });

    test(
      'an earlier backup is never replaced unasked, and --force replaces it',
      () async {
        bakFile().writeAsStringSync('an older backup\n');
        final (code, _, err) = await init([...migrateArgs(), '--yes']);
        expect(code, 1);
        expect(err, contains('wincode.yaml.bak already exists'));
        expect(bakFile().readAsStringSync(), 'an older backup\n');
        expect(yaml(), flat);
        final (forced, _, ferr) = await init([
          ...migrateArgs(),
          '--yes',
          '--force',
        ]);
        expect(forced, 0, reason: ferr);
        expect(bakFile().readAsStringSync(), flat);
        expect(loadSettings(yamlFile().path).isFlat, isFalse);
      },
    );

    test('--dry-run shows the diff and writes neither file', () async {
      final (code, out, _) = await init([...migrateArgs(), '--dry-run']);
      expect(code, 0);
      expect(
        out,
        contains('Dry run: nothing was written, and no backup was made.'),
      );
      expect(yaml(), flat);
      expect(bakFile().existsSync(), isFalse);
    });

    test('a file that describes another app is not moved: init says which run to make first', () async {
      final (code, _, err) = await init([
        '--app',
        'beta',
        '--bundle-id',
        'com.example.beta',
        '--credentials',
        'team-one',
        '--yes',
      ]);
      expect(code, 1);
      expect(err, contains('wincode init: wincode.yaml describes another app'));
      expect(
        err,
        contains(
          'name the app of the file first: wincode init --app <its name> --flavor <its flavor>, then add beta with a second run.',
        ),
      );
      expect(yaml(), flat);
      expect(bakFile().existsSync(), isFalse);
    });

    test('the values of the flat file are not taken from options: they are refused', () async {
      for (final option in [
        '--team-id',
        '--profile',
        '--entitlements',
        '--workflow-ref',
        '--output',
      ]) {
        final (code, _, err) = await init([
          ...migrateArgs(),
          option,
          'x',
          '--yes',
        ]);
        expect(code, 64, reason: option);
        expect(
          err,
          contains(
            '$option: init --app moves the values of the flat wincode.yaml under apps: unchanged',
          ),
        );
      }
      expect(yaml(), flat);
    });

    test('credentials are required, as for every app', () async {
      final (code, _, err) = await init([
        '--app',
        'alpha',
        '--bundle-id',
        'com.example.alpha',
        '--yes',
      ]);
      expect(code, 64);
      expect(err, contains('credentials: not detected; pass --credentials'));
      expect(yaml(), flat);
    });

    test('--json names the backup', () async {
      final (code, out, _) = await init([...migrateArgs(), '--yes', '--json']);
      expect(code, 0);
      final doc = jsonDecode(out) as Map<String, Object?>;
      expect(doc['app'], 'alpha');
      expect(doc['written'], isTrue);
      expect(doc['backup'], 'wincode.yaml.bak');
    });

    test(
      '--redact and CI hide the names, the IDs and the paths in the diff',
      () async {
        for (final (args, environment) in [
          (['--redact'], <String, String>{}),
          (<String>[], {'CI': 'true'}),
        ]) {
          yamlFile().writeAsStringSync(flat);
          if (bakFile().existsSync()) {
            bakFile().deleteSync();
          }
          final (code, out, err) = await init([
            ...migrateArgs(),
            '--yes',
            ...args,
          ], environment: environment);
          expect(code, 0, reason: err);
          for (final word in [
            'alpha',
            'team-one',
            'TEAM000001',
            'com.example',
          ]) {
            expect('$out$err', isNot(contains(word)), reason: '$args: $word');
          }
          expect(out, contains('app-1'));
          expect(out, contains('<bundle ID 1>'));
          expect(out, contains('<team ID 1>'));
          expect(out, contains('<profile of app-1>'));
        }
      },
    );

    test('the migration, before and after, is test/goldens/init-migration.txt (UPDATE_GOLDENS=1 rewrites it)', () async {
      final (_, out, _) = await init([...migrateArgs(), '--yes', '--redact']);
      final report = StringBuffer()
        ..writeln('# before: wincode.yaml')
        ..write(flat)
        ..writeln('# wincode init ${migrateArgs().join(' ')} --yes --redact')
        ..write(out)
        ..writeln('# after: wincode.yaml')
        ..write(yaml())
        ..writeln('# after: wincode.yaml.bak is the file before, byte for byte')
        ..writeln(bakFile().readAsStringSync() == flat);
      final golden = File('test/goldens/init-migration.txt');
      if (Platform.environment['UPDATE_GOLDENS'] != null) {
        golden.writeAsStringSync('$report');
      }
      expect('$report', golden.readAsStringSync().replaceAll('\r\n', '\n'));
    });
  });

  group('a write that would leave a file that does not load', () {
    Initializer initializer(
      List<String> args, {
      required void Function(File, String) writeFile,
      String app = 'alpha',
      bool team = false,
    }) {
      final options = InitOptions(
        app: app,
        bundleId: 'com.example.$app',
        teamId: team ? 'TEAM000001' : null,
        credentials: 'team-one',
        flavor: 'alpha',
        yes: true,
        force: args.contains('--force'),
      );
      return Initializer(
        options: options,
        cwd: project,
        redactor: Redactor(active: false),
        report: StringBuffer(),
        readLine: () => null,
        interactive: false,
        clock: DateTime.now,
        writeFile: writeFile,
      );
    }

    void broken(File file, String text) =>
        file.writeAsStringSync('apps:\n  alpha: [\n');

    Future<WincodeException> failed(Initializer i) async {
      try {
        await i.execute();
      } on WincodeException catch (e) {
        return e;
      }
      fail('no failure');
    }

    test('a new file is removed again', () async {
      final e = await failed(initializer([], writeFile: broken, team: true));
      expect(e.exitCode, ExitCode.internal);
      expect(e.id, 'init-wrote-invalid');
      expect(
        e.what,
        startsWith('init wrote a wincode.yaml that does not load: '),
      );
      expect(e.next, contains('report it at'));
      expect(yamlFile().existsSync(), isFalse);
    });

    test('an edited file is restored byte for byte', () async {
      yamlFile().writeAsStringSync(handKept);
      final before = yamlFile().readAsBytesSync();
      final e = await failed(
        initializer([], writeFile: broken, app: 'gamma', team: true),
      );
      expect(e.id, 'init-wrote-invalid');
      expect(e.why, contains('The previous file was restored'));
      expect(yamlFile().readAsBytesSync(), before);
    });

    test(
      'a migration puts back the flat file, and undoes the backup it made',
      () async {
        yamlFile().writeAsStringSync(flat);
        final e = await failed(initializer([], writeFile: broken));
        expect(e.why, contains('the backup undone'));
        expect(yaml(), flat);
        expect(bakFile().existsSync(), isFalse);
      },
    );

    test(
      'a migration with --force puts back the backup that it replaced',
      () async {
        yamlFile().writeAsStringSync(flat);
        bakFile().writeAsStringSync('an older backup\n');
        await failed(initializer(['--force'], writeFile: broken));
        expect(yaml(), flat);
        expect(bakFile().readAsStringSync(), 'an older backup\n');
      },
    );

    test(
      'a flat init that was asked to replace the file puts the old one back',
      () async {
        yamlFile().writeAsStringSync(flat);
        final options = InitOptions(
          bundleId: 'com.example.beta',
          teamId: 'TEAM000002',
          yes: true,
          force: true,
        );
        final i = Initializer(
          options: options,
          cwd: project,
          redactor: Redactor(active: false),
          report: StringBuffer(),
          readLine: () => null,
          interactive: false,
          clock: DateTime.now,
          writeFile: (file, text) => file.writeAsStringSync('apps: {'),
        );
        final e = await failed(i);
        expect(e.id, 'init-wrote-invalid');
        expect(yaml(), flat);
      },
    );
  });
}
