import 'dart:io';

import 'package:yaml/yaml.dart';

import 'failure.dart';
import 'redact.dart';

/// A GitHub Actions workflow at a branch or tag, written as GitHub writes it: `<owner>/<repo>/.github/workflows/<file>@<ref>`.
typedef Workflow = ({String repository, String file, String ref});

/// The settings of one app, read from `wincode.yaml` (ADR-0013, ADR-0014). The file holds no secrets: the App Store
/// Connect key and the distribution key are found through environment variables or a credentials reference, never
/// through this file.
class WincodeConfig {
  const WincodeConfig({
    required this.file,
    required this.bundleId,
    required this.teamId,
    required this.output,
    this.name,
    this.profile,
    this.entitlements,
    this.workflow,
    this.flavor,
    this.configuration = 'Release',
    this.credentials,
    this.workflowInputs = const {},
  });

  /// The file the settings were read from. The paths in it are relative to its folder.
  final File file;

  /// The app's name in a file of apps; null for a flat file, whose one app has none.
  final String? name;

  final String bundleId;
  final String teamId;

  /// Where `wincode build` and `wincode sign` write their IPAs: `build/wincode` for a flat file, `build/wincode/<name>`
  /// for an app of a file of apps, unless `output` says otherwise.
  final Directory output;

  /// The App Store provisioning profile that `wincode sign` signs with.
  final File? profile;

  /// The app's own `.entitlements` file, signed together with the four keys every store build gets (ADR-0011, rule 6).
  final File? entitlements;

  /// The workflow that `wincode build` starts on a macOS runner.
  final Workflow? workflow;

  /// The Flutter flavor that builds this app, if it has one.
  final String? flavor;

  /// The Xcode build configuration that `wincode init` reads: `configuration` if the file says it, else
  /// `Release-<flavor>`, else `Release`.
  final String configuration;

  /// The name of the credentials reference that holds this app's keys (ADR-0014, section 2). Required in a file of apps.
  /// Null in a flat file without it, which keeps `WINCODE_ASC_KEY_DIR` and `WINCODE_DIST_KEY`.
  final String? credentials;

  /// Extra inputs that `wincode build` passes to the workflow.
  final Map<String, String> workflowInputs;
}

/// Everything `wincode.yaml` says: one app for a flat file (ADR-0013), or the apps of a file with `apps:` in file order
/// (ADR-0014).
class WincodeSettings {
  const WincodeSettings({
    required this.file,
    required this.apps,
    required this.isFlat,
  });

  final File file;

  /// The apps in file order. Never empty. A flat file has exactly one, without a name.
  final List<WincodeConfig> apps;

  /// Whether the file has no `apps:` and describes one app.
  final bool isFlat;

  /// The app called [name], or null.
  WincodeConfig? app(String name) =>
      apps.where((a) => a.name == name).firstOrNull;
}

/// The keys of one app, in the order that the messages list them. A flat file and each entry under `apps` read these.
const _appKeys = [
  'bundle_id',
  'team_id',
  'profile',
  'entitlements',
  'workflow',
  'output',
  'flavor',
  'configuration',
  'workflow_inputs',
  'credentials',
];

/// The keys that apps may share through `defaults`. The others are per app by nature.
const _defaultsKeys = [
  'team_id',
  'entitlements',
  'workflow',
  'workflow_inputs',
  'credentials',
];

/// Words that an app name or a credentials reference may not be (ADR-0014, section 4): winCode prints them itself, so
/// replacing one with a placeholder would hide an ordinary word.
const reservedNames = {
  'build',
  'key',
  'keys',
  'app',
  'apps',
  'test',
  'release',
  'debug',
  'profile',
  'sign',
  'upload',
  'config',
  'default',
  'all',
  'defaults',
  'init',
  'doctor',
  'preflight',
  'status',
  'team',
  'credentials',
  'output',
  'workflow',
  'entitlements',
  'flavor',
};

