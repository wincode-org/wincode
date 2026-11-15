import 'dart:convert';
import 'dart:io';

import 'package:wincode_asc/wincode_asc.dart';
import 'package:wincode_core/wincode_core.dart';

import 'build_number.dart';
import 'build_project.dart';
import 'config.dart';
import 'credentials.dart';
import 'events.dart';
import 'failure.dart';
import 'github.dart';
import 'preflight.dart';
import 'redact.dart';

/// The options of `wincode build` that the checks need (ADR-0015, section 1).
class BuildOptions {
  const BuildOptions({
    this.ref,
    this.buildName,
    this.buildNumber,
    this.allowPublic = false,
  });

  /// `--ref`: a branch or tag to build instead of the `@<ref>` of `workflow:`.
  final String? ref;

  /// `--build-name`: the version, for this build only.
  final String? buildName;

  /// `--build-number`: a number, or `auto`.
  final String? buildNumber;

  /// `--allow-public`.
  final bool allowPublic;
}

/// Everything `wincode build` has decided about a build before it starts one: the plan that the person is asked to
/// confirm, and the inputs of the dispatch. A field is null while the checks have not found it out.
class BuildPlan {
  BuildPlan({required this.app, required this.bundleId});

  final String? app;
  final String bundleId;

  /// Whether this is the plan of a dry run, which reads nothing: what only GitHub can say is shown as a placeholder.
  bool placeholders = false;

  String? repository;
  bool? private;

  /// The workflow's path in the repository, such as `.github/workflows/wincode-ios.yml`.
  String? workflow;
  int? contract;
  String? ref;
  String? commit;
  String? runsOn;
  int? timeoutMinutes;

  /// The version of the workflow's `XCODE_APP`, and `min_xcode_version`.
  String? xcode;
  String? minXcode;
  String? flutter;

  /// How the Flutter constraint of `pubspec.yaml` stands: `allowed by pubspec.yaml`, or what could not be told.
  String? flutterNote;
  String? flavor;
  String? scheme;
  String? configuration;
  String? target;
  String? buildName;
  String? buildNameSource;
  String? buildNumber;
  String? buildNumberSource;
  String? buildNumberNote;
  String? requestId;

  /// The inputs of the dispatch, once everything they need is known.
  Map<String, String>? inputs;

  /// The plan as the person reads it, before the question (ADR-0015, section 7).
  List<String> lines() {
    final name = app == null ? bundleId : '$app ($bundleId)';
    String line(String label, String? value) =>
        '  ${'$label:'.padRight(13)}${value ?? 'unknown'}';
    return [
      'Build plan:',
      line('app', name),
      line(
        'repository',
        repository == null
            ? null
            : '$repository${private == null
                  ? ''
                  : private!
                  ? ', private: the account pays for the minutes'
                  : ', public: standard runners are free'}',
      ),
      line(
        'workflow',
        workflow == null
            ? null
            : '$workflow${contract == null ? '' : ', contract $contract'}',
      ),
      line(
        'ref',
        ref == null
            ? null
            : '$ref, commit ${placeholders ? '<commit of $ref>' : _short(commit)}',
      ),
      line(
        'runner',
        placeholders
            ? '<runs-on and timeout-minutes of the workflow at $ref>'
            : runsOn == null
            ? null
            : '$runsOn${timeoutMinutes == null ? '' : ', stopped after $timeoutMinutes minutes (timeout-minutes)'}',
      ),
      line(
        'xcode',
        placeholders
            ? '<XCODE_APP of the workflow at $ref>, at least $minXcode (min_xcode_version)'
            : xcode == null
            ? 'not named by the workflow, at least $minXcode (min_xcode_version)'
            : '$xcode (XCODE_APP), at least $minXcode (min_xcode_version)',
      ),
      line(
        'flutter',
        '$flutter (flutter_version)${placeholders
            ? ', <checked against pubspec.yaml at $ref>'
            : flutterNote == null
            ? ''
            : ', $flutterNote'}',
      ),
      line(
        'flavor',
        flavor == null
            ? 'none, scheme ${scheme ?? 'Runner'}, configuration ${configuration ?? 'Release'}'
            : '$flavor, scheme ${scheme ?? 'unknown'}, configuration ${configuration ?? 'unknown'}',
      ),
      line('target', target ?? 'lib/main.dart'),
      line(
        'version',
        buildName == null ? null : '$buildName ($buildNameSource)',
      ),
      line(
        'build',
        buildNumber == null
            ? null
            : '$buildNumber ($buildNumberSource${buildNumberNote == null ? '' : ': $buildNumberNote'})',
      ),
    ];
  }

  static String _short(String? commit) => commit == null
      ? 'unknown'
      : commit.substring(0, commit.length.clamp(0, 7));

  /// The plan as an object, for `--json`.
  Map<String, Object?> toJson() => {
    'repository': repository,
    'private': private,
    'workflow': workflow,
    'contract': contract,
    'ref': ref,
    'commit': commit,
    'runsOn': runsOn,
    'timeoutMinutes': timeoutMinutes,
    'xcodeApp': xcode,
    'minXcodeVersion': minXcode,
    'flutterVersion': flutter,
    'flavor': flavor,
    'scheme': scheme,
    'configuration': configuration,
    'target': target ?? 'lib/main.dart',
    'buildName': buildName,
    'buildNameSource': buildNameSource,
    'buildNumber': buildNumber,
    'buildNumberSource': buildNumberSource,
    'requestId': requestId,
    'inputs': inputs,
  };

  /// The fields of the `plan` event (ADR-0015, section 9).
  Map<String, Object?> toEvent() => {
    'repository': repository,
    'private': private,
    'workflow': workflow,
    'ref': ref,
    'commit': commit,
    'runsOn': runsOn,
    'timeoutMinutes': timeoutMinutes,
    'inputs': inputs,
    'buildName': buildName,
    'buildNumber': buildNumber,
    'buildNumberSource': buildNumberSource,
  };
}

/// What the checks of `wincode build` found: every finding in order, and the plan as far as they got. The [client] is
/// the one the checks read GitHub with, once they had a token, so that a run goes on with it; [workflowId] is the id
/// that GitHub gives the workflow, once they found it.
typedef BuildReport = ({
  List<Finding> findings,
  BuildPlan plan,
  GithubClient? client,
  int? workflowId,
});

/// The checks that `wincode build` makes before it starts a run, and that `wincode doctor --build` makes without one
/// (ADR-0015, sections 2, 3, 8 and 10). They read GitHub, and App Store Connect when the build number needs it, and send
/// nothing else: no request here changes anything.
///
/// A checker is used once. Each check adds its finding; one that finds a problem which makes the next ones impossible
/// ends the run with a line that says so.
class BuildChecker {
  BuildChecker({
    required this.config,
    required this.options,
    required this.environment,
    required this.redactor,
    required this.clock,
    required this.github,
    required this.connect,
    required this.run,
    this.doctor = false,
    this.log,
    this.events,
    String Function()? random,
  }) : _random = random ?? randomHex,
       plan = BuildPlan(app: config.name, bundleId: config.bundleId);

