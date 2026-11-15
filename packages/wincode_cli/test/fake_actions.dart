/// GitHub Actions on 127.0.0.1 for tests: the routes of the dispatch, the run, its jobs, its artifacts and their
/// download, on top of [FakeRepo]. Not for use outside tests.
library;

import 'package:wincode_core/testing.dart' show sha256Hex;

import 'fake_github.dart';

/// One step of a job as GitHub lists it.
Map<String, Object?> fakeStep(
  int number,
  String name,
  String status, [
  String? conclusion,
]) => {
  'number': number,
  'name': name,
  'status': status,
  'conclusion': conclusion,
};

/// One job of a run in one state.
class FakeJob {
  const FakeJob(
    this.name,
    this.status, {
    this.conclusion,
    this.steps = const [],
    this.startedAt = '2026-11-15T12:00:05Z',
    this.completedAt,
    this.labels = const ['macos-26'],
  });

  final String name;
  final String status;
  final String? conclusion;
  final List<Map<String, Object?>> steps;
  final String? startedAt;
  final String? completedAt;
  final List<String> labels;
}

/// What a run looks like for [polls] reads of it.
class RunState {
  const RunState(
    this.status, {
    this.conclusion,
    this.jobs = const [],
    this.polls = 1,
  });

  final String status;
  final String? conclusion;
  final List<FakeJob> jobs;
  final int polls;
}

const _stepNames = [
  'Set up job',
  'Checkout',
  'Xcode',
  'Flutter',
  'Build the archive, unsigned',
  'Pack the IPA',
  'Upload the artifact',
  'Complete job',
];

/// The steps of the job, the first [done] completed with [conclusion] (the last of them), then one running.
List<Map<String, Object?>> stepsAt(int done, {String conclusion = 'success'}) =>
    [
      for (var i = 0; i < _stepNames.length; i++)
        if (i < done - 1)
          fakeStep(i + 1, _stepNames[i], 'completed', 'success')
        else if (i == done - 1)
          fakeStep(i + 1, _stepNames[i], 'completed', conclusion)
        else if (i == done)
          fakeStep(i + 1, _stepNames[i], 'in_progress')
        else
          fakeStep(i + 1, _stepNames[i], 'queued'),
    ];

/// A run that queues for a read, builds for three, and succeeds after 205 seconds of job time (4 minutes).
List<RunState> succeeding() => [
  const RunState('queued'),
  RunState(
    'in_progress',
    polls: 3,
    jobs: [FakeJob('unsigned-ipa', 'in_progress', steps: stepsAt(4))],
  ),
  RunState(
    'completed',
    conclusion: 'success',
    jobs: [
      FakeJob(
        'unsigned-ipa',
        'completed',
        conclusion: 'success',
        steps: stepsAt(8),
        completedAt: '2026-11-15T12:03:30Z',
      ),
    ],
  ),
];

/// A run whose build step fails.
List<RunState> failing({String conclusion = 'failure'}) => [
  RunState(
    'in_progress',
    jobs: [FakeJob('unsigned-ipa', 'in_progress', steps: stepsAt(4))],
  ),
  RunState(
    'completed',
    conclusion: conclusion,
    jobs: [
      FakeJob(
        'unsigned-ipa',
        'completed',
        conclusion: conclusion,
        steps: stepsAt(5, conclusion: conclusion),
        completedAt: '2026-11-15T12:02:00Z',
      ),
    ],
  ),
];

/// A run that goes on for ever.
List<RunState> endless() => [
  RunState(
    'in_progress',
    polls: 100000,
    jobs: [FakeJob('unsigned-ipa', 'in_progress', steps: stepsAt(4))],
  ),
];

class _Run {
  _Run(this.id, this.title, this.headSha, this.ref, this.created);

  final int id;
  final String title;
  final String headSha;
  final String ref;
  final DateTime created;
  var reads = 0;
}

/// The Actions routes of a made-up repository. [handle] answers a request, or returns null for one that is not about a
/// run, so that [FakeRepo] answers it.
class FakeActions {
  FakeActions(this.repo, {required this.now});