final _bundleId = RegExp(r'^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$');
final _teamId = RegExp(r'^[A-Z0-9]{10}$');
final _workflow = RegExp(
  r'^([A-Za-z0-9-]+/[A-Za-z0-9._-]+)/\.github/workflows/([A-Za-z0-9._-]+\.ya?ml)@(\S+)$',
);
final _secretName = RegExp(
  'key|secret|pass|token|issuer|credential|p8|p12',
  caseSensitive: false,
);
final _name = RegExp(r'^[a-z][a-z0-9-]{1,30}[a-z0-9]$');
final _deviceName = RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$');
final _placeholderName = RegExp(
  r'^(app|credentials|flavor|configuration)-\d+$',
);
final _flavor = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$');
final _configuration = RegExp(r'^[A-Za-z0-9 ._-]{1,64}$');
final _inputName = RegExp(r'^[a-z][a-z0-9_]{0,31}$');
final _inputValue = RegExp(r'^[A-Za-z0-9._/-]{0,64}$');

/// Inputs that `wincode build` sets itself, so that the file may not.
const _reservedInputs = {'request_id', 'flavor', 'build_number'};

/// Whether [text] is a bundle ID as `wincode.yaml` accepts it.
bool isBundleId(String text) => _bundleId.hasMatch(text);

/// Whether [text] is a team ID as `wincode.yaml` accepts it.
bool isTeamId(String text) => _teamId.hasMatch(text);

/// What is wrong with [text] as the name of an app or of a credentials reference, or null when it is fine. The text
/// never repeats a name that may be a brand: only a refused common word, which is not one, is quoted.
String? nameProblem(String text) {
  if (text.length < 3) {
    return 'is shorter than 3 characters';
  }
  if (text.length > 32) {
    return 'is longer than 32 characters';
  }
  if (!_name.hasMatch(text)) {
    return 'has characters other than lower-case letters, digits and hyphens, or does not start with a letter or end '
        'with a letter or digit';
  }
  if (reservedNames.contains(text)) {
    return 'is the common word "$text"';
  }
  if (_deviceName.hasMatch(text)) {
    return 'is the name of a Windows device ("$text")';
  }
  if (_placeholderName.hasMatch(text)) {
    return 'has the shape of a placeholder that --redact prints ("$text")';
  }
  return null;
}

/// Reads and checks the settings of one app in [path]: a flat file, or a file of apps that holds exactly one app. A
/// file of several apps needs `--app`, which a later change adds, so it is refused here with exit 64.
///
/// With a [redactor], every name, ID and path that the file holds is registered with it as soon as it has been checked,
/// so that even an error message can be printed with placeholders.
WincodeConfig loadConfig(String path, {Redactor? redactor}) =>
    _single(loadSettings(path, redactor: redactor), path);

/// [parseSettings], for the one app that existing commands work on (see [loadConfig]).
WincodeConfig parseConfig(
  String text, {
  required String path,
  Redactor? redactor,
}) => _single(parseSettings(text, path: path, redactor: redactor), path);

WincodeConfig _single(WincodeSettings settings, String path) =>
    settings.apps.length == 1
    ? settings.apps.single
    : throw WincodeException(
        ExitCode.usage,
        'not-implemented',
        '$path has ${settings.apps.length} apps, and several apps need --app, which is not implemented yet, see ADR-0014',
        why: 'each app has its own bundle ID, team, profile and keys, and the command cannot yet choose one.',
        next: 'use a wincode.yaml with one app for now, or name another file with --config.',
      );