  final WincodeConfig config;
  final BuildOptions options;
  final Map<String, String> environment;
  final Redactor redactor;
  final DateTime Function() clock;
  final GithubConnect github;
  final AscConnect connect;
  final RunProcess run;

  /// For `wincode doctor --build`: a public repository is a warning, since `--allow-public` is an option of `build`.
  final bool doctor;
  final void Function(String line)? log;
  final EventWriter? events;
  final String Function() _random;

  final BuildPlan plan;

  /// What the checks learned that a run needs.
  GithubClient? _client;
  int? _workflowId;

  /// Whether the read of App Store Connect failed and said so in a finding, as distinct from there being no key to read.
  bool _ascFailed = false;
  late final List<Finding> _findings = events == null
      ? <Finding>[]
      : EventFindings(events!);

  void _add(Finding f) => _findings.add(f);

  Finding _fail(
    String check,
    String id,
    String what, {
    required String why,
    required String next,
    ExitCode code = ExitCode.config,
  }) => Finding.fail(
    check,
    WincodeException(code, id, what, why: why, next: next),
  );

  Finding _warn(
    String check,
    String id,
    String what, {
    required String why,
    required String next,
  }) => Finding.warn(
    check,
    WincodeException(ExitCode.ok, id, what, why: why, next: next),
  );

  String get _repository => config.workflow!.repository;
  String get _ref => options.ref ?? config.workflow!.ref;
  String get _workflowFile => config.workflow!.file;
  String get _workflowPath => '.github/workflows/$_workflowFile';
  String get _appName => config.name ?? 'this app';

  /// The other side of [redactor]: IDs that this run prints are registered first.
  void _registerIds() => redactor.hide(config.bundleId, '<bundle ID>');

  BuildReport _report() => (
    findings: _findings,
    plan: plan,
    client: _client,
    workflowId: _workflowId,
  );

  // The settings.

  /// The checks of `wincode.yaml` alone. False when the run cannot go on, since it does not know what to read.
  bool _settings() {
    plan
      ..flavor = config.flavor
      ..minXcode = config.minXcodeVersion
      ..flutter = config.flutterVersion
      ..target = config.target
      ..configuration = config.configuration;
    if (!_workflowSetting()) return false;
    var complete = true;
    if (config.flutterVersion == null) {
      complete = false;
      _add(
        _fail(
          'settings',
          'flutter-version-missing',
          'wincode.yaml names no flutter_version for $_appName',
          why:
              'wincode build clones exactly that release of Flutter on the runner, so that each app of one workflow can '
              'build with its own.',
          next: 'add flutter_version: 3.47.7 (the release the app is made with) to the app or to defaults.',
        ),
      );
    }
    if (config.minXcodeVersion == null) {
      complete = false;
      _add(
        _fail(
          'settings',
          'min-xcode-missing',
          'wincode.yaml names no min_xcode_version for $_appName',
          why:
              'it is the oldest Xcode that may build the app, since App Store Connect refuses builds made with an older '
              'one. The workflow stops when its Xcode is older, and winCode compares them before it starts a run.',
          next: 'add min_xcode_version: "26.0" to the app or to defaults.',
        ),
      );
    }
    if (complete) {
      _add(
        const Finding.pass(
          'settings',
          'wincode.yaml names the workflow, flutter_version and min_xcode_version',
        ),
      );
    }
    return true;
  }

  /// The one setting that every use of GitHub needs: the workflow, which names the repository.
  bool _workflowSetting() {
    final workflow = config.workflow;
    if (workflow == null) {
      _add(
        _fail(
          'settings',
          'workflow-missing',
          'wincode.yaml names no workflow for $_appName',
          why: "wincode build starts the workflow that workflow: names, in the app's repository, on a macOS runner.",
          next:
              'add workflow: <owner>/<repository>/.github/workflows/wincode-ios.yml@<branch> to the app or to defaults, '
              'or give it to wincode init with --workflow-ref.',
        ),
      );
      return false;
    }
    plan
      ..repository = workflow.repository
      ..workflow = _workflowPath
      ..ref = _ref;
    return true;
  }

  // Without a network.

  /// What `--dry-run` shows: the plan from `wincode.yaml` and the options alone, with a placeholder for what only GitHub
  /// or App Store Connect can say, and the dispatch request as it would go out. Sends nothing and starts no program.
  ({BuildReport report, List<String> request}) dryRun() {
    _registerIds();
    if (!_settings()) {
      return (report: _report(), request: const []);
    }
    final ref = _ref;
    final pubspec = '<pubspec.yaml at $ref>';
    final flavor = config.flavor;
    plan
      ..placeholders = true
      ..scheme = flavor == null
          ? 'Runner'
          : flavor[0].toUpperCase() + flavor.substring(1)
      ..commit = null
      ..buildName = options.buildName ?? config.buildName ?? pubspec
      ..buildNameSource = options.buildName != null
          ? '--build-name'
          : config.buildName != null
          ? 'build_name in wincode.yaml'
          : "pubspec.yaml's version at $ref";
    final given = options.buildNumber;
    final auto = given == 'auto' || (given == null && !_isFlat);
    plan
      ..buildNumber = auto
          ? "<auto: App Store Connect's highest + 1>"
          : given ?? '<pubspec.yaml at $ref>'
      ..buildNumberSource = auto
          ? 'auto'
          : given != null
          ? '--build-number'
          : "pubspec.yaml's number at $ref";
    plan.requestId = requestIdOf(
      tag: appTag(config.bundleId),
      version: plan.buildName!,
      number: plan.buildNumber!,
      random: '<random>',
    );
    _inputs();
    return (report: _report(), request: _requestLines());
  }

  bool get _isFlat => config.name == null;

  /// The inputs of the dispatch, in the order of ADR-0015 (section 8), and then those of `workflow_inputs`.
  void _inputs() {
    plan.inputs = {
      'request_id': plan.requestId!,
      'build_name': plan.buildName!,
      'build_number': plan.buildNumber!,
      'flutter_version': config.flutterVersion ?? '',
      'min_xcode_version': config.minXcodeVersion ?? '',
      'flavor': config.flavor ?? '',
      'target': config.target ?? '',
      ...config.workflowInputs,
    };
  }

  /// The dispatch request as it would go out (ADR-0015, section 4). No token is shown, only where it would come from.
  List<String> _requestLines() {
    final own = githubTokenVariable(config.name);
    final from = [?own, 'GH_TOKEN', 'GITHUB_TOKEN'].firstWhere(
      (v) => (environment[v] ?? '').trim().isNotEmpty,
      orElse: () => 'gh auth token, which a dry run does not ask',
    );
    return [
      'POST https://api.github.com/repos/$_repository/actions/workflows/$_workflowFile/dispatches',
      '    X-GitHub-Api-Version: $githubApiVersion',
      '    Authorization: Bearer <token from $from>',
      '    ${jsonEncode({'ref': _ref, 'inputs': plan.inputs})}',
    ];
  }

