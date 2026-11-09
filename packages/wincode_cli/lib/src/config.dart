import 'dart:io';

import 'package:yaml/yaml.dart';

import 'failure.dart';

/// A GitHub Actions workflow at a branch or tag, written as GitHub writes it: `<owner>/<repo>/.github/workflows/<file>@<ref>`.
typedef Workflow = ({String repository, String file, String ref});

/// The settings of one app, read from `wincode.yaml` (ADR-0013). The file holds no secrets: the App Store Connect key
/// and the distribution key are found through environment variables, never through this file.
class WincodeConfig {
  const WincodeConfig({
    required this.file,
    required this.bundleId,
    required this.teamId,
    required this.output,
    this.profile,
    this.entitlements,
    this.workflow,
  });

  /// The file the settings were read from. The paths in it are relative to its folder.
  final File file;

  final String bundleId;
  final String teamId;

  /// Where `wincode build` and `wincode sign` write their IPAs (default `build/wincode`).
  final Directory output;

  /// The App Store provisioning profile that `wincode sign` signs with.
  final File? profile;

  /// The app's own `.entitlements` file, signed together with the four keys every store build gets (ADR-0011, rule 6).
  final File? entitlements;

  /// The workflow that `wincode build` starts on a macOS runner.
  final Workflow? workflow;
}

const _keys = {
  'bundle_id',
  'team_id',
  'profile',
  'entitlements',
  'workflow',
  'output',
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

/// Whether [text] is a bundle ID as `wincode.yaml` accepts it.
bool isBundleId(String text) => _bundleId.hasMatch(text);

/// Whether [text] is a team ID as `wincode.yaml` accepts it.
bool isTeamId(String text) => _teamId.hasMatch(text);

/// Reads and checks the settings in [path].
///
/// Every problem is a [WincodeException] with [ExitCode.config] that names the line, says why it matters and what to
/// write instead. A value is never repeated in a message, only its key, in case it is a secret put in the wrong place.
/// The files that the settings name are not opened here: each command checks the ones it uses.
WincodeConfig loadConfig(String path) {
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
  return parseConfig(text, path: path);
}

/// Checks the settings in [text], as if it were the file at [path] (which need not exist). Problems are reported as
/// [loadConfig] reports them.
WincodeConfig parseConfig(String text, {required String path}) {
  final file = File(path);
  WincodeException invalid(
    YamlNode? node,
    String what, {
    required String why,
    required String next,
  }) => WincodeException(
    ExitCode.config,
    'config-invalid',
    '$path${node == null ? '' : ' line ${node.span.start.line + 1}'}: $what',
    why: why,
    next: next,
  );

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

  final values = <String, ({YamlNode node, String text})>{};
  for (final MapEntry(:key, :value) in root.nodes.entries) {
    final keyNode = key as YamlNode;
    final name = '${keyNode.value}';
    if (!_keys.contains(name)) {
      throw _secretName.hasMatch(name)
          ? invalid(
              keyNode,
              '"$name" looks like a secret, and wincode.yaml holds none',
              why:
                  'the file goes with the project. The App Store Connect key comes from WINCODE_ASC_KEY_DIR and the '
                  'distribution key from WINCODE_DIST_KEY.',
              next:
                  'remove the line. If the file was ever committed or shared with a secret in it, revoke that key '
                  'and make a new one.',
            )
          : invalid(
              keyNode,
              'unknown key "$name"',
              why:
                  'wincode.yaml reads only ${_keys.join(', ')}, so a misspelled key would be ignored.',
              next: 'remove it, or correct its spelling.',
            );
    }
    final text = value.value;
    if (text is! String) {
      throw invalid(
        value,
        '$name must be text',
        why: 'YAML reads some values as numbers or lists: 0123456789 would become 123456789.',
        next: "write the value in single quotes: $name: '...'.",
      );
    }
    values[name] = (node: value, text: text);
  }

  String required(String key, {required String why, required String next}) =>
      values[key]?.text ??
      (throw WincodeException(
        ExitCode.config,
        'config-invalid',
        '$path has no $key',
        why: why,
        next: next,
      ));

  final bundleId = required(
    'bundle_id',
    why: 'winCode checks that the IPA, the profile and App Store Connect all name this app.',
    next: "add bundle_id: <the app's bundle ID>, the PRODUCT_BUNDLE_IDENTIFIER of the build you ship.",
  );
  if (!_bundleId.hasMatch(bundleId)) {
    throw invalid(
      values['bundle_id']!.node,
      'bundle_id is not a bundle ID',
      why: 'a bundle ID is two or more parts of letters, digits and hyphens joined by dots, such as com.example.app.',
      next: 'use the bundle ID of the app record in App Store Connect.',
    );
  }
  final teamId = required(
    'team_id',
    why: 'winCode checks that the profile belongs to this team.',
    next: 'add team_id: <your team ID>, the 10 characters under Membership details in the developer portal.',
  );
  if (!_teamId.hasMatch(teamId)) {
    throw invalid(
      values['team_id']!.node,
      'team_id is not a team ID',
      why: 'a team ID is 10 capital letters and digits.',
      next: 'copy it from Membership details in the developer portal.',
    );
  }

  // The value of key, checked by valid; null when the key is not there.
  String? optional(
    String key,
    bool Function(String) valid, {
    required String what,
    required String why,
    required String next,
  }) {
    final value = values[key];
    if (value != null && !valid(value.text)) {
      throw invalid(value.node, what, why: why, next: next);
    }
    return value?.text;
  }

  final profile = optional(
    'profile',
    (p) => p.toLowerCase().endsWith('.mobileprovision'),
    what: 'profile must name a .mobileprovision file',
    why:
        'wincode sign signs with the App Store profile as the developer portal delivers it. wincode.yaml never names '
        'a key.',
    next: 'point it at the downloaded .mobileprovision file.',
  );
  final entitlements = optional(
    'entitlements',
    (p) => RegExp(r'\.(entitlements|plist)$').hasMatch(p.toLowerCase()),
    what: 'entitlements must name an .entitlements or .plist file',
    why: 'wincode sign signs the app with the keys in it, as Xcode does with CODE_SIGN_ENTITLEMENTS.',
    next: "point it at the app's file, usually ios/Runner/Runner.entitlements.",
  );
  final workflow = optional(
    'workflow',
    _workflow.hasMatch,
    what: 'workflow must be <owner>/<repository>/.github/workflows/<file>.yml@<branch or tag>',
    why: 'wincode build starts that workflow at that branch or tag.',
    next: 'write it as GitHub does, for example example-org/example-app/.github/workflows/wincode-ios.yml@main.',
  );
  final output = optional(
    'output',
    (p) => p.trim().isNotEmpty,
    what: 'output must name a folder',
    why: 'wincode build and wincode sign write their IPAs there.',
    next: 'name a folder, or remove the line to use build/wincode.',
  );

  String resolve(String p) =>
      File(p).isAbsolute ? p : '${file.parent.path}${Platform.pathSeparator}$p';
  final parts = workflow == null ? null : _workflow.firstMatch(workflow)!;
  return WincodeConfig(
    file: file,
    bundleId: bundleId,
    teamId: teamId,
    output: Directory(resolve(output ?? 'build/wincode')),
    profile: profile == null ? null : File(resolve(profile)),
    entitlements: entitlements == null ? null : File(resolve(entitlements)),
    workflow: parts == null
        ? null
        : (repository: parts[1]!, file: parts[2]!, ref: parts[3]!),
  );
}