/// Reads and checks every app in [path].
///
/// Every problem is a [WincodeException] with [ExitCode.config] that names the line, says why it matters and what to
/// write instead. A value is never repeated in a message, only its key, in case it is a secret put in the wrong place;
/// the name of an app or a credentials reference is repeated only after it passed the name rules. The files that the
/// settings name are not opened here: each command checks the ones it uses.
WincodeSettings loadSettings(String path, {Redactor? redactor}) {
  final file = File(path);
  if (!file.existsSync()) {
    throw WincodeException(
      ExitCode.config,
      'config-missing',
      '$path does not exist',
      why: "build, sign, preflight, upload and status read the app's bundle ID, team ID and signing files from it.",
      next: 'create it in the Flutter project with `wincode init`, or name another file with --config.',
    );
  }

  final String text;
  try {
    text = file.readAsStringSync();
  } on FileSystemException catch (e) {
    throw WincodeException(
      ExitCode.config,
      'config-invalid',
      '$path: cannot be read: ${e.osError?.message ?? e.message}',
      why: 'winCode reads wincode.yaml as UTF-8 text.',
      next: 'check that the file can be opened, save it as UTF-8 text, then run the command again.',
    );
  }
  return parseSettings(text, path: path, redactor: redactor);
}

/// Checks the settings in [text], as if it were the file at [path] (which need not exist). Problems are reported as
/// [loadSettings] reports them.
WincodeSettings parseSettings(
  String text, {
  required String path,
  Redactor? redactor,
}) => _Parser(path, redactor).parse(text);

/// One value of the file: where it stands, what it is (a `String`, or a `YamlMap` for `workflow_inputs`), and whether
/// it stands in the app itself rather than in `defaults`.
typedef _Field = ({YamlNode node, Object value, bool own});

class _Rule {
  const _Rule(this.valid, this.what, this.why, this.next);

  final bool Function(String) valid;
  final String what;
  final String why;
  final String next;
}

final _rules = <String, _Rule>{
  'bundle_id': _Rule(
    _bundleId.hasMatch,
    'bundle_id is not a bundle ID',
    'a bundle ID is two or more parts of letters, digits and hyphens joined by dots, such as com.example.app.',
    'use the bundle ID of the app record in App Store Connect.',
  ),
  'team_id': _Rule(
    _teamId.hasMatch,
    'team_id is not a team ID',
    'a team ID is 10 capital letters and digits.',
    'copy it from Membership details in the developer portal.',
  ),
  'profile': _Rule(
    (p) => p.toLowerCase().endsWith('.mobileprovision'),
    'profile must name a .mobileprovision file',
    'wincode sign signs with the App Store profile as the developer portal delivers it. wincode.yaml never names a key.',
    'point it at the downloaded .mobileprovision file.',
  ),
  'entitlements': _Rule(
    (p) => RegExp(r'\.(entitlements|plist)$').hasMatch(p.toLowerCase()),
    'entitlements must name an .entitlements or .plist file',
    'wincode sign signs the app with the keys in it, as Xcode does with CODE_SIGN_ENTITLEMENTS.',
    "point it at the app's file, usually ios/Runner/Runner.entitlements.",
  ),
  'workflow': _Rule(
    _workflow.hasMatch,
    'workflow must be <owner>/<repository>/.github/workflows/<file>.yml@<branch or tag>',
    'wincode build starts that workflow at that branch or tag.',
    'write it as GitHub does, for example example-org/example-app/.github/workflows/wincode-ios.yml@main.',
  ),
  'output': _Rule(
    (p) => p.trim().isNotEmpty,
    'output must name a folder',
    'wincode build and wincode sign write their IPAs there.',
    'name a folder, or remove the line to use build/wincode.',
  ),
  'flavor': _Rule(
    _flavor.hasMatch,
    'flavor is not a flavor name',
    'wincode build passes the flavor to Flutter, and wincode init reads Release-<flavor>. A flavor is 1 to 64 letters, '
        'digits, _ and -, starting with a letter or digit.',
    'write the flavor as the Flutter project names it, such as alpha.',
  ),
  'configuration': _Rule(
    (c) => _configuration.hasMatch(c) && c.trim().isNotEmpty,
    'configuration is not a build configuration name',
    'wincode init reads the IDs from that Xcode build configuration. A name is 1 to 64 letters, digits, spaces, ., _ and -.',
    'write the configuration as the Xcode project names it, such as Release-alpha, or remove the line to use '
        'Release-<flavor>.',
  ),
};

class _Parser {
  _Parser(this.path, this.redactor) : file = File(path);

  final String path;
  final File file;
  final Redactor? redactor;