  // With a network: GitHub.

  /// Makes every check, in the order of ADR-0015 (section 10): the token, the repository, the workflow, the ref, the
  /// project at the ref's commit, the workflow at the ref, and the build number. It sends GET requests only.
  Future<BuildReport> check() async {
    _registerIds();
    if (!_settings()) {
      return _report();
    }
    try {
      await _checkAll();
    } on GithubException catch (e) {
      _add(Finding.fail('github', githubProblem(e, what: 'read $_repository')));
      _stopped();
    }
    return _report();
  }

  /// The checks of `wincode build --run` (ADR-0015, section 4), which collects a run that an earlier build started: the
  /// workflow is named, the token works, the repository can be read (and is not public without `--allow-public`), and
  /// the workflow is there, whose id tells that a run belongs to it. The project, the versions and the build number are
  /// not checked: the run was started with them, and carries them in its name.
  Future<BuildReport> collect() async {
    _registerIds();
    if (!_workflowSetting()) {
      return _report();
    }
    try {
      final token = await _token();
      if (token != null) {
        final client = _client = github(token.value, log);
        final repo = await _repositoryCheck(client);
        if (repo != null) {
          await _workflowCheck(client, repo, starts: false);
        }
      }
    } on GithubException catch (e) {
      _add(Finding.fail('github', githubProblem(e, what: 'read $_repository')));
      _stopped();
    }
    return _report();
  }

  void _stopped() => _add(
    const Finding.info('build', 'the checks after this one were not run'),
  );

  Future<void> _checkAll() async {
    final token = await _token();
    if (token == null) return;
    final client = _client = github(token.value, log);

    final repo = await _repositoryCheck(client);
    if (repo == null) return;
    if (!await _workflowCheck(client, repo)) return;
    final commit = await _refCheck(client);
    if (commit == null) return;
    final files = await _files(client, commit);
    if (files == null) return;
    plan.commit = commit.sha;

    final facts = _workflowFacts(files);
    if (facts != null) {
      _contract(facts);
      _workflowInputs(facts);
      _xcode(facts);
    }
    final pubspec = _pubspec(files);
    if (pubspec != null) {
      _flutterConstraint(pubspec);
    }
    await _flutterTag(client);
    _buildName(pubspec, files);
    _target(files);
    _xcodeProject(files);
    await _buildNumber(client, pubspec, files);
  }

  Future<GithubToken?> _token() async {
    try {
      final token = await findGithubToken(
        config,
        environment: environment,
        redactor: redactor,
        run: run,
      );
      _add(
        token.broad
            ? Finding.info(
                'github-token',
                'the token comes from ${token.source}, ${token.kind}, which can do far more than wincode build needs; a '
                    'fine-grained token limited to the repository is enough',
              )
            : Finding.pass(
                'github-token',
                'the token comes from ${token.source}, ${token.kind}',
              ),
      );
      return token;
    } on WincodeException catch (e) {
      _add(Finding.fail('github-token', e));
      _stopped();
      return null;
    }
  }

  /// The repository, or null when the run cannot go on.
  Future<Map<String, Object?>?> _repositoryCheck(GithubClient client) async {
    final Map<String, Object?> repo;
    try {
      repo = await client.getJson('/repos/$_repository');
    } on GithubException catch (e) {
      if (e.failure != GithubFailure.notFound) rethrow;
      _add(
        _fail(
          'repository',
          'repository-not-found',
          'GitHub has no repository $_repository, or the token cannot see it',
          why:
              'GitHub answers 404 for a misspelled name, and also for a private repository that the token has no access '
              'to.',
          next: 'check workflow: in wincode.yaml, and that the token is limited to this repository or includes it.',
        ),
      );
      _stopped();
      return null;
    }
    final public =
        repo['visibility'] == 'public' ||
        (repo['visibility'] == null && repo['private'] == false);
    plan.private = !public;
    final default_ = repo['default_branch'];
    if (!public) {
      _add(
        Finding.pass(
          'repository',
          '$_repository is private, so the account pays for the minutes${default_ is String ? ' (default branch $default_)' : ''}',
        ),
      );
    } else if (options.allowPublic) {
      _add(
        Finding.info(
          'repository',
          '$_repository is public, and --allow-public was given: the IPA can be downloaded by anyone until it is '
              'deleted',
        ),
      );
    } else {
      final problem = WincodeException(
        doctor ? ExitCode.ok : ExitCode.usage,
        'repository-public',
        '$_repository is a public repository',
        why:
            "anyone with a GitHub account can download a run's artifacts until they expire, so the app's IPA would be "
            'public.${doctor ? '' : ' Nothing was started.'}',
        next: doctor
            ? 'wincode build will need --allow-public, or a private repository.'
            : 'build from a private repository, or give --allow-public; winCode then deletes the artifact as soon as it '
                  'has downloaded and checked it.',
      );
      _add(
        doctor
            ? Finding.warn('repository', problem)
            : Finding.fail('repository', problem),
      );
      if (!doctor) {
        _stopped();
        return null;
      }
    }
    return repo;
  }

  /// Whether the run can go on after the checks of the workflow file in the repository. With [starts] false, the
  /// workflow is only looked up, for its id: a run that exists does not need the workflow to be active.
  Future<bool> _workflowCheck(
    GithubClient client,
    Map<String, Object?> repo, {
    bool starts = true,
  }) async {
    final branch = repo['default_branch'] is String
        ? repo['default_branch']! as String
        : 'the default branch';
    final Map<String, Object?> workflow;
    try {
      workflow = await client.getJson(
        '/repos/$_repository/actions/workflows/$_workflowFile',
      );
    } on GithubException catch (e) {
      if (e.failure != GithubFailure.notFound) rethrow;
      _add(
        _fail(
          'workflow',
          'workflow-not-found',
          '$_workflowFile is not a workflow of $_repository',
          why:
              "GitHub dispatches only a workflow that is on the repository's default branch ($branch), and it has none "
              'of that name.',
          next:
              'push $_workflowPath to $branch, or correct workflow: in wincode.yaml.',
        ),
      );
      _stopped();
      return false;
    }
    final id = workflow['id'];
    if (id is int) _workflowId = id;
    final state = workflow['state'];
    if (!starts) {
      _add(
        Finding.pass(
          'workflow',
          '$_workflowFile is a workflow of $_repository, which the run must belong to',
        ),
      );
    } else if (state != 'active') {
      _add(
        _fail(
          'workflow',
          'workflow-disabled',
          'the workflow $_workflowFile is disabled${state is String ? ' ($state)' : ''}',
          why:
              'GitHub starts no run of a disabled workflow, and it disables the workflows of a repository that has had no '
              'activity for 60 days.',
          next:
              'enable it on the Actions tab of $_repository, then run the command again.',
        ),
      );
    } else {
      _add(
        Finding.pass(
          'workflow',
          '$_workflowFile is an active workflow of $_repository',
        ),
      );
    }
    return true;
  }

