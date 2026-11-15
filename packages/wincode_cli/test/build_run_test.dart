import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wincode_cli/src/build_number.dart';
import 'package:wincode_cli/wincode_cli.dart';
import 'package:wincode_core/testing.dart';
import 'package:wincode_core/wincode_core.dart'
    show runProcess, writePlistBinary;

import 'fake_actions.dart';
import 'fake_github.dart';

/// ADR-0015, part 5b: what `wincode build` does after its checks, against a fake GitHub (no network): the question, the
/// dispatch, the wait, Ctrl-C, the artifact and its checks. Time is a variable that the waits advance.
const _token = 'github_pat_FAKE0123456789abcdefghijklmnopqrstuv';
const _bundleId = 'org.example.demo';
const _workflowRef =
    'example-org/example-app/.github/workflows/wincode-ios.yml@main';

String _flat({String extra = ''}) => [
  'bundle_id: $_bundleId',
  'team_id: TEAM000001',
  'workflow: $_workflowRef',
  'flutter_version: 3.47.7',
  'min_xcode_version: "26.0"',
  extra,
].join('\n');

/// An unsigned IPA of the sample project: version 2.3.0, build 57, as its pubspec.yaml says.
Uint8List _ipa({
  String bundleId = _bundleId,
  String version = '2.3.0',
  String build = '57',
  bool profile = false,
  bool twoApps = false,
  List<int>? infoPlist,
}) => zipOf({
  'Payload/Runner.app/Info.plist':
      infoPlist ??
      writePlistBinary({
        'CFBundleIdentifier': bundleId,
        'CFBundleShortVersionString': version,
        'CFBundleVersion': build,
      }),
  'Payload/Runner.app/Runner': List.generate(5000, (i) => i * 7 % 251),
  if (profile) 'Payload/Runner.app/embedded.mobileprovision': [1, 2, 3],
  if (twoApps)
    'Payload/Other.app/Info.plist': writePlistBinary({
      'CFBundleIdentifier': 'org.example.other',
    }),
});

/// The artifact of a run: the IPA and the hash that the build job recorded, which is the IPA's unless [recorded] says
/// otherwise.
Uint8List _artifact(
  List<int> ipa, {
  String? recorded,
  bool hash = true,
  Map<String, List<int>> more = const {},
}) => zipOf({
  'unsigned.ipa': ipa,
  if (hash)
    'unsigned.ipa.sha256': utf8.encode(
      '${recorded ?? sha256Hex(ipa)}  unsigned.ipa\n',
    ),
  ...more,
});

