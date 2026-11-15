import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'build.dart' show BuildPlan;
import 'build_artifact.dart';
import 'build_number.dart';
import 'config.dart';
import 'events.dart';
import 'failure.dart';
import 'github.dart';
import 'preflight.dart' show Finding;
import 'redact.dart';

/// The wait for a run when `--timeout` is not given (ADR-0015, section 4), counted from the dispatch.
const defaultBuildTimeout = Duration(minutes: 60);

/// How long, and how often, the run that a dispatch started is looked for until GitHub shows it.
const _findTimeout = Duration(minutes: 2);
const _findInterval = Duration(seconds: 5);

/// How many reads of the run in a row may fail before the wait gives up. Each read has its own retries.
const _pollFailures = 3;

/// The signals that end the wait for a run: Ctrl-C, and SIGTERM where the system has it (ADR-0015, section 11).
Stream<ProcessSignal> systemInterrupts() {
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  late final StreamController<ProcessSignal> controller;
  controller = StreamController<ProcessSignal>(
    onListen: () {
      for (final signal in [
        ProcessSignal.sigint,
        if (!Platform.isWindows) ProcessSignal.sigterm,
      ]) {
        subscriptions.add(signal.watch().listen(controller.add));
      }
    },
    onCancel: () async {
      for (final s in subscriptions) {
        await s.cancel();
      }
    },
  );
  return controller.stream;
}

/// Reads the lines of standard input as they come, for a question that a signal can also answer. The blocking
/// `readLineSync` cannot be raced against a second Ctrl-C.
Future<String?> Function() stdinLines() {
  StreamIterator<String>? lines;
  return () async {
    try {
      lines ??= StreamIterator(
        stdin.transform(utf8.decoder).transform(const LineSplitter()),
      );
      return await lines!.moveNext() ? lines!.current : null;
    } on IOException {
      // Standard input is gone: nobody answers, which is a no.
      return null;
    }
  };
}

/// The signals that arrived while `wincode build` waits.
class _Signals {
  _Signals(Stream<ProcessSignal> signals) {
    _subscription = signals.listen((signal) {
      _count++;
      last = signal;
      final waiting = _next;
      _next = Completer<void>();
      waiting.complete();
    });
  }

  late final StreamSubscription<ProcessSignal> _subscription;
  var _count = 0;
  var _seen = 0;
  Completer<void> _next = Completer<void>();

  /// The last signal that arrived.
  ProcessSignal? last;

  /// Whether a signal arrived that nothing has dealt with.
  bool get pending => _count > _seen;

  /// Completes when the next signal arrives.
  Future<void> get next => _next.future;

  /// Marks every signal that arrived as dealt with.
  ProcessSignal take() {
    _seen = _count;
    return last!;
  }

  Future<void> close() => _subscription.cancel();
}

/// The jobs of a run as GitHub lists them.
typedef _Jobs = List<Map<String, Object?>>;

/// The time that the jobs of a run have used, as an estimate: each job from its start to its end (or to [now], while
/// it goes), rounded up to whole minutes. GitHub bills a job in whole minutes, and its multiplier for macOS is not
/// applied here.
Map<String, Object?> minutesOf(List<Map<String, Object?>> jobs, DateTime now) {
  final rows = <Map<String, Object?>>[];
  var total = 0;
  for (final job in jobs) {
    final started = DateTime.tryParse('${job['started_at']}');
    if (started == null) continue;
    final ended = DateTime.tryParse('${job['completed_at']}') ?? now;
    final seconds = ended.difference(started).inSeconds;
    final used = seconds < 0 ? 0 : seconds;
    final minutes = used <= 60 ? 1 : (used + 59) ~/ 60;
    total += minutes;
    final labels = job['labels'];
    rows.add({
      'name': job['name'],
      'runsOn': labels is List<Object?> ? labels.join(', ') : null,
      'seconds': used,
      'minutes': minutes,
    });
  }
  return {'total': total, 'jobs': rows};
}

