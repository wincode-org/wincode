import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import 'build_number.dart';

/// Reading the files of a project at the commit that a build will use (ADR-0015, section 2). Pure functions: the text
/// of a file in, what the checks need out.

/// The contract that this winCode needs of the reference workflow (ADR-0015, section 8).
const workflowContract = 2;

final _contractLine = RegExp(
  r'^#[ \t]*wincode-workflow-contract:[ \t]*(\d+)[ \t]*$',
  multiLine: true,
);

/// An input of a workflow's `workflow_dispatch`, as the file declares it.
typedef WorkflowInput = ({bool required, bool hasDefault});

/// What a workflow file says that the checks need.
class WorkflowFacts {
  const WorkflowFacts({
    this.contract,
    this.inputs = const {},
    this.runsOn,
    this.timeoutMinutes,
    this.xcodeApp,
    this.flutterVersion,
    this.flavor,
    this.problem,
  });

  /// The number of the `# wincode-workflow-contract: N` line, or null when the file has none (contract 1).
  final int? contract;

  /// The inputs of `on.workflow_dispatch.inputs`, by name.
  final Map<String, WorkflowInput> inputs;

  /// `runs-on` and `timeout-minutes` of the first job that has them: what the plan shows about the runner.
  final String? runsOn;
  final int? timeoutMinutes;

  /// The value of `XCODE_APP` in the workflow's or a job's `env`.
  final String? xcodeApp;

  /// `FLUTTER_VERSION` and `FLAVOR` of the workflow's or a job's `env`, as contract 1 kept them there.
  final String? flutterVersion;
  final String? flavor;

  /// Why the file could not be read as a workflow, or null.
  final String? problem;
}

/// Reads [text], a workflow file. The contract line is a comment, so it is found in the text; the rest is read as YAML.
WorkflowFacts readWorkflow(String text) {
  final contract = _contractLine.firstMatch(text)?[1];
  final number = contract == null ? null : int.tryParse(contract);
  try {
    final root = loadYaml(text);
    if (root is! YamlMap) {
      return WorkflowFacts(
        contract: number,
        problem: 'it is not a map of keys',
      );
    }
    final inputs = <String, WorkflowInput>{};
    final on = root['on'];
    final dispatch = on is YamlMap ? on['workflow_dispatch'] : null;
    final declared = dispatch is YamlMap ? dispatch['inputs'] : null;
    if (declared is YamlMap) {
      for (final MapEntry(:key, :value) in declared.entries) {
        final map = value is YamlMap ? value : const {};
        inputs['$key'] = (
          required: map['required'] == true,
          hasDefault: map.containsKey('default'),
        );
      }
    }
    String? xcodeApp = _text(_map(root['env'])['XCODE_APP']);
    String? flutterVersion = _text(_map(root['env'])['FLUTTER_VERSION']);
    String? flavor = _text(_map(root['env'])['FLAVOR']);
    String? runsOn;
    int? timeout;
    final jobs = root['jobs'];
    if (jobs is YamlMap) {
      for (final job in jobs.values) {
        if (job is! YamlMap) continue;
        xcodeApp ??= _text(_map(job['env'])['XCODE_APP']);
        flutterVersion ??= _text(_map(job['env'])['FLUTTER_VERSION']);
        flavor ??= _text(_map(job['env'])['FLAVOR']);
        final runner = job['runs-on'];
        if (runsOn == null && runner != null) {
          runsOn = runner is YamlList ? runner.join(', ') : '$runner';
          final minutes = job['timeout-minutes'];
          timeout = minutes is int ? minutes : null;
        }
      }
    }
    return WorkflowFacts(
      contract: number,
      inputs: inputs,
      runsOn: runsOn,
      timeoutMinutes: timeout,
      xcodeApp: xcodeApp,
      flutterVersion: flutterVersion,
      flavor: flavor,
    );
  } on YamlException catch (e) {
    return WorkflowFacts(contract: number, problem: e.message);
  }
}

Map<Object?, Object?> _map(Object? value) =>
    value is YamlMap ? value : const {};

String? _text(Object? value) => value is String ? value : null;

final _xcodeApp = RegExp(r'^/Applications/Xcode_(\d+(?:\.\d+){0,2})\.app/?$');

/// The version in the path of an Xcode of GitHub's runner images, `/Applications/Xcode_26.6.app`, or null for a path
/// that names none (`/Applications/Xcode.app`, or an expression).
String? xcodeVersionOf(String xcodeApp) => _xcodeApp.firstMatch(xcodeApp)?[1];

/// What `pubspec.yaml` says that the checks need.
class PubspecFacts {
  const PubspecFacts({this.version, this.flutterConstraint, this.problem});

  /// The `version:`, such as `2.3.0+57`.
  final String? version;

  /// The `environment: flutter:` constraint, or null when there is none.
  final String? flutterConstraint;

  final String? problem;

  /// The part of [version] before `+`, or null.
  String? get name => _versionParts(version).$1;

  /// The part of [version] after `+`, or null.
  String? get number => _versionParts(version).$2;
}

(String?, String?) _versionParts(String? version) {
  if (version == null) {
    return (null, null);
  }
  final plus = version.indexOf('+');
  return plus < 0
      ? (version, null)
      : (version.substring(0, plus), version.substring(plus + 1));
}

/// Reads [text], a `pubspec.yaml`.
PubspecFacts readPubspec(String text) {
  try {
    final root = loadYaml(text);
    if (root is! YamlMap) {
      return const PubspecFacts(problem: 'it is not a map of keys');
    }
    final version = root['version'];
    final flutter = _map(root['environment'])['flutter'];
    return PubspecFacts(
      version: version == null ? null : '$version',
      flutterConstraint: flutter == null ? null : '$flutter',
    );
  } on YamlException catch (e) {
    return PubspecFacts(problem: e.message);
  }
}

/// Whether the pub constraint [constraint] allows the Flutter release [version], by pub's rules. Null when [constraint]
/// is not a constraint that pub reads, or [version] is not a version.
bool? flutterAllows(String constraint, String version) {
  try {
    return VersionConstraint.parse(constraint).allows(Version.parse(version));
  } on FormatException {
    return null;
  }
}

/// The build number a `pubspec.yaml` version gives: what follows `+`, when that is a number Apple takes.
String? pubspecBuildNumber(PubspecFacts pubspec) {
  final n = pubspec.number;
  return n != null && isDottedNumber(n) ? n : null;
}