void main() {
  late Directory temp;
  late FakeRepo repo;
  late FakeActions actions;
  late File config;
  late DateTime now;
  late StreamController<ProcessSignal> signals;
  late Uint8List ipa;
  FakeGithub? github;
  FakeGithub? storage;
  final slept = <Duration>[];
  GhAnswer Function(GhRequest) storageAnswers = (_) => const GhAnswer({});

  String inside(Directory folder, String name) =>
      '${folder.path}${Platform.pathSeparator}$name';

  Directory output() => Directory(inside(temp, 'build/wincode'));
  File unsigned() => File(inside(output(), 'unsigned.ipa'));

  setUp(() {
    temp = Directory.systemTemp.createTempSync('wincode_run_');
    repo = FakeRepo();
    now = DateTime.utc(2026, 11, 15, 12);
    actions = FakeActions(repo, now: () => now);
    config = File(inside(temp, 'wincode.yaml'))..writeAsStringSync(_flat());
    signals = StreamController<ProcessSignal>.broadcast(sync: true);
    ipa = _ipa();
    actions.zip = _artifact(ipa);
    storageAnswers = (_) => GhAnswer.bytes(actions.zip!);
    slept.clear();
  });

  tearDown(() async {
    await github?.close();
    await storage?.close();
    github = null;
    storage = null;
    await signals.close();
    temp.deleteSync(recursive: true);
  });

  Future<void> pause(Duration d) async {
    slept.add(d);
    now = now.add(d);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> serve() async {
    storage ??= await FakeGithub.start((r) => storageAnswers(r));
    actions.storage = storage!.uri;
    github ??= await FakeGithub.start(
      (r) => actions.handle(r) ?? repo(r),
      token: _token,
    );
  }

  /// Runs `wincode [command] [args]` against the fakes, and checks what must hold for every run: no token and no signed
  /// link in anything printed, the token sent to the API only, at most one dispatch, and no folder of the download left.
  Future<(int, String, String)> wincode(
    List<String> args, {
    String command = 'build',
    bool terminal = false,
    List<String> answers = const [],
    Future<String?> Function()? answer,
    Map<String, String>? environment,
  }) async {
    await serve();
    final out = StringBuffer();
    final err = StringBuffer();
    final lines = [...answers];
    final code = await runWincode(
      [command, '--config', config.path, ...args],
      out,
      err,
      environment: environment ?? {'GH_TOKEN': _token},
      clock: () => now,
      connectGithub: (token, log) => HttpGithubClient(
        api: github!.uri,
        token: token,
        log: log,
        timeout: const Duration(seconds: 5),
        retryDelays: const [Duration(milliseconds: 1)],
        sleep: pause,
        clock: () => now,
      ),
      run: (exe, a, {workingDirectory}) async {
        // gh is not installed here; git, which the key-location checks run, is.
        if (exe != 'gh') {
          return runProcess(exe, a, workingDirectory: workingDirectory);
        }
        throw ProcessException(exe, a, 'not found', 2);
      },
      terminal: terminal,
      answer: answer ?? () async => lines.isEmpty ? null : lines.removeAt(0),
      sleep: pause,
      interrupts: () => signals.stream,
    );
    final printed = '$out$err';
    expect(printed, isNot(contains(_token)), reason: 'the token was printed');
    expect(
      printed,
      isNot(contains(FakeActions.signature)),
      reason: 'the signed link was printed',
    );
    expect(printed, isNot(contains(RegExp(r'Bearer [A-Za-z0-9_.-]{12,}'))));
    expect(
      actions.dispatches.length,
      lessThanOrEqualTo(1),
      reason: 'the dispatch is never sent twice',
    );
    for (final r in storage?.requests ?? const <GhRequest>[]) {
      expect(r.headers, isNot(contains('authorization')), reason: '$r');
    }
    for (final r in github!.requests) {
      expect(r.token, _token, reason: 'every request carries the token');
    }
    if (output().existsSync()) {
      expect(
        output().listSync().map((e) => e.uri.pathSegments.last),
        everyElement(isNot(startsWith('.wincode-build-'))),
        reason: 'the folder of the download is deleted',
      );
    }
    return (code, '$out', '$err');
  }

  /// `wincode build --yes --json [args]`: the exit code, the object, and the id of its error.
  Future<(int, Map<String, Object?>, String?)> buildJson(
    List<String> args, {
    bool yes = true,
    Map<String, String>? environment,
  }) async {
    final (code, out, err) = await wincode([
      '--json',
      if (yes) '--yes',
      ...args,
    ], environment: environment);
    printOnFailure('wincode build ${args.join(' ')}\n$out\n$err');
    final json = jsonDecode(out) as Map<String, Object?>;
    expect(json['exitCode'], code, reason: err);
    return (
      code,
      json,
      (json['error'] as Map<String, Object?>?)?['id'] as String?,
    );
  }

  List<Map<String, Object?>> eventsOf(String out) => [
    for (final line in const LineSplitter().convert(out))
      jsonDecode(line) as Map<String, Object?>,
  ];

  String requestId() =>
      (actions.dispatches.single.json['inputs'] as Map)['request_id'] as String;

  /// The paths that the API server got, with their methods.
  List<String> paths() => [
    for (final r in github!.requests) '${r.method} ${r.path}',
  ];

  List<String> checkIds(Map<String, Object?> json, String status) => [
    for (final c in json['checks']! as List<Object?>)
      if ((c as Map)['status'] == status) '${c['check']}',
  ];

  const base = '/repos/example-org/example-app';

  group('the question', () {
    test('--yes starts the run without asking', () async {
      final (code, out, err) = await wincode(['--yes']);
      expect(code, 0, reason: '$out$err');
      expect(out, isNot(contains('Start this build')));
      expect(actions.dispatches, hasLength(1));
    });

    test(
      'at a terminal it prints the plan and asks, and y starts the run',
      () async {
        final (code, out, err) = await wincode(
          [],
          terminal: true,
          answers: ['y'],
        );
        expect(code, 0, reason: '$out$err');
        expect(out, contains('Build plan:'));
        expect(
          out,
          contains('Start this build on GitHub? It uses macOS minutes. [y/N] '),
        );
        expect(actions.dispatches, hasLength(1));
      },
    );

    test('yes, in capitals, is also a yes', () async {
      final (code, _, err) = await wincode(
        [],
        terminal: true,
        answers: [' YES '],
      );
      expect(code, 0, reason: err);
    });

    test(
      'any other answer, an empty one and the end of the input start nothing',
      () async {
        for (final answers in [
          ['n'],
          [''],
          ['maybe'],
          ['yess'],
          <String>[],
        ]) {
          actions = FakeActions(repo, now: () => now)..zip = _artifact(ipa);
          final (code, out, err) = await wincode(
            [],
            terminal: true,
            answers: answers,
          );
          expect(code, 1, reason: '$answers');
          expect(out, contains('FAIL  the build was not started'));
          expect(out, contains('Nothing was started.'));
          expect(actions.dispatches, isEmpty, reason: '$answers $err');
        }
      },
    );

    test('without a terminal, in CI, with --json or with --events, it is refused before any request', () async {
      for (final (args, env, terminal) in [
        (<String>[], null, false),
        (<String>[], {'GH_TOKEN': _token, 'CI': 'true'}, true),
        (<String>['--json'], null, true),
        (<String>['--events'], null, true),
      ]) {
        await serve();
        final before = github!.requests.length;
        final (code, out, err) = await wincode(
          args,
          environment: env,
          terminal: terminal,
        );
        expect(code, 64, reason: '$args $err');
        expect(github!.requests.length, before, reason: 'no request: $args');
        expect(actions.dispatches, isEmpty);
        if (args.contains('--json')) {
          final error = (jsonDecode(out) as Map)['error'] as Map;
          expect(error['id'], 'confirmation-required');
        } else if (args.contains('--events')) {
          final result = eventsOf(out).last;
          expect(result['event'], 'result');
          expect((result['error'] as Map)['id'], 'confirmation-required');
        } else {
          expect(err, contains('wincode build: build needs your confirmation'));
          expect(err, contains('Nothing was started.'));
        }
      }
    });

    test('--dry-run asks nothing and sends nothing', () async {
      final (code, out, err) = await wincode(['--dry-run']);
      expect(code, 0, reason: '$out$err');
      expect(github?.requests ?? const [], isEmpty);
    });
  });

  group('the dispatch', () {
    test('is sent once, with the ref and every input, and the run is followed to its IPA', () async {
      final (code, json, id) = await buildJson([]);
      expect((code, id), (0, null));
      expect(json['ok'], isTrue);
      final dispatch = actions.dispatches.single;
      expect(
        dispatch.path,
        '$base/actions/workflows/wincode-ios.yml/dispatches',
      );
      expect(dispatch.headers['x-github-api-version'], '2026-03-10');
      final body = dispatch.json;
      expect(body['ref'], 'main');
      expect((body['inputs'] as Map).keys, [
        'request_id',
        'build_name',
        'build_number',
        'flutter_version',
        'min_xcode_version',
        'flavor',
        'target',
      ], reason: 'the inputs, in the order of ADR-0015');
      final inputs = (body['inputs'] as Map).cast<String, String>();
      expect(inputs['build_name'], '2.3.0');
      expect(inputs['build_number'], '57');
      expect(inputs['flutter_version'], '3.47.7');
      expect(
        inputs['request_id'],
        matches(RegExp('^${appTag(_bundleId)}-2\\.3\\.0-57-[0-9a-f]{8}\$')),
      );
      expect(json['requestId'], inputs['request_id']);
      expect(json['runId'], 9000001);
      expect(json['runUrl'], actions.runUrl);
      expect(json['conclusion'], 'success');
      expect(json['buildName'], '2.3.0');
      expect(json['buildNumber'], '57');
      final ipaJson = json['ipa']! as Map;
      expect(ipaJson['path'], unsigned().path);
      expect(ipaJson['size'], ipa.length);
      expect(ipaJson['sha256'], sha256Hex(ipa));
      expect(
        (ipaJson['bundleId'], ipaJson['version'], ipaJson['build']),
        (_bundleId, '2.3.0', '57'),
      );
      expect(unsigned().readAsBytesSync(), ipa);
      expect(paths().where((p) => p.startsWith('POST')), [
        'POST $base/actions/workflows/wincode-ios.yml/dispatches',
      ], reason: 'the only write is the dispatch');
    });

    test('is not sent at all by a check that fails', () async {
      repo.files['pubspec.yaml'] = 'name: demo\nversion: 2.3.0\n';
      final (code, _, id) = await buildJson([]);
      expect((code, id), (78, 'build-number-missing'));
      expect(actions.dispatches, isEmpty);
    });

    test(
      'takes the run from a listing by its name when the answer names none',
      () async {
        actions.answersNoRun = true;
        final (code, json, _) = await buildJson([]);
        expect(code, 0, reason: '$json');
        expect(json['runId'], 9000001);
        final listing = github!.requests
            .where((r) => r.path.endsWith('/wincode-ios.yml/runs'))
            .toList();
        expect(
          listing,
          isNotEmpty,
          reason: 'the run was found in the list of the workflow\'s runs',
        );
        expect(listing.last.query['event'], 'workflow_dispatch');
        expect(actions.dispatches, hasLength(1));
      },
    );

    test('looks for a run that GitHub does not show yet, every five seconds, up to two minutes', () async {
      actions.hiddenReads = 3;
      final (code, json, _) = await buildJson([]);
      expect(code, 0, reason: '$json');
      expect(slept.take(3), everyElement(const Duration(seconds: 5)));
    });

    test(
      'a run that never shows is run-not-found, after two minutes',
      () async {
        actions.hiddenReads = 1000000;
        final (code, json, id) = await buildJson([]);
        expect((code, id), (1, 'run-not-found'));
        expect(now.difference(DateTime.utc(2026, 11, 15, 12)).inSeconds, 120);
        expect(
          (json['error'] as Map)['next'],
          contains('look for the run named wincode ${requestId()}'),
        );
        expect(json['runId'], 9000001, reason: 'the dispatch named it');
        expect(actions.dispatches, hasLength(1));
      },
    );

    test('a listing that never shows the run is run-not-found too', () async {
      actions.answersNoRun = true;
      actions.hiddenFromList = true;
      final (code, json, id) = await buildJson([]);
      expect((code, id), (1, 'run-not-found'));
      expect(json['runId'], isNull);
      expect(actions.dispatches, hasLength(1));
      expect(
        paths().where((p) => p.endsWith('/runs')),
        hasLength(greaterThan(5)),
      );
    });

    test('a run that shows the name of the workflow at first is waited for until it shows its own', () async {
      // A real run did: GitHub shows the workflow's name right after a dispatch, and the run-name a moment later.
      actions.untitledReads = 2;
      final (code, json, _) = await buildJson([]);
      expect(code, 0, reason: '$json');
      expect(slept.take(2), everyElement(const Duration(seconds: 5)));
    });

    test(
      'a run that never gets our name is run-not-found, with the name it has',
      () async {
        actions.titled = 'wincode 000000000000-1.0.0-1-00000000';
        final (code, json, id) = await buildJson([]);
        expect((code, id), (1, 'run-not-found'));
        expect(
          (json['error'] as Map)['what'],
          contains(
            'is not the run that this build started, 2 minutes after the dispatch: it is named "wincode 000000000000-1.0.0-1-00000000"',
          ),
        );
        expect(now.difference(DateTime.utc(2026, 11, 15, 12)).inSeconds, 120);
        expect(actions.dispatches, hasLength(1));
      },
    );

    test('a lost answer is offline, says how to find the run, and does not send it again', () async {
      actions.dropsAnswer = true;
      final (code, json, id) = await buildJson([]);
      expect((code, id), (69, 'offline'));
      final error = json['error']! as Map;
      expect(error['what'], contains('not known whether the run started'));
      expect(error['why'], contains('does not send it again'));
      expect(error['next'], contains('wincode ${requestId()}'));
      expect(error['next'], contains('--run <run id>'));
      expect(json['runId'], isNull);
      expect(actions.dispatches, hasLength(1));
      expect(
        paths().where((p) => p.contains('/dispatches')),
        hasLength(1),
        reason: 'the client did not try again either',
      );
    });

    test(
      'a 5xx is the same: the run may exist, and nothing is sent again',
      () async {
        actions.refusesDispatch = GhAnswer.error(502, 'Bad gateway');
        final (code, json, id) = await buildJson([]);
        expect((code, id), (69, 'github-unavailable'));
        expect((json['error'] as Map)['what'], contains('not known whether'));
        expect(actions.dispatches, hasLength(1));
      },
    );

    for (final (answer, code, id) in [
      (
        GhAnswer.error(403, 'Resource not accessible by personal access token'),
        77,
        'github-forbidden',
      ),
      (
        GhAnswer.error(422, 'Unexpected inputs provided: ["x"]'),
        78,
        'workflow-input-unknown',
      ),
      (
        GhAnswer.error(422, "Required input 'build_name' not provided"),
        78,
        'workflow-input-missing',
      ),
      (
        GhAnswer.error(422, 'No ref found for: refs/heads/main'),
        78,
        'ref-not-found',
      ),
      (
        GhAnswer.error(422, 'Workflow does not have workflow_dispatch trigger'),
        1,
        'github-error',
      ),
      (GhAnswer.error(404, 'Not Found'), 1, 'github-error'),
      (
        GhAnswer.error(429, 'Slow down', headers: {'retry-after': '120'}),
        69,
        'github-rate-limited',
      ),
    ]) {
      test(
        'a dispatch that GitHub refuses with ${answer.status} ${(answer.json as Map)['message']} is $id ($code), and nothing was started',
        () async {
          actions.refusesDispatch = answer;
          final (got, json, gotId) = await buildJson([]);
          expect((got, gotId), (code, id));
          expect(
            (json['error'] as Map)['next'],
            contains('Nothing was started.'),
          );
          expect(json['runId'], isNull);
          expect(
            actions.dispatches,
            hasLength(1),
            reason: 'and not sent again',
          );
        },
      );
    }
  });

  group('the same commit', () {
    test('a branch that moved after the checks stops the build, with the run reported and nothing downloaded', () async {
      actions.builds = 'f' * 40;
      final (code, json, id) = await buildJson([]);
      expect((code, id), (1, 'ref-moved'));
      final error = json['error']! as Map;
      expect(
        error['what'],
        'main moved while the build was starting: run ${actions.runUrl} builds commit fffffff, and the checks read 1a2b3c4',
      );
      expect(error['next'], contains('cancel it at ${actions.runUrl}'));
      expect(json['runId'], 9000001);
      expect(json['runUrl'], actions.runUrl);
      expect(json['ipa'], isNull);
      expect(actions.polls, 0, reason: 'the run is not waited for');
      expect(actions.cancels, isEmpty, reason: 'winCode never cancels unasked');
      expect(paths().where((p) => p.contains('/artifacts')), isEmpty);
      expect(unsigned().existsSync(), isFalse);
    });

    test('--events reports the run before it stops', () async {
      actions.builds = 'f' * 40;
      final (code, out, _) = await wincode(['--yes', '--events']);
      expect(code, 1);
      final events = eventsOf(out);
      expect(events.map((e) => e['event']), contains('dispatched'));
      expect(events.last['event'], 'result');
      expect(events.last['runUrl'], actions.runUrl);
    });
  });

  group('following the run', () {
    test('reads it every 30 seconds with the ETag of the last answer, and a 304 changes nothing', () async {
      final (code, json, _) = await buildJson([]);
      expect(code, 0);
      expect(actions.polls, 5);
      final reads = github!.requests
          .where((r) => r.path.endsWith('/attempts/1'))
          .toList();
      expect(reads, hasLength(5));
      expect(reads.first.headers, isNot(contains('if-none-match')));
      expect(reads.skip(1).map((r) => r.headers['if-none-match']), [
        'W/"run-9000001-0"',
        'W/"run-9000001-1"',
        'W/"run-9000001-1"',
        'W/"run-9000001-1"',
      ], reason: 'each read sends the ETag of the last 200');
      final jobs = github!.requests.where((r) => r.path.endsWith('/jobs'));
      expect(
        jobs,
        hasLength(4),
        reason: 'the jobs are read once the run left the queue',
      );
      expect(
        slept.where((d) => d == const Duration(seconds: 30)),
        hasLength(4),
      );
      expect(
        (json['minutes']! as Map)['total'],
        4,
        reason: '205 seconds of job time, rounded up',
      );
      final minutes = json['minutes']! as Map;
      expect(minutes['jobs'], [
        {
          'name': 'unsigned-ipa',
          'runsOn': 'macos-26',
          'seconds': 205,
          'minutes': 4,
        },
      ]);
    });

    test('follows the attempt it started, not the run', () async {
      await buildJson([]);
      expect(paths().where((p) => p.endsWith('/attempts/1')), isNotEmpty);
      expect(
        paths().where((p) => RegExp(r'/runs/\d+/jobs$').hasMatch(p)),
        isEmpty,
      );
    });

    test(
      'writes what changes to stderr for people, and the findings to stdout',
      () async {
        final (code, out, err) = await wincode(['--yes']);
        expect(code, 0);
        for (final line in [
          'dispatched: run 9000001, ${actions.runUrl}',
          'run queued',
          'run in_progress',
          'job unsigned-ipa in_progress',
          'step 5 "Build the archive, unsigned" in_progress',
          'run completed: success',
          'step 8 "Complete job" completed: success',
        ]) {
          expect(err, contains(line));
        }
        expect(err, contains('2026-11-15 12:00:30 UTC  run in_progress'));
        expect(out, isNot(contains('run queued')));
        expect(
          out,
          contains('PASS  unsigned.ipa holds $_bundleId 2.3.0 (build 57)'),
        );
        expect(out, contains('wincode build: passed'));
      },
    );

    test('--events writes the events of the ADR in order, and ends with the result of --json', () async {
      final (code, out, err) = await wincode(['--yes', '--events']);
      expect(code, 0, reason: err);
      final events = eventsOf(out);
      for (final e in events) {
        expect(e, contains('event'));
        expect(e['app'], isNull);
        if (e['event'] != 'result') {
          expect(e['time'], matches(r'^2026-11-15T12:0\d:\d\dZ$'));
        }
      }
      final names = [for (final e in events) e['event']];
      int at(String name, {String? status}) => events.indexWhere(
        (e) => e['event'] == name && (status == null || e['status'] == status),
      );
      expect(at('plan'), lessThan(at('dispatched')));
      expect(at('dispatched'), lessThan(at('run', status: 'queued')));
      expect(
        at('run', status: 'queued'),
        lessThan(at('run', status: 'in_progress')),
      );
      expect(at('run', status: 'in_progress'), lessThan(at('wait')));
      expect(at('wait'), lessThan(at('run', status: 'completed')));
      expect(at('run', status: 'completed'), lessThan(at('artifact')));
      expect(at('artifact'), lessThan(at('ipa')));
      expect(at('ipa'), lessThan(names.length - 1));
      expect(names.last, 'result');
      expect(names.where((n) => n == 'dispatched'), hasLength(1));
      expect(names.where((n) => n == 'wait'), hasLength(1));

      final dispatched = events[at('dispatched')];
      expect(dispatched['requestId'], requestId());
      expect(dispatched['runId'], 9000001);
      expect(dispatched['runUrl'], actions.runUrl);

      final waiting = events[at('wait')];
      expect(waiting['status'], 'in_progress');
      expect(waiting['elapsedSeconds'], 60);
      expect(waiting['minutes'], 1);

      final step = events.firstWhere(
        (e) =>
            e['event'] == 'step' &&
            e['number'] == 5 &&
            e['status'] == 'in_progress',
      );
      expect(step['job'], 'unsigned-ipa');
      expect(step['name'], 'Build the archive, unsigned');
      expect(step['conclusion'], isNull);
      expect(events.where((e) => e['event'] == 'job').map((e) => e['status']), [
        'in_progress',
        'completed',
      ]);
      // A step that is still queued is not an event yet.
      expect(
        events.where((e) => e['event'] == 'step' && e['status'] == 'queued'),
        isEmpty,
      );

      final artifact = events[at('artifact')];
      expect(artifact['name'], 'unsigned-ipa');
      expect(artifact['size'], actions.zip!.length);
      expect(artifact['digest'], 'sha256:${sha256Hex(actions.zip!)}');
      expect(artifact['expiresAt'], '2026-11-16T12:03:34Z');
      final ipaEvent = events[at('ipa')];
      expect(ipaEvent['path'], unsigned().path);
      expect(ipaEvent['sha256'], sha256Hex(ipa));

      // The last line is the object that --json prints, with "event" added.
      final result = Map.of(events.last)..remove('event');
      actions = FakeActions(repo, now: () => now)..zip = _artifact(ipa);
      now = DateTime.utc(2026, 11, 15, 12);
      final (_, json, _) = await buildJson([]);
      for (final map in [result, json]) {
        map.remove('requestId');
        (map['plan'] as Map).remove('requestId');
        ((map['plan'] as Map)['inputs'] as Map).remove('request_id');
        (map['ipa'] as Map).remove('path');
        // The wait of the first run was shifted by the second dispatch of the same fake.
        map.remove('checks');
      }
      expect(result, json);
    });

    test(
      'a rate limit slows the polling and does not fail the build',
      () async {
        var limited = true;
        actions.onRead = (_) {};
        final server = await FakeGithub.start((r) {
          if (limited && r.path.endsWith('/attempts/1')) {
            limited = false;
            return GhAnswer.error(
              429,
              'Slow down',
              headers: {'retry-after': '120'},
            );
          }
          return actions.handle(r) ?? repo(r);
        }, token: _token);
        github = server;
        final (code, json, _) = await buildJson([]);
        expect(code, 0, reason: '$json');
        expect(slept, contains(const Duration(seconds: 120)));
        expect(
          github!.requests.where((r) => r.path.endsWith('/attempts/1')),
          hasLength(greaterThan(5)),
        );
      },
    );

    test('a failed read is asked again, but not for ever', () async {
      var failures = 0;
      final server = await FakeGithub.start((r) {
        if (r.path.endsWith('/attempts/1') && failures < 2) {
          failures++;
          return GhAnswer.error(502, 'Bad gateway');
        }
        return actions.handle(r) ?? repo(r);
      }, token: _token);
      github = server;
      final (code, _, _) = await buildJson([]);
      expect(code, 0);
      expect(failures, 2);

      await server.close();
      github = await FakeGithub.start((r) {
        if (r.path.endsWith('/attempts/1')) {
          return GhAnswer.error(502, 'Bad gateway');
        }
        return actions.handle(r) ?? repo(r);
      }, token: _token);
      actions = FakeActions(repo, now: () => now)..zip = _artifact(ipa);
      final (down, json, id) = await buildJson([]);
      expect((down, id), (69, 'github-unavailable'));
      final next = (json['error'] as Map)['next'] as String;
      expect(next, contains('--run 9000001'), reason: 'the run goes on');
      expect(next, contains(actions.runUrl));
      expect(json['runId'], 9000001);
      expect(actions.cancels, isEmpty);
    });
  });

  group('a run that does not succeed', () {
    test(
      'names the step that failed and links its log, and is not started again',
      () async {
        actions.timeline = failing();
        final (code, json, id) = await buildJson([]);
        expect((code, id), (1, 'run-failed'));
        final error = json['error']! as Map;
        expect(
          error['what'],
          'run ${actions.runUrl} failed at step "Build the archive, unsigned"',
        );
        expect(error['why'], contains('${actions.runUrl}/job/100#step:5:1'));
        expect(error['why'], contains('does not start it again'));
        expect(error['next'], contains('Build number 57 was not used.'));
        expect(json['conclusion'], 'failure');
        expect(
          (json['minutes']! as Map)['total'],
          2,
          reason: '115 seconds, rounded up',
        );
        expect(json['ipa'], isNull);
        expect(actions.dispatches, hasLength(1));
        expect(actions.cancels, isEmpty);
        expect(paths().where((p) => p.contains('/artifacts')), isEmpty);
      },
    );

    test('a step that timed out says so', () async {
      actions.timeline = failing(conclusion: 'timed_out');
      final (_, json, id) = await buildJson([]);
      expect(id, 'run-failed');
      expect(
        (json['error'] as Map)['what'],
        contains('ended (timed_out) at step "Build the archive, unsigned"'),
      );
    });

    test('a cancelled run is run-cancelled', () async {
      actions.timeline = [
        const RunState('in_progress'),
        const RunState('completed', conclusion: 'cancelled'),
      ];
      final (code, json, id) = await buildJson([]);
      expect((code, id), (1, 'run-cancelled'));
      expect(
        (json['error'] as Map)['what'],
        'run ${actions.runUrl} was cancelled',
      );
      expect(json['conclusion'], 'cancelled');
    });

    test('a run whose job never started says so', () async {
      actions.timeline = [
        const RunState('queued'),
        const RunState('completed', conclusion: 'failure'),
      ];
      final (code, json, id) = await buildJson([]);
      expect((code, id), (1, 'run-failed'));
      expect(
        (json['error'] as Map)['what'],
        'run ${actions.runUrl} ended (failure) before its job started',
      );
      expect((json['error'] as Map)['why'], contains('spending limit'));
    });
  });

  group('the timeout', () {
    test('ends the wait, not the run: 75, nothing cancelled, and the way to collect it', () async {
      actions.timeline = endless();
      final (code, json, id) = await buildJson(['--timeout', '90s']);
      expect((code, id), (75, 'run-timeout'));
      final error = json['error']! as Map;
      expect(error['what'], contains('after 90 seconds'));
      expect(error['why'], contains('--timeout ends the wait, never the run'));
      expect(error['next'], contains('wincode build --run 9000001'));
      expect(actions.polls, 4, reason: 'at 0, 30, 60 and 90 seconds');
      expect(actions.cancels, isEmpty);
      expect(json['runId'], 9000001);
      expect(json['conclusion'], isNull);
    });

    test(
      'is 60 minutes without --timeout, counted from the dispatch',
      () async {
        actions.timeline = endless();
        final (code, _, id) = await buildJson([]);
        expect((code, id), (75, 'run-timeout'));
        expect(actions.polls, 121);
        expect(
          now.difference(DateTime.utc(2026, 11, 15, 12)),
          const Duration(minutes: 60),
        );
      },
    );

    test(
      'is given in minutes, or in seconds with an s, and nothing else',
      () async {
        actions.timeline = endless();
        final (code, _, _) = await buildJson(['--timeout', '2']);
        expect(code, 75);
        expect(actions.polls, 5, reason: '0, 30, 60, 90 and 120 seconds');
        for (final bad in ['0', '-1', 'ten', '1m', '']) {
          final (got, _, err) = await wincode(['--yes', '--timeout', bad]);
          expect(got, 64, reason: bad);
          expect(
            err,
            contains('--timeout is a number of minutes'),
            reason: bad,
          );
        }
      },
    );
  });

  group('Ctrl-C', () {
    /// Ctrl-C arrives as the run is read for the second time.
    void pressAfterRead(
      int reads, [
      ProcessSignal signal = ProcessSignal.sigint,
    ]) {
      actions.onRead = (n) {
        if (n == reads) signals.add(signal);
      };
    }

    test('at a terminal asks whether to cancel, and no (Enter) leaves the run going: 75', () async {
      actions.timeline = endless();
      pressAfterRead(2);
      final (code, out, err) = await wincode(
        ['--yes'],
        terminal: true,
        answers: [''],
      );
      expect(code, 75, reason: '$out$err');
      expect(
        out,
        contains(
          'Cancel the run on GitHub too? It has run for about 1 minute. [y/N] ',
        ),
      );
      expect(actions.cancels, isEmpty);
      expect(
        out,
        contains(
          'FAIL  stopped waiting for run ${actions.runUrl}, which is still in_progress',
        ),
      );
      expect(out, contains('wincode build --run 9000001'));
      expect(out, contains('or cancel it at ${actions.runUrl}'));
    });

    test(
      'yes sends the cancel request, and the build ends with run-cancelled',
      () async {
        actions.timeline = endless();
        pressAfterRead(2);
        final (code, out, err) = await wincode(
          ['--yes'],
          terminal: true,
          answers: ['y'],
        );
        expect(code, 1, reason: '$out$err');
        expect(actions.cancels, hasLength(1));
        expect(
          actions.cancels.single.path,
          '$base/actions/runs/9000001/cancel',
        );
        expect(actions.cancels.single.body, isEmpty);
        expect(out, contains('FAIL  you cancelled run ${actions.runUrl}'));
      },
    );

    test('a second Ctrl-C while it asks is a no', () async {
      actions.timeline = endless();
      pressAfterRead(2);
      final asked = Completer<void>();
      final (code, out, _) = await wincode(
        ['--yes'],
        terminal: true,
        answer: () {
          asked.complete();
          // The person never types: a second Ctrl-C comes instead.
          Future<void>.delayed(
            Duration.zero,
            () => signals.add(ProcessSignal.sigint),
          );
          return Completer<String?>().future;
        },
      );
      expect(asked.isCompleted, isTrue);
      expect(code, 75);
      expect(actions.cancels, isEmpty);
      expect(out, contains('stopped waiting'));
    });

    test(
      'a cancel that GitHub refuses is told, with the run still going',
      () async {
        actions.timeline = endless();
        actions.refusesCancel = GhAnswer.error(403, 'Resource not accessible');
        pressAfterRead(2);
        final (code, out, err) = await wincode(
          ['--yes'],
          terminal: true,
          answers: ['y'],
        );
        expect(code, 77, reason: '$out$err');
        expect(actions.cancels, hasLength(1));
        expect(out, contains('FAIL  GitHub refused POST'));
        expect(out, contains('The run goes on at ${actions.runUrl}.'));
        expect(out, contains('wincode build --run 9000001'));
      },
    );

    test(
      'with --json it asks nothing, cancels nothing, and stops: 75',
      () async {
        actions.timeline = endless();
        pressAfterRead(2);
        final (code, out, err) = await wincode(
          ['--yes', '--json'],
          terminal: true,
          answer: () => fail('asked'),
        );
        expect(code, 75, reason: err);
        final json = jsonDecode(out) as Map<String, Object?>;
        expect((json['error'] as Map)['id'], 'wait-stopped');
        expect(json['runId'], 9000001);
        expect(actions.cancels, isEmpty);
        expect(err, isNot(contains('Cancel the run')));
      },
    );

    test(
      'with --events it asks nothing either, and ends with the result',
      () async {
        actions.timeline = endless();
        pressAfterRead(2);
        final (code, out, _) = await wincode(
          ['--yes', '--events'],
          terminal: true,
          answer: () => fail('asked'),
        );
        expect(code, 75);
        final events = eventsOf(out);
        expect(events.last['event'], 'result');
        expect((events.last['error'] as Map)['id'], 'wait-stopped');
        expect(
          events.where((e) => e['event'] == 'dispatched'),
          hasLength(1),
          reason: 'the run\'s ID is in the dispatched event, for a caller that wants it cancelled',
        );
      },
    );

    test(
      'without a terminal it asks nothing, and SIGTERM never asks',
      () async {
        for (final (signal, terminal) in [
          (ProcessSignal.sigint, false),
          (ProcessSignal.sigterm, true),
        ]) {
          actions = FakeActions(repo, now: () => now)
            ..zip = _artifact(ipa)
            ..timeline = endless();
          pressAfterRead(2, signal);
          final (code, _, err) = await wincode(
            ['--yes'],
            terminal: terminal,
            answer: () => fail('asked'),
          );
          expect(code, 75, reason: '$signal $err');
          expect(actions.cancels, isEmpty);
          expect(err, isNot(contains('Cancel the run')));
        }
      },
    );

    test('while the artifact downloads it stops the download, deletes what it wrote and leaves the old IPA', () async {
      output().createSync(recursive: true);
      unsigned().writeAsBytesSync([9, 9, 9]);
      // The storage never answers, and Ctrl-C arrives meanwhile: the download ends when the signal stops it.
      storage = await FakeGithub.start((r) async {
        signals.add(ProcessSignal.sigint);
        await Completer<void>().future;
        return const GhAnswer({});
      });
      final (code, out, err) = await wincode(['--yes']);
      expect(code, 75, reason: '$out$err');
      expect(
        out,
        contains(
          'stopped while downloading the IPA of run ${actions.runUrl}, which has ended',
        ),
      );
      expect(unsigned().readAsBytesSync(), [9, 9, 9]);
      expect(
        actions.cancels,
        isEmpty,
        reason: 'the run is over: nothing to cancel',
      );
    });
  });

  group('--run', () {
    String name(String version, String number) =>
        '${appTag(_bundleId)}-$version-$number-0a1b2c3d';

    test('collects a run that earlier build started, without the question, the dispatch or the project checks', () async {
      actions.existingRun(name('2.3.0', '57'));
      actions.timeline = [
        RunState(
          'completed',
          conclusion: 'success',
          jobs: [
            FakeJob(
              'unsigned-ipa',
              'completed',
              conclusion: 'success',
              completedAt: '2026-11-15T12:00:35Z',
            ),
          ],
        ),
      ];
      // Nothing of the project is there, and wincode.yaml names no Flutter or Xcode version.
      repo.files.removeWhere((k, _) => k.startsWith('ios/'));
      repo.files.remove('pubspec.yaml');
      config.writeAsStringSync(
        'bundle_id: $_bundleId\nteam_id: TEAM000001\nworkflow: $_workflowRef\n',
      );
      final (code, json, id) = await buildJson([
        '--run',
        '9000001',
      ], yes: false);
      expect((code, id), (0, null), reason: '$json');
      expect(actions.dispatches, isEmpty);
      expect(json['runId'], 9000001);
      expect(json['runUrl'], actions.runUrl);
      expect(json['requestId'], name('2.3.0', '57'));
      expect(json['buildName'], '2.3.0');
      expect(json['buildNumber'], '57');
      expect(json['commit'], repo.commit);
      expect((json['ipa'] as Map)['version'], '2.3.0');
      expect(unsigned().readAsBytesSync(), ipa);
      expect(
        paths().where((p) => p.contains('/contents/') || p.contains('/git/')),
        isEmpty,
        reason: 'the project is not read',
      );
      expect(paths().where((p) => p.startsWith('POST')), isEmpty);
    });

    test('checks the IPA against the version and the number in the name of the run', () async {
      actions.existingRun(name('2.4.0', '58'));
      actions.timeline = [const RunState('completed', conclusion: 'success')];
      final (code, json, id) = await buildJson([
        '--run',
        '9000001',
      ], yes: false);
      expect((code, id), (1, 'ipa-version-mismatch'));
      expect(
        (json['error'] as Map)['what'],
        'the IPA holds version 2.3.0 (build 57), and the build asked for 2.4.0 (build 58)',
      );
    });

    test('waits for a run that is still going', () async {
      actions.existingRun(name('2.3.0', '57'));
      final (code, json, _) = await buildJson(['--run', '9000001'], yes: false);
      expect(code, 0, reason: '$json');
      expect(actions.polls, 5);
    });

    test('--timeout counts from the wait, and the run goes on', () async {
      actions.existingRun(name('2.3.0', '57'));
      actions.timeline = endless();
      final (code, json, id) = await buildJson([
        '--run',
        '9000001',
        '--timeout',
        '60s',
      ], yes: false);
      expect((code, id), (75, 'run-timeout'));
      expect(
        (json['error'] as Map)['next'],
        contains('wincode build --run 9000001'),
      );
    });

    test(
      'refuses a run that is not a dispatched run of this app and workflow',
      () async {
        for (final (setup, why) in [
          (() => actions.existingRun(name('2.3.0', '57')), 'event'),
          (() => actions.existingRun('000000000000-2.3.0-57-0a1b2c3d'), 'tag'),
          (() => actions.existingRun('free text'), 'name'),
          (() => actions.existingRun(name('2.3.0', '57')), 'workflow'),
        ]) {
          actions = FakeActions(repo, now: () => now)
            ..zip = _artifact(ipa)
            ..timeline = [const RunState('completed', conclusion: 'success')];
          setup();
          if (why == 'event') actions.event = 'push';
          if (why == 'workflow') actions.workflowId = 1;
          final (code, json, id) = await buildJson([
            '--run',
            '9000001',
          ], yes: false);
          expect((code, id), (1, 'run-mismatch'), reason: why);
          expect(json['ipa'], isNull);
          expect(unsigned().existsSync(), isFalse, reason: why);
        }
      },
    );

    test('a run that does not exist is run-not-found', () async {
      final (code, _, id) = await buildJson(['--run', '12345'], yes: false);
      expect((code, id), (1, 'run-not-found'));
    });

    test('is a usage error with --ref, --build-name, --build-number or --dry-run, or with a number that is not one', () async {
      for (final args in [
        ['--run', '1', '--ref', 'main'],
        ['--run', '1', '--build-name', '2.3.0'],
        ['--run', '1', '--build-number', '57'],
        ['--run', '1', '--dry-run'],
        ['--run', 'abc'],
        ['--run', '0'],
        ['--run', '-3'],
      ]) {
        await serve();
        final before = github!.requests.length;
        final (code, _, err) = await wincode(args);
        expect(code, 64, reason: '$args');
        expect(
          err,
          anyOf(
            contains('cannot be given together'),
            contains('--run is the number'),
          ),
        );
        expect(github!.requests.length, before, reason: 'no request: $args');
      }
    });

    test('a public repository needs --allow-public here too', () async {
      repo.isPrivate = false;
      actions.existingRun(name('2.3.0', '57'));
      actions.timeline = [const RunState('completed', conclusion: 'success')];
      final (code, _, id) = await buildJson(['--run', '9000001'], yes: false);
      expect((code, id), (64, 'repository-public'));
      expect(paths().where((p) => p.contains('/artifacts')), isEmpty);
    });

    test('in an app of a file of apps, the command to collect it names the app', () async {
      config.writeAsStringSync(
        'defaults:\n  team_id: TEAM000001\n  workflow: $_workflowRef\n  flutter_version: 3.47.7\n'
        '  min_xcode_version: "26.0"\napps:\n  alpha:\n    bundle_id: $_bundleId\n    credentials: team-one\n',
      );
      actions.existingRun(name('2.3.0', '57'));
      actions.timeline = endless();
      final (_, json, _) = await buildJson([
        '--app',
        'alpha',
        '--run',
        '9000001',
        '--timeout',
        '30s',
      ], yes: false);
      expect(
        (json['error'] as Map)['next'],
        contains('wincode build --app alpha --run 9000001'),
      );
    });
  });

  group('the artifact', () {
    Future<(int, Map<String, Object?>, String?)> failsWith(
      String id, {
      int code = 1,
    }) async {
      output().createSync(recursive: true);
      unsigned().writeAsBytesSync([1, 2, 3]);
      final result = await buildJson([]);
      expect((result.$1, result.$3), (code, id), reason: '${result.$2}');
      expect(
        unsigned().readAsBytesSync(),
        [1, 2, 3],
        reason:
            'the IPA of an earlier build is replaced only by one that passed',
      );
      return result;
    }

    test('is downloaded through the redirect without the token, and the IPA is put in the output folder', () async {
      final (code, _, err) = await wincode(['--yes', '--verbose']);
      expect(code, 0, reason: err);
      final got = storage!.requests.single;
      expect(got.path, '/blob/7001');
      expect(got.token, isNull);
      expect(got.headers, isNot(contains('authorization')));
      expect(
        github!.requests.where((r) => r.path.endsWith('/artifacts/7001/zip')),
        hasLength(1),
      );
      expect(
        err,
        contains('GET 127.0.0.1: HTTP 200'),
        reason: 'only the host of the link',
      );
      expect(unsigned().readAsBytesSync(), ipa);
      expect(output().listSync().map((e) => e.uri.pathSegments.last), [
        'unsigned.ipa',
      ]);
    });

    test('replaces the IPA of an earlier build', () async {
      output().createSync(recursive: true);
      unsigned().writeAsBytesSync([1, 2, 3]);
      final (code, _, _) = await wincode(['--yes']);
      expect(code, 0);
      expect(unsigned().readAsBytesSync(), ipa);
    });

    test('a download that the storage failed once is tried again', () async {
      var calls = 0;
      storageAnswers = (_) => ++calls == 1
          ? GhAnswer.error(503, 'busy')
          : GhAnswer.bytes(actions.zip!);
      final (code, _, err) = await wincode(['--yes']);
      expect(code, 0, reason: err);
      expect(calls, 2);
    });

    test('a link that the storage refuses is github-error, with the run still to collect', () async {
      storageAnswers = (_) => GhAnswer.error(403, 'expired');
      final (code, json, id) = await buildJson([]);
      expect((code, id), (1, 'github-error'));
      expect(
        (json['error'] as Map)['what'],
        contains('the download link answered HTTP 403'),
      );
      expect(
        (json['error'] as Map)['next'],
        contains('wincode build --run 9000001'),
      );
      expect(json['conclusion'], 'success');
    });

    test('no artifact is artifact-missing, and an expired one says so', () async {
      actions.noArtifact = true;
      var (code, json, id) = await buildJson([]);
      expect((code, id), (1, 'artifact-missing'));
      expect(
        (json['error'] as Map)['what'],
        'run ${actions.runUrl} ended (success) without an artifact named unsigned-ipa',
      );
      actions = FakeActions(repo, now: () => now)
        ..zip = _artifact(ipa)
        ..expired = true;
      (code, json, id) = await buildJson([]);
      expect((code, id), (1, 'artifact-missing'));
      expect(
        (json['error'] as Map)['what'],
        contains('expired at 2026-11-16T12:03:34Z'),
      );
    });

    test('two artifacts of that name are artifact-content', () async {
      actions.twoArtifacts = true;
      final (code, _, id) = await buildJson([]);
      expect((code, id), (1, 'artifact-content'));
    });

    group('the integrity, at each level', () {
      test('the zip against the digest that GitHub reports', () async {
        actions.digest = 'sha256:${'a' * 64}';
        final (_, json, _) = await failsWith('artifact-integrity');
        expect(
          (json['error'] as Map)['what'],
          'the artifact that was downloaded does not match the SHA-256 that GitHub reports for it',
        );
        expect(json['ipa'], isNull);
      });

      test('an artifact without a digest is an INFO, and the other checks still hold', () async {
        actions.noDigest = true;
        final (code, json, _) = await buildJson([]);
        expect(code, 0);
        expect(checkIds(json, 'INFO'), contains('artifact-digest'));
        actions = FakeActions(repo, now: () => now)
          ..zip = _artifact(ipa, recorded: 'b' * 64)
          ..noDigest = true;
        final (c2, _, id) = await buildJson([]);
        expect((c2, id), (1, 'artifact-integrity'));
      });

      test('a digest in another form is an INFO too', () async {
        actions.digest = 'sha512:${'a' * 128}';
        final (code, json, _) = await buildJson([]);
        expect(code, 0);
        expect(checkIds(json, 'INFO'), contains('artifact-digest'));
      });

      test('the IPA against the hash that the build job recorded', () async {
        actions.zip = _artifact(ipa, recorded: 'b' * 64);
        final (_, json, _) = await failsWith('artifact-integrity');
        expect(
          (json['error'] as Map)['what'],
          'the IPA in the artifact does not match the SHA-256 that the run recorded',
        );
        expect(
          (json['error'] as Map)['next'],
          contains('wincode build --run 9000001'),
        );
      });

      test('passes when both agree', () async {
        final (_, json, _) = await buildJson([]);
        expect(
          checkIds(json, 'PASS'),
          containsAll(['artifact-digest', 'artifact-content', 'artifact-hash']),
        );
      });
    });

    group('the content', () {
      for (final (what, zip) in [
        (
          'a file besides the two',
          _artifact(
            _ipa(),
            more: {
              'notes.txt': [65],
            },
          ),
        ),
        ('no hash file', _artifact(_ipa(), hash: false)),
        (
          'a hash file that holds no hash',
          zipOf({
            'unsigned.ipa': _ipa(),
            'unsigned.ipa.sha256': utf8.encode('not a hash\n'),
          }),
        ),
        (
          'a hash file that is far too long',
          zipOf({
            'unsigned.ipa': _ipa(),
            'unsigned.ipa.sha256': List.filled(5000, 97),
          }),
        ),
        (
          'no IPA',
          zipOf({
            'unsigned.ipa.sha256': utf8.encode('${'a' * 64}  unsigned.ipa\n'),
          }),
        ),
        (
          'something that is not a zip',
          Uint8List.fromList(List.filled(300, 7)),
        ),
      ]) {
        test('$what is artifact-content', () async {
          actions.zip = zip;
          await failsWith('artifact-content');
        });
      }
    });

    group('the IPA', () {
      test('of another app is bundle-id-mismatch, and the other ID is not printed under --redact', () async {
        actions.zip = _artifact(_ipa(bundleId: 'org.example.other'));
        final (_, json, _) = await failsWith('bundle-id-mismatch');
        expect(
          (json['error'] as Map)['what'],
          "the IPA's bundle ID is org.example.other, but wincode.yaml says $_bundleId",
        );
        actions = FakeActions(repo, now: () => now)
          ..zip = _artifact(_ipa(bundleId: 'org.example.other'));
        final (code, out, err) = await wincode(['--yes', '--redact']);
        expect(code, 1);
        expect('$out$err', isNot(contains('org.example.other')));
        expect('$out$err', isNot(contains(_bundleId)));
      });

      test('with an Info.plist in XML, as the Linux rehearsal writes it, is read as well', () async {
        actions.zip = _artifact(
          _ipa(
            infoPlist: utf8.encode(
              '<?xml version="1.0" encoding="UTF-8"?>\n'
              '<plist version="1.0"><dict>'
              '<key>CFBundleIdentifier</key><string>$_bundleId</string>'
              '<key>CFBundleShortVersionString</key><string>2.3.0</string>'
              '<key>CFBundleVersion</key><string>57</string>'
              '</dict></plist>\n',
            ),
          ),
        );
        final (code, json, _) = await buildJson([]);
        expect(code, 0, reason: '$json');
      });

      test('that is signed is ipa-signed', () async {
        actions.zip = _artifact(_ipa(profile: true));
        await failsWith('ipa-signed');
      });

      for (final (what, ipa) in [
        ('the wrong version', _ipa(version: '2.3.1')),
        ('the wrong build number', _ipa(build: '58')),
        ('no version', _ipa(version: '')),
      ]) {
        test('with $what is ipa-version-mismatch', () async {
          actions.zip = _artifact(ipa);
          final (_, json, _) = await failsWith('ipa-version-mismatch');
          expect(
            (json['error'] as Map)['what'],
            contains('and the build asked for 2.3.0 (build 57)'),
          );
        });
      }

      test('of two apps, or of none, or with an Info.plist that cannot be read, is ipa-unreadable', () async {
        for (final bad in [
          _ipa(twoApps: true),
          zipOf({
            'Payload/Runner.app/Runner': [1],
          }),
          _ipa(infoPlist: [1, 2, 3]),
        ]) {
          actions = FakeActions(repo, now: () => now)..zip = _artifact(bad);
          await failsWith('ipa-unreadable');
        }
      });
    });

    test('a disk that cannot be written to is output-unwritable', () async {
      // A file where the output folder should be.
      Directory(inside(temp, 'build')).createSync();
      File(inside(temp, 'build/wincode')).writeAsStringSync('in the way');
      final (code, _, id) = await buildJson([]);
      expect((code, id), (1, 'output-unwritable'));
    });
  });

  group('a public repository', () {
    setUp(() => repo.isPrivate = false);

    test('is refused without --allow-public, before any dispatch', () async {
      final (code, _, id) = await buildJson([]);
      expect((code, id), (64, 'repository-public'));
      expect(actions.dispatches, isEmpty);
    });

    test(
      'with --allow-public the artifact is deleted once the IPA is in place',
      () async {
        final (code, json, _) = await buildJson(['--allow-public']);
        expect(code, 0, reason: '$json');
        expect(unsigned().readAsBytesSync(), ipa);
        expect(actions.deletes, hasLength(1));
        expect(actions.deletes.single.path, '$base/actions/artifacts/7001');
        expect(
          paths().last,
          'DELETE $base/actions/artifacts/7001',
          reason: 'after the checks and the move',
        );
        expect(checkIds(json, 'PASS'), contains('artifact-delete'));
      },
    );

    test('a delete that fails is a warning, with the run to look at', () async {
      actions.refusesDelete = GhAnswer.error(403, 'Resource not accessible');
      final (code, json, _) = await buildJson(['--allow-public']);
      expect(code, 0);
      expect(checkIds(json, 'WARN'), contains('artifact-delete'));
      final check = (json['checks'] as List)
          .cast<Map<String, Object?>>()
          .firstWhere((c) => c['check'] == 'artifact-delete');
      expect(check['id'], 'artifact-not-deleted');
      expect(check['next'], contains(actions.runUrl));
      expect(unsigned().readAsBytesSync(), ipa);
    });

    test('a check that fails deletes nothing, and says that the artifact is still public', () async {
      actions.zip = _artifact(ipa, recorded: 'b' * 64);
      final (code, json, id) = await buildJson(['--allow-public']);
      expect((code, id), (1, 'artifact-integrity'));
      expect(actions.deletes, isEmpty);
      expect(
        (json['error'] as Map)['next'],
        contains(
          'anyone with a GitHub account can download the artifact until it expires',
        ),
      );
    });

    test('a private repository keeps the artifact for --run', () async {
      repo.isPrivate = true;
      final (code, _, _) = await buildJson([]);
      expect(code, 0);
      expect(actions.deletes, isEmpty);
    });
  });

  group('the token', () {
    test('is in no output of any run, --verbose included, and is sent to the API only', () async {
      for (final args in [
        ['--yes', '--verbose'],
        ['--yes', '--verbose', '--events'],
        ['--yes', '--verbose', '--json'],
      ]) {
        actions = FakeActions(repo, now: () => now)..zip = _artifact(ipa);
        final (code, out, err) = await wincode(args);
        expect(code, 0, reason: '$args $err');
        expect('$out$err', isNot(contains(_token)));
        expect('$out$err', isNot(contains(FakeActions.signature)));
      }
      expect(
        storage!.requests,
        isNotEmpty,
        reason: 'the storage was asked, and never with the token',
      );
    });
  });
}