/// A build after its checks (ADR-0015, sections 4, 6 and 7): the question, the dispatch, the wait for the run, and the
/// download of its IPA. It also collects a run that an earlier build started (`--run`).
///
/// - The dispatch is sent once. A lost answer ends the build, and says how to find the run.
/// - Nothing cancels the run but the person: not the timeout, not a failed read, not a check that fails after it
///   started. Ctrl-C asks first, at a terminal.
/// - Every outcome is a finding. A failure is a FAIL, whose exit code the run ends with; what the run learned for the
///   result is in the fields.
class BuildRun {
  BuildRun({
    required this.config,
    required this.plan,
    required this.client,
    required this.findings,
    required this.redactor,
    required this.clock,
    required this.sleep,
    required this.report,
    required this.progress,
    required this.signals,
    required this.readAnswer,
    required this.canAsk,
    required this.timeout,
    required this.pollInterval,
    this.cleanup = false,
    this.events,
  });

  final WincodeConfig config;
  final BuildPlan plan;
  final GithubClient client;

  /// Every finding of the build, which this adds to.
  final List<Finding> findings;
  final Redactor redactor;
  final DateTime Function() clock;
  final Future<void> Function(Duration) sleep;

  /// Where the questions are written, and where the progress for people goes.
  final StringSink report;
  final StringSink progress;
  final Stream<ProcessSignal> signals;
  final Future<String?> Function() readAnswer;

  /// Whether Ctrl-C may ask whether to cancel the run: at a terminal, without `--json` or `--events`.
  final bool canAsk;
  final Duration timeout;
  final Duration pollInterval;

  /// The repository is public and `--allow-public` was given: the artifact is deleted once the IPA is in place.
  final bool cleanup;
  final EventWriter? events;

  // What the run learned, for the result.
  int? runId;
  String? runUrl;
  String? conclusion;
  Map<String, Object?>? ipa;
  Map<String, Object?>? minutes;

  late _Signals _signals;
  var _phase = 'dispatch';
  DateTime? _begun;
  Map<String, Object?>? _lastRun;
  _Jobs _jobs = const [];

  String get _repository => config.workflow!.repository;
  String get _file => config.workflow!.file;

  String _collect(Object id) =>
      'wincode build${config.name == null ? '' : ' --app ${config.name}'} --run $id';

  void _say(String message) => progress.writeln('${_stamp(clock())}  $message');

  GoingRun? get _going {
    final id = runId;
    return id == null ? null : (url: runUrl!, collect: _collect(id));
  }

  // The two ways in.

  /// Asks for the go-ahead unless [yes], starts the run and follows it to its IPA.
  Future<void> start({required bool yes}) async {
    if (!yes) {
      report.write('Start this build on GitHub? It uses macOS minutes. [y/N] ');
      final answer = (await readAnswer())?.trim().toLowerCase();
      report.writeln();
      if (answer != 'y' && answer != 'yes') {
        findings.add(
          Finding.fail(
            'build',
            const WincodeException(
              ExitCode.failed,
              'build-cancelled',
              'the build was not started: the answer was not y',
              why: 'a build uses macOS minutes, which a private repository pays for.',
              next: 'run the command again and answer y, or give --yes. Nothing was started.',
            ),
          ),
        );
        return;
      }
    }
    await _guarded(_start);
  }

  /// Collects run [id], which an earlier build started: waits for it while it goes, then downloads and checks its IPA
  /// against the version and the build number in its name. [workflowId] is the id of the app's workflow.
  Future<void> collect(int id, {required int workflowId}) =>
      _guarded(() => _collectRun(id, workflowId));

  Future<void> _guarded(Future<void> Function() body) async {
    // The signals are watched from here: Ctrl-C cannot end the program while a run may have started.
    _signals = _Signals(signals);
    try {
      await body();
    } on WincodeException catch (e) {
      findings.add(Finding.fail(_phase, e));
    } on GithubException catch (e) {
      findings.add(
        Finding.fail(
          _phase,
          githubProblem(e, what: 'follow the run', run: _going),
        ),
      );
    } finally {
      conclusion = _lastRun?['conclusion'] as String?;
      if (_jobs.isNotEmpty) minutes = minutesOf(_jobs, clock());
      await _signals.close();
    }
  }

  // Starting.