  /// The distinct team IDs and credentials references seen so far, in file order, for the numbers of their placeholders.
  final _teams = <String>[];
  final _references = <String>[];

  WincodeException invalid(
    YamlNode? node,
    String what, {
    required String why,
    required String next,
    String scope = '',
  }) => WincodeException(
    ExitCode.config,
    'config-invalid',
    '$path${node == null ? '' : ' line ${node.span.start.line + 1}'}: $scope$what',
    why: why,
    next: next,
  );

  WincodeSettings parse(String text) {
    final YamlNode root;
    try {
      // Notepad may start the file with a byte order mark.
      root = loadYamlNode(text.startsWith('\uFEFF') ? text.substring(1) : text);
    } on YamlException catch (e) {
      throw WincodeException(
        ExitCode.config,
        'config-invalid',
        '$path line ${(e.span?.start.line ?? 0) + 1}: ${e.message}',
        why: 'wincode.yaml must be valid YAML.',
        next: "fix that line. Write Windows paths with forward slashes (C:/signing/app.mobileprovision) or in single quotes.",
      );
    }
    if (root is! YamlMap) {
      throw invalid(
        null,
        'holds no settings',
        why: 'wincode.yaml is a map with one key per line, such as bundle_id: com.example.app.',
        next: 'write bundle_id and team_id, and the profile, entitlements, workflow and output that you use (ADR-0013).',
      );
    }
    final isFile = root.nodes.keys.any((k) => (k as YamlNode).value == 'apps');
    return isFile ? _parseApps(root) : _parseFlat(root);
  }

  // A flat file: one app, without a name.

  WincodeSettings _parseFlat(YamlMap root) {
    if (root.nodes.keys.any((k) => (k as YamlNode).value == 'defaults')) {
      final key = root.nodes.keys.firstWhere(
        (k) => (k as YamlNode).value == 'defaults',
      );
      throw invalid(
        key as YamlNode,
        'defaults has no apps to apply to',
        why: 'defaults holds the values that the apps under apps: share.',
        next: 'add the apps: map, or remove defaults and write its keys at the top level.',
      );
    }
    final fields = _readKeys(root, _appKeys, scope: '', own: true);
    final app = _buildApp(
      fields,
      name: null,
      index: 1,
      appKey: null,
      scope: '',
      missing: (key, why, next) => WincodeException(
        ExitCode.config,
        'config-invalid',
        '$path has no $key',
        why: why,
        next: next,
      ),
    );
    return WincodeSettings(file: file, apps: [app], isFlat: true);
  }

  // A file of apps.

