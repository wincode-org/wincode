import 'dart:convert';
import 'dart:io';

import 'package:wincode_core/wincode_core.dart';

import 'config.dart';
import 'failure.dart';
import 'init_detect.dart';
import 'key_location.dart';
import 'redact.dart';
import 'workflow_template.g.dart';

/// Reads one line of the user's answer, or null when the input has ended.
typedef ReadLine = String? Function();

/// What the command line of `wincode init` said. A field that is null is detected or asked.
class InitOptions {
  const InitOptions({
    this.config,
    this.bundleId,
    this.teamId,
    this.profile,
    this.profileDir,
    this.entitlements,
    this.workflowRef,
    this.output,
    this.flavor,
    this.configuration,
    this.yes = false,
    this.force = false,
    this.copyWorkflow = false,
    this.dryRun = false,
  });

  /// `--config`, when given; else `wincode.yaml` in the project root.
  final String? config;
  final String? bundleId;
  final String? teamId;
  final String? profile;
  final String? profileDir;
  final String? entitlements;
  final String? workflowRef;
  final String? output;
  final String? flavor;

  /// `--configuration`: the build configuration to read, by name.
  final String? configuration;

  /// `--yes`: accept what was detected, ask nothing.
  final bool yes;

  /// `--force`: replace an existing `wincode.yaml`.
  final bool force;

  /// `--workflow`: copy the reference workflow into `.github/workflows`.
  final bool copyWorkflow;
  final bool dryRun;
}

/// A value that `init` found: the [value] to write, how a prompt [display]s it, and, for a message that says what it
/// found, its [name] and the [source] it came from.
typedef _Candidate = ({
  String value,
  String display,
  String name,
  String source,
});

/// `wincode init` (ADR-0013, phase 2): writes `wincode.yaml` for the Flutter project at or above [cwd].
///
/// It reads the project and the profiles in a folder the user names, and nothing else: no search of the disk, no
/// credential store, no network. It shows what it found and asks about it, unless [interactive] is false, when it
/// takes every field from the options (or from what it found, with `--yes`) and fails with the missing options. It
/// never writes a key or a key folder: the settings file has no field for one.
class Initializer {
  Initializer({
    required this.options,
    required this.cwd,
    required this.redactor,
    required this.report,
    required this.readLine,
    required this.interactive,
    required this.clock,
    this.run = runProcess,
  });

  final InitOptions options;
  final Directory cwd;
  final Redactor redactor;

  /// Where people-readable output goes: stdout, or stderr with `--json`.
  final StringSink report;
  final ReadLine readLine;
  final bool interactive;
  final DateTime Function() clock;
  final RunProcess run;

  /// The options that a non-interactive run needs and did not get, with what was found for them.
  final _missing = <String>[];

  /// What `detectProject` said the user should look at.
  var _warnings = const <String>[];