  final FakeRepo repo;
  DateTime Function() now;

  /// The states the run goes through, one per [RunState.polls] reads.
  List<RunState> timeline = succeeding();

  // What the dispatch does.
  /// Answers 204 with no run, as the API version before 2026-03-10 does.
  bool answersNoRun = false;

  /// Starts the run and then closes the connection without an answer.
  bool dropsAnswer = false;

  /// Refuses the dispatch with this answer instead.
  GhAnswer? refusesDispatch;

  /// The run does not show for this many reads of it.
  int hiddenReads = 0;

  /// The run does not show in the list of the workflow's runs either.
  bool hiddenFromList = false;

  /// The run carries another name than the request ID, as a run of another workflow would.
  String? titled;

  /// The commit the run builds, when it is not the one the ref points to: the branch moved.
  String? builds;

  /// What the run says it is, when it is not a dispatched run of the workflow.
  int workflowId = 419286522;
  String event = 'workflow_dispatch';

  /// Called after each read of the run through its attempt, with the number of reads so far.
  void Function(int reads)? onRead;

  // The artifact.
  List<int>? zip;
  String? digest;
  bool noDigest = false;
  bool expired = false;
  bool noArtifact = false;
  bool twoArtifacts = false;
  Uri? storage;
  GhAnswer? refusesDelete;

  /// Refuses the request to cancel the run with this answer instead.
  GhAnswer? refusesCancel;

  /// The requests that change something, in order.
  final dispatches = <GhRequest>[];
  final cancels = <GhRequest>[];
  final deletes = <GhRequest>[];

  /// How many times the run was read through its attempt, which a wait does.
  int get polls => _run?.reads ?? 0;

  _Run? _run;
  var _nextId = 9000001;

  String get _base => '/repos/${repo.owner}/${repo.name}';

  String get runUrl =>
      'https://github.com/${repo.owner}/${repo.name}/actions/runs/${_run!.id}';

  int get runId => _run!.id;

  static const artifactId = 7001;
  static const signature = 'SECRETSIGNATURE';

  int _stateIndex(int read) {
    var left = read < 0 ? 0 : read;
    for (var i = 0; i < timeline.length; i++) {
      if (left < timeline[i].polls) return i;
      left -= timeline[i].polls;
    }
    return timeline.length - 1;
  }

  Map<String, Object?> _runJson(_Run run, RunState state) => {
    'id': run.id,
    'name': titled ?? run.title,
    'display_title': titled ?? run.title,
    'event': event,
    'status': state.status,
    'conclusion': state.conclusion,
    'head_sha': builds ?? run.headSha,
    'head_branch': run.ref,
    'run_attempt': 1,
    'workflow_id': workflowId,
    'created_at': run.created.toUtc().toIso8601String(),
    'html_url': runUrl,
  };

  List<Map<String, Object?>> _jobsJson(RunState state) => [
    for (final (i, job) in state.jobs.indexed)
      {
        'id': 100 + i,
        'name': job.name,
        'status': job.status,
        'conclusion': job.conclusion,
        'started_at': job.startedAt,
        'completed_at': job.completedAt,
        'labels': job.labels,
        'html_url': '$runUrl/job/${100 + i}',
        'steps': job.steps,
      },
  ];

  /// A run that an earlier build started, for `--run`: named with [requestId], on [ref].
  void existingRun(String requestId, {String ref = 'main'}) {
    _run = _Run(_nextId++, 'wincode $requestId', repo.refs[ref]!, ref, now());
  }