  Future<void> _start() async {
    final requestId = plan.requestId!;
    final title = 'wincode $requestId';
    final dispatchedAt = _begun = clock();
    final dispatched = await _dispatch();
    // An answer without a run (204, as the API version before 2026-03-10 answers): find it by its name.
    final id = dispatched.id ?? await _search(title, dispatchedAt);
    runId = id;
    runUrl =
        dispatched.url ?? 'https://github.com/$_repository/actions/runs/$id';
    events?.emit('dispatched', {
      'requestId': requestId,
      'runId': id,
      'runUrl': runUrl,
    });
    _say('dispatched: run $id, $runUrl');
    _phase = 'run';
    final run = await _identify(id, title, dispatchedAt);
    final commit = plan.commit;
    final built = run['head_sha'];
    if (commit != null && built is String && built != commit) {
      throw WincodeException(
        ExitCode.failed,
        'ref-moved',
        '${plan.ref} moved while the build was starting: run $runUrl builds commit ${_short(built)}, and the checks read ${_short(commit)}',
        why:
            'the scheme, the configuration, the bundle ID and the other checks were made on the commit they read, not on '
            'the one the runner builds, so winCode downloads nothing from this run. The run goes on and uses macOS '
            'minutes until it ends.',
        next:
            'cancel it at $runUrl if you do not want it, then run wincode build again to check and build the new commit.',
      );
    }
    await _afterIdentified(run, (
      bundleId: config.bundleId,
      version: plan.buildName!,
      number: plan.buildNumber!,
    ));
  }

  Future<({int? id, String? url})> _dispatch() async {
    final GithubWrite answer;
    try {
      answer = await client.post(
        '/repos/$_repository/actions/workflows/$_file/dispatches',
        {'ref': plan.ref, 'inputs': plan.inputs},
      );
    } on GithubException catch (e) {
      throw _dispatchProblem(e);
    }
    final id = answer.json?['workflow_run_id'];
    final url = answer.json?['html_url'];
    return (id: id is int ? id : null, url: url is String ? url : null);
  }

  /// What a dispatch that GitHub refused, or did not answer, comes to.
  WincodeException _dispatchProblem(GithubException e) {
    final said = e.message.toLowerCase();
    if (e.failure == GithubFailure.offline ||
        e.failure == GithubFailure.unavailable) {
      return _lost(e);
    }
    if (e.failure == GithubFailure.unprocessable) {
      if (said.contains('unexpected inputs')) {
        return WincodeException(
          ExitCode.config,
          'workflow-input-unknown',
          'GitHub refused the dispatch: ${e.message}',
          why:
              'the workflow at ${plan.ref} declares no input that wincode build sends, so nothing started. The checks read '
              'the workflow at the commit they saw, and it may have changed since.',
          next:
              'declare the input under on.workflow_dispatch.inputs in ${plan.workflow}, push it to ${plan.ref}, or remove '
              'the entry from workflow_inputs in wincode.yaml, then run the command again. Nothing was started.',
        );
      }
      if (said.contains('required input')) {
        return WincodeException(
          ExitCode.config,
          'workflow-input-missing',
          'GitHub refused the dispatch: ${e.message}',
          why:
              'the workflow at ${plan.ref} requires an input that wincode build does not send, so nothing started.',
          next:
              'give the input a default in ${plan.workflow}, or add it to workflow_inputs in wincode.yaml, then run the '
              'command again. Nothing was started.',
        );
      }
      if (said.contains('no ref found')) {
        return WincodeException(
          ExitCode.config,
          'ref-not-found',
          'GitHub refused the dispatch: ${e.message}',
          why: 'the branch or tag was there when the checks ran and is gone now.',
          next: 'push it again, or give another --ref. Nothing was started.',
        );
      }
    }
    return githubProblem(e, what: 'start the workflow');
  }

  /// The dispatch, or the search for its run, got no answer: the run may or may not exist (ADR-0015, section 4).
  WincodeException _lost(GithubException e) => WincodeException(
    ExitCode.unavailable,
    e.failure == GithubFailure.unavailable ? 'github-unavailable' : 'offline',
    e.failure == GithubFailure.unavailable
        ? 'GitHub answered ${e.request} with ${e.message}, so it is not known whether the run started'
        : 'the answer of GitHub to ${e.request} was lost, so it is not known whether the run started: ${e.message}',
    why:
        'the run may or may not exist, and a second dispatch could start a second paid run, so winCode does not send it '
        'again.',
    next:
        'look for the run named wincode ${plan.requestId} on https://github.com/$_repository/actions/workflows/$_file ; if it '
        'is there, collect it with ${_collect('<run id>')}; if it is not, run wincode build again.',
  );

