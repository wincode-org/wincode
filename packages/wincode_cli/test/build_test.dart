import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wincode_asc/testing.dart';
import 'package:wincode_asc/wincode_asc.dart';
import 'package:wincode_cli/src/build_number.dart';
import 'package:wincode_cli/wincode_cli.dart';
import 'package:wincode_core/wincode_core.dart' show RunProcess, runProcess;

import 'fake_github.dart';
import 'private.dart';

/// ADR-0015, parts 2 and 3: everything `wincode build` checks before a dispatch, against a fake GitHub (no network).
final _now = DateTime.utc(2026, 11, 15, 12);
const _token = 'github_pat_FAKE0123456789abcdefghijklmnopqrstuv';

/// The bundle ID of the Release configuration of the flavored sample project that the fake repository holds.
const _bundleId = 'org.example.demo';
const _keyId = 'ABCDE12345';
const _appRecord = '1000000001';

/// What GitHub answers to the dispatch of a build whose checks all passed: the token may not start a run. The tests of the
/// checks read this as "every check passed".
final _dispatchRefused = GhAnswer.error(
  403,
  'Resource not accessible by personal access token',
);
const _passedChecks = (77, 'github-forbidden');

const _workflowRef =
    'example-org/example-app/.github/workflows/wincode-ios.yml@main';

/// A flat `wincode.yaml` for the fake repository. A null [workflow], [flutter] or [xcode] leaves the key out.
String _flat({
  String bundleId = _bundleId,
  String? workflow = _workflowRef,
  String? flutter = '3.47.7',
  String? xcode = '26.0',
  String extra = '',
}) => [
  'bundle_id: $bundleId',
  'team_id: TEAM000001',
  if (workflow != null) 'workflow: $workflow',
  if (flutter != null) 'flutter_version: $flutter',
  if (xcode != null) 'min_xcode_version: "$xcode"',
  extra,
].join('\n');

/// A file of apps: `alpha` builds the flavor alpha, `beta` the flavor beta, each with its own bundle ID.
String _apps({String alpha = '', String beta = ''}) =>
    'defaults:\n'
    '  team_id: TEAM000001\n'
    '  credentials: team-one\n'
    '  workflow: $_workflowRef\n'
    '  flutter_version: 3.47.7\n'
    '  min_xcode_version: "26.0"\n'
    'apps:\n'
    '  alpha:\n    bundle_id: org.example.demo.alpha\n    flavor: alpha\n$alpha'
    '  beta:\n    bundle_id: org.example.demo.beta\n    flavor: beta\n$beta';