  /// Runs the command, and returns the object for `--json`.
  Future<Map<String, Object?>> execute() async {
    final root =
        findFlutterRoot(cwd) ??
        (throw WincodeException(
          ExitCode.failed,
          'not-a-flutter-project',
          'there is no Flutter project in this folder or above it',
          why:
              'init reads ios/Runner.xcodeproj for the bundle ID and the entitlements, and it writes wincode.yaml next to '
              'pubspec.yaml.',
          next:
              'run wincode init in the folder with pubspec.yaml and ios, or create the iOS project with `flutter create '
              '--platforms ios .`.',
        ));
    final target = File(
      options.config != null
          ? _absolute(options.config!)
          : '${root.path}/wincode.yaml',
    );
    final name = target.uri.pathSegments.last;
    // An existing file is never replaced without --force. Nothing is asked: the summary shows what init found.
    final preview = target.existsSync() && !options.force;

    if (options.flavor != null && options.configuration != null) {
      throw const WincodeException(
        ExitCode.usage,
        'init-value-invalid',
        '--flavor and --configuration both name the build configuration to read',
        why: '--flavor <name> reads Release-<name>; --configuration <name> reads the configuration of exactly that name.',
        next: 'give one of them.',
      );
    }
    final facts = detectProject(
      root,
      flavor: options.flavor,
      configuration: options.configuration,
    );
    final unknown = options.configuration;
    if (unknown != null &&
        facts.configurations.isNotEmpty &&
        !facts.configurations.contains(unknown)) {
      throw WincodeException(
        ExitCode.failed,
        'configuration-not-found',
        'the Xcode project has no build configuration named $unknown; it has ${facts.configurations.join(', ')}',
        why:
            '--configuration names the build configuration whose bundle ID, team ID and entitlements init reads, '
            'and it must match a name in ios/Runner.xcodeproj exactly.',
        next: 'pass one of those names to --configuration, or leave it out to read Release.',
      );
    }
    for (final note in facts.notes) {
      report.writeln('note: $note.');
    }
    for (final warning in facts.warnings) {
      report.writeln('WARN  $warning.');
    }
    _warnings = facts.warnings;
    String inProject(String? configuration) =>
        'ios/Runner.xcodeproj${configuration == null ? '' : ' ($configuration)'}';
    _hideAll([
      ?facts.bundleId,
      for (final c in facts.bundleIdCandidates) c.value,
    ], 'bundle ID');

    final bundleId = await _choose(
      label: 'Bundle ID',
      key: 'bundle_id',
      flagName: 'bundle-id',
      flag: options.bundleId,
      candidates: [
        if (facts.bundleId != null)
          (
            value: facts.bundleId!,
            display: facts.bundleId!,
            name: facts.bundleId!,
            source: inProject(facts.configuration),
          )
        else
          for (final c in facts.bundleIdCandidates)
            (
              value: c.value,
              display: '${c.value} (${c.configuration})',
              name: c.value,
              source: inProject(c.configuration),
            ),
      ],
      preview: preview,
      validate: (v) => isBundleId(v) ? null : 'it is not a bundle ID: two or more parts of letters, digits and hyphens joined by dots',
    );
    if (bundleId != null) {
      redactor.hide(bundleId, '<bundle ID>');
    }

    final profile = await _profile(bundleId, preview: preview);

    final teams = <_Candidate>[
      if (profile != null)
        (
          value: profile.profile.teamId,
          display: '${profile.profile.teamId} (the profile)',
          name: profile.profile.teamId,
          source: 'the profile',
        ),
      if (facts.teamId != null && facts.teamId != profile?.profile.teamId)
        (
          value: facts.teamId!,
          display: '${facts.teamId} (the Xcode project)',
          name: facts.teamId!,
          source: inProject(facts.configuration),
        ),
    ];
    _hideAll([for (final t in teams) t.value], 'team ID');
    final teamId = await _choose(
      label: 'Team ID',
      key: 'team_id',
      flagName: 'team-id',
      flag: options.teamId,
      candidates: teams,
      preview: preview,
      validate: (v) => isTeamId(v)
          ? null
          : 'it is not a team ID: 10 capital letters and digits',
    );
    if (teamId != null) {
      redactor.hide(teamId, '<team ID>');
    }

    final entitlementsChosen = await _choose(
      label: 'Entitlements file',
      key: 'entitlements',
      flagName: 'entitlements',
      flag: options.entitlements,
      required: false,
      candidates: [
        for (final path in [
          if (facts.entitlements != null)
            facts.entitlements!
          else
            ...facts.entitlementsCandidates,
        ])
          (
            value: path,
            display: relativePath(root.path, path) ?? path,
            name: relativePath(root.path, path) ?? path,
            source: facts.entitlementsNamedByProject
                ? inProject(facts.configuration)
                : 'ios/Runner',
          ),
      ],
      preview: preview,
      validate: (v) =>
          File(_absolute(v)).existsSync() ? null : 'there is no such file',
    );

    if (_missing.isNotEmpty) {
      throw WincodeException(
        ExitCode.usage,
        'init-input-missing',
        'init cannot ask here, and ${_missing.length == 1 ? 'one value is' : '${_missing.length} values are'} not '
            'settled. ${_missing.join('. ')}.',
        why:
            'init asks questions only at a terminal, and not in CI, with --yes or with --json; there it takes every '
            'field from the options, and what it detected only with --yes.',
        next: 'give the missing options, add --yes to accept what init found, or run wincode init in a terminal.',
      );
    }

    final yamlFolder = target.parent.path;
    String? inYaml(String? path) => path == null
        ? null
        : relativePath(yamlFolder, _absolute(path)) ??
              _absolute(path).replaceAll('\\', '/');
    final text = renderConfig(
      bundleId: bundleId,
      teamId: teamId,
      profile: inYaml(profile?.file.path),
      entitlements: inYaml(entitlementsChosen),
      workflow: options.workflowRef,
      output: options.output ?? 'build/wincode',
    );

    final workflowTarget = File(
      '${root.path}/.github/workflows/wincode-ios.yml',
    );
    if (target.existsSync() && !options.force) {
      final old = target.readAsStringSync().replaceAll('\r\n', '\n');
      report
        ..writeln(
          'Changes init would make to $name (- is in the file, + is what init found):',
        )
        ..writeln(diffLines(old.split('\n'), text.split('\n')).join('\n'));
      throw WincodeException(
        ExitCode.failed,
        'config-exists',
        '$name already exists',
        why: 'init never replaces a settings file unless asked: it may hold choices that init cannot detect.',
        next: 'read the changes above, then run wincode init --force to replace the file, or edit the file by hand.',
      );
    }
    if (!preview) {
      // The same checks that every other command makes, before anything is written.
      parseConfig(text, path: target.path);
    }
    if (options.copyWorkflow) {
      if (workflowTarget.existsSync()) {
        throw WincodeException(
          ExitCode.failed,
          'workflow-exists',
          '.github/workflows/wincode-ios.yml already exists',
          why: 'init copies the reference workflow only to a new file, even with --force.',
          next:
              'compare it with the reference workflow (templates/wincode-ios.yml in winCode) by hand, or delete it and '
              'run init again.',
        );
      }
    }

    report
      ..writeln('--- $name')
      ..write(text)
      ..writeln('---');
    if (target.existsSync()) {
      report.writeln('The file exists; --force replaces it.');
    }
    if (interactive && !options.dryRun) {
      final answer = _ask('Write $name? [Y/n] ').toLowerCase();
      if (answer == 'n' || answer == 'no') {
        report.writeln('Nothing was written.');
        return _json(
          written: false,
          workflow: null,
          values: _values(bundleId, teamId, profile, entitlementsChosen),
        );
      }
    }
    if (options.dryRun) {
      report.writeln('Dry run: nothing was written.');
      if (options.copyWorkflow) {
        report.writeln(
          'It would copy the reference workflow to .github/workflows/wincode-ios.yml.',
        );
      }
    } else {
      target.parent.createSync(recursive: true);
      target.writeAsStringSync(text);
      report.writeln('Wrote $name.');
      if (options.copyWorkflow) {
        workflowTarget.parent.createSync(recursive: true);
        // The bytes of templates/wincode-ios.yml, which a test compares with the constant.
        workflowTarget.writeAsBytesSync(utf8.encode(workflowTemplate));
        report.writeln(
          'Copied the reference workflow to .github/workflows/wincode-ios.yml.',
        );
      }
    }
    if (profile != null) {
      final folder = relativePath(root.path, profile.file.parent.path);
      if (folder != null && !folder.startsWith('..')) {
        report.writeln(
          'The profile is inside the project: list ${folder.isEmpty ? '.' : folder}/ in .gitignore, so that it is '
          'never committed (init does not edit .gitignore).',
        );
      }
    }
    if (options.copyWorkflow && options.workflowRef == null) {
      report.writeln(
        'When the workflow is pushed, add its reference to $name: workflow: <owner>/<repository>/.github/workflows/'
        'wincode-ios.yml@<branch>.',
      );
    }
    _nextSteps(target);
    return _json(
      written: !options.dryRun,
      workflow: !options.copyWorkflow
          ? null
          : (options.dryRun ? 'would-copy' : 'copied'),
      values: _values(bundleId, teamId, profile, entitlementsChosen),
    );
  }