  Future<({String sha, String tree})?> _refCheck(GithubClient client) async {
    final Map<String, Object?> commit;
    try {
      commit = await client.getJson('/repos/$_repository/commits/$_ref');
    } on GithubException catch (e) {
      if (e.failure != GithubFailure.notFound &&
          e.failure != GithubFailure.unprocessable) {
        rethrow;
      }
      _add(
        _fail(
          'ref',
          'ref-not-found',
          'GitHub has no branch or tag $_ref in $_repository',
          why: 'the run starts at that ref, with the workflow file as it is there.',
          next: 'push the branch or tag, or correct the @<ref> of workflow: in wincode.yaml, or give --ref.',
        ),
      );
      _stopped();
      return null;
    }
    final sha = commit['sha'];
    final inner = commit['commit'];
    final node = inner is Map<String, Object?> ? inner['tree'] : null;
    final tree = node is Map<String, Object?> ? node['sha'] : null;
    if (sha is! String || tree is! String) {
      throw GithubException(
        GithubFailure.refused,
        'GET /repos/$_repository/commits/$_ref',
        'the answer holds no commit SHA and tree',
      );
    }
    _add(
      Finding.pass(
        'ref',
        '$_ref is commit ${sha.substring(0, 7)}, and every file below is read at that commit',
      ),
    );
    return (sha: sha, tree: tree);
  }

  // The files at the commit.

  /// The files of the commit that the checks read: its paths, and the text of those the checks need. Null when the run
  /// cannot go on.
  Future<_Files?> _files(
    GithubClient client,
    ({String sha, String tree}) commit,
  ) async {
    final tree = await client.getJson(
      '/repos/$_repository/git/trees/${commit.tree}',
      const {'recursive': '1'},
    );
    final entries = tree['tree'];
    if (entries is! List<Object?>) {
      throw GithubException(
        GithubFailure.refused,
        'GET /repos/$_repository/git/trees/${commit.tree}',
        'the answer holds no list of files',
      );
    }
    final paths = <String>{
      for (final e in entries)
        if (e is Map<String, Object?> &&
            e['type'] == 'blob' &&
            e['path'] is String)
          e['path']! as String,
    };
    final truncated = tree['truncated'] == true;
    if (truncated) {
      _add(
        _warn(
          'project',
          'tree-truncated',
          'GitHub cut the list of files of $_repository short',
          why:
              'a repository of more than 100,000 files is not listed whole, so the checks that need the list cannot tell '
              'whether a file is there.',
          next: 'the checks that depend on the list say so, and the IPA is checked after the run.',
        ),
      );
    }
    const projectFile = 'ios/Runner.xcodeproj/project.pbxproj';
    final missing = [
      if (!truncated && !paths.contains('pubspec.yaml')) 'pubspec.yaml',
      if (!truncated && !paths.contains(projectFile)) 'ios/Runner.xcodeproj',
    ];
    if (missing.isNotEmpty) {
      _add(
        _fail(
          'project',
          'project-not-found',
          'the Flutter project is not at the root of $_repository at ${commit.sha.substring(0, 7)}: no ${missing.join(' or ')}',
          why:
              'wincode build builds the project at the root of the repository, where the reference workflow runs '
              'flutter build ipa.',
          next:
              'push the project there, or build from a repository that has it.',
        ),
      );
    }
    final wanted = <String>[
      _workflowPath,
      if (paths.contains('pubspec.yaml')) 'pubspec.yaml',
      if (paths.contains(projectFile)) projectFile,
    ];
    final xcconfigs = [
      for (final p in paths)
        if (p.startsWith('ios/') && p.endsWith('.xcconfig')) p,
    ];
    const maxXcconfigs = 40;
    wanted.addAll(xcconfigs.take(maxXcconfigs));
    if (xcconfigs.length > maxXcconfigs) {
      _add(
        _warn(
          'project',
          'xcconfig-limit',
          'the project holds ${xcconfigs.length} xcconfig files, and winCode reads the first $maxXcconfigs',
          why: 'each file is one request to GitHub.',
          next: 'a setting that comes from another file may not be found; the IPA is checked after the run.',
        ),
      );
    }
    final texts = <String, String>{};
    for (final path in wanted) {
      final text = await _text(client, commit.sha, path);
      if (text != null) {
        texts[path] = text;
      }
    }
    return _Files(commit.sha, paths, truncated, texts, missing.isNotEmpty);
  }

  Future<String?> _text(GithubClient client, String commit, String path) async {
    try {
      return await client.getText('/repos/$_repository/contents/$path', {
        'ref': commit,
      });
    } on GithubException catch (e) {
      // A file that the list shows but GitHub does not give (over its size limit) is left out, and its checks say so.
      if (e.failure == GithubFailure.notFound ||
          e.failure == GithubFailure.forbidden ||
          e.failure == GithubFailure.unprocessable) {
        _add(
          _warn(
            'project',
            'file-unreadable',
            '$path could not be read at the commit: ${e.message}',
            why: 'GitHub did not give the file, so the checks that read it cannot tell.',
            next: 'the IPA is checked after the run.',
          ),
        );
        return null;
      }
      rethrow;
    }
  }

  // The workflow at the ref.

  WorkflowFacts? _workflowFacts(_Files files) {
    final text = files.texts[_workflowPath];
    if (text == null) {
      _add(
        _fail(
          'workflow-contract',
          'workflow-not-found',
          '$_workflowPath is not in $_repository at ${files.commit.substring(0, 7)}',
          why:
              'GitHub runs the workflow file as it is at the ref, and it has none of that name there, though the default '
              'branch has.',
          next:
              'push the workflow to $_ref, or correct the @<ref> of workflow: in wincode.yaml.',
        ),
      );
      return null;
    }
    final facts = readWorkflow(text);
    plan
      ..contract = facts.contract ?? 1
      ..runsOn = facts.runsOn
      ..timeoutMinutes = facts.timeoutMinutes;
    return facts;
  }

  void _contract(WorkflowFacts facts) {
    final found = facts.contract;
    if (found == workflowContract) {
      _add(
        Finding.pass(
          'workflow-contract',
          'the workflow at $_ref says contract $workflowContract, the one this wincode needs',
        ),
      );
      return;
    }
    final newer = (found ?? 1) > workflowContract;
    _add(
      _fail(
        'workflow-contract',
        'workflow-contract',
        'the workflow at $_ref says ${found == null ? 'no contract (contract 1)' : 'contract $found'}, and this wincode needs contract $workflowContract',
        why: newer
            ? 'a newer workflow expects a newer wincode, which this one is not. Nothing was started.'
            : 'contract $workflowContract adds inputs, such as build_name and flutter_version, that a contract 1 workflow '
                  'does not declare, and GitHub refuses a run with inputs that its workflow does not declare. Nothing was '
                  'started.',
        next: newer
            ? 'update wincode, or use the workflow that came with this version.'
            : 'run wincode init --workflow, which shows the changes and keeps the old file as wincode-ios.yml.bak, then '
                  'push the workflow to $_ref and run wincode build again.',
      ),
    );
  }