  WincodeSettings _parseApps(YamlMap root) {
    YamlNode? appsNode, defaultsNode;
    for (final MapEntry(:key, :value) in root.nodes.entries) {
      final keyNode = key as YamlNode;
      final name = '${keyNode.value}';
      if (name == 'apps') {
        appsNode = value;
      } else if (name == 'defaults') {
        defaultsNode = value;
      } else if (_appKeys.contains(name)) {
        throw invalid(
          keyNode,
          '"$name" is at the top level, next to apps',
          why: 'a file with apps holds only apps and defaults, so that no value is read from the wrong level.',
          next: 'move it under the app it belongs to, or under defaults if the apps share it.',
        );
      } else {
        throw _unknownKey(
          keyNode,
          name,
          const ['apps', 'defaults'],
          scope: '',
          apps: true,
        );
      }
    }

    Map<String, _Field> defaults = {};
    if (defaultsNode != null) {
      if (defaultsNode is! YamlMap) {
        throw invalid(
          defaultsNode,
          'defaults holds no settings',
          why: 'defaults is a map of the values that the apps share, such as team_id and credentials.',
          next: 'write its keys under it, or remove it.',
        );
      }
      defaults = _readKeys(
        defaultsNode,
        _defaultsKeys,
        scope: 'defaults: ',
        own: false,
        defaults: true,
      );
    }

    if (appsNode is! YamlMap || appsNode.nodes.isEmpty) {
      throw invalid(
        appsNode,
        'apps lists no app',
        why: 'apps is a map from the name of each app to its settings.',
        next: 'write one entry per app, such as alpha: with its bundle_id, flavor and credentials under it.',
      );
    }

    final apps = <WincodeConfig>[];
    final bundleIds = <String, ({String name, YamlNode node})>{};
    final outputs = <String, String>{};
    final referenceTeams = <String, ({String team, String app})>{};
    for (final (i, MapEntry(:key, :value)) in appsNode.nodes.entries.indexed) {
      final keyNode = key as YamlNode;
      final problem = keyNode.value is! String
          ? 'is not text'
          : nameProblem(keyNode.value as String);
      if (problem != null) {
        throw invalid(
          keyNode,
          'the app name $problem',
          why:
              'an app name becomes a folder name (build/wincode/<app>) and part of a variable name, and --redact '
              'replaces it as a whole word, so it must be plain and never an ordinary word (ADR-0014, sections 1 and 4).',
          next: 'use 3 to 32 lower-case letters, digits and hyphens that are not an ordinary word, such as alpha or team-one.',
        );
      }
      final name = keyNode.value as String;
      redactor?.hideName(name, 'app-${i + 1}');
      final scope = 'app $name: ';
      if (value is! YamlMap) {
        throw invalid(
          keyNode,
          'app $name holds no settings',
          why: 'each app is a map with at least its bundle_id.',
          next: 'write the keys of the app under its name.',
        );
      }
      final own = _readKeys(value, _appKeys, scope: scope, own: true);
      final merged = {
        for (final key in _appKeys) key: ?(own[key] ?? defaults[key]),
      };
      final app = _buildApp(
        merged,
        name: name,
        index: i + 1,
        appKey: keyNode,
        scope: scope,
        missing: (key, why, next) =>
            invalid(keyNode, 'app $name has no $key', why: why, next: next),
      );
      final bundleNode = merged['bundle_id']!.node;

      final earlier = bundleIds[app.bundleId.toLowerCase()];
      if (earlier != null) {
        throw invalid(
          bundleNode,
          'apps $name and ${earlier.name} have the same bundle_id',
          why:
              'one bundle ID is one app record in App Store Connect, so the two entries would sign and upload two '
              'different builds to it.',
          next:
              'correct the bundle_id of $name (line ${bundleNode.span.start.line + 1}) or of ${earlier.name} '
              '(line ${earlier.node.span.start.line + 1}), or remove one of the two entries.',
        );
      }
      bundleIds[app.bundleId.toLowerCase()] = (name: name, node: bundleNode);

      final reference = app.credentials!;
      final team = referenceTeams[reference];
      if (team != null && team.team != app.teamId) {
        throw invalid(
          merged['credentials']!.node,
          'apps $name and ${team.app} use the credentials $reference, but their team_id differs',
          why:
              'Apple issues an App Store Connect key and a distribution certificate to one team, so one of the two apps '
              'would fail at Apple.',
          next: 'give the apps of each team a credentials reference of their own, or correct the team_id of the app that is wrong.',
        );
      }
      referenceTeams[reference] ??= (team: app.teamId, app: name);

      final outputKey = _folderKey(app.output.path);
      final sameOutput = outputs[outputKey];
      if (sameOutput != null) {
        throw invalid(
          (merged['output'] ?? merged['bundle_id']!).node,
          'apps $name and $sameOutput have the same output folder',
          why: "the IPAs of one app would replace the other's.",
          next: 'give one of them another output, or remove the key to use build/wincode/<app>.',
        );
      }
      outputs[outputKey] = name;
      apps.add(app);
    }
    return WincodeSettings(file: file, apps: apps, isFlat: false);
  }

  // Reading and checking one level.