  Map<String, String> _values(
    String? bundleId,
    String? teamId,
    ({File file, ProvisioningProfile profile})? profile,
    String? entitlements,
  ) => {
    'bundle_id': ?bundleId,
    'team_id': ?teamId,
    if (profile != null) 'profile': profile.file.uri.pathSegments.last,
    if (entitlements != null)
      'entitlements': entitlements.split(RegExp(r'[\\/]')).last,
    'workflow': ?options.workflowRef,
    'output': options.output ?? 'build/wincode',
  };

  Map<String, Object?> _json({
    required bool written,
    required String? workflow,
    required Map<String, String> values,
  }) => {
    'command': 'init',
    'ok': true,
    'exitCode': ExitCode.ok.code,
    'dryRun': options.dryRun,
    'written': written,
    'config': values,
    'warnings': ?(_warnings.isEmpty ? null : _warnings),
    'workflow': ?workflow,
  };

  void _nextSteps(File target) {
    final configFlag =
        options.config == null &&
            target.parent.absolute.path == cwd.absolute.path
        ? ''
        : ' --config "${relativePath(cwd.path, target.path) ?? target.path.replaceAll('\\', '/')}"';
    report
      ..writeln()
      ..writeln('Next:')
      ..writeln(
        '  1. Put AuthKey_<Key ID>.p8, as App Store Connect delivered it, and a file issuer-id with the Issuer ID in a '
        'folder outside the project and outside OneDrive, and set WINCODE_ASC_KEY_DIR to it. init never stores them.',
      )
      ..writeln('  2. wincode preflight$configFlag --dry-run')
      ..writeln(
        '  3. wincode preflight$configFlag    (checks signed.ipa in the output folder; name another IPA as the last '
        'argument)',
      );
  }