  void _workflowInputs(WorkflowFacts facts) {
    if (facts.problem != null) {
      _add(
        _fail(
          'workflow-inputs',
          'workflow-unreadable',
          '$_workflowPath cannot be read as a workflow: ${facts.problem}',
          why: 'winCode reads the inputs that the workflow declares, to check them against the ones it sends.',
          next: 'fix the file, push it, then run the command again.',
        ),
      );
      return;
    }
    final sent = {
      'request_id',
      'build_name',
      'build_number',
      'flutter_version',
      'min_xcode_version',
      'flavor',
      'target',
      ...config.workflowInputs.keys,
    };
    final unknown = [
      for (final name in sent)
        if (!facts.inputs.containsKey(name)) name,
    ];
    final required = [
      for (final MapEntry(:key, :value) in facts.inputs.entries)
        if (value.required && !value.hasDefault && !sent.contains(key)) key,
    ];
    if (unknown.isNotEmpty) {
      _add(
        _fail(
          'workflow-inputs',
          'workflow-input-unknown',
          'the workflow at $_ref declares no input ${unknown.join(', ')}, and wincode build sends ${unknown.length == 1 ? 'it' : 'them'}',
          why:
              'GitHub refuses a dispatch with an input that the workflow does not declare at the ref (422), so nothing '
              'would start.',
          next:
              'declare ${unknown.length == 1 ? 'it' : 'them'} under on.workflow_dispatch.inputs in $_workflowPath, push '
              'it to $_ref, or remove the entry from workflow_inputs in wincode.yaml.',
        ),
      );
    }
    if (required.isNotEmpty) {
      _add(
        _fail(
          'workflow-inputs',
          'workflow-input-missing',
          'the workflow at $_ref requires ${required.length == 1 ? 'an input' : 'inputs'} that wincode build does not send: ${required.join(', ')}',
          why: 'GitHub refuses a dispatch that lacks a required input, so nothing would start.',
          next:
              'give ${required.length == 1 ? 'it' : 'each'} a default in $_workflowPath, or add ${required.length == 1 ? 'it' : 'them'} to workflow_inputs in wincode.yaml.',
        ),
      );
    }
    if (unknown.isEmpty && required.isEmpty) {
      _add(
        Finding.pass(
          'workflow-inputs',
          'the workflow declares every input that wincode build sends, and needs no other',
        ),
      );
    }
  }

  void _xcode(WorkflowFacts facts) {
    final min = config.minXcodeVersion;
    if (min == null) return;
    final app = facts.xcodeApp;
    final version = app == null ? null : xcodeVersionOf(app);
    plan.xcode = version;
    if (version == null) {
      _add(
        _warn(
          'xcode',
          'xcode-version-unknown',
          app == null
              ? 'the workflow names no XCODE_APP, so winCode cannot tell which Xcode it selects'
              : 'XCODE_APP in the workflow names no version, so winCode cannot tell which Xcode it selects',
          why:
              'GitHub names each Xcode of its runner images /Applications/Xcode_<version>.app. The job checks its Xcode '
              'against min_xcode_version as its first step, and stops if it is older.',
          next: 'set XCODE_APP to /Applications/Xcode_<version>.app, to have it checked before a run starts.',
        ),
      );
      return;
    }
    if (compareVersions(version, min) < 0) {
      _add(
        _fail(
          'xcode',
          'xcode-too-old',
          'the workflow selects Xcode $version, and wincode.yaml asks for $min or later',
          why:
              'min_xcode_version is the oldest Xcode that may build ${config.name ?? 'the app'}, and the job would stop at its '
              'Xcode step, after a billed minute. Nothing was started.',
          next:
              'set XCODE_APP in $_workflowPath to an Xcode of $min or later that the runner image has, push it to $_ref, '
              'then run wincode build again.',
        ),
      );
      return;
    }
    _add(
      Finding.pass(
        'xcode',
        'the workflow selects Xcode $version, which is $min or later',
      ),
    );
  }

  // The project at the commit.

  PubspecFacts? _pubspec(_Files files) {
    final text = files.texts['pubspec.yaml'];
    if (text == null) return null;
    final pubspec = readPubspec(text);
    if (pubspec.problem != null) {
      _add(
        _warn(
          'flutter',
          'pubspec-unreadable',
          'pubspec.yaml cannot be read: ${pubspec.problem}',
          why: 'winCode reads the version and the Flutter constraint from it, so neither is checked.',
          next: 'fix the file; flutter pub get fails on it on the runner too.',
        ),
      );
      return null;
    }
    return pubspec;
  }

  void _flutterConstraint(PubspecFacts pubspec) {
    final version = config.flutterVersion;
    if (version == null) return;
    final constraint = pubspec.flutterConstraint;
    if (constraint == null) {
      plan.flutterNote = 'pubspec.yaml has no environment: flutter: constraint';
      _add(
        const Finding.pass(
          'flutter',
          'pubspec.yaml sets no environment: flutter: constraint, so any release is allowed',
        ),
      );
    } else {
      switch (flutterAllows(constraint, version)) {
        case true:
          plan.flutterNote = 'allowed by pubspec.yaml';
          _add(
            Finding.pass(
              'flutter',
              'pubspec.yaml allows Flutter $version (environment: flutter: $constraint)',
            ),
          );
        case false:
          _add(
            _fail(
              'flutter',
              'flutter-version-mismatch',
              'pubspec.yaml allows Flutter $constraint, and flutter_version is $version',
              why:
                  'the build runs Flutter $version on the runner, and flutter pub get refuses a project whose '
                  'environment: flutter: constraint excludes it, after a billed minute. Nothing was started.',
              next:
                  'set flutter_version to a release that the constraint allows, or widen environment: flutter: in '
                  'pubspec.yaml and push it.',
            ),
          );
        case null:
          plan.flutterNote = 'its constraint could not be read';
          _add(
            _warn(
              'flutter',
              'flutter-constraint-unreadable',
              'winCode cannot read the constraint environment: flutter: $constraint, or the release $version',
              why: 'pub reads it, and flutter pub get on the runner would refuse it too.',
              next: 'write the constraint as pub does, such as ">=3.27.0".',
            ),
          );
      }
    }
  }

  /// One read of flutter/flutter: the tag that the workflow clones exists. A missing one fails the job at its first
  /// minute, after the runner is billed.
  Future<void> _flutterTag(GithubClient client) async {
    final version = config.flutterVersion;
    if (version == null) return;
    try {
      await client.getJson('/repos/flutter/flutter/git/ref/tags/$version');
      _add(
        Finding.pass(
          'flutter-tag',
          'flutter/flutter has a tag $version, which the workflow clones',
        ),
      );
    } on GithubException catch (e) {
      if (e.failure != GithubFailure.notFound) rethrow;
      _add(
        _fail(
          'flutter-tag',
          'flutter-version-not-found',
          'flutter/flutter has no tag $version',
          why:
              'the workflow clones that tag on the runner, and git fails at once on a release that does not exist, after '
              'a billed minute. Nothing was started.',
          next:
              'correct flutter_version in wincode.yaml: flutter --version prints the release, and the tags are listed at '
              'https://github.com/flutter/flutter/tags.',
        ),
      );
    }
  }