  /// The run named [title], found in the list of the workflow's dispatched runs every few seconds.
  Future<int> _search(String title, DateTime since) async {
    final created = since
        .toUtc()
        .subtract(const Duration(minutes: 1))
        .toIso8601String()
        .replaceFirst(RegExp(r'\.\d+Z$'), 'Z');
    for (;;) {
      if (_signals.pending) {
        _signals.take();
        throw WincodeException(
          ExitCode.pending,
          'wait-stopped',
          'stopped looking for the run that the dispatch started, which may still start or be running',
          why:
              'the dispatch was answered without the run, so winCode looks for it by its name, and cannot cancel what it has '
              'not found.',
          next:
              'look for the run named $title on https://github.com/$_repository/actions/workflows/$_file ; if it is there, '
              'collect it with ${_collect('<run id>')}, or cancel it there.',
        );
      }
      try {
        final answer = await client.getJson(
          '/repos/$_repository/actions/workflows/$_file/runs',
          {
            'event': 'workflow_dispatch',
            'created': '>=$created',
            'per_page': '30',
          },
        );
        final list = answer['workflow_runs'];
        if (list is List<Object?>) {
          for (final run in list.whereType<Map<String, Object?>>()) {
            if ((run['display_title'] ?? run['name']) == title &&
                run['id'] is int) {
              return run['id']! as int;
            }
          }
        }
      } on GithubException catch (e) {
        throw _lost(e);
      }
      if (clock().difference(since) + _findInterval > _findTimeout) {
        throw _notFound(
          'GitHub shows no run named $title ${_findTimeout.inMinutes} minutes after the dispatch',
        );
      }
      await _pause(_findInterval);
    }
  }

  WincodeException _notFound(String what) => WincodeException(
    ExitCode.failed,
    'run-not-found',
    what,
    why:
        'the dispatch was accepted, but GitHub does not show it as a run named wincode ${plan.requestId}${runUrl == null ? '' : ' at $runUrl'}.',
    next:
        'look for the run named wincode ${plan.requestId} on https://github.com/$_repository/actions/workflows/$_file ; if it '
        'is there, collect it with ${_collect('<run id>')}.',
  );

  /// The run [id] as GitHub shows it, once it does, and checked to be the one this build started: named
  /// `wincode <request ID>`, started by a dispatch.
  ///
  /// Right after a dispatch GitHub may show the run under the name of the workflow, and only a moment later under the
  /// name that `run-name` gives it (a real run showed `wincode-ios` first). The dispatch named the run, so a name that
  /// is not ours yet is waited for like a run that is not there yet; only two minutes of it are a failure.
  Future<Map<String, Object?>> _identify(
    int id,
    String title,
    DateTime since,
  ) async {
    String? seen;
    for (;;) {
      await _checkInterrupt();
      try {
        final run = await client.getJson(
          '/repos/$_repository/actions/runs/$id',
        );
        final shown = run['display_title'] ?? run['name'];
        if (shown == title && run['event'] == 'workflow_dispatch') {
          return run;
        }
        seen =
            'it is named "${shown ?? 'nothing'}" and was started by ${run['event']}';
      } on GithubException catch (e) {
        if (e.failure != GithubFailure.notFound) rethrow;
      }
      if (clock().difference(since) + _findInterval > _findTimeout) {
        throw _notFound(
          seen == null
              ? 'GitHub shows no run $id ${_findTimeout.inMinutes} minutes after the dispatch'
              : 'run $id is not the run that this build started, ${_findTimeout.inMinutes} minutes after the dispatch: $seen',
        );
      }
      await _pause(_findInterval);
    }
  }

  // Collecting.