  // The profile.

  /// The profile that `wincode.yaml` will name: the `--profile` file, or one chosen from the folder that
  /// `--profile-dir` (or the user) names. Null when there is none. Each file passes [requireOutsideGit] before it is read.
  Future<({File file, ProvisioningProfile profile})?> _profile(
    String? bundleId, {
    required bool preview,
  }) async {
    final String? path;
    if (options.profile != null) {
      path = options.profile;
    } else {
      var folder = options.profileDir;
      if (folder == null && interactive && !preview) {
        final answer = _ask(
          'Folder with the App Store profile (Enter to skip): ',
        );
        folder = answer.isEmpty ? null : answer;
      }
      if (folder == null) {
        return null;
      }
      final directory = Directory(_absolute(folder));
      if (!directory.existsSync()) {
        throw WincodeException(
          ExitCode.failed,
          'profile-dir-missing',
          'the profile folder does not exist',
          why: 'init lists the .mobileprovision files in the folder that --profile-dir names.',
          next: 'name the folder where you saved the App Store profile, or give the file with --profile.',
        );
      }
      final scan = await scanProfiles(
        directory,
        bundleId: bundleId,
        now: clock(),
        run: run,
      );
      for (final line in scan.skipped) {
        report.writeln('note: $line.');
      }
      if (scan.usable.isEmpty) {
        if (scan.refused != null) {
          throw scan.refused!;
        }
        report.writeln(
          'note: the folder holds no App Store profile that has not expired${bundleId == null ? '' : ' for this app'}.',
        );
        return null;
      }
      path = await _choose(
        label: 'Profile',
        key: 'profile',
        flagName: 'profile',
        required: false,
        preview: preview,
        candidates: [
          for (final (:file, :profile) in scan.usable)
            (
              value: file.path,
              display:
                  '${file.uri.pathSegments.last}, valid until ${profile.expirationDate.toIso8601String().substring(0, 10)}',
              name: file.uri.pathSegments.last,
              source: 'the profile folder',
            ),
        ],
        validate: _profileFileProblem,
      );
    }
    if (path == null) {
      return null;
    }
    final problem = _profileFileProblem(path);
    if (problem != null) {
      throw WincodeException(
        ExitCode.usage,
        'init-value-invalid',
        '--profile: $problem',
        why: 'wincode.yaml names the App Store profile as the developer portal delivers it, a .mobileprovision file.',
        next: 'download the profile (developer portal, Profiles) and give its file.',
      );
    }
    final file = File(_absolute(path));
    await requireOutsideGit(file.path, source: 'the profile', run: run);
    final ProvisioningProfile profile;
    try {
      profile = readProvisioningProfile(file.readAsBytesSync());
    } on FormatException catch (e) {
      throw WincodeException(
        ExitCode.failed,
        'profile-unreadable',
        '${file.uri.pathSegments.last} is not a provisioning profile: ${e.message}',
        why: 'init reads the team and the app from the profile.',
        next: 'download the App Store profile again (developer portal, Profiles) and give its file.',
      );
    }
    redactor.hide(profile.teamId, '<team ID>');
    final profileBundle = profile.applicationIdentifier.substring(
      profile.applicationIdentifier.indexOf('.') + 1,
    );
    if (bundleId != null && profileBundle != bundleId) {
      if (profileBundle.contains(RegExp('[A-Za-z0-9]'))) {
        redactor.hide(profileBundle, '<other bundle ID>');
      }
      report.writeln(
        'note: the profile is for $profileBundle, not for $bundleId; preflight will fail it.',
      );
    }
    if (!profile.isForAppStore) {
      report.writeln(
        'note: the profile is not an App Store profile; preflight will fail it.',
      );
    }
    if (!profile.expirationDate.isAfter(clock())) {
      report.writeln('note: the profile has expired; preflight will fail it.');
    }
    return (file: file, profile: profile);
  }