  WincodeException _unknownKey(
    YamlNode keyNode,
    String name,
    List<String> allowed, {
    required String scope,
    required bool apps,
    String owner = 'wincode.yaml',
  }) => _secretName.hasMatch(name)
      ? invalid(
          keyNode,
          '"$name" looks like a secret, and wincode.yaml holds none',
          scope: scope,
          why: apps
              ? 'the file goes with the project. Each app names a credentials reference, and its keys are read from the '
                    'folder of that name (ADR-0014), never from this file.'
              : 'the file goes with the project. The App Store Connect key comes from WINCODE_ASC_KEY_DIR and the '
                    'distribution key from WINCODE_DIST_KEY.',
          next:
              'remove the line. If the file was ever committed or shared with a secret in it, revoke that key '
              'and make a new one.',
        )
      : invalid(
          keyNode,
          'unknown key "$name"',
          scope: scope,
          why:
              '$owner reads only ${allowed.join(', ')}, so a misspelled key would be ignored.',
          next: 'remove it, or correct its spelling.',
        );

  /// The values of [map], each checked to be text (a map for `workflow_inputs`) and to be a key that [allowed] lists.
  /// Their shapes are checked by [_buildApp], or here for `defaults`.
  Map<String, _Field> _readKeys(
    YamlMap map,
    List<String> allowed, {
    required String scope,
    required bool own,
    bool defaults = false,
  }) {
    final values = <String, _Field>{};
    for (final MapEntry(:key, :value) in map.nodes.entries) {
      final keyNode = key as YamlNode;
      final name = '${keyNode.value}';
      if (!allowed.contains(name)) {
        if (defaults && _appKeys.contains(name)) {
          throw invalid(
            keyNode,
            '"$name" is per app and cannot be shared',
            scope: scope,
            why: 'each app has its own bundle ID, flavor, configuration, profile and output; a shared value would make two apps the same.',
            next: 'move it under each app that needs it.',
          );
        }
        throw _unknownKey(
          keyNode,
          name,
          allowed,
          scope: scope,
          apps: scope.isNotEmpty,
          owner: defaults ? 'defaults' : 'wincode.yaml',
        );
      }
      if (name == 'workflow_inputs') {
        if (value is! YamlMap) {
          throw invalid(
            value,
            'workflow_inputs must be a map of input names to text',
            scope: scope,
            why: 'wincode build passes each entry to the workflow as an input of the run.',
            next: 'write it as name: value lines under workflow_inputs.',
          );
        }
        _checkInputs(value, scope);
        values[name] = (node: value, value: value, own: own);
        continue;
      }
      final text = value.value;
      if (text is! String) {
        throw invalid(
          value,
          '$name must be text',
          scope: scope,
          why: 'YAML reads some values as numbers or lists: 0123456789 would become 123456789.',
          next: "write the value in single quotes: $name: '...'.",
        );
      }
      values[name] = (node: value, value: text, own: own);
    }
    if (defaults) {
      for (final MapEntry(:key, :value) in values.entries) {
        _check(key, value, scope);
      }
    }
    return values;
  }

  void _checkInputs(YamlMap inputs, String scope) {
    for (final MapEntry(:key, :value) in inputs.nodes.entries) {
      final keyNode = key as YamlNode;
      final name = '${keyNode.value}';
      if (_secretName.hasMatch(name)) {
        throw invalid(
          keyNode,
          'the workflow input "$name" looks like a secret, and wincode.yaml holds none',
          scope: scope,
          why:
              "an input of a dispatched run is shown on the run's page and in its log to everyone who can read the "
              'repository.',
          next: "remove the line, and keep the secret in the repository's Actions secrets.",
        );
      }
      if (!_inputName.hasMatch(name) || _reservedInputs.contains(name)) {
        throw invalid(
          keyNode,
          'the workflow input "$name" is not allowed',
          scope: scope,
          why:
              'an input name is 1 to 32 lower-case letters, digits and _, starting with a letter, and not request_id, '
              'flavor or build_number, which wincode build sets itself.',
          next: 'rename the input in the workflow and here.',
        );
      }
      final text = value.value;
      if (text is! String || !_inputValue.hasMatch(text)) {
        throw invalid(
          value,
          'the value of the workflow input "$name" must be text of at most 64 letters, digits, ., _, - and /',
          scope: scope,
          why:
              "an input of a dispatched run is shown on the run's page and in its log to everyone who can read the "
              'repository, so it is never a place for a secret.',
          next: "write a short plain value in quotes, and keep any secret in the repository's Actions secrets.",
        );
      }
    }
  }