  Future<void> _collectRun(int id, int workflowId) async {
    _phase = 'run';
    final Map<String, Object?> run;
    try {
      run = await client.getJson('/repos/$_repository/actions/runs/$id');
    } on GithubException catch (e) {
      if (e.failure != GithubFailure.notFound) rethrow;
      throw WincodeException(
        ExitCode.failed,
        'run-not-found',
        'GitHub has no run $id in $_repository, or the token cannot see it',
        why: 'wincode build --run collects a run that an earlier wincode build started.',
        next: 'check the number: it is in the address of the run, ending .../actions/runs/<id>.',
      );
    }
    final title = '${run['display_title'] ?? run['name']}';
    final named = parseRunName(title);
    if (run['event'] != 'workflow_dispatch' ||
        run['workflow_id'] != workflowId ||
        named == null ||
        named.tag != appTag(config.bundleId)) {
      throw WincodeException(
        ExitCode.failed,
        'run-mismatch',
        'run $id is not a build of ${config.name ?? 'this app'} by the workflow $_file',
        why:
            'wincode build --run collects a dispatched run of the app\'s workflow whose name carries the app\'s tag, so '
            'that it never signs the IPA of another app.',
        next:
            'check the number of the run, and the app: ${config.name == null ? 'wincode.yaml' : '--app ${config.name}'}.',
      );
    }
    runId = id;
    runUrl = run['html_url'] is String
        ? run['html_url']! as String
        : 'https://github.com/$_repository/actions/runs/$id';
    plan
      ..requestId = title.substring('wincode '.length)
      ..buildName = named.version
      ..buildNumber = named.number
      ..commit = run['head_sha'] as String?
      ..ref = run['head_branch'] as String? ?? plan.ref;
    _begun = clock();
    _say('collecting run $id, $runUrl');
    await _afterIdentified(run, (
      bundleId: config.bundleId,
      version: named.version,
      number: named.number,
    ));
  }

  // Following.

  Future<void> _afterIdentified(
    Map<String, Object?> first,
    IpaExpectation expect,
  ) async {
    _lastRun = first;
    await _follow(first);
    final ended = _lastRun!['conclusion'] as String? ?? 'unknown';
    conclusion = ended;
    if (ended == 'cancelled') {
      throw WincodeException(
        ExitCode.failed,
        'run-cancelled',
        'run $runUrl was cancelled',
        why: "someone cancelled it on GitHub, or the account's usage limit stopped it. A cancelled run makes no IPA.",
        next:
            'run wincode build again. Build number ${expect.number} was not used.',
      );
    }
    if (ended != 'success') {
      throw _failed(ended, expect);
    }
    _phase = 'artifact';
    await _checkInterrupt();
    final IpaFacts facts;
    try {
      facts = await ArtifactFetcher(
        client: client,
        repository: _repository,
        runId: runId!,
        runUrl: runUrl!,
        conclusion: ended,
        collect: _collect(runId!),
        expect: expect,
        output: config.output,
        redactor: redactor,
        findings: findings,
        deleteAfter: cleanup,
        events: events,
        say: _say,
        stop: _signals.next,
      ).fetch();
    } on WincodeException catch (e) {
      // A download that was interrupted fails in some way, and the interruption is the reason.
      await _checkInterrupt();
      if (!cleanup) rethrow;
      throw WincodeException(
        e.exitCode,
        e.id,
        e.what,
        why: e.why,
        next:
            "${e.next} The repository is public, so anyone with a GitHub account can download the artifact until it expires: delete it on the run's page, $runUrl, if you do not need it.",
        details: e.details,
      );
    } on GithubException {
      await _checkInterrupt();
      rethrow;
    }
    ipa = {
      'path': facts.path,
      'size': facts.size,
      'sha256': facts.sha256,
      'bundleId': facts.bundleId,
      'version': facts.version,
      'build': facts.build,
    };
  }

  WincodeException _failed(String ended, IpaExpectation expect) {
    final step = _failedStep();
    final free = 'Build number ${expect.number} was not used.';
    if (step == null) {
      return WincodeException(
        ExitCode.failed,
        'run-failed',
        'run $runUrl ended ($ended) before its job started',
        why:
            "the job has no steps, as when the account's spending limit is reached or no runner could be given. The "
            "run's page says why.",
        next:
            "open the run's page, fix the cause, then run wincode build again. $free",
      );
    }
    return WincodeException(
      ExitCode.failed,
      'run-failed',
      'run $runUrl ${ended == 'failure' ? 'failed' : 'ended ($ended)'} at step "${step.name}"',
      why:
          "the step's log says why: ${step.log}. A build that fails on the runner usually fails the same way again, so "
          'winCode does not start it again.',
      next:
          'read the log at ${step.log}, fix the cause and push it, then run wincode build again. $free',
    );
  }