  String? _profileFileProblem(String path) {
    final file = File(_absolute(path));
    if (!path.toLowerCase().endsWith('.mobileprovision')) {
      return 'it is not a .mobileprovision file';
    }
    return file.existsSync() ? null : 'there is no such file';
  }

  // Asking.

  /// The value of one field: [flag] if given, else what was found, confirmed or chosen by the user, or, without a
  /// terminal, what `--yes` accepts. A field that a non-interactive run cannot settle goes to [_missing]. With [preview],
  /// nothing is asked and nothing is missing: the best guess, or null.
  Future<String?> _choose({
    required String label,
    required String key,
    required String flagName,
    required List<_Candidate> candidates,
    required String? Function(String) validate,
    String? flag,
    bool required = true,
    bool preview = false,
  }) async {
    if (flag != null) {
      final problem = validate(flag);
      if (problem != null) {
        throw WincodeException(
          ExitCode.usage,
          'init-value-invalid',
          '--$flagName: $problem',
          why: 'wincode.yaml checks the same shape when any command loads it.',
          next: 'correct --$flagName.',
        );
      }
      return flag;
    }
    if (preview) {
      return candidates.length == 1 ? candidates.single.value : null;
    }
    if (!interactive) {
      if (candidates.length == 1 && options.yes) {
        return candidates.single.value;
      }
      if (required || candidates.isNotEmpty) {
        _missing.add(
          '$key: ${switch (candidates.length) {
            0 => 'not detected; pass --$flagName',
            1 => 'detected ${candidates.single.name} in ${candidates.single.source}; confirm with --yes or pass --$flagName',
            _ => 'detected several (${candidates.map((c) => '${c.name} in ${c.source}').join(', ')}); pass --$flagName',
          }}',
        );
      }
      return null;
    }
    if (candidates.length > 1) {
      report.writeln('$label: init found several.');
      for (final (i, c) in candidates.indexed) {
        report.writeln('  ${i + 1}) ${c.display}');
      }
    }
    while (true) {
      final prompt = switch (candidates.length) {
        0 => '$label${required ? '' : ' (Enter to skip)'}: ',
        1 =>
          '$label [${candidates.single.display}]${required ? '' : ' (- for none)'}: ',
        _ =>
          '$label (1-${candidates.length}, or type one${required ? '' : ', Enter for none'}): ',
      };
      final answer = _ask(prompt);
      if (answer.isEmpty) {
        if (candidates.length == 1) {
          return candidates.single.value;
        }
        if (!required) {
          return null;
        }
        report.writeln('$label is needed.');
        continue;
      }
      if (!required && answer == '-' && candidates.length == 1) {
        return null;
      }
      final number = int.tryParse(answer);
      if (number != null &&
          number >= 1 &&
          number <= candidates.length &&
          candidates.length > 1) {
        return candidates[number - 1].value;
      }
      final problem = validate(answer);
      if (problem == null) {
        return answer;
      }
      report.writeln('$answer: $problem.');
    }
  }

  String _ask(String question) {
    report.write(question);
    final line = readLine();
    if (line == null) {
      report.writeln();
      throw const WincodeException(
        ExitCode.usage,
        'init-input-ended',
        'the input ended before init had all it needs',
        why: 'init asked a question and got no answer.',
        next: 'run wincode init again in a terminal, or give every field as an option (wincode init --help).',
      );
    }
    return line.trim();
  }

  /// Registers [values], IDs found in the project, with the redactor: a single one is `<bundle ID>` or `<team ID>`,
  /// several are numbered, so that a list of choices can still be told apart.
  void _hideAll(List<String> values, String kind) {
    final distinct = values.toSet().toList();
    for (final (i, v) in distinct.indexed) {
      redactor.hide(v, distinct.length == 1 ? '<$kind>' : '<$kind ${i + 1}>');
    }
  }

  String _absolute(String path) =>
      File(path).isAbsolute ? path : '${cwd.absolute.path}/$path';
}