  void _buildName(PubspecFacts? pubspec, _Files files) {
    final fromPubspec = pubspec?.name;
    final usable = fromPubspec != null && isDottedNumber(fromPubspec)
        ? fromPubspec
        : null;
    final name = options.buildName ?? config.buildName ?? usable;
    plan
      ..buildName = name
      ..buildNameSource = options.buildName != null
          ? '--build-name'
          : config.buildName != null
          ? 'build_name in wincode.yaml'
          : "pubspec.yaml's version at $_ref";
    if (name == null && files.noProject) {
      return;
    }
    if (name == null) {
      _add(
        _fail(
          'build-name',
          'build-name-missing',
          pubspec?.version == null
              ? 'no version for the build: no --build-name, no build_name in wincode.yaml, and pubspec.yaml has no version'
              : "no version for the build: pubspec.yaml's version has no form that Apple takes, and there is no --build-name or build_name",
          why:
              'the App Store version (CFBundleShortVersionString) is one to three whole numbers joined by dots, and '
              'wincode build gives it to Flutter as --build-name.',
          next: 'give --build-name 2.4.0, or add build_name: 2.4.0 to wincode.yaml, or set version: 2.4.0+1 in pubspec.yaml.',
        ),
      );
    } else {
      _add(
        Finding.pass(
          'build-name',
          'the version is $name (${plan.buildNameSource})',
        ),
      );
    }
  }

  void _target(_Files files) {
    final target = config.target ?? 'lib/main.dart';
    plan.target = config.target;
    if (files.noProject) {
      return;
    }
    if (files.paths.contains(target)) {
      _add(
        Finding.pass('target', '$target is in the repository at the commit'),
      );
    } else if (files.truncated) {
      _add(
        _warn(
          'target',
          'target-unknown',
          'GitHub cut the list of files short, so winCode cannot tell whether $target is there',
          why: 'flutter build ipa gives it to Flutter as --target.',
          next: 'the build fails early on the runner if it is missing.',
        ),
      );
    } else {
      _add(
        _fail(
          'target',
          'target-missing',
          '$target is not in $_repository at ${files.commit.substring(0, 7)}',
          why:
              'wincode build gives it to Flutter as --target, and flutter build ipa would fail on a missing entry point '
              'after the runner has set up Xcode and Flutter. Nothing was started.',
          next:
              'push the file, or correct target in wincode.yaml${config.target == null ? ' (it is lib/main.dart when there is none)' : ''}.',
        ),
      );
    }
  }

  static final _scheme = RegExp(
    r'^ios/Runner\.xcodeproj/xcshareddata/xcschemes/([^/]+)\.xcscheme$',
  );

  /// The scheme, the configuration and the bundle ID, by the rules of flutter_tools 3.47.
  void _xcodeProject(_Files files) {
    const projectFile = 'ios/Runner.xcodeproj/project.pbxproj';
    final pbxproj = files.texts[projectFile];
    if (pbxproj == null) return;
    final schemes = [
      for (final p in files.paths)
        if (_scheme.firstMatch(p) case final m?) m[1]!,
    ];
    final List<String> configurations;
    try {
      configurations = buildConfigurationNames(pbxproj);
    } on FormatException catch (e) {
      _add(
        _warn(
          'configuration',
          'project-unreadable',
          '$projectFile cannot be read: ${e.message}',
          why: 'winCode reads the build configurations and the bundle ID from it, so neither is checked.',
          next: 'the IPA is checked after the run.',
        ),
      );
      return;
    }
    final choice = flutterBuildChoice(
      flavor: config.flavor,
      schemes: schemes,
      configurations: configurations,
    );
    plan
      ..scheme = choice.scheme
      ..configuration = choice.configuration ?? config.configuration;

    // The scheme.
    if (choice.scheme == null) {
      if (files.truncated && schemes.isEmpty) {
        _add(
          _warn(
            'scheme',
            'scheme-unknown',
            'GitHub cut the list of files short, so winCode cannot tell which schemes are shared',
            why: 'the scheme must be shared, in xcshareddata/xcschemes.',
            next: 'the build fails early on the runner if it is missing.',
          ),
        );
      } else {
        _add(
          _fail(
            'scheme',
            'scheme-missing',
            schemes.isEmpty
                ? 'the Xcode project has no shared scheme, and Flutter builds the scheme ${choice.expectedScheme}'
                : 'the Xcode project has no shared scheme ${choice.expectedScheme}, and it has ${schemes.join(', ')}',
            why:
                'flutter build ipa${config.flavor == null ? '' : ' --flavor ${config.flavor}'} builds the scheme '
                '${config.flavor == null ? 'Runner' : 'named after the flavor with its first letter in capitals'}, and the '
                'runner has only the schemes that are in the repository (ios/Runner.xcodeproj/xcshareddata/xcschemes). A '
                'scheme kept only in someone\'s xcuserdata is not there. Nothing was started.',
            next:
                'in Xcode, choose Product, Scheme, Manage Schemes, tick Shared for ${choice.expectedScheme}, and push the '
                '.xcscheme file.',
          ),
        );
      }
      return;
    }
    _add(
      Finding.pass(
        'scheme',
        'the Xcode project has the shared scheme ${choice.scheme}, which Flutter builds${config.flavor == null ? '' : ' for the flavor ${config.flavor}'}',
      ),
    );

    // The configuration.
    final built = choice.configuration;
    if (choice.ambiguous) {
      _add(
        _fail(
          'configuration',
          'configuration-mismatch',
          'several build configurations fit the flavor ${config.flavor}, and Flutter stops',
          why:
              'flutter build ipa takes ${choice.expectedConfiguration}, and failing that the one configuration whose name '
              'holds Release and ${choice.scheme}. More than one does here. Nothing was started.',
          next:
              'name one configuration ${choice.expectedConfiguration} in ios/Runner.xcodeproj and push it.',
        ),
      );
    } else if (built == null ||
        built.toLowerCase() != config.configuration.toLowerCase()) {
      _add(
        _fail(
          'configuration',
          'configuration-mismatch',
          choice.fellBack
              ? 'flavor ${config.flavor} builds the configuration $built, not ${config.configuration}'
              : 'flavor ${config.flavor ?? '(none)'} builds the configuration $built, and wincode.yaml says ${config.configuration}',
          why: choice.fellBack
              ? 'Flutter builds the configuration named after the flavor\'s scheme (${choice.scheme}), and when the project '
                    'has none it builds Release without an error, so the IPA would carry Release\'s bundle ID and settings. '
                    'Nothing was started.'
              : 'Flutter picks the configuration itself, and it is not the one that winCode was told about. Nothing was '
                    'started.',
          next: choice.fellBack
              ? 'add a configuration ${choice.expectedConfiguration} to ios/Runner.xcodeproj and push it, or set '
                    'configuration in wincode.yaml to the configuration that this flavor really uses.'
              : 'set configuration in wincode.yaml to $built, or change the project so that Flutter builds '
                    '${config.configuration}.',
        ),
      );
    } else {
      _add(
        Finding.pass(
          'configuration',
          'flavor ${config.flavor ?? '(none)'} builds the configuration $built, as wincode.yaml says',
        ),
      );
    }

    // The bundle ID of the configuration that Flutter builds.
    if (built == null) return;
    _bundleId(files, built);
  }