  /// The first step that did not succeed, with the address of its log.
  ({String name, String log})? _failedStep() {
    const fine = {'success', 'skipped', 'neutral'};
    for (final job in _jobs) {
      if (fine.contains(job['conclusion'])) continue;
      final steps = job['steps'];
      if (steps is! List<Object?>) continue;
      for (final step in steps.whereType<Map<String, Object?>>()) {
        final result = step['conclusion'];
        if (result is String && !fine.contains(result)) {
          return (
            name: '${step['name']}',
            log: '${job['html_url'] ?? runUrl}#step:${step['number']}:1',
          );
        }
      }
    }
    return null;
  }

  /// Reads the run every [pollInterval] until it ends, with the ETag of the last answer, and tells what changes.
  Future<void> _follow(Map<String, Object?> first) async {
    final begun = _begun!;
    final attempt = first['run_attempt'] is int
        ? first['run_attempt']! as int
        : 1;
    // The attempt that this build started: a re-run on GitHub is another attempt, and not followed.
    final path = '/repos/$_repository/actions/runs/$runId/attempts/$attempt';
    var run = first;
    String? runTag, jobsTag;
    var failures = 0;
    var waits = 0;
    for (;;) {
      await _checkInterrupt();
      try {
        final read = await client.getJsonIfChanged(path, etag: runTag);
        if (!read.notModified) {
          run = read.json!;
          runTag = read.etag;
        }
        if (run['status'] != 'queued') {
          final listed = await client.getJsonIfChanged(
            '$path/jobs',
            query: const {'per_page': '100'},
            etag: jobsTag,
          );
          if (!listed.notModified) {
            _jobs = [
              for (final j
                  in (listed.json!['jobs'] as List<Object?>? ?? const []))
                if (j is Map<String, Object?>) j,
            ];
            jobsTag = listed.etag;
          }
        }
        failures = 0;
      } on GithubException catch (e) {
        final elapsed = clock().difference(begun);
        if (e.failure == GithubFailure.rateLimited) {
          // A rate limit slows the polling; it does not fail the build.
          final wait = e.retryAfter ?? const Duration(minutes: 1);
          if (elapsed + wait > timeout) throw _timedOut(elapsed);
          _say(
            'GitHub limits the requests of this token: waiting ${wait.inSeconds} s',
          );
          await _pause(wait);
          continue;
        }
        final again =
            (e.failure == GithubFailure.offline ||
                e.failure == GithubFailure.unavailable) &&
            ++failures < _pollFailures &&
            elapsed + pollInterval <= timeout;
        if (!again) rethrow;
        _say(
          'could not read the run (${e.message}); asking again in ${pollInterval.inSeconds} s',
        );
        await _pause(pollInterval);
        continue;
      }
      _lastRun = run;
      _noteChanges(run);
      if (run['status'] == 'completed') return;
      final elapsed = clock().difference(begun);
      if (elapsed.inSeconds >= 60 * (waits + 1)) {
        waits = elapsed.inSeconds ~/ 60;
        events?.emit('wait', {
          'status': run['status'],
          'elapsedSeconds': elapsed.inSeconds,
          'minutes': minutesOf(_jobs, clock())['total'],
        });
      }
      if (elapsed + pollInterval > timeout) throw _timedOut(elapsed);
      await _pause(pollInterval);
    }
  }

  WincodeException _timedOut(Duration elapsed) => WincodeException(
    ExitCode.pending,
    'run-timeout',
    'stopped waiting for run $runUrl after ${_minutes(timeout)}; it is still ${_lastRun?['status'] ?? 'going'}',
    why:
        'the run goes on and uses macOS minutes until it ends; --timeout ends the wait, never the run. Its IPA can be '
        'downloaded for a day after it ends.',
    next:
        'run ${_collect(runId!)} to wait for it and collect the IPA, or cancel it at $runUrl.',
  );

  // What changed since the last look.

  String? _lastRunState;
  final _jobStates = <Object?, String>{};
  final _stepStates = <String, String>{};