  /// Checks the shape of one value of the file; the message names the key, never the value.
  void _check(String key, _Field field, String scope) {
    final value = field.value;
    if (value is! String) {
      return;
    }
    final rule = _rules[key];
    if (rule != null && !rule.valid(value)) {
      throw invalid(
        field.node,
        rule.what,
        scope: scope,
        why: rule.why,
        next: key == 'output' && scope.isNotEmpty
            ? 'name a folder, or remove the line to use build/wincode/<app>.'
            : rule.next,
      );
    }
    if (key == 'credentials') {
      final problem = nameProblem(value);
      if (problem != null) {
        throw invalid(
          field.node,
          'the credentials name $problem',
          scope: scope,
          why:
              'a credentials reference names the folder that holds the keys, and part of the variable that overrides it, '
              'and --redact replaces it as a whole word (ADR-0014, sections 2 and 4).',
          next: 'use 3 to 32 lower-case letters, digits and hyphens that are not an ordinary word, such as team-one.',
        );
      }
    }
  }

  WincodeConfig _buildApp(
    Map<String, _Field> fields, {
    required String? name,
    required int index,
    required YamlNode? appKey,
    required String scope,
    required WincodeException Function(String key, String why, String next)
    missing,
  }) {
    final flat = name == null;
    Object? value(String key) => fields[key]?.value;
    String? text(String key) => value(key) as String?;

    // Own values are checked here, those inherited from defaults were checked when defaults was read.
    void check(String key) {
      final field = fields[key];
      if (field != null && field.own) {
        _check(key, field, scope);
      }
    }

    String need(String key, {required String why, required String next}) =>
        text(key) ?? (throw missing(key, why, next));

    need(
      'bundle_id',
      why: 'winCode checks that the IPA, the profile and App Store Connect all name this app.',
      next: "add bundle_id: <the app's bundle ID>, the PRODUCT_BUNDLE_IDENTIFIER of the build you ship.",
    );
    check('bundle_id');
    need(
      'team_id',
      why: 'winCode checks that the profile belongs to this team.',
      next: flat
          ? 'add team_id: <your team ID>, the 10 characters under Membership details in the developer portal.'
          : 'add team_id: <your team ID>, the 10 characters under Membership details in the developer portal, to the app or to defaults.',
    );
    for (final key in [
      'team_id',
      'profile',
      'entitlements',
      'workflow',
      'output',
      'flavor',
      'configuration',
    ]) {
      check(key);
    }
    if (!flat) {
      need(
        'credentials',
        why: 'each app of a file of apps names the credentials reference that holds its keys (ADR-0014, section 2).',
        next: 'add credentials: <reference> to the app, or to defaults if the apps share one, such as team-one.',
      );
    }
    check('credentials');

    final bundleId = text('bundle_id')!;
    final flavor = text('flavor');
    final configuration = text('configuration');
    String resolve(String p) => File(p).isAbsolute
        ? p
        : '${file.parent.path}${Platform.pathSeparator}$p';
    final workflow = text('workflow');
    final parts = workflow == null ? null : _workflow.firstMatch(workflow)!;
    final inputs = value('workflow_inputs') as YamlMap?;
    final output = text('output');
    final outputWritten =
        output ?? (flat ? 'build/wincode' : 'build/wincode/$name');
    final profile = text('profile');
    final entitlements = text('entitlements');

    final app = WincodeConfig(
      file: file,
      name: name,
      bundleId: bundleId,
      teamId: text('team_id')!,
      output: Directory(resolve(outputWritten)),
      profile: profile == null ? null : File(resolve(profile)),
      entitlements: entitlements == null ? null : File(resolve(entitlements)),
      workflow: parts == null
          ? null
          : (repository: parts[1]!, file: parts[2]!, ref: parts[3]!),
      flavor: flavor,
      configuration:
          configuration ?? (flavor == null ? 'Release' : 'Release-$flavor'),
      credentials: text('credentials'),
      workflowInputs: Map.unmodifiable({
        for (final MapEntry<dynamic, dynamic>(:key, :value)
            in inputs?.entries ?? const <MapEntry<dynamic, dynamic>>[])
          '$key': '$value',
      }),
    );

    // Everything above passed its checks, so every value registered here is well formed.
    for (final key in [
      'bundle_id',
      'team_id',
      'flavor',
      'configuration',
      'credentials',
    ]) {
      if (fields[key] case final field?) {
        _register(key, field.value, index: index, flat: flat);
      }
    }
    _hidePath(
      'profile',
      profile,
      outputWritten: null,
      index: index,
      flat: flat,
    );
    _hidePath(
      'entitlements',
      entitlements,
      outputWritten: null,
      index: index,
      flat: flat,
    );
    _hidePath(
      'output',
      outputWritten,
      outputWritten: outputWritten,
      index: index,
      flat: flat,
    );
    return app;
  }