void main() {
  late Directory temp;
  late FakeRepo repo;
  FakeGithub? github;
  FakeAppStoreConnect? apple;
  late ThrowawayKey ascKey;
  late Directory keys;
  late String issuer;
  late File config;
  final slept = <Duration>[];
  final ghCalls = <List<String>>[];

  String inside(Directory folder, String name) =>
      '${folder.path}${Platform.pathSeparator}$name';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('wincode_build_');
    repo = FakeRepo();
    ascKey = ThrowawayKey();
    final random = Random.secure();
    String hex(int n) =>
        [for (var i = 0; i < n; i++) random.nextInt(16).toRadixString(16)]
            .join();
    issuer = [hex(8), hex(4), hex(4), hex(4), hex(12)].join('-');
    keys = private(Directory(inside(temp, 'asc'))..createSync());
    private(
      File(inside(keys, 'AuthKey_$_keyId.p8'))..writeAsStringSync(ascKey.pem()),
    );
    File(inside(keys, 'issuer-id')).writeAsStringSync('$issuer\n');
    config = File(inside(temp, 'wincode.yaml'))..writeAsStringSync(_flat());
    slept.clear();
    ghCalls.clear();
  });

  tearDown(() async {
    await github?.close();
    await apple?.close();
    github = null;
    apple = null;
    temp.deleteSync(recursive: true);
  });

  /// The fake App Store Connect, with the app record of [bundleId] and these builds and build uploads. Null [uploads]
  /// is an App Store Connect that has no such endpoint.
  Future<void> startApple({
    List<String> builds = const [],
    List<String>? uploads = const [],
    String bundleId = _bundleId,
    bool appRecord = true,
    Map<String, List<String>> more = const {},
  }) async {
    // The records, by bundle ID: the app of the test, then those of [more] with their builds.
    final records = <String, List<String>>{
      if (appRecord) bundleId: builds,
      ...more,
    };
    String idOf(String bundle) =>
        '${int.parse(_appRecord) + records.keys.toList().indexOf(bundle)}';
    apple = await FakeAppStoreConnect.start(
      (r) {
        if (r.path == '/v1/apps') {
          final wanted = r.query['filter[bundleId]'];
          return FakeAnswer.page([
            for (final bundle in records.keys)
              if (wanted == null || wanted == bundle)
                fakeResource('apps', idOf(bundle), {'bundleId': bundle}),
          ]);
        }
        for (final MapEntry(key: bundle, value: numbers) in records.entries) {
          if (r.path == '/v1/apps/${idOf(bundle)}/builds') {
            return FakeAnswer.page([
              for (final (i, v) in numbers.indexed)
                fakeResource('builds', 'b$i', {
                  'version': v,
                  'processingState': 'VALID',
                }),
            ]);
          }
          if (r.path == '/v1/apps/${idOf(bundle)}/buildUploads') {
            return uploads == null
                ? FakeAnswer.error(404, 'NOT_FOUND')
                : FakeAnswer.page([
                    for (final (i, v) in uploads.indexed)
                      fakeResource('buildUploads', 'u$i', {
                        'cfBundleVersion': v,
                      }),
                  ]);
          }
        }
        return FakeAnswer.error(404, 'NOT_FOUND');
      },
      key: ascKey,
      now: () => _now,
    );
  }

  /// Runs `wincode [command] [args]` against the fakes, and checks what must hold for every run: no secret printed, and
  /// nothing but GET requests sent to GitHub and to Apple. Returns the exit code, stdout and stderr.
  Future<(int, String, String)> wincode(
    List<String> args, {
    String command = 'build',
    String? yaml,
    Map<String, String>? environment,
    GhAnswer? Function(GhRequest)? answer,
    RunProcess? run,
  }) async {
    if (yaml != null) config.writeAsStringSync(yaml);
    final server = github ??= await FakeGithub.start(
      (r) =>
          answer?.call(r) ??
          (r.method == 'POST' && r.path.endsWith('/dispatches')
              ? _dispatchRefused
              : repo(r)),
      token: _token,
    );
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runWincode(
      [
        command,
        '--config',
        config.path,
        // These tests are about the checks: a build that passes them is let through the question.
        if (command == 'build' && !args.contains('--dry-run')) '--yes',
        ...args,
      ],
      out,
      err,
      environment: environment ?? {'GH_TOKEN': _token},
      clock: () => _now,
      connectGithub: (token, log) => HttpGithubClient(
        api: server.uri,
        token: token,
        log: log,
        timeout: const Duration(seconds: 5),
        retryDelays: const [Duration(milliseconds: 1)],
        sleep: (d) async => slept.add(d),
        clock: () => _now,
      ),
      connect: (token, log) => HttpAscClient(
        api: (apple ?? (throw StateError('App Store Connect was asked'))).uri,
        token: token,
        log: log,
        timeout: const Duration(seconds: 5),
        retryDelays: const [Duration(milliseconds: 1)],
      ),
      run:
          run ??
          (exe, args, {workingDirectory}) async {
            // gh is not installed here; git, which the key-location checks run, is.
            if (exe != 'gh') {
              return runProcess(exe, args, workingDirectory: workingDirectory);
            }
            ghCalls.add([exe, ...args]);
            throw ProcessException(exe, args, 'not found', 2);
          },
    );
    final printed = '$out$err';
    expect(printed, isNot(contains(_token)), reason: 'the token was printed');
    expect(
      printed,
      isNot(contains(RegExp(r'Bearer [A-Za-z0-9_.-]{12,}'))),
      reason: 'an Authorization header was printed',
    );
    for (final r in server.requests) {
      expect(
        r.method == 'GET' || r.path.endsWith('/dispatches'),
        isTrue,
        reason: 'only reads, and the dispatch that is refused: $r',
      );
    }
    for (final r in apple?.requests ?? const <FakeRequest>[]) {
      expect(r.method, 'GET', reason: '${r.method} ${r.path}');
    }
    return (code, '$out', '$err');
  }

  Map<String, Object?> parse(String out) =>
      jsonDecode(out) as Map<String, Object?>;

  /// Runs `wincode build --json [args]`: the exit code, the object, and the id of the first failure.
  Future<(int, Map<String, Object?>, String?)> buildJson(
    List<String> args, {
    String? yaml,
    Map<String, String>? environment,
    GhAnswer? Function(GhRequest)? answer,
  }) async {
    final (code, out, err) = await wincode(
      ['--json', ...args],
      yaml: yaml,
      environment: environment,
      answer: answer,
    );
    final json = parse(out);
    printOnFailure('wincode build ${args.join(' ')}\n$out\n$err');
    expect(json['exitCode'], code, reason: err);
    final error = json['error'] as Map<String, Object?>?;
    return (code, json, error?['id'] as String?);
  }

  List<Map<String, Object?>> checksOf(Map<String, Object?> json) =>
      (json['checks']! as List<Object?>).cast<Map<String, Object?>>();

  /// The checks of [json] that have this [status], by name. The refused dispatch of a build whose checks all passed is
  /// not one of the checks.
  List<String> named(Map<String, Object?> json, String status) => [
    for (final c in checksOf(json))
      if (c['status'] == status && c['check'] != 'dispatch') '${c['check']}',
  ];

  List<String> paths() => [
    for (final r in github!.requests) '${r.method} ${r.path}',
  ];

  const repoPath = '/repos/example-org/example-app';

  group('a build with nothing wrong', () {
    test('makes every check with GET requests, shows its plan, and goes on to the dispatch', () async {
      final (code, out, err) = await wincode([]);
      expect(code, 77, reason: '$out$err');
      expect(
        out,
        contains(
          'FAIL  GitHub refused POST /repos/example-org/example-app/actions/workflows/wincode-ios.yml/dispatches',
        ),
      );
      expect(out, contains('Nothing was started.'));
      for (final line in [
        'PASS  wincode.yaml names the workflow, flutter_version and min_xcode_version',
        'PASS  the token comes from GH_TOKEN, a fine-grained token',
        'PASS  example-org/example-app is private, so the account pays for the minutes (default branch main)',
        'PASS  wincode-ios.yml is an active workflow of example-org/example-app',
        'PASS  main is commit 1a2b3c4, and every file below is read at that commit',
        'PASS  the workflow at main says contract 2, the one this wincode needs',
        'PASS  the workflow declares every input that wincode build sends, and needs no other',
        'PASS  the workflow selects Xcode 26.6, which is 26.0 or later',
        'PASS  pubspec.yaml allows Flutter 3.47.7 (environment: flutter: >=3.27.0 <4.0.0)',
        'PASS  flutter/flutter has a tag 3.47.7, which the workflow clones',
        "PASS  the version is 2.3.0 (pubspec.yaml's version at main)",
        'PASS  lib/main.dart is in the repository at the commit',
        'PASS  the Xcode project has the shared scheme Runner, which Flutter builds',
        'PASS  flavor (none) builds the configuration Release, as wincode.yaml says',
        'PASS  the configuration Release has the bundle ID $_bundleId',
        'PASS  no run of this app is going, and none succeeded in the last 24 hours',
        'INFO  nothing was read in App Store Connect: the app has no credentials',
        'WARN  build 57 was not compared with App Store Connect: this app has no credentials',
      ]) {
        expect(out, contains(line));
      }
      expect(
        out,
        contains('''
Build plan:
  app:         $_bundleId
  repository:  example-org/example-app, private: the account pays for the minutes
  workflow:    .github/workflows/wincode-ios.yml, contract 2
  ref:         main, commit 1a2b3c4
  runner:      macos-26, stopped after 45 minutes (timeout-minutes)
  xcode:       26.6 (XCODE_APP), at least 26.0 (min_xcode_version)
  flutter:     3.47.7 (flutter_version), allowed by pubspec.yaml
  flavor:      none, scheme Runner, configuration Release
  target:      lib/main.dart
  version:     2.3.0 (pubspec.yaml's version at main)
  build:       57 (pubspec.yaml's number at main)
'''),
      );
      expect(
        ghCalls,
        isEmpty,
        reason: 'the token came from GH_TOKEN, so gh was not asked',
      );
    });

    test('reads, one request each: the repository, the workflow, the commit, its tree, the files, the tag and the runs', () async {
      await wincode([]);
      expect(paths().take(4), [
        'GET $repoPath',
        'GET $repoPath/actions/workflows/wincode-ios.yml',
        'GET $repoPath/commits/main',
        'GET $repoPath/git/trees/${repo.tree}',
      ]);
      expect(paths().toSet(), {
        'GET $repoPath',
        'GET $repoPath/actions/workflows/wincode-ios.yml',
        'GET $repoPath/commits/main',
        'GET $repoPath/git/trees/${repo.tree}',
        'GET $repoPath/contents/.github/workflows/wincode-ios.yml',
        'GET $repoPath/contents/pubspec.yaml',
        'GET $repoPath/contents/ios/Runner.xcodeproj/project.pbxproj',
        'GET $repoPath/contents/ios/Flutter/Release.xcconfig',
        'GET $repoPath/contents/ios/Flutter/alpha.xcconfig',
        'GET $repoPath/contents/ios/Flutter/beta.xcconfig',
        'GET /repos/flutter/flutter/git/ref/tags/3.47.7',
        'GET $repoPath/actions/workflows/wincode-ios.yml/runs',
        // The checks passed, and the fake GitHub refuses the dispatch that follows.
        'POST $repoPath/actions/workflows/wincode-ios.yml/dispatches',
      });
      expect(paths(), hasLength(13), reason: 'no request twice');
      // Every file is read at the commit, not at the branch, and the token goes with every request.
      for (final r in github!.requests.where(
        (r) => r.path.contains('/contents/'),
      )) {
        expect(r.query, {'ref': repo.commit});
        expect(r.headers['accept'], 'application/vnd.github.raw+json');
      }
      for (final r in github!.requests) {
        expect(r.token, _token);
        expect(r.headers['x-github-api-version'], '2026-03-10');
      }
      final runs = github!.requests.firstWhere((r) => r.path.endsWith('/runs'));
      expect(runs.query['event'], 'workflow_dispatch');
      expect(runs.query['created'], '>=2026-11-14T12:00:00Z');
    });

    test(
      '--json has the fields of the ADR, null where nothing is known yet',
      () async {
        final (code, json, id) = await buildJson([]);
        expect((code, id), _passedChecks);
        expect(json['command'], 'build');
        expect(json['app'], isNull);
        expect(json['ok'], isFalse);
        expect(json['repository'], 'example-org/example-app');
        expect(json['workflow'], '.github/workflows/wincode-ios.yml');
        expect(json['ref'], 'main');
        expect(json['commit'], repo.commit);
        expect(
          json['requestId'],
          matches(RegExp('^${appTag(_bundleId)}-2\\.3\\.0-57-[0-9a-f]{8}\$')),
        );
        expect(
          (
            json['runId'],
            json['runUrl'],
            json['conclusion'],
            json['ipa'],
            json['minutes'],
          ),
          (null, null, null, null, null),
        );
        expect((json['buildName'], json['buildNumber']), ('2.3.0', '57'));
        final plan = json['plan']! as Map<String, Object?>;
        expect(plan['buildNumberSource'], "pubspec.yaml's number at main");
        expect(plan['inputs'], {
          'request_id': json['requestId'],
          'build_name': '2.3.0',
          'build_number': '57',
          'flutter_version': '3.47.7',
          'min_xcode_version': '26.0',
          'flavor': '',
          'target': '',
        });
        expect(named(json, 'FAIL'), isEmpty);
      },
    );

    test('the run name hides the app: only a hash of the bundle ID is in the request ID', () async {
      final (_, json, _) = await buildJson([]);
      final id = json['requestId']! as String;
      expect(id, isNot(contains('demo')));
      expect(id, startsWith(appTag(_bundleId)));
    });
  });

  group('--dry-run', () {
    test('sends no request and starts no program, and prints the plan and the dispatch as it would go out', () async {
      final (code, out, err) = await wincode(['--dry-run']);
      expect(code, 0, reason: '$out$err');
      expect(github!.requests, isEmpty);
      expect(ghCalls, isEmpty);
      expect(
        out,
        contains('INFO  dry run: nothing was sent, and nothing was started'),
      );
      expect(out, contains('  ref:         main, commit <commit of main>'));
      expect(
        out,
        contains(
          '  runner:      <runs-on and timeout-minutes of the workflow at main>',
        ),
      );
      expect(
        out,
        contains(
          '  xcode:       <XCODE_APP of the workflow at main>, at least 26.0 (min_xcode_version)',
        ),
      );
      expect(
        out,
        contains(
          '  flutter:     3.47.7 (flutter_version), <checked against pubspec.yaml at main>',
        ),
      );
      expect(
        out,
        contains(
          "  version:     <pubspec.yaml at main> (pubspec.yaml's version at main)",
        ),
      );
      expect(
        out,
        contains(
          'POST https://api.github.com/repos/example-org/example-app/actions/workflows/wincode-ios.yml/dispatches',
        ),
      );
      expect(out, contains('    X-GitHub-Api-Version: 2026-03-10'));
      expect(out, contains('    Authorization: Bearer <token from GH_TOKEN>'));
      expect(out, contains('"ref":"main"'));
      expect(out, endsWith('wincode build: passed\n'));
    });

    test(
      'takes every value it can from wincode.yaml and the options',
      () async {
        final (code, out, err) = await wincode([
          '--dry-run',
          '--ref',
          'release/2.4',
          '--build-name',
          '2.5.0',
          '--build-number',
          '58',
        ], yaml: _flat(extra: 'target: lib/main_store.dart\nflavor: store\n'));
        expect(code, 0, reason: err);
        expect(
          out,
          contains(
            '  ref:         release/2.4, commit <commit of release/2.4>',
          ),
        );
        expect(
          out,
          contains(
            '  flavor:      store, scheme Store, configuration Release-store',
          ),
        );
        expect(out, contains('  target:      lib/main_store.dart'));
        expect(out, contains('  version:     2.5.0 (--build-name)'));
        expect(out, contains('  build:       58 (--build-number)'));
        final request = out
            .split('\n')
            .firstWhere((l) => l.startsWith('    {'));
        final body = parse(request);
        expect(body['ref'], 'release/2.4');
        expect(body['inputs'], containsPair('flavor', 'store'));
        expect(body['inputs'], containsPair('target', 'lib/main_store.dart'));
        expect(body['inputs'], containsPair('build_number', '58'));
        expect(github!.requests, isEmpty);
      },
    );

    test('in a file of apps, the number is auto, and the plan says what auto will ask', () async {
      final (code, out, err) = await wincode([
        '--dry-run',
        '--app',
        'alpha',
      ], yaml: _apps());
      expect(code, 0, reason: err);
      expect(
        out,
        contains(
          "  build:       <auto: App Store Connect's highest + 1> (auto)",
        ),
      );
      expect(out, contains('Authorization: Bearer <token from GH_TOKEN>'));
      expect(github!.requests, isEmpty);
    });

    test(
      'names the token variable of the app when it is set, and does not ask gh',
      () async {
        final (_, out, _) = await wincode(
          ['--dry-run', '--app', 'beta'],
          yaml: _apps(),
          environment: {'WINCODE_GH_TOKEN_BETA': _token, 'GH_TOKEN': 'other'},
        );
        expect(
          out,
          contains('Authorization: Bearer <token from WINCODE_GH_TOKEN_BETA>'),
        );
        final (_, other, _) = await wincode([
          '--dry-run',
          '--app',
          'alpha',
        ], environment: {});
        expect(
          other,
          contains('<token from gh auth token, which a dry run does not ask>'),
        );
        expect(ghCalls, isEmpty);
      },
    );

    test('--json gives the plan and the request as an object', () async {
      final (code, json, _) = await buildJson(['--dry-run']);
      expect(code, 0);
      expect(json['dryRun'], isTrue);
      expect(json['ok'], isTrue);
      expect(
        (json['request']! as List).first,
        startsWith('POST https://api.github.com/repos/'),
      );
      expect((json['plan']! as Map)['commit'], isNull);
    });

    test('a setting that is missing fails it too, with no request', () async {
      final (code, json, id) = await buildJson([
        '--dry-run',
      ], yaml: _flat(flutter: null));
      expect((code, id), (78, 'flutter-version-missing'));
      expect(github!.requests, isEmpty);
    });
  });

  group('every refusal comes before any dispatch, and nothing but GET is sent', () {
    /// Runs the build with [mutate] applied to the fake repository, and expects the first failure to be [id] with exit
    /// code [code]. Returns the object.
    Future<Map<String, Object?>> refused(
      String id,
      int code, {
      void Function()? mutate,
      String? yaml,
      List<String> args = const [],
      Map<String, String>? environment,
      GhAnswer? Function(GhRequest)? answer,
    }) async {
      mutate?.call();
      final (exit, json, found) = await buildJson(
        args,
        yaml: yaml,
        environment: environment,
        answer: answer,
      );
      expect((exit, found), (code, id), reason: jsonEncode(json['error']));
      expect(github!.requests.where((r) => r.method != 'GET'), isEmpty);
      return json;
    }

    group('the settings', () {
      test('no workflow: no request is sent', () async {
        await refused('workflow-missing', 78, yaml: _flat(workflow: null));
        expect(github!.requests, isEmpty);
      });

      test('no flutter_version, and no min_xcode_version', () async {
        final a = await refused(
          'flutter-version-missing',
          78,
          yaml: _flat(flutter: null),
        );
        expect(named(a, 'FAIL'), ['settings']);
        await github!.close();
        github = null;
        await refused('min-xcode-missing', 78, yaml: _flat(xcode: null));
      });
    });

    group('the token', () {
      test('none at all: 77, and nothing is sent', () async {
        final json = await refused('github-token-missing', 77, environment: {});
        expect(github!.requests, isEmpty);
        expect(
          (json['error']! as Map)['what'],
          contains(
            'GH_TOKEN and GITHUB_TOKEN are not set, and gh is not installed',
          ),
        );
        expect(ghCalls, [
          ['gh', 'auth', 'token', '--hostname', 'github.com'],
        ]);
      });

      test('GitHub refusing the token is 77 too', () async {
        await refused(
          'github-unauthorized',
          77,
          environment: {'GH_TOKEN': 'github_pat_WRONG0123456789abcdefghij'},
        );
        expect(github!.requests, hasLength(1));
      });

      test(
        'a value that cannot be a token is a setup error, and not sent',
        () async {
          await refused(
            'github-token-invalid',
            78,
            environment: {'GH_TOKEN': 'not a token'},
          );
          expect(github!.requests, isEmpty);
        },
      );

      test('gh gives it when no variable does', () async {
        final (code, out, err) = await wincode(
          [],
          environment: {},
          run: (exe, args, {workingDirectory}) async {
            ghCalls.add([exe, ...args]);
            return ProcessResult(1, 0, '$_token\n', '');
          },
        );
        expect(code, _passedChecks.$1, reason: '$out$err');
        expect(
          out,
          contains(
            'INFO  the token comes from gh auth token, a fine-grained token, which can do far more',
          ),
        );
        expect(github!.requests.first.token, _token);
      });

      test(
        'the token of one app comes before GH_TOKEN, for that app only',
        () async {
          final (code, _, err) = await wincode(
            ['--app', 'alpha', '--dry-run'],
            yaml: _apps(),
            environment: {
              'WINCODE_GH_TOKEN_ALPHA': _token,
              'GH_TOKEN': 'github_pat_OTHER0123456789abcdefgh',
            },
          );
          expect(code, 0, reason: err);
          final (beta, json, id) = await buildJson(
            ['--app', 'beta'],
            yaml: _apps(),
            environment: {
              'WINCODE_GH_TOKEN_ALPHA': _token,
              'GH_TOKEN': 'github_pat_OTHER0123456789abcdefgh',
            },
          );
          expect(
            (beta, id),
            (77, 'github-unauthorized'),
            reason: 'beta uses GH_TOKEN, which the fake refuses: $json',
          );
        },
      );
    });

    group('the repository, the workflow and the ref', () {
      test(
        'a repository that is not there, or that the token cannot see',
        () async {
          await refused(
            'repository-not-found',
            78,
            mutate: () => repo.owner = 'elsewhere',
          );
          expect(github!.requests, hasLength(1));
        },
      );

      test('a public repository is refused (64) without --allow-public, before the workflow is read', () async {
        final json = await refused(
          'repository-public',
          64,
          mutate: () => repo.isPrivate = false,
        );
        expect(github!.requests, hasLength(1));
        final error = json['error']! as Map<String, Object?>;
        expect(error['what'], 'example-org/example-app is a public repository');
        expect(error['next'], contains('give --allow-public'));
      });

      test('--allow-public builds in it, and says so', () async {
        repo.isPrivate = false;
        final (code, out, err) = await wincode(['--allow-public']);
        expect(code, _passedChecks.$1, reason: '$out$err');
        expect(
          out,
          contains(
            'INFO  example-org/example-app is public, and --allow-public was given',
          ),
        );
        expect(out, contains('public: standard runners are free'));
      });

      test('a workflow that is not on the default branch', () async {
        await refused(
          'workflow-not-found',
          78,
          mutate: () => repo.workflowExists = false,
        );
        expect(github!.requests, hasLength(2));
      });

      test('a workflow that is disabled', () async {
        await refused(
          'workflow-disabled',
          78,
          mutate: () => repo.workflowState = 'disabled_inactivity',
        );
      });

      test('a ref that is not a branch or a tag', () async {
        await refused(
          'ref-not-found',
          78,
          yaml: _flat(
            workflow: 'example-org/example-app/.github/workflows/wincode-ios.yml@nowhere',
          ),
        );
        expect(paths().last, 'GET $repoPath/commits/nowhere');
      });

      test('--ref builds another ref, and reads it', () async {
        repo.refs['release/2.4'] = repo.commit;
        final (code, out, _) = await wincode(['--ref', 'release/2.4']);
        expect(code, _passedChecks.$1);
        expect(out, contains('PASS  release/2.4 is commit 1a2b3c4'));
        expect(paths(), contains('GET $repoPath/commits/release/2.4'));
      });

      test('--ref with a commit SHA is refused (64) before any request, and so is a ref that is no name', () async {
        await refused(
          'ref-is-commit',
          64,
          args: ['--ref', '0123456789abcdef0123456789abcdef01234567'],
        );
        expect(github!.requests, isEmpty);
        final (code, _, err) = await wincode(['--ref', 'a b']);
        expect(code, 64);
        expect(err, contains('--ref is a branch or tag name'));
        expect(github!.requests, isEmpty);
      });

      test('a ref that moves between the checks is not an issue: every file is read at the commit that was found', () async {
        await wincode([]);
        final commits = {
          for (final r in github!.requests.where(
            (r) => r.path.contains('/contents/'),
          ))
            r.query['ref'],
        };
        expect(commits, {repo.commit});
      });
    });

    group('the project at the commit', () {
      test('no Flutter project at the root: one failure, without a cascade of the checks of its files', () async {
        final json = await refused(
          'project-not-found',
          78,
          mutate: () {
            repo.files.removeWhere(
              (k, _) => k == 'pubspec.yaml' || k.startsWith('ios/'),
            );
          },
        );
        expect(named(json, 'FAIL'), ['project']);
        expect(
          checksOf(json).map((c) => c['check']),
          isNot(contains('target')),
        );
      });

      test('a list that GitHub cut short is a warning, and the checks that need it cannot tell', () async {
        repo
          ..truncated = true
          ..schemes = [];
        final (code, json, _) = await buildJson([]);
        expect(code, _passedChecks.$1);
        expect(named(json, 'WARN'), containsAll(['project', 'scheme']));
        expect(named(json, 'FAIL'), isEmpty);
      });

      test('a file that GitHub does not give is a warning', () async {
        repo.failing['ios/Flutter/alpha.xcconfig'] = GhAnswer.error(
          403,
          'This API returns blobs up to 1 MB in size',
        );
        final (_, json, _) = await buildJson([]);
        expect(named(json, 'WARN'), contains('project'));
      });
    });

    group('the workflow at the ref', () {
      test(
        'contract 1 (no line) is refused with the message of the ADR',
        () async {
          final json = await refused(
            'workflow-contract',
            78,
            mutate: () {
              repo.files['.github/workflows/wincode-ios.yml'] = workflowText
                  .replaceFirst('# wincode-workflow-contract: 2\n', '');
            },
          );
          final error = json['error']! as Map<String, Object?>;
          expect(
            error['what'],
            'the workflow at main says no contract (contract 1), and this wincode needs contract 2',
          );
          expect(
            error['why'],
            contains(
              'GitHub refuses a run with inputs that its workflow does not declare. Nothing was started.',
            ),
          );
          expect(
            error['next'],
            contains(
              'run wincode init --workflow, which shows the changes and keeps the old file as wincode-ios.yml.bak',
            ),
          );
        },
      );

      test('contract 1 written out, and a contract that is newer than this wincode', () async {
        await refused(
          'workflow-contract',
          78,
          mutate: () {
            repo.files['.github/workflows/wincode-ios.yml'] = workflowText
                .replaceFirst('contract: 2', 'contract: 1');
          },
        );
        await github!.close();
        github = null;
        repo.files['.github/workflows/wincode-ios.yml'] = workflowText
            .replaceFirst('contract: 2', 'contract: 3');
        final (code, json, id) = await buildJson([]);
        expect((code, id), (78, 'workflow-contract'));
        expect(
          (json['error']! as Map)['why'],
          contains('a newer workflow expects a newer wincode'),
        );
      });

      test(
        'an input that wincode sends and the workflow does not declare',
        () async {
          final json = await refused(
            'workflow-input-unknown',
            78,
            mutate: () {
              repo.files['.github/workflows/wincode-ios.yml'] = workflowText
                  .replaceFirst(
                    '      target:\n        description: The entry point, or empty for lib/main.dart\n        required: false\n        type: string\n        default: ""\n',
                    '',
                  );
            },
          );
          expect(
            (json['error']! as Map)['what'],
            'the workflow at main declares no input target, and wincode build sends it',
          );
        },
      );

      test(
        'an entry of workflow_inputs that the workflow does not declare',
        () async {
          await refused(
            'workflow-input-unknown',
            78,
            yaml: _flat(extra: 'workflow_inputs:\n  environment: staging\n'),
          );
        },
      );

      test(
        'a required input without a default that wincode does not send',
        () async {
          final json = await refused(
            'workflow-input-missing',
            78,
            mutate: () {
              repo.files['.github/workflows/wincode-ios.yml'] = workflowText
                  .replaceFirst(
                    '      flavor:\n',
                    '      region:\n        required: true\n        type: string\n      flavor:\n',
                  );
            },
          );
          expect(
            (json['error']! as Map)['what'],
            contains(
              'requires an input that wincode build does not send: region',
            ),
          );
        },
      );

      test('a workflow_inputs entry that the workflow declares is accepted, and is sent', () async {
        repo.files['.github/workflows/wincode-ios.yml'] = workflowText
            .replaceFirst(
              '      flavor:\n',
              '      region:\n        required: true\n        type: string\n      flavor:\n',
            );
        final (_, json, _) = await buildJson(
          [],
          yaml: _flat(extra: 'workflow_inputs:\n  region: eu\n'),
        );
        expect((json['plan']! as Map)['inputs'], containsPair('region', 'eu'));
        expect(named(json, 'FAIL'), isEmpty);
      });

      test('a workflow that is not YAML', () async {
        await refused(
          'workflow-unreadable',
          78,
          mutate: () {
            repo.files['.github/workflows/wincode-ios.yml'] =
                '# wincode-workflow-contract: 2\n: : :\n  - [\n';
          },
        );
      });

      test('a workflow file that the ref does not have', () async {
        await refused(
          'workflow-not-found',
          78,
          mutate: () => repo.files.remove('.github/workflows/wincode-ios.yml'),
        );
      });
    });

    group('Xcode', () {
      test('older than min_xcode_version: the message of the ADR', () async {
        final json = await refused(
          'xcode-too-old',
          78,
          mutate: () {
            repo.files['.github/workflows/wincode-ios.yml'] = workflowText
                .replaceFirst('Xcode_26.6.app', 'Xcode_26.0.app');
          },
          yaml: _flat(xcode: '26.4'),
        );
        final error = json['error']! as Map<String, Object?>;
        expect(
          error['what'],
          'the workflow selects Xcode 26.0, and wincode.yaml asks for 26.4 or later',
        );
        expect(
          error['why'],
          contains(
            'min_xcode_version is the oldest Xcode that may build the app, and the job would stop at its Xcode step, after a billed minute. Nothing was started.',
          ),
        );
        expect(
          error['next'],
          contains(
            'set XCODE_APP in .github/workflows/wincode-ios.yml to an Xcode of 26.4 or later that the runner image has, push it to main, then run wincode build again.',
          ),
        );
      });

      test('equal, newer, and written with another number of parts', () async {
        for (final (have, want) in [
          ('26.6', '26.6'),
          ('26.6', '26.6.0'),
          ('26.10', '26.9'),
          ('27', '26.6'),
        ]) {
          repo.files['.github/workflows/wincode-ios.yml'] = workflowText
              .replaceFirst('Xcode_26.6.app', 'Xcode_$have.app');
          final (code, json, id) = await buildJson(
            [],
            yaml: _flat(xcode: want),
          );
          expect((code, id), _passedChecks, reason: '$have against $want');
          expect(named(json, 'FAIL'), isEmpty);
          await github!.close();
          github = null;
        }
      });

      test('an Xcode that names no version, or none at all, is a warning: the job checks it', () async {
        for (final change in [
          '/Applications/Xcode.app',
          '\${{ matrix.xcode }}',
        ]) {
          repo.files['.github/workflows/wincode-ios.yml'] = workflowText
              .replaceFirst('/Applications/Xcode_26.6.app', change);
          final (code, json, id) = await buildJson([]);
          expect((code, id), _passedChecks);
          expect(named(json, 'WARN'), contains('xcode'));
          await github!.close();
          github = null;
        }
      });
    });

    group('Flutter', () {
      test('a release that pubspec.yaml excludes', () async {
        final json = await refused(
          'flutter-version-mismatch',
          78,
          mutate: () {
            repo.files['pubspec.yaml'] = repo.files['pubspec.yaml']!
                .replaceFirst('>=3.27.0 <4.0.0', '>=3.50.0');
          },
        );
        expect(
          (json['error']! as Map)['what'],
          'pubspec.yaml allows Flutter >=3.50.0, and flutter_version is 3.47.7',
        );
      });

      test('a tag that flutter/flutter does not have: one read-only request, and a refusal before any dispatch', () async {
        final json = await refused(
          'flutter-version-not-found',
          78,
          yaml: _flat(flutter: '3.47.9'),
        );
        expect(paths().where((p) => p.contains('flutter/flutter')), [
          'GET /repos/flutter/flutter/git/ref/tags/3.47.9',
        ]);
        final error = json['error']! as Map<String, Object?>;
        expect(error['what'], 'flutter/flutter has no tag 3.47.9');
        expect(
          error['next'],
          contains('https://github.com/flutter/flutter/tags'),
        );
      });

      test('a pre-release tag is looked up as it is written', () async {
        final (code, _, _) = await buildJson(
          [],
          yaml: _flat(flutter: '3.48.0-0.1.pre'),
        );
        expect(code, _passedChecks.$1);
        expect(
          paths(),
          contains('GET /repos/flutter/flutter/git/ref/tags/3.48.0-0.1.pre'),
        );
      });

      test('the tag is checked when pubspec.yaml sets no constraint, and when there is no pubspec.yaml', () async {
        repo.files['pubspec.yaml'] = 'name: demo\nversion: 2.3.0+57\n';
        final (code, json, _) = await buildJson([]);
        expect(code, _passedChecks.$1);
        expect(
          checksOf(json).firstWhere((c) => c['check'] == 'flutter')['what'],
          contains('sets no environment: flutter: constraint'),
        );
        expect(
          paths(),
          contains('GET /repos/flutter/flutter/git/ref/tags/3.47.7'),
        );
      });

      test('a failing read of the tag stops the run, and is reported as GitHub\'s answer', () async {
        final (code, _, id) = await buildJson(
          [],
          answer: (r) => r.path.contains('flutter/flutter')
              ? GhAnswer.error(500, 'Server Error')
              : null,
        );
        expect((code, id), (69, 'github-unavailable'));
      });
    });

    group('the version, the entry point, the scheme and the configuration', () {
      test('no version anywhere', () async {
        await refused(
          'build-name-missing',
          78,
          mutate: () {
            repo.files['pubspec.yaml'] =
                'name: demo\nenvironment:\n  flutter: ">=3.27.0"\n';
          },
          args: ['--build-number', '3'],
        );
      });

      test('--build-name and build_name come before pubspec.yaml, and a pubspec version that Apple refuses is none', () async {
        repo.files['pubspec.yaml'] = 'name: demo\nversion: 1.0.0-beta+4\n';
        await refused('build-name-missing', 78);
        await github!.close();
        github = null;
        final (_, given, _) = await buildJson(['--build-name', '3.0.0']);
        expect(given['buildName'], '3.0.0');
        await github!.close();
        github = null;
        final (_, fromFile, _) = await buildJson(
          [],
          yaml: _flat(extra: 'build_name: 4.0.0\n'),
        );
        expect(
          (fromFile['plan']! as Map)['buildNameSource'],
          'build_name in wincode.yaml',
        );
        expect(fromFile['buildName'], '4.0.0');
      });

      test('an entry point that is not in the repository', () async {
        final json = await refused(
          'target-missing',
          78,
          yaml: _flat(extra: 'target: lib/main_store.dart\n'),
        );
        expect(
          (json['error']! as Map)['what'],
          'lib/main_store.dart is not in example-org/example-app at ${repo.commit.substring(0, 7)}',
        );
      });

      test(
        'an entry point that is there, with a flavor and its scheme',
        () async {
          repo.files['lib/main_alpha.dart'] = 'void main() {}';
          final (code, json, _) = await buildJson(
            [],
            yaml: _flat(
              bundleId: 'org.example.demo.alpha',
              extra: 'flavor: alpha\ntarget: lib/main_alpha.dart\n',
            ),
          );
          expect(code, _passedChecks.$1);
          expect(named(json, 'FAIL'), isEmpty);
          expect((json['plan']! as Map)['scheme'], 'Alpha');
          expect((json['plan']! as Map)['configuration'], 'Release-alpha');
        },
      );

      test('a scheme that is not shared', () async {
        final json = await refused(
          'scheme-missing',
          78,
          mutate: () => repo.schemes = ['Runner'],
          yaml: _flat(
            bundleId: 'org.example.demo.alpha',
            extra: 'flavor: alpha\n',
          ),
        );
        final error = json['error']! as Map<String, Object?>;
        expect(
          error['what'],
          'the Xcode project has no shared scheme Alpha, and it has Runner',
        );
        expect(error['next'], contains('tick Shared for Alpha'));
      });

      test('no shared scheme at all', () async {
        await refused('scheme-missing', 78, mutate: () => repo.schemes = []);
      });

      test(
        'a scheme that matches only ignoring case is the one Flutter builds',
        () async {
          repo.schemes = ['Runner', 'ALPHA'];
          final (code, json, _) = await buildJson(
            [],
            yaml: _flat(
              bundleId: 'org.example.demo.alpha',
              extra: 'flavor: alpha\n',
            ),
          );
          expect(code, _passedChecks.$1);
          expect((json['plan']! as Map)['scheme'], 'ALPHA');
        },
      );

      test('the silent fallback to Release: the message of the ADR', () async {
        final json = await refused(
          'configuration-mismatch',
          78,
          mutate: () => repo.schemes = ['Runner', 'Gamma'],
          yaml: _flat(extra: 'flavor: gamma\n'),
        );
        final error = json['error']! as Map<String, Object?>;
        expect(
          error['what'],
          'flavor gamma builds the configuration Release, not Release-gamma',
        );
        expect(
          error['why'],
          startsWith(
            "Flutter builds the configuration named after the flavor's scheme (Gamma), and when the project has none it builds Release without an error, so the IPA would carry Release's bundle ID and settings.",
          ),
        );
        expect(
          error['next'],
          startsWith(
            'add a configuration Release-Gamma to ios/Runner.xcodeproj and push it, or set configuration in wincode.yaml',
          ),
        );
      });

      test(
        'a configuration that wincode.yaml names and Flutter does not build',
        () async {
          final json = await refused(
            'configuration-mismatch',
            78,
            yaml: _flat(
              bundleId: 'org.example.demo.alpha',
              extra: 'flavor: alpha\nconfiguration: Release-beta\n',
            ),
          );
          expect(
            (json['error']! as Map)['what'],
            'flavor alpha builds the configuration Release-alpha, and wincode.yaml says Release-beta',
          );
        },
      );

      test('the bundle ID that the configuration has must be bundle_id (exit 1)', () async {
        final json = await refused(
          'bundle-id-mismatch',
          1,
          yaml: _flat(bundleId: 'org.example.other'),
        );
        final error = json['error']! as Map<String, Object?>;
        expect(
          error['what'],
          'the configuration Release has the bundle ID $_bundleId, but wincode.yaml says org.example.other',
        );
      });

      test(
        'a bundle ID from an xcconfig that is not committed is a warning',
        () async {
          repo.files.remove('ios/Flutter/alpha.xcconfig');
          final (code, json, _) = await buildJson(
            [],
            yaml: _flat(
              bundleId: 'org.example.demo.alpha',
              extra: 'flavor: alpha\n',
            ),
          );
          expect(code, _passedChecks.$1);
          expect(named(json, 'WARN'), contains('bundle-id'));
          expect(named(json, 'FAIL'), isEmpty);
        },
      );

      test(
        'a project file that cannot be read is a warning, not a failure',
        () async {
          repo.files['ios/Runner.xcodeproj/project.pbxproj'] = 'garbage';
          final (code, json, _) = await buildJson([]);
          expect(code, _passedChecks.$1);
          expect(named(json, 'WARN'), contains('configuration'));
        },
      );
    });

    group('the build number', () {
      test('a flat file without +N in pubspec.yaml, and no option', () async {
        await refused(
          'build-number-missing',
          78,
          mutate: () {
            repo.files['pubspec.yaml'] = repo.files['pubspec.yaml']!
                .replaceFirst('+57', '');
          },
        );
      });

      test('--build-number gives the number, and an unusual one is refused (64) before any request', () async {
        final (_, json, _) = await buildJson(['--build-number', '12']);
        expect(json['buildNumber'], '12');
        expect((json['plan']! as Map)['buildNumberSource'], '--build-number');
        for (final bad in ['x', '1.2.3.4', '-3', '']) {
          final (code, _, err) = await wincode(['--build-number', bad]);
          expect(code, 64, reason: bad);
          expect(err, contains('--build-number is a number'));
        }
        final (code, _, err) = await wincode(['--build-name', '2.x']);
        expect(code, 64);
        expect(err, contains('--build-name is one to three whole numbers'));
      });

      test(
        'a build of the app that is going stops this one, and links it',
        () async {
          final tag = appTag(_bundleId);
          final json = await refused(
            'build-in-progress',
            1,
            mutate: () => repo.runs.add(
              fakeRun(
                777,
                '$tag-2.3.0-58-0a0a0a0a',
                status: 'in_progress',
                conclusion: null,
              ),
            ),
          );
          final error = json['error']! as Map<String, Object?>;
          expect(
            error['what'],
            'a build of this app is already running: https://github.com/example-org/example-app/actions/runs/777 (build 58)',
          );
          expect(
            error['next'],
            'collect it with wincode build --run 777, or cancel it at https://github.com/example-org/example-app/actions/runs/777, then run wincode build again.',
          );
        },
      );

      test('a run of another app, or one that ended badly, or one older than a day, is not in the way', () async {
        final tag = appTag(_bundleId);
        repo.runs.addAll([
          fakeRun(
            1,
            '${appTag('org.example.other')}-2.3.0-58-0a0a0a0a',
            status: 'in_progress',
            conclusion: null,
          ),
          fakeRun(2, '$tag-2.3.0-58-0a0a0a0a', conclusion: 'failure'),
          fakeRun(
            3,
            '$tag-2.3.0-90-0a0a0a0a',
            status: 'in_progress',
            conclusion: null,
            created: _now.subtract(const Duration(hours: 30)),
          ),
          fakeRun(4, '$tag-2.3.0-59-0a0a0a0a', conclusion: 'cancelled'),
        ]);
        final (code, json, _) = await buildJson([]);
        expect(code, _passedChecks.$1);
        expect(named(json, 'FAIL'), isEmpty);
      });

      test('a given number must be above a successful run of the app, which holds its number', () async {
        final tag = appTag(_bundleId);
        repo.runs.add(fakeRun(5, '$tag-2.3.0-60-0a0a0a0a'));
        final json = await refused(
          'build-number-not-higher',
          1,
          args: ['--build-number', '60'],
        );
        expect(
          (json['error']! as Map)['what'],
          'build 60 is not higher than 60, the highest build of a run in the last 24 hours for this app',
        );
        await github!.close();
        github = null;
        final (code, ok, _) = await buildJson(['--build-number', '61']);
        expect(code, _passedChecks.$1);
        expect(ok['buildNumber'], '61');
      });

      test('more than one page of runs is read, and a list that is cut short is a warning', () async {
        final tag = appTag(_bundleId);
        for (var i = 0; i < 230; i++) {
          repo.runs.add(fakeRun(1000 + i, 'ffffffffffff-1.0.0-$i-0a0a0a0a'));
        }
        repo.runs.add(
          fakeRun(
            9999,
            '$tag-2.3.0-61-0a0a0a0a',
            status: 'queued',
            conclusion: null,
            created: _now,
          ),
        );
        final (_, json, id) = await buildJson([]);
        expect(
          id,
          'build-in-progress',
          reason: 'the last run is on the third page',
        );
        expect(paths().where((p) => p.endsWith('/runs')), hasLength(3));
        expect(json['ok'], isFalse);
      });
    });

    group('the build number from App Store Connect (auto)', () {
      test('is one above the highest build, and above the highest successful run of the last day', () async {
        await startApple(builds: ['40', '41', '9']);
        repo.runs.add(fakeRun(5, '${appTag(_bundleId)}-2.3.0-43-0a0a0a0a'));
        final (code, json, _) = await buildJson(
          ['--build-number', 'auto'],
          environment: {'GH_TOKEN': _token, 'WINCODE_ASC_KEY_DIR': keys.path},
        );
        expect(code, _passedChecks.$1);
        expect(json['buildNumber'], '44');
        final plan = json['plan']! as Map<String, Object?>;
        expect(plan['buildNumberSource'], 'auto');
        expect((json['requestId']! as String), contains('-2.3.0-44-'));
        expect(apple!.requests.map((r) => r.path).toSet(), {
          '/v1/apps',
          '/v1/apps/$_appRecord/builds',
          '/v1/apps/$_appRecord/buildUploads',
        });
      });

      test('the highest of builds, build uploads and runs wins', () async {
        await startApple(builds: ['40'], uploads: ['52']);
        repo.runs.add(fakeRun(5, '${appTag(_bundleId)}-2.3.0-45-0a0a0a0a'));
        final (_, json, _) = await buildJson(
          ['--build-number', 'auto'],
          environment: {'GH_TOKEN': _token, 'WINCODE_ASC_KEY_DIR': keys.path},
        );
        expect(
          json['buildNumber'],
          '53',
          reason: 'an upload that Apple has not turned into a build holds its number',
        );
      });

      test('an app with no build yet starts at 1', () async {
        await startApple();
        final (_, json, _) = await buildJson(
          ['--build-number', 'auto'],
          environment: {'GH_TOKEN': _token, 'WINCODE_ASC_KEY_DIR': keys.path},
        );
        expect(json['buildNumber'], '1');
      });

      test('an App Store Connect without the build uploads endpoint gives the builds only, and says so', () async {
        await startApple(builds: ['7'], uploads: null);
        final (code, out, _) = await wincode(
          ['--build-number', 'auto'],
          environment: {'GH_TOKEN': _token, 'WINCODE_ASC_KEY_DIR': keys.path},
        );
        expect(code, _passedChecks.$1);
        expect(
          out,
          contains(
            "highest build number for this app is 7, from its builds only: it did not list the build uploads",
          ),
        );
      });

      test('a highest number with dots cannot be added to', () async {
        await startApple(builds: ['57.1', '12']);
        final (code, json, id) = await buildJson(
          ['--build-number', 'auto'],
          environment: {'GH_TOKEN': _token, 'WINCODE_ASC_KEY_DIR': keys.path},
        );
        expect((code, id), (1, 'build-number-auto'));
        expect(
          (json['error']! as Map)['what'],
          contains('57.1, which has dots'),
        );
      });

      test('in a flat file without credentials it is credentials-missing (78), and App Store Connect is not asked', () async {
        final (code, json, id) = await buildJson(['--build-number', 'auto']);
        expect((code, id), (78, 'credentials-missing'));
        expect(json['buildNumber'], isNull);
      });

      test('a given number is checked against App Store Connect when the app has credentials', () async {
        await startApple(builds: ['57']);
        final (code, _, id) = await buildJson(
          [],
          environment: {'GH_TOKEN': _token, 'WINCODE_ASC_KEY_DIR': keys.path},
        );
        expect(
          (code, id),
          (1, 'build-number-not-higher'),
          reason: 'pubspec.yaml says 57, and Apple has 57',
        );
        await github!.close();
        github = null;
        final (ok, json, _) = await buildJson(
          ['--build-number', '58'],
          environment: {'GH_TOKEN': _token, 'WINCODE_ASC_KEY_DIR': keys.path},
        );
        expect(ok, _passedChecks.$1);
        expect(named(json, 'WARN'), isNot(contains('build-number')));
      });

      test('an app record that App Store Connect lacks', () async {
        await startApple(appRecord: false);
        final (code, _, id) = await buildJson(
          ['--build-number', 'auto'],
          environment: {'GH_TOKEN': _token, 'WINCODE_ASC_KEY_DIR': keys.path},
        );
        expect((code, id), (1, 'app-record-missing'));
      });

      test('a key that Apple refuses is 77, and a key folder that is not there is a setup error', () async {
        await startApple(builds: ['1']);
        await apple!.close();
        apple = await FakeAppStoreConnect.start(
          (_) => FakeAnswer.error(401, 'NOT_AUTHORIZED'),
        );
        final (code, _, id) = await buildJson(
          ['--build-number', 'auto'],
          environment: {'GH_TOKEN': _token, 'WINCODE_ASC_KEY_DIR': keys.path},
        );
        expect((code, id), (77, 'asc-unauthorized'));
        await github!.close();
        github = null;
        final (setup, _, other) = await buildJson(
          ['--build-number', 'auto'],
          environment: {
            'GH_TOKEN': _token,
            'WINCODE_ASC_KEY_DIR': inside(temp, 'nowhere'),
          },
        );
        expect(setup, 78);
        expect(other, isNotNull);
      });

      test('in a file of apps, auto is the default, with the key of the reference and the flavor of each app', () async {
        await startApple(builds: ['20'], bundleId: 'org.example.demo.alpha');
        final environment = {
          'GH_TOKEN': _token,
          'WINCODE_ASC_KEY_DIR_TEAM_ONE': keys.path,
        };
        final (code, json, _) = await buildJson(
          ['--app', 'alpha'],
          yaml: _apps(),
          environment: environment,
        );
        expect(code, _passedChecks.$1);
        expect(json['app'], 'alpha');
        expect(json['buildNumber'], '21');
        final plan = json['plan']! as Map<String, Object?>;
        expect(
          (plan['buildNumberSource'], plan['scheme'], plan['configuration']),
          ('auto', 'Alpha', 'Release-alpha'),
        );
        expect(json['requestId'], startsWith(appTag('org.example.demo.alpha')));
        expect(
          (json['requestId']! as String),
          isNot(startsWith(appTag('org.example.demo.beta'))),
        );
      });

      test(
        'two apps of one workflow get their own inputs and their own tag',
        () async {
          await startApple(builds: ['20'], bundleId: 'org.example.demo.alpha');
          final environment = {
            'GH_TOKEN': _token,
            'WINCODE_ASC_KEY_DIR_TEAM_ONE': keys.path,
          };
          final (_, alpha, _) = await buildJson(
            ['--app', 'alpha'],
            yaml: _apps(),
            environment: environment,
          );
          await github!.close();
          github = null;
          await apple!.close();
          await startApple(builds: ['3'], bundleId: 'org.example.demo.beta');
          final (_, beta, _) = await buildJson(
            ['--app', 'beta'],
            yaml: _apps(),
            environment: environment,
          );
          final a = (alpha['plan']! as Map)['inputs']! as Map<String, Object?>;
          final b = (beta['plan']! as Map)['inputs']! as Map<String, Object?>;
          expect((a['flavor'], a['build_number']), ('alpha', '21'));
          expect((b['flavor'], b['build_number']), ('beta', '4'));
          expect(
            (a['request_id']! as String).split('-').first,
            isNot((b['request_id']! as String).split('-').first),
          );
        },
      );
    });
  });

  group('GitHub failing', () {
    test('a rate limit that clears soon is waited out', () async {
      var calls = 0;
      final (code, _, _) = await buildJson(
        [],
        answer: (r) => r.path == repoPath && ++calls == 1
            ? GhAnswer.error(429, 'Slow down', headers: {'retry-after': '3'})
            : null,
      );
      expect(code, _passedChecks.$1);
      expect(slept, [const Duration(seconds: 3)]);
    });

    test('a rate limit that does not clear is 69 with its own id', () async {
      final (code, json, id) = await buildJson(
        [],
        answer: (r) => GhAnswer.error(
          403,
          'You have exceeded a secondary rate limit',
          headers: {'retry-after': '900'},
        ),
      );
      expect((code, id), (69, 'github-rate-limited'));
      expect(checksOf(json).last['check'], 'build');
      expect(slept, isEmpty);
    });

    test('a permission that is missing is 77, and ends the run', () async {
      final (code, _, id) = await buildJson(
        [],
        answer: (r) => r.path.endsWith('/git/trees/${repo.tree}')
            ? GhAnswer.error(
                403,
                'Resource not accessible by personal access token',
              )
            : null,
      );
      expect((code, id), (77, 'github-forbidden'));
    });

    test('no answer at all is offline (69)', () async {
      final (_, out, _) = await wincode(['--dry-run']);
      expect(out, isNotEmpty);
      await github!.close();
      final (code, json, id) = await buildJson([]);
      expect((code, id), (69, 'offline'));
      expect(json['ok'], isFalse);
    });

    test(
      'an answer that is not what GitHub documents is github-error',
      () async {
        final (code, _, id) = await buildJson(
          [],
          answer: (r) =>
              r.path == repoPath ? const GhAnswer.text('<html>') : null,
        );
        expect((code, id), (1, 'github-error'));
      },
    );
  });

  group('a workflow that is not winCode\'s template', () {
    const driftCheck = 'workflow-contract';

    List<Map<String, Object?>> drifts(Map<String, Object?> json) => [
      for (final c in checksOf(json))
        if (c['check'] == driftCheck && c['status'] == 'WARN') c,
    ];

    test('the template itself passes the contract, the inputs and the Xcode, with no warning', () async {
      final (code, json, id) = await buildJson([]);
      expect((code, id), _passedChecks);
      expect(drifts(json), isEmpty);
      final passed = [
        for (final c in checksOf(json))
          if (c['status'] == 'PASS') '${c['what']}',
      ];
      expect(
        passed,
        containsAll([
          'the workflow at main says contract 2, the one this wincode needs',
          'the workflow declares every input that wincode build sends, and needs no other',
          'the workflow selects Xcode 26.6, which is 26.0 or later',
        ]),
      );
    });

    test('the three values of its owner, comments and the order of keys are not differences', () async {
      repo.files['.github/workflows/wincode-ios.yml'] =
          '# A note of the owner\n${workflowText.replaceFirst('runs-on: macos-26', 'runs-on: macos-15').replaceFirst('timeout-minutes: 45', 'timeout-minutes: 90').replaceFirst('Xcode_26.6.app', 'Xcode_26.0.app').replaceFirst('permissions:\n  contents: read\n\n', '').replaceFirst('name: wincode-ios\n', 'permissions:\n  contents: read\nname: wincode-ios\n')}';
      final (code, json, id) = await buildJson([]);
      expect((code, id), _passedChecks);
      expect(drifts(json), isEmpty);
    });

    test(
      'is one warning that names its parts, and the build goes on',
      () async {
        repo.files['.github/workflows/wincode-ios.yml'] = workflowText
            .replaceFirst(
              '          xcodebuild -version\n',
              '          xcodebuild -version\n          echo extra\n',
            )
            .replaceFirst(
              'description: The entry point, or empty for lib/main.dart\n        required: false\n        type: string\n        default: ""',
              'description: The entry point\n        required: false\n        type: string\n        default: lib/main.dart',
            )
            .replaceFirst('contents: read', 'contents: write');
        final (code, json, id) = await buildJson([]);
        expect((code, id), _passedChecks, reason: 'the build is not refused');
        final found = drifts(json);
        expect(found, hasLength(1));
        expect(
          found.single['what'],
          'the workflow at main has contract 2 but differs from winCode\'s template in: permissions, input target, step "Xcode" (3 parts)',
        );
        expect(
          [
            for (final c in checksOf(json))
              if (c['check'] == driftCheck) c['status'],
          ],
          ['PASS', 'WARN'],
        );
      },
    );

    test('names a step that was added, and one that is missing, and a pin that was bumped', () async {
      repo.files['.github/workflows/wincode-ios.yml'] = workflowText
          .replaceFirst(
            'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1',
            'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b2 # v7.0.2',
          )
          .replaceFirst(
            '      - name: Flutter\n',
            '      - name: Lint\n        run: echo lint\n\n      - name: Flutter\n',
          );
      // Flutter is renamed, so that the template's step is missing and the owner's is a new one.
      repo.files['.github/workflows/wincode-ios.yml'] = repo
          .files['.github/workflows/wincode-ios.yml']!
          .replaceFirst('      - name: Flutter\n', '      - name: Flutter 3\n');
      final (_, json, _) = await buildJson([]);
      final text = '${drifts(json).single['what']}';
      expect(text, contains('step "actions/checkout"'));
      expect(text, contains('step "Lint" (added)'));
      expect(text, contains('step "Flutter 3" (added)'));
      expect(text, contains('step "Flutter" (missing)'));
    });

    test(
      'with --verbose shows the differing lines, without the three values',
      () async {
        repo.files['.github/workflows/wincode-ios.yml'] = workflowText
            .replaceFirst('runs-on: macos-26', 'runs-on: macos-15')
            .replaceFirst(
              '          xcodebuild -version\n',
              '          xcodebuild -version\n          echo extra\n',
            );
        final (_, _, err) = await wincode(['--verbose']);
        expect(err, contains('the workflow differs from winCode\'s template'));
        expect(err, contains('-           echo extra'));
        final diff = [
          for (final l in err.split('\n'))
            if (l.startsWith('- ') || l.startsWith('+ ')) l,
        ];
        expect(diff, isNotEmpty);
        expect(diff.join('\n'), isNot(contains('runs-on')));
      },
    );

    test(
      'is shown by --json as a check, and by doctor --build as a WARN',
      () async {
        repo.files['.github/workflows/wincode-ios.yml'] = workflowText
            .replaceFirst(
              "if: github.event_name == 'workflow_dispatch'",
              "if: github.event_name == 'workflow_dispatch' && true",
            );
        await startApple(builds: ['3']);
        final (code, out, err) = await wincode(
          ['--build'],
          command: 'doctor',
          environment: {'GH_TOKEN': _token, 'WINCODE_ASC_KEY_DIR': keys.path},
        );
        expect(code, 0, reason: '$out$err');
        expect(
          out,
          contains(
            'WARN  the workflow at main has contract 2 but differs from winCode\'s template in: job unsigned-ipa if (1 part)',
          ),
        );
        expect(out, contains('PASS  the workflow at main says contract 2'));
        expect(
          out,
          contains('run wincode init --workflow to see the differences.'),
        );
      },
    );
  });

  group('doctor --build', () {
    Map<String, String> asc() => {
      'GH_TOKEN': _token,
      'WINCODE_ASC_KEY_DIR': keys.path,
    };

    test('says that Actions write is not tested ahead, and plain build does not', () async {
      const line =
          'Actions write permission is not tested ahead: every request that needs it changes something, and the dispatch itself refuses a token without it, before anything runs';
      await startApple(builds: ['3']);
      final (_, doctorOut, _) = await wincode(
        ['--build'],
        command: 'doctor',
        environment: asc(),
      );
      expect(doctorOut, contains('INFO  $line'));
      final (_, buildOut, _) = await wincode([]);
      expect(buildOut, isNot(contains('Actions write permission')));
    });

    test('makes the checks of build and prints no plan, and does not stop at the place of the dispatch', () async {
      await startApple(builds: ['3']);
      final (code, out, err) = await wincode(
        ['--build'],
        command: 'doctor',
        environment: asc(),
      );
      expect(code, 0, reason: '$out$err');
      expect(out, isNot(contains('Build plan')));
      expect(out, isNot(contains('not implemented')));
      expect(out, contains('PASS  wincode.yaml loads'));
      expect(out, contains('PASS  the version is 2.3.0'));
      expect(
        out,
        contains('PASS  build 57 is higher than 3, the highest known'),
      );
      expect(out, endsWith('wincode doctor: passed\n'));
      expect(github!.requests, isNotEmpty);
    });

    test('is --build only: without it doctor reads no GitHub', () async {
      final (code, _, err) = await wincode(
        [],
        command: 'doctor',
        environment: asc(),
      );
      expect(code, 0, reason: err);
      expect(github?.requests ?? const [], isEmpty);
    });

    test('a public repository is a warning here, since --allow-public is an option of build', () async {
      repo.isPrivate = false;
      await startApple(builds: ['3']);
      final (code, out, _) = await wincode(
        ['--build'],
        command: 'doctor',
        environment: asc(),
      );
      expect(code, 0);
      expect(
        out,
        contains('WARN  example-org/example-app is a public repository'),
      );
      expect(out, contains('wincode build will need --allow-public'));
    });

    test('fails as build does, with the exit code of the first failure, and sends nothing but GET', () async {
      repo.files['pubspec.yaml'] = repo.files['pubspec.yaml']!.replaceFirst(
        '>=3.27.0 <4.0.0',
        '>=3.50.0',
      );
      await startApple(builds: ['3']);
      final (code, json, id) = await (() async {
        final (c, o, _) = await wincode(
          ['--build', '--json'],
          command: 'doctor',
          environment: asc(),
        );
        final j = parse(o);
        return (c, j, (j['error'] as Map<String, Object?>?)?['id'] as String?);
      })();
      expect((code, id), (78, 'flutter-version-mismatch'));
      expect(named(json, 'FAIL'), ['flutter']);
      expect(json['command'], 'doctor');
    });

    test('has no --dry-run, and is not for a binary', () async {
      final (code, _, err) = await wincode(
        ['--build', '--dry-run'],
        command: 'doctor',
        environment: asc(),
      );
      expect(code, 64);
      expect(err, contains('doctor --build reads GitHub'));
      final (other, _, message) = await wincode(
        ['--build', '--binary', 'x', '--sdk', 'y'],
        command: 'doctor',
        environment: asc(),
      );
      expect(other, 64);
      expect(message, contains('--sign and --build check the setup'));
      expect(github!.requests, isEmpty);
    });

    test('--all checks every app of a file and prints the table; the exit code is that of the first app that fails', () async {
      repo.schemes = ['Runner', 'Alpha'];
      await startApple(
        builds: ['20'],
        bundleId: 'org.example.demo.alpha',
        more: {
          'org.example.demo.beta': ['3'],
        },
      );
      final environment = {
        'GH_TOKEN': _token,
        'WINCODE_ASC_KEY_DIR_TEAM_ONE': keys.path,
      };
      final (code, out, err) = await wincode(
        ['--build', '--all'],
        command: 'doctor',
        yaml: _apps(),
        environment: environment,
      );
      expect(code, 78, reason: '$out$err');
      expect(out, contains('== alpha =='));
      expect(out, contains('== beta =='));
      expect(
        out,
        contains('wincode doctor --all: 1 of 2 apps failed; exit 78'),
      );
      final table = out
          .split('\n')
          .where((l) => RegExp(r'^(alpha|beta) ').hasMatch(l))
          .toList();
      expect(table, [
        startsWith('alpha  PASS'),
        allOf(
          startsWith('beta   FAIL'),
          contains('scheme-missing'),
          endsWith('78'),
        ),
      ]);
    });

    test('--app checks one app, with the --json object of that app', () async {
      await startApple(builds: ['20'], bundleId: 'org.example.demo.alpha');
      final environment = {
        'GH_TOKEN': _token,
        'WINCODE_ASC_KEY_DIR_TEAM_ONE': keys.path,
      };
      final (code, out, err) = await wincode(
        ['--build', '--app', 'alpha', '--json'],
        command: 'doctor',
        yaml: _apps(),
        environment: environment,
      );
      expect(code, 0, reason: err);
      final json = parse(out);
      expect(
        (json['command'], json['app'], json['ok']),
        ('doctor', 'alpha', true),
      );
      expect(named(json, 'FAIL'), isEmpty);
    });
  });

  group('--events', () {
    test('build writes a check event for each finding, the plan, and the result that is the object of --json', () async {
      final (code, out, err) = await wincode(['--events']);
      expect(code, _passedChecks.$1, reason: err);
      final events = [
        for (final l in const LineSplitter().convert(out)) parse(l),
      ];
      final names = [for (final e in events) e['event']];
      expect(names.first, 'check');
      expect(names.last, 'result');
      expect(names.where((n) => n == 'plan'), hasLength(1));
      // The plan comes after the checks, and then the dispatch that the fake GitHub refuses is one more check.
      expect(
        names[names.length - 3],
        'plan',
        reason: 'the plan comes after the checks, and before the dispatch and the result',
      );
      expect(names.take(names.length - 3), everyElement('check'));
      expect(names[names.length - 2], 'check');
      final plan = events.firstWhere((e) => e['event'] == 'plan');
      expect(
        plan.keys,
        containsAll([
          'event',
          'time',
          'app',
          'repository',
          'private',
          'workflow',
          'ref',
          'commit',
          'runsOn',
          'timeoutMinutes',
          'inputs',
          'buildName',
          'buildNumber',
          'buildNumberSource',
        ]),
      );
      expect(plan['time'], '2026-11-15T12:00:00Z');
      expect(
        (
          plan['repository'],
          plan['private'],
          plan['runsOn'],
          plan['timeoutMinutes'],
        ),
        ('example-org/example-app', true, 'macos-26', 45),
      );
      expect(events.last['ok'], isFalse);
      expect((events.last['error']! as Map)['id'], 'github-forbidden');
      expect(err, contains('PASS'));
      expect(out, isNot(contains('PASS  ')));
      await github!.close();
      github = null;
      final (_, json, _) = await buildJson([]);
      final result = Map.of(events.last)..remove('event');
      for (final key in ['requestId']) {
        result.remove(key);
        json.remove(key);
      }
      ((result['plan']! as Map).cast<String, Object?>())
        ..remove('requestId')
        ..remove('inputs');
      ((json['plan']! as Map).cast<String, Object?>())
        ..remove('requestId')
        ..remove('inputs');
      expect(result, json);
    });

    test(
      'a dry run writes the plan and the result, and no request is sent',
      () async {
        final (code, out, _) = await wincode(['--events', '--dry-run']);
        expect(code, 0);
        final events = [
          for (final l in const LineSplitter().convert(out)) parse(l),
        ];
        expect(
          {for (final e in events) e['event']},
          {'check', 'plan', 'result'},
        );
        expect(github!.requests, isEmpty);
      },
    );

    test(
      'a failure before the checks can report is still a result event',
      () async {
        final (code, out, _) = await wincode([
          '--events',
        ], yaml: _flat(workflow: null));
        expect(code, 78);
        final events = [
          for (final l in const LineSplitter().convert(out)) parse(l),
        ];
        expect(events.last['event'], 'result');
        expect(events.last['exitCode'], 78);
        final failed = events.where(
          (e) => e['event'] == 'check' && e['status'] == 'FAIL',
        );
        expect(failed.single['id'], 'settings');
      },
    );

    test('--events with --json is a usage error', () async {
      final (code, out, _) = await wincode(['--events', '--json']);
      expect(code, 64);
      expect((parse(out)['error']! as Map)['id'], 'usage');
      expect(github?.requests ?? const [], isEmpty);
    });

    test(
      '--all is refused for build, as for the commands that write',
      () async {
        final (code, out, _) = await wincode(['--all', '--json']);
        expect(code, 64);
        expect((parse(out)['error']! as Map)['id'], 'all-not-allowed');
        expect(github?.requests ?? const [], isEmpty);
      },
    );
  });

  group('the names in the output', () {
    test('--redact hides the app, its bundle ID and its variable, and never the token', () async {
      final (code, out, err) = await wincode(
        ['--redact', '--app', 'alpha', '--dry-run'],
        yaml: _apps(),
        environment: {'WINCODE_GH_TOKEN_ALPHA': _token},
      );
      expect(code, 0, reason: err);
      expect(out, isNot(contains('alpha')));
      expect(out, isNot(contains('org.example.demo.alpha')));
      expect(out, contains('<token from WINCODE_GH_TOKEN_APP_1>'));
      expect(out, contains('app:         app-1 (<bundle ID 1>)'));
    });

    test('--verbose logs each request without the token', () async {
      final (_, _, err) = await wincode(['--verbose']);
      expect(
        err,
        contains('GET 127.0.0.1/repos/example-org/example-app: HTTP 200'),
      );
      expect(
        err,
        contains(
          'GET 127.0.0.1/repos/flutter/flutter/git/ref/tags/3.47.7: HTTP 200',
        ),
      );
    });
  });
}