  /// The answer to [r], or null when it is not about the Actions of the repository.
  GhAnswer? handle(GhRequest r) {
    final path = r.path;
    if (!path.startsWith('$_base/actions/')) return null;
    final rest = path.substring('$_base/actions/'.length);
    if (r.method == 'POST' && rest == 'workflows/wincode-ios.yml/dispatches') {
      return _dispatch(r);
    }
    final run = _run;
    if (r.method == 'POST' && run != null && rest == 'runs/${run.id}/cancel') {
      cancels.add(r);
      return refusesCancel ?? const GhAnswer.empty(202);
    }
    if (r.method == 'DELETE' && rest == 'artifacts/$artifactId') {
      deletes.add(r);
      return refusesDelete ?? const GhAnswer.empty();
    }
    if (r.method != 'GET' || run == null) return null;
    if (rest == 'runs/${run.id}') {
      if (hiddenReads > 0) {
        hiddenReads--;
        return const GhAnswer.notFound();
      }
      return GhAnswer(_runJson(run, timeline[_stateIndex(run.reads - 1)]));
    }
    if (rest == 'runs/${run.id}/attempts/1') {
      final index = _stateIndex(run.reads);
      run.reads++;
      onRead?.call(run.reads);
      return _tagged(r, 'run-${run.id}-$index', _runJson(run, timeline[index]));
    }
    if (rest == 'runs/${run.id}/attempts/1/jobs') {
      final index = _stateIndex(run.reads - 1);
      return _tagged(r, 'jobs-${run.id}-$index', {
        'total_count': timeline[index].jobs.length,
        'jobs': _jobsJson(timeline[index]),
      });
    }
    if (rest == 'runs/${run.id}/artifacts') {
      return GhAnswer({'total_count': 1, 'artifacts': _artifacts()});
    }
    if (rest == 'artifacts/$artifactId/zip') {
      final at = storage ?? (throw StateError('no storage was given'));
      return GhAnswer.redirect('$at/blob/$artifactId?sv=2024&sig=$signature');
    }
    return null;
  }

  GhAnswer _tagged(GhRequest r, String tag, Map<String, Object?> json) {
    final etag = 'W/"$tag"';
    return r.headers['if-none-match'] == etag
        ? const GhAnswer.empty(304, {'etag': '"stale form"'})
        : GhAnswer(json, headers: {'etag': etag});
  }

  GhAnswer _dispatch(GhRequest r) {
    dispatches.add(r);
    if (refusesDispatch != null) return refusesDispatch!;
    final body = r.json;
    final ref = body['ref'] as String;
    final inputs = (body['inputs'] as Map).cast<String, String>();
    const declared = {
      'request_id',
      'build_name',
      'build_number',
      'flutter_version',
      'min_xcode_version',
      'flavor',
      'target',
    };
    final unknown = inputs.keys.where((k) => !declared.contains(k)).toList();
    if (unknown.isNotEmpty) {
      return GhAnswer.error(
        422,
        'Unexpected inputs provided: ${unknown.map((u) => '"$u"').toList()}',
      );
    }
    final sha = repo.refs[ref];
    if (sha == null) {
      return GhAnswer.error(422, 'No ref found for: refs/heads/$ref');
    }
    final run = _run = _Run(
      _nextId++,
      'wincode ${inputs['request_id']}',
      sha,
      ref,
      now(),
    );
    // Only a build that looks for its run in the list needs it there.
    if (answersNoRun && !hiddenFromList) {
      repo.runs.add(
        fakeRun(
          run.id,
          inputs['request_id']!,
          status: 'queued',
          conclusion: null,
          created: run.created,
        ),
      );
    }
    if (dropsAnswer) return const GhAnswer.drop();
    if (answersNoRun) return const GhAnswer.empty();
    return GhAnswer({
      'workflow_run_id': run.id,
      'run_url': 'https://api.github.com$_base/actions/runs/${run.id}',
      'html_url': runUrl,
    });
  }

  List<Map<String, Object?>> _artifacts() {
    if (noArtifact) return const [];
    final bytes = zip ?? const <int>[];
    Map<String, Object?> one(int id) => {
      'id': id,
      'name': 'unsigned-ipa',
      'size_in_bytes': bytes.length,
      'expired': expired,
      'expires_at': '2026-11-16T12:03:34Z',
      if (!noDigest) 'digest': digest ?? 'sha256:${sha256Hex(bytes)}',
    };
    return [one(artifactId), if (twoArtifacts) one(artifactId + 1)];
  }
}