  // Redaction (ADR-0014, section 4).

  void _register(
    String key,
    Object value, {
    required int index,
    required bool flat,
  }) {
    final r = redactor;
    if (r == null || value is! String) {
      return;
    }
    switch (key) {
      case 'bundle_id':
        r.hide(value, flat ? '<bundle ID>' : '<bundle ID $index>');
      case 'team_id':
        if (!_teams.contains(value)) _teams.add(value);
        r.hide(
          value,
          flat ? '<team ID>' : '<team ID ${_teams.indexOf(value) + 1}>',
        );
      case 'credentials':
        if (!_references.contains(value)) _references.add(value);
        final n = _references.indexOf(value) + 1;
        r.hideName(value, 'credentials-$n');
        r.hide(value.toUpperCase().replaceAll('-', '_'), 'CREDENTIALS_$n');
      case 'flavor':
        if (_brand(value)) r.hideName(value, 'flavor-$index');
      case 'configuration':
        if (_brand(value)) r.hideName(value, 'configuration-$index');
    }
  }

  /// Whether [value], a flavor or configuration from the Xcode project, can carry a brand: an ordinary word or a very
  /// short one does not, and is not replaced on its own.
  bool _brand(String value) =>
      value.length >= 3 && !reservedNames.contains(value.toLowerCase());

  /// Registers a path of the file, as written and as resolved, with the placeholder `<what of app-n>`.
  void _hidePath(
    String what,
    String? written, {
    required String? outputWritten,
    required int index,
    required bool flat,
  }) {
    final r = redactor;
    if (r == null || written == null || written.isEmpty) {
      return;
    }
    final placeholder = flat ? '<$what>' : '<$what of app-$index>';
    String slashes(String p) => p.replaceAll(r'\', '/');
    String backslashes(String p) => p.replaceAll('/', r'\');
    final forms = <String>{};
    final resolved = File(written).isAbsolute
        ? written
        : '${file.parent.path}${Platform.pathSeparator}$written';
    final absolute = File(resolved).absolute.path;
    forms.addAll([resolved, absolute]);
    try {
      forms.add(Uri.file(absolute).normalizePath().toFilePath());
    } on Object {
      // A path that is not a valid file URI keeps the forms above.
    }
    // A one-word relative path such as `out` would hide that word wherever it stands, so only a path with a separator
    // or a file name with an extension is registered as written.
    if (written.contains('/') ||
        written.contains(r'\') ||
        written.contains('.')) {
      forms.add(written);
    }
    for (final form in forms.toList()) {
      forms
        ..add(slashes(form))
        ..add(backslashes(form));
    }
    for (final form in forms) {
      r.hide(form, placeholder);
    }
  }

  /// A folder as a key for comparing two outputs: Windows ignores case and the direction of the separators.
  String _folderKey(String path) {
    final normalized = path.replaceAll(r'\', '/').toLowerCase();
    return normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
  }
}