  void _bundleId(_Files files, String configuration) {
    String? read(String path) => files.texts['ios/$path'];
    final BuildSettings settings;
    try {
      settings = resolveBuildSettings(
        iosDir: Directory('ios'),
        configuration: configuration,
        read: read,
        generated: flutterGeneratedSettings(
          buildName: plan.buildName ?? '1.0.0',
          buildNumber: plan.buildNumber ?? '1',
          target: config.target ?? 'lib/main.dart',
        ),
      );
    } on FormatException catch (e) {
      _add(
        _warn(
          'bundle-id',
          'bundle-id-unresolved',
          'the bundle ID of the configuration $configuration could not be read: ${e.message}',
          why:
              'winCode reads PRODUCT_BUNDLE_IDENTIFIER from the project and the xcconfig files it names, at the commit. A '
              'file that is not committed cannot be read.',
          next: 'the IPA is checked after the run.',
        ),
      );
      return;
    }
    final missing = settings.unresolved('PRODUCT_BUNDLE_IDENTIFIER');
    String? value;
    try {
      value = missing.isEmpty ? settings['PRODUCT_BUNDLE_IDENTIFIER'] : null;
    } on FormatException {
      value = null;
    }
    if (value == null || value.isEmpty) {
      _add(
        _warn(
          'bundle-id',
          'bundle-id-unresolved',
          missing.isEmpty
              ? 'the configuration $configuration sets no PRODUCT_BUNDLE_IDENTIFIER that winCode can read'
              : 'PRODUCT_BUNDLE_IDENTIFIER of $configuration needs ${missing.map((m) => '\$($m)').join(', ')}, which nothing at the commit defines',
          why:
              'a value may come from an xcconfig file that is not committed, so winCode cannot tell which bundle ID the '
              'build gets.',
          next: 'the IPA is checked after the run.',
        ),
      );
    } else if (value != config.bundleId) {
      redactor.hide(value, '<other bundle ID>');
      _add(
        _fail(
          'bundle-id',
          'bundle-id-mismatch',
          'the configuration $configuration has the bundle ID $value, but wincode.yaml says ${config.bundleId}',
          why:
              'the IPA of this build would carry $value, and winCode signs and uploads only the app that wincode.yaml '
              'names. Nothing was started.',
          next: 'correct bundle_id in wincode.yaml, or the configuration or flavor of the app, so that they name the same app.',
          code: ExitCode.failed,
        ),
      );
    } else {
      _add(
        Finding.pass(
          'bundle-id',
          'the configuration $configuration has the bundle ID ${config.bundleId}',
        ),
      );
    }
  }

  // The build number.

  Future<void> _buildNumber(
    GithubClient client,
    PubspecFacts? pubspec,
    _Files files,
  ) async {
    final given = options.buildNumber;
    final auto = given == 'auto' || (given == null && !_isFlat);
    final fromPubspec = pubspec == null ? null : pubspecBuildNumber(pubspec);
    final String? number;
    if (auto) {
      number = null;
    } else if (given != null) {
      number = given;
    } else {
      number = fromPubspec;
      if (number == null && files.noProject) {
        return;
      }
      if (number == null) {
        _add(
          _fail(
            'build-number',
            'build-number-missing',
            "no build number: no --build-number, and pubspec.yaml's version has no +N",
            why: 'the number goes to the workflow as an input, and App Store Connect keeps one sequence per app record.',
            next: 'give --build-number 58, or --build-number auto, or write the version in pubspec.yaml as 2.4.0+58.',
          ),
        );
        return;
      }
    }
    plan.buildNumberSource = auto
        ? 'auto'
        : given != null
        ? '--build-number'
        : "pubspec.yaml's number at $_ref";

    // This app's runs of the last day.
    final analysis = await _runs(client);
    if (analysis == null) return;
    if (analysis.active.isNotEmpty) {
      final run = analysis.active.first;
      _add(
        _fail(
          'build-in-progress',
          'build-in-progress',
          'a build of $_appName is already running: ${run.url} (build ${run.number})',
          why: 'two runs of one app would compete for the same build number and the same output folder.',
          next:
              'collect it with wincode build${config.name == null ? '' : ' --app ${config.name}'} --run ${run.id}, or '
              'cancel it at ${run.url}, then run wincode build again.',
          code: ExitCode.failed,
        ),
      );
      return;
    }
    _add(
      Finding.pass(
        'build-in-progress',
        analysis.highestSuccessful == null
            ? 'no run of $_appName is going, and none succeeded in the last 24 hours'
            : 'no run of $_appName is going; the highest that succeeded in the last 24 hours is build ${analysis.highestSuccessful}',
      ),
    );

    // App Store Connect, for the app's builds.
    final asc = await _ascHighest();
    if (asc == null && (auto || _ascFailed)) return;
    final known = [?asc?.highest, ?analysis.highestSuccessful];
    final highest = highestNumber(known);
    if (auto) {
      if (highest != null && highest.contains('.')) {
        _add(
          _fail(
            'build-number',
            'build-number-auto',
            'the highest build number of $_appName is $highest, which has dots, and auto cannot add one to it',
            why: "winCode does not guess the next step of someone else's numbering scheme.",
            next: 'give --build-number <n> with a number above $highest.',
            code: ExitCode.failed,
          ),
        );
        return;
      }
      final next = highest == null
          ? BigInt.one
          : BigInt.parse(highest) + BigInt.one;
      plan.buildNumber = '$next';
      plan.buildNumberNote = asc?.source == null
          ? "no App Store Connect build is known${analysis.highestSuccessful == null ? '' : '; a run holds ${analysis.highestSuccessful}'}"
          : "App Store Connect's highest is ${asc!.highest ?? 'none'}; ${analysis.highestSuccessful == null ? 'no run of $_appName in the last 24 hours' : 'a run of $_appName in the last 24 hours holds ${analysis.highestSuccessful}'}";
      _add(
        Finding.pass(
          'build-number',
          'the build number is ${plan.buildNumber}, one above the highest known (${highest ?? 'none'})',
        ),
      );
    } else {
      plan.buildNumber = number;
      if (highest != null && compareBuildNumbers(number!, highest) <= 0) {
        _add(
          _fail(
            'build-number',
            'build-number-not-higher',
            'build $number is not higher than $highest, the highest build ${asc?.highest == highest ? 'App Store Connect has' : 'of a run in the last 24 hours'} for $_appName',
            why: 'Apple refuses a build number it has already seen, and a used number stays used even when its build failed.',
            next:
                'give --build-number auto, or a number above $highest. Nothing was started.',
            code: ExitCode.failed,
          ),
        );
        return;
      }
      if (asc == null) {
        _add(
          _warn(
            'build-number',
            'build-number-unchecked',
            'build $number was not compared with App Store Connect: $_appName has no credentials',
            why: 'winCode reads the highest build number of the app with its App Store Connect key, and has none for this app.',
            next: 'preflight checks the number before the upload. Add credentials to the app to have it checked here too.',
          ),
        );
      } else {
        _add(
          Finding.pass(
            'build-number',
            highest == null
                ? 'build $number is the first build of $_appName'
                : 'build $number is higher than $highest, the highest known',
          ),
        );
      }
    }
    _finish();
  }

