import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_asc/testing.dart';
import 'package:wincode_asc/wincode_asc.dart';
import 'package:wincode_cli/wincode_cli.dart';
import 'package:wincode_core/wincode_core.dart' show RunProcess, runProcess;

/// ADR-0014, section 2: where each app's keys are, and the rules for the keys folder.
void main() {
  late Directory temp;
  late String home;
  final sep = Platform.pathSeparator;
  final adr = File('../../docs/adr/0014-one-project-many-apps.md')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  /// The first YAML block of the ADR: its worked example.
  final example = RegExp(
    r'```yaml\n(.*?)```',
    dotAll: true,
  ).firstMatch(adr)![1]!;

  /// The message that the ADR prints under [heading], as the lines `describe` gives.
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

  const keyId = 'ABCDE12345';
  const issuer = '00000000-0000-4000-8000-000000000001';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('wincode_credentials_');
    home = '${temp.path}${sep}home';
    Directory(home).createSync();
  });
  tearDown(() => temp.deleteSync(recursive: true));

  String inside(String folder, String name) => '$folder$sep$name';

  /// The default keys root of the fake user.
  String defaultRoot() => '$home$sep.wincode${sep}keys';

  Map<String, String> env([Map<String, String> more = const {}]) => {
    'USERPROFILE': home,
    ...more,
  };

  /// A folder of keys: one `.p8`, an `issuer-id`, and a `dist.key`.
  Directory keyFolder(
    String path, {
    String id = keyId,
    bool p8 = true,
    bool issuerFile = true,
    bool dist = true,
  }) {
    final folder = Directory(path)..createSync(recursive: true);
    if (p8) {
      File(inside(path, 'AuthKey_$id.p8')).writeAsStringSync('not a key');
    }
    if (issuerFile) {
      File(inside(path, 'issuer-id')).writeAsStringSync('$issuer\n');
    }
    if (dist) {
      File(inside(path, 'dist.key')).writeAsStringSync('not a key');
    }
    return folder;
  }

  Future<void> git(String folder, List<String> args) async {
    final result = await Process.run('git', ['-C', folder, ...args]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  File write(String name, String yaml) =>
      File(inside(temp.path, name))..writeAsStringSync(yaml);

  /// A flat file for an app that names [reference] (or none).
  WincodeConfig app({String? reference = 'team-one', Redactor? redactor}) =>
      loadConfig(
        write(
          'wincode.yaml',
          'bundle_id: com.example.alpha\nteam_id: TEAM000001\n'
              '${reference == null ? '' : 'credentials: $reference\n'}',
        ).path,
        redactor: redactor,
      );

  /// A process runner that records what it starts and starts only `git`.
  (RunProcess, List<String>) recording() {
    final started = <String>[];
    Future<ProcessResult> run(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    }) {
      started.add(executable);
      return runProcess(
        executable,
        arguments,
        workingDirectory: workingDirectory,
      );
    }

    return (run, started);
  }

  Future<AscKeyFiles?> locate(
    WincodeConfig config,
    Map<String, String> environment, {
    Redactor? redactor,
    RunProcess run = runProcess,
    bool dryRun = false,
  }) => locateAscKeyFiles(
    config,
    environment: environment,
    redactor: redactor ?? Redactor(active: false),
    run: run,
    dryRun: dryRun,
  );

  Future<WincodeException> refused(Future<Object?> work) async {
    try {
      await work;
    } on WincodeException catch (e) {
      expect([e.why, e.next], everyElement(isNotEmpty), reason: e.what);
      return e;
    }
    fail('no failure');
  }

  String idOf(AscKeyFiles key) =>
      readAscKeyIds(key, Redactor(active: false)).keyId;

  group('resolution order', () {
    test(
      'with no variable, the default root under the user profile is used',
      () async {
        keyFolder('${defaultRoot()}${sep}team-one');
        final key = (await locate(app(), env()))!;
        expect(key.source, 'the folder of the credentials team-one');
        expect(idOf(key), keyId);
        expect(readAscKeyIds(key, Redactor(active: false)).issuer, issuer);
      },
    );

    test('HOME serves where there is no USERPROFILE', () async {
      keyFolder('${defaultRoot()}${sep}team-one');
      final key = await locate(app(), {'HOME': home});
      expect(key, isNotNull);
    });

    test('WINCODE_KEYS_DIR replaces the default root', () async {
      keyFolder('${defaultRoot()}${sep}team-one', id: 'DEFAULT001');
      final other = inside(temp.path, 'elsewhere');
      keyFolder('$other${sep}team-one', id: 'ELSEWHERE1');
      final key = await locate(app(), env({keysRootVariable: other}));
      expect(idOf(key!), 'ELSEWHERE1');
    });

    test('the variable of the reference replaces the folder, for the App Store Connect half only', () async {
      keyFolder('${defaultRoot()}${sep}team-one', id: 'ROOTKEY001');
      final ci = inside(temp.path, 'ci');
      keyFolder(ci, id: 'CIKEY00001', dist: false);
      final environment = env({ascOverrideVariable('team-one'): ci});
      final key = await locate(app(), environment);
      expect(key!.source, 'WINCODE_ASC_KEY_DIR_TEAM_ONE');
      expect(idOf(key), 'CIKEY00001');
      final dist = await resolveDistKey(
        app(),
        environment: environment,
        redactor: Redactor(active: false),
      );
      expect(dist!.path, inside('${defaultRoot()}${sep}team-one', 'dist.key'));
    });

    test('the variable of the reference for the distribution key replaces dist.key only', () async {
      keyFolder('${defaultRoot()}${sep}team-one');
      final elsewhere = inside(temp.path, 'secrets${sep}dist.key');
      File(elsewhere).createSync(recursive: true);
      final environment = env({distOverrideVariable('team-one'): elsewhere});
      final dist = await resolveDistKey(
        app(),
        environment: environment,
        redactor: Redactor(active: false),
      );
      expect(dist!.absolute.path, File(elsewhere).absolute.path);
      expect(idOf((await locate(app(), environment))!), keyId);
    });

    test(
      'the suffix of a variable is the reference in capitals with _ for -',
      () {
        expect(ascOverrideVariable('team-one'), 'WINCODE_ASC_KEY_DIR_TEAM_ONE');
        expect(distOverrideVariable('team-two'), 'WINCODE_DIST_KEY_TEAM_TWO');
        expect(ascOverrideVariable('teamone'), 'WINCODE_ASC_KEY_DIR_TEAMONE');
      },
    );

    test('the two legacy variables are read by an app without credentials, and only by it', () async {
      final legacy = keyFolder(inside(temp.path, 'asc'), id: 'LEGACYKEY1');
      final environment = env({'WINCODE_ASC_KEY_DIR': legacy.path});
      final flat = await locate(app(reference: null), environment);
      expect(flat!.source, 'WINCODE_ASC_KEY_DIR');
      expect(idOf(flat), 'LEGACYKEY1');
      // An app with credentials never reads it.
      final e = await refused(locate(app(), environment));
      expect(e.id, 'credentials-missing');
      final file = File(inside(temp.path, 'dist.key'))..writeAsStringSync('x');
      final dist = await resolveDistKey(
        app(reference: null),
        environment: {'WINCODE_DIST_KEY': file.path},
        redactor: Redactor(active: false),
      );
      expect(dist!.absolute.path, file.absolute.path);
      expect(
        await resolveDistKey(
          app(reference: null),
          environment: {},
          redactor: Redactor(active: false),
        ),
        isNull,
      );
    });

    test('a dry run without keys goes on without a token; otherwise the credentials are missing', () async {
      expect(await locate(app(), env(), dryRun: true), isNull);
      expect(
        noTokenReason(app()),
        'no token: the credentials team-one were not found',
      );
      expect(
        noTokenReason(app(reference: null)),
        'no token: WINCODE_ASC_KEY_DIR is not set',
      );
      expect((await refused(locate(app(), env()))).id, 'credentials-missing');
    });
  });

  group('two apps that share one reference', () {
    test('read one folder, and another reference reads another', () async {
      final settings = loadSettings(write('wincode.yaml', example).path);
      keyFolder('${defaultRoot()}${sep}team-one', id: 'TEAMONE001');
      keyFolder('${defaultRoot()}${sep}team-two', id: 'TEAMTWO001');
      final keys = {
        for (final app in settings.apps) app.name!: (await locate(app, env()))!,
      };
      expect(idOf(keys['alpha']!), 'TEAMONE001');
      expect(idOf(keys['beta']!), 'TEAMONE001');
      expect(keys['alpha']!.p8.single.path, keys['beta']!.p8.single.path);
      expect(idOf(keys['gamma']!), 'TEAMTWO001');
    });
  });

  group('the files of a folder', () {
    test('exactly one .p8, named as App Store Connect names it, and an issuer-id with an Issuer ID', () async {
      const forTeam = 'the folder of the credentials team-one';
      final cases = <(void Function(String), String)>[
        ((path) => keyFolder(path, p8: false), '$forTeam holds no .p8 file'),
        (
          (path) {
            keyFolder(path);
            File(inside(path, 'AuthKey_ZZZZZ99999.p8')).writeAsStringSync('x');
          },
          '$forTeam holds 2 .p8 files',
        ),
        (
          (path) {
            keyFolder(path, p8: false);
            File(inside(path, 'key.p8')).writeAsStringSync('x');
          },
          'the .p8 in $forTeam is not named AuthKey_<Key ID>.p8',
        ),
        (
          (path) => keyFolder(path, issuerFile: false),
          '$forTeam has no file issuer-id with an Issuer ID in it',
        ),
      ];
      final path = '${defaultRoot()}${sep}team-one';
      for (final (build, what) in cases) {
        if (Directory(path).existsSync()) {
          Directory(path).deleteSync(recursive: true);
        }
        build(path);
        final key = (await locate(app(), env()))!;
        final e = await refused(
          Future(() => readAscKeyIds(key, Redactor(active: false))),
        );
        expect(e.id, 'asc-key-invalid');
        expect(e.exitCode, ExitCode.config);
        expect(e.what, what);
      }
    });

    test(
      'a variable names itself, never the folder, in the same messages',
      () async {
        final ci = keyFolder(inside(temp.path, 'ci'), p8: false);
        final key = (await locate(
          app(),
          env({ascOverrideVariable('team-one'): ci.path}),
        ))!;
        final e = await refused(
          Future(() => readAscKeyIds(key, Redactor(active: false))),
        );
        expect(e.what, 'WINCODE_ASC_KEY_DIR_TEAM_ONE holds no .p8 file');
        expect(e.describe('wincode preflight'), isNot(contains(ci.path)));
      },
    );
  });

  group('the missing credentials folder', () {
    test('is the message of the ADR for the worked example', () async {
      keyFolder('${defaultRoot()}${sep}team-one');
      final settings = loadSettings(write('wincode.yaml', example).path);
      final e = await refused(locate(settings.app('gamma')!, env()));
      expect(e.exitCode, ExitCode.config);
      expect(e.id, 'credentials-missing');
      expect(
        e.describe('wincode preflight'),
        adrMessage(r'3\. \*\*Missing credentials folder\*\*'),
      );
    });

    test('says when the keys folder itself is missing, with and without WINCODE_KEYS_DIR', () async {
      final e = await refused(locate(app(), env()));
      expect(e.what, endsWith('are missing: the keys folder does not exist'));
      final named = await refused(
        locate(app(), env({keysRootVariable: inside(temp.path, 'nowhere')})),
      );
      expect(
        named.what,
        endsWith(
          'are missing: the folder that WINCODE_KEYS_DIR names does not exist',
        ),
      );
      expect(named.toJson().values.join(), isNot(contains('nowhere')));
    });

    test(
      'says that the legacy variable serves only a file without credentials',
      () async {
        final e = await refused(
          locate(app(), env({'WINCODE_ASC_KEY_DIR': inside(temp.path, 'asc')})),
        );
        expect(
          e.next,
          endsWith(
            'WINCODE_ASC_KEY_DIR is set, but it serves only a wincode.yaml without credentials.',
          ),
        );
        expect(
          (await refused(locate(app(), env()))).next,
          isNot(contains('is set, but')),
        );
      },
    );

    test(
      'names the app only when the file has apps, and the reference by name',
      () async {
        final flat = await refused(locate(app(), env()));
        expect(flat.what, startsWith('the credentials team-one are missing: '));
        expect(flat.why, contains("the app's App Store Connect key"));
      },
    );

    test('with no user profile and no WINCODE_KEYS_DIR, it still says what is missing', () async {
      final e = await refused(locate(app(), {}));
      expect(e.id, 'credentials-missing');
      expect(e.what, contains('WINCODE_KEYS_DIR is not set'));
    });
  });

  group('the keys root in a git working tree', () {
    test(
      'is refused whether or not git ignores it, with the message of the ADR',
      () async {
        final repo = Directory(inside(temp.path, 'project'))..createSync();
        await git(repo.path, ['init', '-q']);
        final root = '${repo.path}${sep}keys';
        keyFolder('$root${sep}team-one');
        for (final ignored in [false, true]) {
          if (ignored) {
            File(inside(repo.path, '.gitignore')).writeAsStringSync('keys/\n');
          }
          final e = await refused(locate(app(), env({keysRootVariable: root})));
          expect(e.id, 'keys-in-git-tree', reason: 'ignored: $ignored');
          expect(e.exitCode, ExitCode.config);
          expect(
            e.describe('wincode preflight'),
            adrMessage(r'4\. \*\*Key folder inside a git working tree\*\*'),
          );
          expect(e.describe('wincode preflight'), isNot(contains(repo.path)));
        }
      },
    );

    test(
      'is refused for the default root when the user profile is a repository',
      () async {
        await git(home, ['init', '-q']);
        keyFolder('${defaultRoot()}${sep}team-one');
        final e = await refused(locate(app(), env()));
        expect(e.id, 'keys-in-git-tree');
        expect(
          e.what,
          'the default keys folder lies inside a git working tree',
        );
        expect(e.next, contains(keysRootVariable));
      },
    );

    test('is refused for a folder that a variable of the reference names, ignored or not', () async {
      final repo = Directory(inside(temp.path, 'project'))..createSync();
      await git(repo.path, ['init', '-q']);
      File(inside(repo.path, '.gitignore')).writeAsStringSync('ci/\n');
      final ci = keyFolder(inside(repo.path, 'ci'));
      final e = await refused(
        locate(app(), env({ascOverrideVariable('team-one'): ci.path})),
      );
      expect(
        e.what,
        'WINCODE_ASC_KEY_DIR_TEAM_ONE points inside a git working tree',
      );
      expect(
        e.next,
        contains('point WINCODE_ASC_KEY_DIR_TEAM_ONE at the new place'),
      );
      final dist = await refused(
        resolveDistKey(
          app(),
          environment: env({
            distOverrideVariable('team-one'): inside(ci.path, 'dist.key'),
          }),
          redactor: Redactor(active: false),
        ),
      );
      expect(
        dist.what,
        'WINCODE_DIST_KEY_TEAM_ONE points inside a git working tree',
      );
    });

    test('is found when only the folder of the reference is a repository inside a root that is outside every one', () async {
      final folder = keyFolder('${defaultRoot()}${sep}team-one');
      await git(folder.path, ['init', '-q']);
      final e = await refused(locate(app(), env()));
      expect(e.id, 'keys-in-git-tree');
      expect(
        e.what,
        'the folder of the credentials team-one lies inside a git working tree',
      );
    });

    test('passes outside every repository', () async {
      keyFolder('${defaultRoot()}${sep}team-one');
      expect(await locate(app(), env()), isNotNull);
    });

    test('the legacy rule is as it was: a key that git ignores passes, one that it does not is refused', () async {
      final repo = Directory(inside(temp.path, 'project'))..createSync();
      await git(repo.path, ['init', '-q']);
      final legacy = keyFolder(inside(repo.path, 'asc'));
      final environment = env({'WINCODE_ASC_KEY_DIR': legacy.path});
      final e = await refused(locate(app(reference: null), environment));
      expect(
        e.what,
        'WINCODE_ASC_KEY_DIR points inside a git working tree, and git does not ignore the file',
      );
      File(inside(repo.path, '.gitignore')).writeAsStringSync('asc/\n');
      expect(await locate(app(reference: null), environment), isNotNull);
      // The same ignored folder, named for a reference, is refused.
      final strict = await refused(
        locate(app(), env({ascOverrideVariable('team-one'): legacy.path})),
      );
      expect(strict.id, 'keys-in-git-tree');
    });

    test('a git that is missing or fails refuses the folder (69)', () async {
      keyFolder('${defaultRoot()}${sep}team-one');
      Future<ProcessResult> missing(
        String e,
        List<String> a, {
        String? workingDirectory,
      }) => throw ProcessException(e, a);
      final e = await refused(locate(app(), env(), run: missing));
      expect(e.id, 'git-unavailable');
      expect(e.exitCode, ExitCode.unavailable);
      Future<ProcessResult> fails(
        String e,
        List<String> a, {
        String? workingDirectory,
      }) async => ProcessResult(0, 128, '', 'fatal: something else');
      expect(
        (await refused(locate(app(), env(), run: fails))).id,
        'git-unavailable',
      );
    });
  });

  group('OneDrive', () {
    test(
      'a keys root in OneDrive is refused, by variable or by default',
      () async {
        final root = '${temp.path}${sep}OneDrive${sep}keys';
        keyFolder('$root${sep}team-one');
        final e = await refused(locate(app(), env({keysRootVariable: root})));
        expect(e.id, 'key-in-onedrive');
        expect(e.what, 'WINCODE_KEYS_DIR points into OneDrive');
        expect(e.describe('wincode preflight'), isNot(contains(root)));
        final ci = keyFolder('${temp.path}${sep}OneDrive${sep}ci');
        final v = await refused(
          locate(app(), env({ascOverrideVariable('team-one'): ci.path})),
        );
        expect(v.what, 'WINCODE_ASC_KEY_DIR_TEAM_ONE points into OneDrive');
      },
    );
  });

  group('wsl.exe', () {
    test('is never started by the resolution of any half', () async {
      keyFolder('${defaultRoot()}${sep}team-one');
      final (run, started) = recording();
      final redactor = Redactor(active: false);
      final key = await locate(app(), env(), run: run);
      readAscKeyIds(key!, redactor);
      await resolveDistKey(
        app(),
        environment: env(),
        redactor: redactor,
        run: run,
      );
      expect(started, isNotEmpty);
      expect(started.toSet(), {'git'});
    });
  });

  group('redaction', () {
    test('an error prints the placeholders of the reference and the app, and not the folder', () async {
      final redactor = Redactor(active: true);
      final settings = loadSettings(
        write('wincode.yaml', example).path,
        redactor: redactor,
      );
      final root = inside(temp.path, 'private-keys');
      keyFolder('$root${sep}team-one');
      final e = await refused(
        locate(
          settings.app('gamma')!,
          env({keysRootVariable: root}),
          redactor: redactor,
        ),
      );
      final text = redactor.apply(e.describe('wincode preflight'));
      expect(
        text,
        contains('the credentials credentials-2 of app app-3 are missing'),
      );
      expect(text, contains('WINCODE_ASC_KEY_DIR_CREDENTIALS_2'));
      expect(text, isNot(contains('team-two')));
      expect(text, isNot(contains('gamma')));
    });

    test('the folders found are secrets: the root, the folder of a reference and a variable\'s folder', () async {
      final redactor = Redactor(active: false);
      final root = inside(temp.path, 'private-keys');
      keyFolder('$root${sep}team-one');
      await locate(
        app(redactor: redactor),
        env({keysRootVariable: root}),
        redactor: redactor,
      );
      expect(
        redactor.apply('${Directory(root).absolute.path}${sep}team-one'),
        '<WINCODE_KEYS_DIR>${sep}team-one',
      );
      final ci = keyFolder(inside(temp.path, 'ci-folder'));
      await locate(
        app(redactor: redactor),
        env({ascOverrideVariable('team-one'): ci.path}),
        redactor: redactor,
      );
      expect(redactor.apply(ci.absolute.path), '<keys folder>');
      final ids = readAscKeyIds(
        (await locate(
          app(),
          env({ascOverrideVariable('team-one'): ci.path}),
          redactor: redactor,
        ))!,
        redactor,
      );
      expect(
        redactor.apply('${ids.keyId} ${ids.issuer}'),
        '<Key ID> <Issuer ID>',
      );
    });
  });

  group('the commands', () {
    late ThrowawayKey throwaway;
    FakeAppStoreConnect? apple;
    final now = DateTime.utc(2026, 11, 9, 12);
    setUp(() => throwaway = ThrowawayKey());
    tearDown(() async {
      await apple?.close();
      apple = null;
    });

    File config(String reference, {String extra = ''}) => write(
      'wincode.yaml',
      'bundle_id: com.example.alpha\nteam_id: TEAM000001\ncredentials: $reference\n$extra',
    );

    void realKey(String path, String id) {
      Directory(path).createSync(recursive: true);
      File(inside(path, 'AuthKey_$id.p8')).writeAsStringSync(throwaway.pem());
      File(inside(path, 'issuer-id')).writeAsStringSync('$issuer\n');
    }

    Future<(int, String, String)> wincode(
      List<String> args, {
      Map<String, String>? environment,
      RunProcess run = runProcess,
    }) async {
      final out = StringBuffer();
      final err = StringBuffer();
      await apple?.close();
      final server = apple = await FakeAppStoreConnect.start(
        (request) => FakeAnswer.error(404, 'NOT_FOUND'),
        key: throwaway,
        now: () => now,
      );
      final code = await runWincode(
        args,
        out,
        err,
        environment: environment ?? env(),
        clock: () => now,
        run: run,
        connect: (token, log) => HttpAscClient(
          api: server.uri,
          token: token,
          log: log,
          timeout: const Duration(seconds: 5),
          retryDelays: const [Duration(milliseconds: 1)],
        ),
      );
      final printed = '$out$err';
      for (final secret in [keyId, issuer, home]) {
        expect(printed, isNot(contains(secret)), reason: 'printed $secret');
      }
      return (code, '$out', '$err');
    }

    String kid(FakeRequest request) {
      final header = request.authorization!
          .substring('Bearer '.length)
          .split('.')
          .first;
      return (jsonDecode(
            utf8.decode(base64Url.decode(base64Url.normalize(header))),
          ) as Map)['kid']
          as String;
    }

    test('preflight reads the key of the reference, with the Key ID of that reference', () async {
      realKey('${defaultRoot()}${sep}team-one', 'ONEONEONE1');
      realKey('${defaultRoot()}${sep}team-two', 'TWOTWOTWO2');
      for (final (reference, id) in [
        ('team-one', 'ONEONEONE1'),
        ('team-two', 'TWOTWOTWO2'),
      ]) {
        final cfg = config(reference);
        final (code, out, _) = await wincode([
          'preflight',
          '--config',
          cfg.path,
        ]);
        expect(code, isNot(ExitCode.config.code), reason: out);
        expect(
          out,
          contains(
            'PASS  the keys of the credentials $reference lie outside every git working tree',
          ),
        );
        expect(apple!.requests, isNotEmpty);
        expect(apple!.requests.map(kid).toSet(), {id});
      }
    });

    test('preflight --dry-run signs a token from the reference and starts no program but git', () async {
      realKey('${defaultRoot()}${sep}team-one', 'ONEONEONE1');
      final (run, started) = recording();
      final (code, out, _) = await wincode([
        'preflight',
        '--config',
        config('team-one').path,
        '--dry-run',
      ], run: run);
      expect(code, 0);
      expect(out, contains('token signed locally, not shown'));
      expect(apple!.requests, isEmpty);
      expect(started.toSet().difference({'git'}), isEmpty);
    });

    test('preflight with missing credentials is a setup error (78) with the ADR message', () async {
      final (code, out, _) = await wincode([
        'preflight',
        '--config',
        config('team-one').path,
      ]);
      expect(code, 78);
      expect(out, contains('FAIL  the credentials team-one are missing'));
    });

    test('preflight never starts wsl.exe, in a full run either', () async {
      realKey('${defaultRoot()}${sep}team-one', 'ONEONEONE1');
      final (run, started) = recording();
      await wincode([
        'preflight',
        '--config',
        config('team-one').path,
      ], run: run);
      expect(started.where((e) => e.toLowerCase().contains('wsl')), isEmpty);
    });

    test(
      '--redact and CI hide the reference and the paths in a failure',
      () async {
        for (final args in [
          ['--redact'],
          <String>[],
        ]) {
          final environment = args.isEmpty ? env({'CI': 'true'}) : env();
          final (code, out, _) = await wincode([
            'preflight',
            '--config',
            config('team-one').path,
            ...args,
          ], environment: environment);
          expect(code, 78);
          expect(out, isNot(contains('team-one')));
          expect(out, contains('credentials-1'));
          expect(out, contains('WINCODE_ASC_KEY_DIR_CREDENTIALS_1'));
        }
      },
    );

    test('doctor without options checks the setup: the settings and the key folder', () async {
      realKey('${defaultRoot()}${sep}team-one', 'ONEONEONE1');
      final (code, out, _) = await wincode([
        'doctor',
        '--config',
        config('team-one').path,
      ]);
      expect(code, 0, reason: out);
      expect(out, contains('PASS  wincode.yaml loads'));
      expect(
        out,
        contains(
          'PASS  the App Store Connect key folder holds one AuthKey_<Key ID>.p8 and an issuer-id',
        ),
      );
      expect(out, contains('wincode doctor: passed'));
      expect(apple!.requests, isEmpty);
    });

    test('doctor says what is missing, and --json gives the checks', () async {
      final (code, out, err) = await wincode([
        'doctor',
        '--config',
        config('team-one').path,
        '--json',
      ]);
      expect(code, 78);
      expect(err, contains('the credentials team-one are missing'));
      final json = jsonDecode(out) as Map<String, Object?>;
      expect(json['command'], 'doctor');
      expect(json['ok'], isFalse);
      expect(json['exitCode'], 78);
      final checks = json['checks']! as List;
      expect(checks.map((c) => (c as Map)['check']), [
        'settings',
        'credentials',
      ]);
      expect(((json['error']! as Map)['id']), 'credentials-missing');
    });

    test('doctor with a broken wincode.yaml reports the settings and checks nothing else', () async {
      final bad = write('wincode.yaml', 'bundle_id: nonsense\n');
      final (code, out, _) = await wincode([
        'doctor',
        '--config',
        bad.path,
        '--json',
      ]);
      expect(code, 78);
      final checks = (jsonDecode(out) as Map)['checks']! as List;
      expect(checks.map((c) => (c as Map)['check']), ['settings']);
    });

    test('doctor for a flat file without credentials checks WINCODE_ASC_KEY_DIR as before', () async {
      final legacy = Directory(inside(temp.path, 'asc'));
      realKey(legacy.path, 'LEGACYKEY1');
      final cfg = write(
        'wincode.yaml',
        'bundle_id: com.example.alpha\nteam_id: TEAM000001\n',
      );
      final (code, out, _) = await wincode(
        ['doctor', '--config', cfg.path],
        environment: {'WINCODE_ASC_KEY_DIR': legacy.path},
      );
      expect(code, 0, reason: out);
      final (missing, report, _) = await wincode([
        'doctor',
        '--config',
        cfg.path,
      ], environment: {});
      expect(missing, 78);
      expect(report, contains('WINCODE_ASC_KEY_DIR is not set'));
    });
  });
}