/// The text of `wincode.yaml` for these values. A value that is null is left as a comment. A value is quoted when YAML
/// would read it as anything but the text it is (a team ID of digits only would become a number).
String renderConfig({
  String? bundleId,
  String? teamId,
  String? profile,
  String? entitlements,
  String? workflow,
  String? output,
}) {
  String scalar(String v) =>
      RegExp(r'^(\.\.?/)*[A-Za-z][A-Za-z0-9._/@-]*$').hasMatch(v)
      ? v
      : "'${v.replaceAll("'", "''")}'";
  String line(String key, String? value, String example) =>
      value == null ? '# $key: $example' : '$key: ${scalar(value)}';
  return [
    '# wincode.yaml: one app, no secrets. Paths are relative to this file.',
    '# Written by wincode init. The App Store Connect key is not stored here: it comes from the folder that',
    '# WINCODE_ASC_KEY_DIR names. Keep the profile out of git working trees, or let .gitignore list it.',
    '',
    '# The app that wincode ships (the PRODUCT_BUNDLE_IDENTIFIER of its build), and the team that signs it.',
    line('bundle_id', bundleId, 'com.example.app'),
    line('team_id', teamId, 'TEAM000000'),
    '',
    '# The App Store profile, as the developer portal delivers it. wincode sign signs with it.',
    line('profile', profile, '../signing/App_Store.mobileprovision'),
    '',
    "# The app's own entitlements file, if it has one. wincode sign signs the app with the keys in it.",
    line('entitlements', entitlements, 'ios/Runner/Runner.entitlements'),
    '',
    '# The workflow that wincode build starts (<owner>/<repository>/.github/workflows/<file>@<branch or tag>).',
    line(
      'workflow',
      workflow,
      'example-org/example-app/.github/workflows/wincode-ios.yml@main',
    ),
    '',
    '# Where wincode build and wincode sign write their IPAs.',
    line('output', output, 'build/wincode'),
    '',
  ].join('\n');
}