  /// The request ID and the inputs, once the version and the number are known.
  void _finish() {
    if (plan.buildName == null || plan.buildNumber == null) return;
    plan.requestId = requestIdOf(
      tag: appTag(config.bundleId),
      version: plan.buildName!,
      number: plan.buildNumber!,
      random: _random(),
    );
    _inputs();
  }

  /// This app's runs of the workflow in the last 24 hours, or null when they could not be listed.
  Future<RunsAnalysis?> _runs(GithubClient client) async {
    final since = clock().toUtc().subtract(const Duration(hours: 24));
    final stamp = since.toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z');
    final runs = <Map<String, Object?>>[];
    var total = 0;
    const perPage = 100;
    const maxPages = 5;
    for (var page = 1; page <= maxPages; page++) {
      final answer = await client.getJson(
        '/repos/$_repository/actions/workflows/$_workflowFile/runs',
        {
          'event': 'workflow_dispatch',
          'created': '>=$stamp',
          'per_page': '$perPage',
          'page': '$page',
        },
      );
      final list = answer['workflow_runs'];
      if (list is! List<Object?>) {
        throw GithubException(
          GithubFailure.refused,
          'GET /repos/$_repository/actions/workflows/$_workflowFile/runs',
          'the answer holds no list of runs',
        );
      }
      total = answer['total_count'] is int
          ? answer['total_count']! as int
          : list.length;
      runs.addAll(list.whereType<Map<String, Object?>>());
      if (list.length < perPage) break;
    }
    if (runs.length < total) {
      _add(
        _warn(
          'build-in-progress',
          'runs-truncated',
          'the workflow had $total dispatched runs in the last 24 hours, and winCode read ${runs.length}',
          why: 'a run of this app among the others may not have been seen.',
          next:
              'check the Actions tab of $_repository for a build of $_appName that is still going.',
        ),
      );
    }
    return analyseRuns(runs, appTag(config.bundleId));
  }

  /// The highest build number App Store Connect knows for the app, or null without credentials. A failure is added as
  /// a finding and ends the run, for `auto`.
  Future<({String? highest, String source})?> _ascHighest() async {
    if (config.credentials == null &&
        (environment['WINCODE_ASC_KEY_DIR'] ?? '').isEmpty) {
      if (options.buildNumber == 'auto') {
        _add(
          _fail(
            'build-number',
            'credentials-missing',
            '--build-number auto needs the App Store Connect key of $_appName, and wincode.yaml names no credentials',
            why: "auto looks for the highest build number of the app in App Store Connect, which needs the app's API key.",
            next:
                'add credentials: <reference> to the app (wincode init --app <name> --credentials <reference>), or give '
                '--build-number <n>.',
          ),
        );
      } else {
        _add(
          const Finding.info(
            'app-store-connect',
            'nothing was read in App Store Connect: the app has no credentials',
          ),
        );
      }
      return null;
    }
    var keySource = 'WINCODE_ASC_KEY_DIR';
    try {
      final files = await locateAscKeyFiles(
        config,
        environment: environment,
        redactor: redactor,
        run: run,
      );
      keySource = files!.source;
      final key = loadAscKey(files, redactor);
      final client = connect(() => ascToken(key, clock, redactor), log);
      final apps = await client.getAll('/v1/apps', {
        'filter[bundleId]': config.bundleId,
        'fields[apps]': 'bundleId',
        'limit': '200',
      });
      final appId = apps
          .where((a) => _attribute(a, 'bundleId') == config.bundleId)
          .map((a) => '${a['id']}')
          .firstOrNull;
      if (appId == null) {
        _add(
          _fail(
            'app-record',
            'app-record-missing',
            'App Store Connect has no app record for ${config.bundleId}',
            why: 'an upload goes to the app record of its bundle ID, and the build number is read from it.',
            next:
                'create the app record in App Store Connect (Apps, New App) with the bundle ID ${config.bundleId}, or '
                'correct bundle_id in wincode.yaml.',
            code: ExitCode.failed,
          ),
        );
        _ascFailed = true;
        _stopped();
        return null;
      }
      redactor.hide(appId, '{id of the app record}');
      final numbers = <String>[
        for (final b in await client.getAll('/v1/apps/$appId/builds', {
          'fields[builds]': 'version,processingState',
          'limit': '200',
        }))
          _attribute(b, 'version'),
      ];
      var uploads = true;
      try {
        // An upload that Apple has not yet turned into a build holds its number too.
        numbers.addAll([
          for (final u in await client.getAll('/v1/apps/$appId/buildUploads', {
            'fields[buildUploads]': 'cfBundleVersion,state',
            'limit': '200',
          }))
            _attribute(u, 'cfBundleVersion'),
        ]);
      } on AscException catch (e) {
        // Apple's documentation lists this endpoint; a key or an account that is refused here is refused everywhere.
        if (e.failure != AscFailure.refused) rethrow;
        uploads = false;
      }
      final highest = highestNumber(numbers.where(isDottedNumber));
      _add(
        Finding.info(
          'app-store-connect',
          "App Store Connect's highest build number for $_appName is ${highest ?? 'none'}${uploads ? '' : ', from its builds only: it did not list the build uploads'}",
        ),
      );
      return (highest: highest, source: keySource);
    } on WincodeException catch (e) {
      _add(Finding.fail('build-number', e));
      _ascFailed = true;
      _stopped();
      return null;
    } on AscException catch (e) {
      _add(
        Finding.fail(
          'build-number',
          ascProblem(e, keySource: keySource, command: 'build'),
        ),
      );
      _ascFailed = true;
      _stopped();
      return null;
    }
  }
}

/// The files of a commit that the checks read: every path of its tree, whether the list was cut short, and the text of
/// the files that were read, by path.
class _Files {
  _Files(this.commit, this.paths, this.truncated, this.texts, this.noProject);

  final String commit;
  final Set<String> paths;
  final bool truncated;
  final Map<String, String> texts;

  /// Whether the Flutter project is not at the root. `project-not-found` said so already, and the checks of its files
  /// say nothing more.
  final bool noProject;
}

String _attribute(AscResource resource, String name) =>
    switch (resource['attributes']) {
      final Map<String, Object?> attributes => switch (attributes[name]) {
        final String value => value,
        _ => '',
      },
      _ => '',
    };