  void _noteChanges(Map<String, Object?> run) {
    final state = '${run['status']}/${run['conclusion']}';
    if (state != _lastRunState) {
      _lastRunState = state;
      events?.emit('run', {
        'status': run['status'],
        'conclusion': run['conclusion'],
      });
      _say(
        'run ${run['status']}${run['conclusion'] == null ? '' : ': ${run['conclusion']}'}',
      );
    }
    for (final job in _jobs) {
      final jobStatus = '${job['status']}';
      if (jobStatus == 'queued' || jobStatus == 'waiting') continue;
      final jobState = '$jobStatus/${job['conclusion']}';
      if (_jobStates[job['id']] != jobState) {
        _jobStates[job['id']] = jobState;
        events?.emit('job', {
          'job': job['name'],
          'status': job['status'],
          'conclusion': job['conclusion'],
        });
        _say(
          'job ${job['name']} ${job['status']}${job['conclusion'] == null ? '' : ': ${job['conclusion']}'}',
        );
      }
      final steps = job['steps'];
      if (steps is! List<Object?>) continue;
      for (final step in steps.whereType<Map<String, Object?>>()) {
        final stepStatus = '${step['status']}';
        if (stepStatus == 'queued' || stepStatus == 'pending') continue;
        final key = '${job['id']}/${step['number']}';
        final stepState = '$stepStatus/${step['conclusion']}';
        if (_stepStates[key] != stepState) {
          _stepStates[key] = stepState;
          events?.emit('step', {
            'job': job['name'],
            'number': step['number'],
            'name': step['name'],
            'status': step['status'],
            'conclusion': step['conclusion'],
          });
          _say(
            'step ${step['number']} "${step['name']}" ${step['status']}${step['conclusion'] == null ? '' : ': ${step['conclusion']}'}',
          );
        }
      }
    }
  }

  // Signals.

  Future<void> _pause(Duration d) => Future.any([sleep(d), _signals.next]);

  /// Deals with a signal that arrived since the last look: Ctrl-C at a terminal asks whether to cancel the run, and
  /// anything else stops the wait. The run is never cancelled unasked (ADR-0015, section 4). Returns when no signal
  /// arrived.
  Future<void> _checkInterrupt() async {
    if (!_signals.pending) return;
    final signal = _signals.take();
    if (_phase == 'artifact') {
      throw WincodeException(
        ExitCode.pending,
        'wait-stopped',
        'stopped while downloading the IPA of run $runUrl, which has ended',
        why: 'the run is over, and its IPA can be downloaded for a day after it ended.',
        next: 'run ${_collect(runId!)} to download it again.',
      );
    }
    if (canAsk && signal == ProcessSignal.sigint) {
      final age = clock().difference(_begun!).inMinutes;
      report.write(
        'Cancel the run on GitHub too? It has run for about $age minute${age == 1 ? '' : 's'}. [y/N] ',
      );
      // No is the default: Enter, anything but y, and a second Ctrl-C.
      final reply = await Future.any<String?>([
        readAnswer(),
        _signals.next.then<String?>((_) => null),
      ]);
      report.writeln();
      if (_signals.pending) _signals.take();
      final answer = reply?.trim().toLowerCase();
      if (answer == 'y' || answer == 'yes') {
        await _cancel();
      }
    }
    throw WincodeException(
      ExitCode.pending,
      'wait-stopped',
      'stopped waiting for run $runUrl, which is still ${_lastRun?['status'] ?? 'going'}',
      why: 'the run goes on and uses macOS minutes until it ends; its IPA can be downloaded for a day after that.',
      next:
          'run ${_collect(runId!)} to wait for it and collect the IPA, or cancel it at $runUrl.',
    );
  }

  Future<void> _cancel() async {
    try {
      await client.post('/repos/$_repository/actions/runs/$runId/cancel');
    } on GithubException catch (e) {
      throw githubProblem(e, what: 'cancel the run', run: _going);
    }
    throw WincodeException(
      ExitCode.failed,
      'run-cancelled',
      'you cancelled run $runUrl',
      why: 'GitHub stops it within moments. The minutes it has used are billed, and it makes no IPA.',
      next:
          'run wincode build again when you want a new build. Build number ${plan.buildNumber} was not used.',
    );
  }
}

String _short(String sha) => sha.substring(0, sha.length.clamp(0, 7));

String _stamp(DateTime time) =>
    '${time.toUtc().toIso8601String().substring(0, 19).replaceFirst('T', ' ')} UTC';

String _minutes(Duration d) => d.inSeconds % 60 == 0
    ? '${d.inMinutes} minute${d.inMinutes == 1 ? '' : 's'}'
    : '${d.inSeconds} second${d.inSeconds == 1 ? '' : 's'}';
