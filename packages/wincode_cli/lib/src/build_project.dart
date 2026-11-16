import 'dart:convert';

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

/// The parts of the workflow [repoText] that differ from [template], winCode's reference workflow, as names for a
/// person (ADR-0015, section 8): `input target`, `step "Xcode"`, `job unsigned-ipa permissions`, `permissions`.
///
/// The two are compared as parsed YAML, so a comment, a blank line, the order of keys and the text of an input's
/// `description` are never differences. Neither are the three values that the owner of the repository sets:
/// `runs-on`, `timeout-minutes` and `XCODE_APP`. An action's pin is one: a bumped pin names its step. The files must
/// both parse (a [YamlException] otherwise).
List<String> workflowDifferences(String repoText, String template) {
  final repo = _comparable(repoText);
  final ours = _comparable(template);
  if (repo is! Map || ours is! Map) {
    return const ['the file'];
  }
  final parts = <String>[];
  bool differ(Object? a, Object? b) => _canonical(a) != _canonical(b);
  for (final key in {...ours.keys, ...repo.keys}) {
    if (key == 'on' || key == 'jobs') continue;
    if (differ(repo[key], ours[key])) parts.add('$key');
  }
  Map<Object?, Object?> inputsOf(Object? on) {
    final dispatch = on is Map ? on['workflow_dispatch'] : null;
    final inputs = dispatch is Map ? dispatch['inputs'] : null;
    return inputs is Map<Object?, Object?> ? inputs : const {};
  }

  Object? withoutInputs(Object? on) {
    if (on is! Map || on['workflow_dispatch'] is! Map) return on;
    return {
      ...on,
      'workflow_dispatch': {...(on['workflow_dispatch'] as Map)}
        ..remove('inputs'),
    };
  }

  if (differ(withoutInputs(repo['on']), withoutInputs(ours['on']))) {
    parts.add('on');
  }
  final theirInputs = inputsOf(repo['on']);
  final ourInputs = inputsOf(ours['on']);
  for (final name in {...ourInputs.keys, ...theirInputs.keys}) {
    if (differ(theirInputs[name], ourInputs[name])) parts.add('input $name');
  }
  final theirJobs = repo['jobs'] is Map ? repo['jobs'] as Map : const {};
  final ourJobs = ours['jobs'] is Map ? ours['jobs'] as Map : const {};
  for (final id in {...ourJobs.keys, ...theirJobs.keys}) {
    final a = theirJobs[id];
    final b = ourJobs[id];
    if (a is! Map || b is! Map) {
      if (differ(a, b)) parts.add('job $id');
      continue;
    }
    for (final key in {...b.keys, ...a.keys}) {
      if (key != 'steps' && differ(a[key], b[key])) parts.add('job $id $key');
    }
    parts.addAll(_stepDifferences(a['steps'], b['steps']));
  }
  return parts;
}

/// [text] as plain maps, lists and scalars, without the values that the owner of the repository sets.
Object? _comparable(String text) {
  final plain = _plain(loadYaml(text.replaceAll('\r\n', '\n')));
  if (plain is! Map) return plain;
  void dropXcode(Object? env) {
    if (env is Map) env.remove('XCODE_APP');
  }

  void dropEmpty(Map<Object?, Object?> owner) {
    if (owner['env'] is Map && (owner['env'] as Map).isEmpty) {
      owner.remove('env');
    }
  }

  dropXcode(plain['env']);
  dropEmpty(plain);
  final jobs = plain['jobs'];
  if (jobs is Map) {
    for (final job in jobs.values) {
      if (job is! Map) continue;
      job
        ..remove('runs-on')
        ..remove('timeout-minutes');
      dropXcode(job['env']);
      dropEmpty(job);
    }
  }
  final on = plain['on'];
  final dispatch = on is Map ? on['workflow_dispatch'] : null;
  final inputs = dispatch is Map ? dispatch['inputs'] : null;
  if (inputs is Map) {
    for (final input in inputs.values) {
      if (input is Map) input.remove('description');
    }
  }
  return plain;
}

Object? _plain(Object? node) => switch (node) {
  YamlMap() => {for (final e in node.entries) '${e.key}': _plain(e.value)},
  YamlList() => [for (final e in node) _plain(e)],
  _ => node,
};

/// [value] as text that does not depend on the order of keys.
String _canonical(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) => switch (value) {
  Map() => {
    for (final k in (value.keys.map((k) => '$k').toList()..sort()))
      k: _sorted(value[k]),
  },
  List() => [for (final e in value) _sorted(e)],
  _ => value,
};

/// The steps of a job, by their names, or by the action they use when they have none: `step "Xcode"`.
List<String> _stepDifferences(Object? repoSteps, Object? ourSteps) {
  Map<String, Object?> byKey(Object? steps) {
    final out = <String, Object?>{};
    if (steps is! List) return out;
    for (final (i, step) in steps.indexed) {
      final map = step is Map ? step : const <Object?, Object?>{};
      var key = map['name'] is String
          ? map['name'] as String
          : map['uses'] is String
          ? (map['uses'] as String).split('@').first
          : 'step ${i + 1}';
      while (out.containsKey(key)) {
        key = '$key (again)';
      }
      out[key] = step;
    }
    return out;
  }

  final theirs = byKey(repoSteps);
  final ours = byKey(ourSteps);
  final parts = <String>[];
  for (final key in {...ours.keys, ...theirs.keys}) {
    if (!ours.containsKey(key)) {
      parts.add('step "$key" (added)');
    } else if (!theirs.containsKey(key)) {
      parts.add('step "$key" (missing)');
    } else if (_canonical(theirs[key]) != _canonical(ours[key])) {
      parts.add('step "$key"');
    }
  }
  final sameOrder =
      [
        for (final k in theirs.keys)
          if (ours.containsKey(k)) k,
      ].join('\n') ==
      [
        for (final k in ours.keys)
          if (theirs.containsKey(k)) k,
      ].join('\n');
  if (!sameOrder) parts.add('the order of the steps');
  return parts;
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
