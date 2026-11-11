import 'dart:convert';
import 'dart:io';

import 'package:wincode_core/wincode_core.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'config.dart';
import 'failure.dart';
import 'init_detect.dart';
import 'key_location.dart';
import 'redact.dart';
import 'select.dart';
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
    this.app,
    this.credentials,
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

  /// `--configuration`: the build configuration to read, by name. It overrides the default `Release-<flavor>`.
  final String? configuration;

  /// `--app`: the app of a file of apps that init adds or updates (ADR-0014).
  final String? app;

  /// `--credentials`: the credentials reference of the app.
  final String? credentials;

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
    this.writeFile = _writeText,
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

  /// Writes the text of `wincode.yaml`. Tests replace it to see that a file that does not load is rolled back.
  final void Function(File file, String text) writeFile;

  /// The options that a non-interactive run needs and did not get, with what was found for them.
  final _missing = <String>[];

  /// What `detectProject` said the user should look at.
  var _warnings = const <String>[];

  /// The build configuration read for `--flavor` or `--configuration`.
  String? _readConfiguration;

  /// For a file of apps: the place of the app in the file (from 1), and the distinct team IDs of the apps already in it,
  /// so that the placeholders of the IDs are those the loader gives (ADR-0014, section 4).
  var _appIndex = 1;
  var _teams = const <String>[];

  /// Whether the file that was there began with a byte order mark and used CRLF, so that a write keeps both.
  var _bom = false;
  var _crlf = false;

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
    final app = options.app;
    for (final (option, value, what) in [
      ('app', app, 'app name'),
      ('credentials', options.credentials, 'credentials name'),
    ]) {
      final problem = value == null ? null : nameProblem(value);
      if (problem != null) {
        throw WincodeException(
          ExitCode.usage,
          'init-value-invalid',
          '--$option: the $what $problem',
          why: 'wincode.yaml checks the same rule for every name it holds (ADR-0014, sections 1 and 4).',
          next: 'use 3 to 32 lower-case letters, digits and hyphens that are not an ordinary word, such as alpha or team-one.',
        );
      }
    }
    // The file as it is. For an app it must be valid, and it decides what --app means.
    // Dart's reader drops a byte order mark, so it is looked for in the bytes. Both it and CRLF are put back on a write.
    final bytes = target.existsSync() ? target.readAsBytesSync() : null;
    _bom =
        bytes != null &&
        bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF;
    final decoded = bytes == null ? null : utf8.decode(bytes);
    final onDisk = decoded != null && decoded.startsWith('\uFEFF')
        ? decoded.substring(1)
        : decoded;
    _crlf = onDisk?.contains('\r\n') ?? false;
    final existingText = onDisk?.replaceAll('\r\n', '\n');
    WincodeSettings? existing;
    if (existingText != null) {
      if (app != null) {
        // A flat file is about to become the one app of a file of apps, whose placeholders are numbered: it registers
        // nothing itself, so that the new text gives them first.
        existing = parseSettings(
          existingText,
          path: target.path,
          redactor: _hasApps(existingText) ? redactor : null,
        );
      } else if (_hasApps(existingText)) {
        throw appRequired(target.path, [
          for (final a in parseSettings(
            existingText,
            path: target.path,
            redactor: redactor,
          ).apps)
            a.name!,
        ], readOnly: false);
      }
    }
    // init --app on a flat file moves the file under apps: with its values unchanged (ADR-0014, section 5).
    final migrating = app != null && existing != null && existing.isFlat;
    if (migrating) {
      for (final (option, value) in [
        ('team-id', options.teamId),
        ('profile', options.profile),
        ('profile-dir', options.profileDir),
        ('entitlements', options.entitlements),
        ('workflow-ref', options.workflowRef),
        ('output', options.output),
      ]) {
        if (value != null) {
          throw WincodeException(
            ExitCode.usage,
            'init-value-invalid',
            '--$option: init --app moves the values of the flat $name under apps: unchanged',
            why: 'a migration changes the shape of the file and nothing else, so that what it shows is easy to check.',
            next:
                'leave --$option out, then change the value with wincode init --app $app --$option <value> --force once the file has an apps: map.',
          );
        }
      }
    }
    final entry = app == null ? null : existing?.app(app);
    _appIndex = migrating
        ? 1
        : entry != null
        ? existing!.apps.indexOf(entry) + 1
        : (existing?.apps.length ?? 0) + 1;
    _teams = migrating
        ? const []
        : {for (final a in existing?.apps ?? const <WincodeConfig>[]) a.teamId}
              .toList();
    // An existing file is never replaced without --force. Nothing is asked: the summary shows what init found. A file of
    // apps is changed instead, after a diff and a confirmation.
    final preview = app == null && target.existsSync() && !options.force;

    // --flavor names the flavor to record and the default configuration, Release-<flavor>; --configuration overrides it.
    final flavor = options.flavor ?? entry?.flavor;
    final configuration =
        options.configuration ??
        (entry != null &&
                entry.configuration != _defaultConfiguration(entry.flavor)
            ? entry.configuration
            : null);
    final reference = options.credentials;
    final facts = detectProject(
      root,
      flavor: flavor,
      configuration: configuration,
    );
    final unknown = configuration;
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
    if ((flavor != null || configuration != null) &&
        facts.configuration != null) {
      _readConfiguration = facts.configuration;
      report.writeln(
        'Read the build configuration ${facts.configuration} of ios/Runner.xcodeproj.',
      );
    }
    for (final note in facts.notes) {
      report.writeln('note: $note.');
    }
    for (final warning in facts.warnings) {
      report.writeln('WARN  $warning.');
    }
    _warnings = facts.warnings;
    // What the user needs to know about a setting that uses a variable that nothing defines.
    String? unresolvedHint(String key) {
      final names = facts.unresolved[key];
      return names == null
          ? null
          : '${names.map((n) => '\$($n)').join(', ')} ${names.length == 1 ? 'is' : 'are'} not defined in '
                '${facts.configuration} or its xcconfig files';
    }

    String inProject(String? configuration) =>
        'ios/Runner.xcodeproj${configuration == null ? '' : ' ($configuration)'}';
    _hideAll([
      ?facts.bundleId,
      for (final c in facts.bundleIdCandidates) c.value,
    ], 'bundle ID');

    final bundleId = await _choose(
      label: 'Bundle ID',
      hint: unresolvedHint('PRODUCT_BUNDLE_IDENTIFIER'),
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
      _hideId(bundleId, 'bundle ID');
    }
    if (migrating) {
      return _migrate(
        target: target,
        name: name,
        app: app,
        flat: existing.apps.single,
        existingText: existingText!,
        bundleId: bundleId,
        flavor: flavor,
        configuration: configuration,
        workflowTarget: File('${root.path}/.github/workflows/wincode-ios.yml'),
      );
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
      hint: unresolvedHint('DEVELOPMENT_TEAM'),
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
      _hideId(teamId, 'team ID');
    }

    final entitlementsChosen = await _choose(
      label: 'Entitlements file',
      hint: unresolvedHint('CODE_SIGN_ENTITLEMENTS'),
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

    final credentials = app == null
        ? reference
        : await _choose(
            label: 'Credentials',
            key: 'credentials',
            flagName: 'credentials',
            flag: reference,
            candidates: [
              if ((entry ?? existing?.apps.firstOrNull)?.credentials
                  case final c?)
                (
                  value: c,
                  display: c,
                  name: c,
                  source: entry != null
                      ? 'the app in $name'
                      : 'the apps in $name',
                ),
            ],
            preview: false,
            validate: (v) => nameProblem(v) == null ? null : 'it is not a name: 3 to 32 lower-case letters, digits and hyphens, not an ordinary word',
          );
    if (credentials != null) {
      final problem = nameProblem(credentials);
      if (problem != null) {
        throw WincodeException(
          ExitCode.usage,
          'init-value-invalid',
          '--credentials: the credentials name $problem',
          why: 'wincode.yaml checks the same rule for every name it holds (ADR-0014, sections 1 and 4).',
          next: 'use 3 to 32 lower-case letters, digits and hyphens that are not an ordinary word, such as team-one.',
        );
      }
    }

    _failIfMissing();

    final yamlFolder = target.parent.path;
    String? inYaml(String? path) => path == null
        ? null
        : relativePath(yamlFolder, _absolute(path)) ??
              _absolute(path).replaceAll('\\', '/');
    final recordConfiguration =
        configuration != null && configuration != _defaultConfiguration(flavor)
        ? configuration
        : null;
    final workflowTarget = File(
      '${root.path}/.github/workflows/wincode-ios.yml',
    );
    if (app != null) {
      return _writeApps(
        target: target,
        name: name,
        app: app,
        existing: existing,
        existingText: existingText,
        workflowTarget: workflowTarget,
        profile: profile,
        values: {
          'bundle_id': ?bundleId,
          'flavor': ?flavor,
          'configuration': ?recordConfiguration,
          'team_id': ?teamId,
          'credentials': ?credentials,
          'profile': ?inYaml(profile?.file.path),
          'entitlements': ?inYaml(entitlementsChosen),
          'workflow': ?options.workflowRef,
          'output': ?options.output,
        },
      );
    }
    final text = renderConfig(
      bundleId: bundleId,
      teamId: teamId,
      profile: inYaml(profile?.file.path),
      entitlements: inYaml(entitlementsChosen),
      workflow: options.workflowRef,
      output: options.output ?? 'build/wincode',
      flavor: flavor,
      configuration: recordConfiguration,
      credentials: credentials,
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
      _commit(target, text);
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
    _nextSteps(target, credentials: credentials);
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

  Map<String, Object?> _jsonOfApp({
    required bool written,
    required String? workflow,
    required Map<String, String> values,
    String? backup,
  }) => {
    'command': 'init',
    'app': options.app,
    'ok': true,
    'exitCode': ExitCode.ok.code,
    'dryRun': options.dryRun,
    'written': written,
    'backup': ?backup,
    'config': values,
    'configuration': ?_readConfiguration,
    'warnings': ?(_warnings.isEmpty ? null : _warnings),
    'workflow': ?workflow,
  };

  Map<String, Object?> _json({
    required bool written,
    required String? workflow,
    required Map<String, String> values,
  }) => {
    'command': 'init',
    'app': null,
    'ok': true,
    'exitCode': ExitCode.ok.code,
    'dryRun': options.dryRun,
    'written': written,
    'config': values,
    'configuration': ?_readConfiguration,
    'warnings': ?(_warnings.isEmpty ? null : _warnings),
    'workflow': ?workflow,
  };

  void _nextSteps(File target, {String? credentials}) {
    final appFlag = options.app == null ? '' : ' --app ${options.app}';
    final configFlag =
        options.config == null &&
            target.parent.absolute.path == cwd.absolute.path
        ? ''
        : ' --config "${relativePath(cwd.path, target.path) ?? target.path.replaceAll('\\', '/')}"';
    report
      ..writeln()
      ..writeln('Next:')
      ..writeln(
        credentials == null
            ? '  1. Put AuthKey_<Key ID>.p8, as App Store Connect delivered it, and a file issuer-id with the Issuer ID in a '
                  'folder outside the project and outside OneDrive, and set WINCODE_ASC_KEY_DIR to it. init never stores them.'
            : '  1. Put AuthKey_<Key ID>.p8, as App Store Connect delivered it, and a file issuer-id with the Issuer ID in '
                  'the folder $credentials of your keys folder (%USERPROFILE%\\.wincode\\keys, or the folder that '
                  'WINCODE_KEYS_DIR names). init never stores them.',
      )
      ..writeln('  2. wincode preflight$configFlag$appFlag --dry-run')
      ..writeln(
        '  3. wincode preflight$configFlag$appFlag    (checks signed.ipa in the output folder; name another IPA as the last '
        'argument)',
      );
  }

  // A file of apps (ADR-0014, section 5).

  /// Throws when a run that cannot ask has values that are not settled, listing each with where it was found.
  void _failIfMissing() {
    if (_missing.isEmpty) {
      return;
    }
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

  /// Writes [text] as the new `wincode.yaml` (and the original to [backup]), loads the file again with the normal
  /// loader, and puts everything back if that fails: init never leaves a file that does not load (ADR-0014, section 5).
  void _commit(File target, String text, {File? backup}) {
    final previous = target.existsSync() ? target.readAsBytesSync() : null;
    final previousBackup = backup != null && backup.existsSync()
        ? backup.readAsBytesSync()
        : null;
    void restore() {
      if (previous == null) {
        if (target.existsSync()) {
          target.deleteSync();
        }
      } else {
        target.writeAsBytesSync(previous);
      }
      if (backup != null) {
        if (previousBackup != null) {
          backup.writeAsBytesSync(previousBackup);
        } else if (backup.existsSync()) {
          backup.deleteSync();
        }
      }
    }

    final name = target.uri.pathSegments.last;
    final onDisk =
        '${_bom ? '\uFEFF' : ''}${_crlf ? text.replaceAll('\n', '\r\n') : text}';
    try {
      target.parent.createSync(recursive: true);
      if (backup != null && previous != null) {
        backup.writeAsBytesSync(previous);
      }
      writeFile(target, onDisk);
      loadSettings(target.path);
    } on Object catch (e) {
      Object? restoreError;
      try {
        restore();
      } on Object catch (r) {
        restoreError = r;
      }
      throw WincodeException(
        ExitCode.internal,
        'init-wrote-invalid',
        'init wrote a $name that does not load: ${e is WincodeException ? e.what : e}',
        why:
            'this is a bug in winCode: init checks the text before it writes it. '
            '${restoreError == null ? 'The previous file was restored${backup == null ? '' : ', and the backup undone'}.' : 'The previous file could not be restored, so check it by hand.'}',
        next: 'report it at https://github.com/wincode-org/wincode/issues with the command line and this message.',
      );
    }
  }

  /// Adds the app [app] to the file of apps at [target], or updates its entry, with the [values] that init found: only a
  /// value that the entry does not inherit from `defaults` goes into it. An existing file is edited in place, so its
  /// comments, blank lines and key order stay, and only the entry changes. It is changed after a diff and a confirmation
  /// (`--yes` where init cannot ask), and a value that the entry already has is replaced only with `--force`. A file
  /// that does not exist is written with the one app.
  Future<Map<String, Object?>> _writeApps({
    required File target,
    required String name,
    required String app,
    required WincodeSettings? existing,
    required String? existingText,
    required File workflowTarget,
    required ({File file, ProvisioningProfile profile})? profile,
    required Map<String, String> values,
  }) async {
    final raw = existingText == null ? null : _rawApps(existingText);
    final index = raw == null ? -1 : raw.apps.indexWhere((a) => a.$1 == app);
    final entry = index < 0 ? const <String, Object?>{} : raw!.apps[index].$2;
    final replaced = <String>[];
    final changes = <String, String>{};
    for (final MapEntry(:key, :value) in values.entries) {
      final current = entry[key];
      if (current == value) {
        continue;
      }
      if (current != null) {
        replaced.add(key);
      } else if (raw?.defaults[key] == value && key != 'bundle_id') {
        continue;
      }
      changes[key] = value;
    }
    final text = existingText == null
        ? renderApps({}, [(app, changes)])
        : _edit(existingText, name, app, isNew: index < 0, changes: changes);
    final unchanged = existingText != null && text == existingText;
    if (existingText != null) {
      report.writeln(
        unchanged
            ? '$name already holds these values for the app.'
            : 'Changes init would make to $name (- is in the file, + is what init found):',
      );
      if (!unchanged) {
        report.writeln(
          diffLines(existingText.split('\n'), text.split('\n')).join('\n'),
        );
      }
    }
    if (replaced.isNotEmpty && !options.force) {
      throw WincodeException(
        ExitCode.failed,
        'app-exists',
        'the app already has ${replaced.join(', ')} in $name, with other values',
        why: 'init changes the values that an app has only when asked: it may hold choices that init cannot detect.',
        next:
            'read the changes above, then run wincode init --app $app --force to replace them, or edit the file by hand.',
      );
    }
    // The same checks that every other command makes, before anything is written. They also register the names, the IDs
    // and the paths with the redactor, before the text is printed.
    parseSettings(text, path: target.path, redactor: redactor);
    if (existingText == null) {
      report
        ..writeln('--- $name')
        ..write(text)
        ..writeln('---');
    }
    _requireFreeWorkflow(workflowTarget);
    if (!unchanged &&
        !options.dryRun &&
        !_goAhead(name, existing: existingText != null)) {
      return _jsonOfApp(
        written: false,
        workflow: null,
        values: _valuesOfApp(values, profile),
      );
    }
    final wrote = !options.dryRun && !unchanged;
    if (options.dryRun) {
      report.writeln('Dry run: nothing was written.');
    }
    if (wrote) {
      _commit(target, text);
      report.writeln('Wrote $name.');
    }
    final workflow = _workflowStep(workflowTarget);
    _nextSteps(target, credentials: values['credentials']);
    return _jsonOfApp(
      written: wrote,
      workflow: workflow,
      values: _valuesOfApp(values, profile),
    );
  }

  /// [text] with the [changes] made to the entry of [app] by `yaml_edit`, which keeps the comments, the blank lines and
  /// the order of everything else.
  String _edit(
    String text,
    String name,
    String app, {
    required bool isNew,
    required Map<String, String> changes,
  }) {
    if (changes.isEmpty) {
      return text;
    }
    YamlNode node(String v) => YamlScalar.wrap(
      v,
      style: _scalar(v) == v ? ScalarStyle.PLAIN : ScalarStyle.SINGLE_QUOTED,
    );
    try {
      final editor = YamlEditor(text);
      if (isNew) {
        editor.update(
          ['apps', app],
          wrapAsYamlNode({
            for (final c in changes.entries) c.key: node(c.value),
          }),
        );
      } else {
        for (final MapEntry(:key, :value) in changes.entries) {
          editor.update(['apps', app, key], node(value));
        }
      }
      return editor.toString();
    } on Object catch (e) {
      throw WincodeException(
        ExitCode.failed,
        'init-edit-failed',
        'init cannot edit $name safely: $e',
        why: 'the layout of the file is one that the editor cannot change without risking the rest of it.',
        next: 'add the entry by hand, or simplify the layout (block maps, no anchors) and run wincode init again.',
      );
    }
  }

  /// Moves the flat `wincode.yaml` under `apps:` as the app [app] (ADR-0014, section 5), with its values unchanged and
  /// the original kept as `wincode.yaml.bak`. Never silent: the diff comes first, and a yes (`--yes` where init cannot
  /// ask). The file is rendered again here, because its shape changes; the backup keeps its comments.
  Future<Map<String, Object?>> _migrate({
    required File target,
    required String name,
    required String app,
    required WincodeConfig flat,
    required String existingText,
    required String? bundleId,
    required String? flavor,
    required String? configuration,
    required File workflowTarget,
  }) async {
    if (bundleId != null &&
        bundleId.toLowerCase() != flat.bundleId.toLowerCase()) {
      throw WincodeException(
        ExitCode.failed,
        'config-is-another-app',
        '$name describes another app',
        why:
            'init --app moves the flat $name under apps: only for the app that the file describes. One change per run, '
            'and no app is named after a guess.',
        next:
            'name the app of the file first: wincode init --app <its name> --flavor <its flavor>, then add $app with a '
            'second run.',
      );
    }
    final credentials = await _choose(
      label: 'Credentials',
      key: 'credentials',
      flagName: 'credentials',
      flag: options.credentials,
      candidates: [
        if (flat.credentials case final c?)
          (value: c, display: c, name: c, source: 'the app in $name'),
      ],
      preview: false,
      validate: (v) => nameProblem(v) == null ? null : 'it is not a name: 3 to 32 lower-case letters, digits and hyphens, not an ordinary word',
    );
    _failIfMissing();
    final recordConfiguration =
        configuration != null && configuration != _defaultConfiguration(flavor)
        ? configuration
        : null;
    final entry = _plain(loadYaml(existingText) as YamlMap);
    if (flavor != null) {
      entry['flavor'] = flavor;
    }
    if (recordConfiguration != null) {
      entry['configuration'] = recordConfiguration;
    }
    if (credentials != null) {
      entry['credentials'] = credentials;
    }
    entry.putIfAbsent('output', () => 'build/wincode');
    final text = renderApps({}, [(app, entry)]);
    // The same checks that every other command makes, before anything is written; they register the names and paths.
    parseSettings(text, path: target.path, redactor: redactor);
    report
      ..writeln(
        'Moving $name under apps: as the app that it describes. Changes init would make (- is in the file, + is what init '
        'found):',
      )
      ..writeln(
        diffLines(existingText.split('\n'), text.split('\n')).join('\n'),
      );
    final backup = File('${target.path}.bak');
    final backupName = '$name.bak';
    if (backup.existsSync() && !options.force) {
      throw WincodeException(
        ExitCode.failed,
        'backup-exists',
        '$backupName already exists',
        why:
            'init keeps the original of a flat $name as $backupName, and never replaces an earlier backup unasked.',
        next:
            'move or delete $backupName, or run the command again with --force to replace it.',
      );
    }
    _requireFreeWorkflow(workflowTarget);
    final values = {
      'bundle_id': flat.bundleId,
      'team_id': flat.teamId,
      'flavor': ?flavor,
      'configuration': ?recordConfiguration,
      'credentials': ?credentials,
    };
    if (!options.dryRun && !_goAhead(name, existing: true, migration: true)) {
      return _jsonOfApp(written: false, workflow: null, values: values);
    }
    if (options.dryRun) {
      report.writeln('Dry run: nothing was written, and no backup was made.');
    } else {
      _commit(target, text, backup: backup);
      report
        ..writeln('Kept the original as $backupName.')
        ..writeln('Wrote $name.');
    }
    final workflow = _workflowStep(workflowTarget);
    _nextSteps(target, credentials: credentials);
    return _jsonOfApp(
      written: !options.dryRun,
      workflow: workflow,
      values: values,
      backup: options.dryRun ? null : backupName,
    );
  }

  /// Whether to go on with a change to the file: a yes at a terminal, or `--yes`. For a file that exists, init cannot go
  /// on without one of them (`init-input-missing`); a new file needs only an answer at a terminal. `--force` is not a yes
  /// to a migration: it means "replace this file".
  bool _goAhead(String name, {required bool existing, bool migration = false}) {
    if (interactive) {
      final answer = _ask('Write $name? [Y/n] ').toLowerCase();
      if (answer == 'n' || answer == 'no') {
        report.writeln('Nothing was written.');
        return false;
      }
      return true;
    }
    if (existing && !options.yes) {
      throw WincodeException(
        ExitCode.usage,
        'init-input-missing',
        'init changes an existing $name only after you confirm, and it cannot ask here',
        why:
            'init asks questions only at a terminal, and not in CI, with --yes or with --json.${migration ? ' --force is not a yes: it means replace this file.' : ''}',
        next: 'read the changes above, then run the command again with --yes, or run wincode init in a terminal.',
      );
    }
    return true;
  }

  void _requireFreeWorkflow(File workflowTarget) {
    if (options.copyWorkflow && workflowTarget.existsSync()) {
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

  /// Copies the reference workflow, or says that it would, when `--workflow` was given. Returns what `--json` calls it.
  String? _workflowStep(File workflowTarget) {
    if (!options.copyWorkflow) {
      return null;
    }
    if (options.dryRun) {
      report.writeln(
        'It would copy the reference workflow to .github/workflows/wincode-ios.yml.',
      );
      return 'would-copy';
    }
    workflowTarget.parent.createSync(recursive: true);
    workflowTarget.writeAsBytesSync(utf8.encode(workflowTemplate));
    report.writeln(
      'Copied the reference workflow to .github/workflows/wincode-ios.yml.',
    );
    return 'copied';
  }

  Map<String, String> _valuesOfApp(
    Map<String, String> values,
    ({File file, ProvisioningProfile profile})? profile,
  ) => {
    for (final MapEntry(:key, :value) in values.entries)
      key: switch (key) {
        'profile' || 'entitlements' => value.split(RegExp(r'[\\/]')).last,
        _ => value,
      },
  };

  /// Registers [value], an ID found in the project. A flat file has one of each kind, and a file of apps numbers them as
  /// the loader does: the bundle ID by the place of the app, the team ID by first use.
  void _hideId(String value, String kind) {
    if (options.app == null) {
      redactor.hide(value, '<$kind>');
    } else if (kind == 'bundle ID') {
      redactor.hide(value, '<bundle ID $_appIndex>');
    } else {
      final known = _teams.indexOf(value);
      redactor.hide(
        value,
        '<team ID ${known >= 0 ? known + 1 : _teams.length + 1}>',
      );
    }
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
    _hideId(profile.teamId, 'team ID');
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
    String? hint,
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
      // An optional value whose variable could not be resolved is not skipped: it may be one that the app needs.
      if (required || candidates.isNotEmpty || hint != null) {
        _missing.add(
          '$key: ${switch (candidates.length) {
            0 => 'not detected${hint == null ? '' : ' ($hint)'}; pass --$flagName',
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
    if (options.app != null) {
      for (final v in values) {
        _hideId(v, kind);
      }
      return;
    }
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
  String? flavor,
  String? configuration,
  String? credentials,
}) {
  String line(String key, String? value, String example) =>
      value == null ? '# $key: $example' : '$key: ${_scalar(value)}';
  return [
    '# wincode.yaml: one app, no secrets. Paths are relative to this file.',
    '# Written by wincode init. The App Store Connect key is not stored here: it comes from the folder that',
    '# WINCODE_ASC_KEY_DIR names. Keep the profile out of git working trees, or let .gitignore list it.',
    '',
    '# The app that wincode ships (the PRODUCT_BUNDLE_IDENTIFIER of its build), and the team that signs it.',
    line('bundle_id', bundleId, 'com.example.app'),
    line('team_id', teamId, 'TEAM000000'),
    if (flavor != null) ...[
      '',
      '# The Flutter flavor that builds this app. init read Release-<flavor> of the Xcode project for it.',
      'flavor: ${_scalar(flavor)}',
    ],
    if (configuration != null) 'configuration: ${_scalar(configuration)}',
    if (credentials != null) ...[
      '',
      '# The credentials reference: its keys are in the folder of that name of your keys folder (ADR-0014).',
      'credentials: ${_scalar(credentials)}',
    ],
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

/// [v] as YAML text: plain when YAML reads it as the text it is, else in single quotes (a team ID of digits only would
/// become a number).
String _scalar(String v) =>
    RegExp(r'^(\.\.?/)*[A-Za-z][A-Za-z0-9._/@-]*$').hasMatch(v) &&
        !const {'true', 'false', 'null'}.contains(v)
    ? v
    : "'${v.replaceAll("'", "''")}'";

void _writeText(File file, String text) => file.writeAsStringSync(text);

/// [map] as plain data in file order: text, or a map of text for `workflow_inputs`.
Map<String, Object?> _plain(YamlMap map) => {
  for (final MapEntry(:key, :value) in map.entries)
    '$key': value is YamlMap ? _plain(value) : '$value',
};

/// The configuration that `wincode.yaml` means when it names none: `Release-<flavor>`, or `Release`.
String _defaultConfiguration(String? flavor) =>
    flavor == null ? 'Release' : 'Release-$flavor';

/// Whether [text] is a file with an `apps:` map. A text that is not YAML is not.
bool _hasApps(String text) {
  try {
    final root = loadYamlNode(text.startsWith('﻿') ? text.substring(1) : text);
    return root is YamlMap &&
        root.nodes.keys.any((k) => (k as YamlNode).value == 'apps');
  } on YamlException {
    return false;
  }
}

/// The `defaults:` and the apps of a file of apps, as plain data in file order. The text passed the loader, so every
/// value is text, or a map of text for `workflow_inputs`.
({Map<String, Object?> defaults, List<(String, Map<String, Object?>)> apps})
_rawApps(String text) {
  final root =
      loadYaml(text.startsWith('﻿') ? text.substring(1) : text) as YamlMap;
  return (
    defaults: switch (root['defaults']) {
      final YamlMap d => _plain(d),
      _ => <String, Object?>{},
    },
    apps: [
      for (final MapEntry(:key, :value) in (root['apps'] as YamlMap).entries)
        ('$key', _plain(value as YamlMap)),
    ],
  );
}

/// The text of a file of apps (ADR-0014, section 1). `defaults` and the apps keep their values and their order; the
/// comments of an earlier file are not kept.
String renderApps(
  Map<String, Object?> defaults,
  List<(String, Map<String, Object?>)> apps,
) {
  void fields(List<String> lines, Map<String, Object?> map, String indent) {
    for (final MapEntry(:key, :value) in map.entries) {
      if (value is Map<String, Object?>) {
        lines.add('$indent$key:');
        fields(lines, value, '$indent  ');
      } else {
        lines.add('$indent$key: ${_scalar('$value')}');
      }
    }
  }

  final lines = <String>[
    '# wincode.yaml: ${apps.length} app${apps.length == 1 ? '' : 's'}, no secrets. Paths are relative to this file.',
    '# Written by wincode init. Each app names a credentials reference: its keys are read from the folder of that name',
    '# of your keys folder (ADR-0014), never from this file.',
    '',
    if (defaults.isNotEmpty) 'defaults:',
  ];
  fields(lines, defaults, '  ');
  if (defaults.isNotEmpty) {
    lines.add('');
  }
  lines.add('apps:');
  for (final (name, map) in apps) {
    lines.add('  $name:');
    fields(lines, map, '    ');
  }
  return '${lines.join('\n')}\n';
}
