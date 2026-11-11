/// The `wincode` command (ADR-0013).
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:wincode_core/wincode_core.dart';

import 'src/config.dart';
import 'src/credentials.dart';
import 'src/failure.dart';
import 'src/init.dart';
import 'src/preflight.dart';
import 'src/redact.dart';
import 'src/select.dart';
import 'src/sign.dart';
import 'src/zsign.dart';

export 'src/config.dart'
    show
        WincodeConfig,
        WincodeSettings,
        Workflow,
        loadConfig,
        loadSettings,
        nameProblem,
        parseSettings,
        reservedNames;
export 'src/credentials.dart'
    show
        AscKeyFiles,
        ascOverrideVariable,
        distOverrideVariable,
        keysRoot,
        keysRootVariable,
        locateAscKeyFiles,
        noTokenReason,
        readAscKeyIds,
        resolveDistKey;
export 'src/failure.dart' show ExitCode, WincodeException;
export 'src/key_location.dart' show requireOutsideGit;
export 'src/init.dart' show ReadLine;
export 'src/preflight.dart' show AscConnect;
export 'src/redact.dart' show Redactor, runsInCi;
export 'src/sign.dart' show permits, signingEntitlements;
export 'src/zsign.dart'
    show
        StartProcess,
        ZsignEnd,
        ZsignRunner,
        distroVariable,
        parseWslList,
        zsignCommit,
        zsignPath,
        zsignSourceSha256,
        zsignStateFile,
        zsignVersion;

/// The commands that ADR-0013 designs and later phases implement: name, summary, arguments and phase.
const _planned = [
  (
    'build',
    "Build the unsigned IPA on the app's macOS runner (GitHub Actions) and download it.",
    '',
    5,
  ),
  (
    'upload',
    'Upload the signed IPA to App Store Connect and wait for its processing.',
    '[<signed .ipa>]',
    4,
  ),
  (
    'status',
    "Show the state of the app's latest uploads in App Store Connect. Read-only.",
    '',
    4,
  ),
];

/// Runs `wincode` with [args] and returns its exit code, one of [ExitCode].
///
/// Reports and `--help` go to [out], errors to [err]. With `--json`, [out] gets one JSON object when the command ends
/// and nothing else. Everything printed passes through a [Redactor], which is active with `--redact` or when [environment]
/// (default: the process's) sets `CI`.
///
/// [clock] (default: the system's), [connect] (default: App Store Connect), [workingDirectory] (default: the current
/// folder), [readLine] and [terminal] (default: standard input), [run] (default: starts the program) and [zsign]
/// (default: runs zsign through `wsl.exe`) are there for tests.
Future<int> runWincode(
  List<String> args,
  StringSink out,
  StringSink err, {
  Map<String, String>? environment,
  DateTime Function()? clock,
  AscConnect connect = connectToApple,
  Directory? workingDirectory,
  ReadLine? readLine,
  bool? terminal,
  RunProcess run = runProcess,
  ZsignRunner? zsign,
}) async {
  environment ??= Platform.environment;
  // A usage error comes before the arguments are parsed, so the flags can only be looked up in the list itself.
  final flags = args.takeWhile((a) => a != '--');
  var json = flags.contains('--json');
  var verbose = flags.contains('--verbose');
  final redactor = Redactor.forRun(
    flag: flags.contains('--redact'),
    environment: environment,
  );
  out = redactor.sink(out);
  err = redactor.sink(err);
  final runner = _Wincode(
    out,
    _Doctor(out, err, environment, redactor, run),
    _Preflight(
      out,
      err,
      environment,
      redactor,
      clock ?? DateTime.now,
      connect,
      run,
    ),
    _Init(
      out,
      err,
      environment,
      redactor,
      clock ?? DateTime.now,
      workingDirectory ?? Directory.current,
      readLine ?? stdin.readLineSync,
      terminal ?? stdin.hasTerminal,
    ),
    _Sign(
      out,
      err,
      environment,
      redactor,
      clock ?? DateTime.now,
      connect,
      run,
      zsign ?? ZsignRunner(),
    ),
  );
  var command = '';

  int report(WincodeException e) {
    err.writeln(e.describe(command.isEmpty ? 'wincode' : 'wincode $command'));
    if (json) {
      out.writeln(
        jsonEncode({
          if (command.isNotEmpty) 'command': command,
          'ok': false,
          'exitCode': e.exitCode.code,
          'error': e.toJson(),
        }),
      );
    }
    return e.exitCode.code;
  }

  try {
    if (args.isEmpty) {
      runner.usageException('Give a command.');
    }
    final results = runner.parse(args);
    json = results.flag('json');
    verbose = results.flag('verbose');
    command = results.command?.name ?? '';
    return await runner.runCommand(results) ?? ExitCode.ok.code;
  } on UsageException catch (e) {
    err
      ..writeln(e.message)
      ..writeln()
      ..writeln(e.usage);
    if (json) {
      out.writeln(
        jsonEncode({
          'ok': false,
          'exitCode': ExitCode.usage.code,
          'error': {'id': 'usage', 'what': e.message},
        }),
      );
    }
    return ExitCode.usage.code;
  } on WincodeException catch (e) {
    return report(e);
  } catch (e, stack) {
    if (verbose) {
      err.writeln(stack);
    }
    return report(
      WincodeException(
        ExitCode.internal,
        'internal',
        // The message is meant to be pasted into an issue.
        redactor.forReport('internal error: $e'),
        why: 'this is a bug in winCode.',
        next:
            'report it at https://github.com/wincode-org/wincode/issues with the command line and this message'
            '${verbose ? '' : ', and the stack trace that --verbose prints'}.',
      ),
    );
  }
}

class _Wincode extends CommandRunner<int> {
  _Wincode(
    this.out,
    _Doctor doctor,
    _Preflight preflight,
    _Init init,
    _Sign sign,
  ) : super(
        'wincode',
        'Build, sign and upload Flutter iOS apps from Windows.',
      ) {
    argParser
      ..addOption(
        'config',
        valueHelp: 'file',
        defaultsTo: 'wincode.yaml',
        help: "The app's settings: bundle ID, team ID, profile, entitlements, CI workflow, output folder. No secrets.",
      )
      ..addOption(
        'app',
        valueHelp: 'name',
        help:
            'The app that the command works on, when wincode.yaml has an apps: map. Needed when it has several '
            '(ADR-0014).',
      )
      ..addFlag(
        'all',
        negatable: false,
        help:
            'Run preflight or doctor for every app in wincode.yaml, one after another, and print a summary table. '
            'Refused by commands that write.',
      )
      ..addFlag(
        'json',
        negatable: false,
        help: 'Print one JSON object on stdout when the command ends, and the messages on stderr.',
      )
      ..addFlag(
        'redact',
        negatable: false,
        help: 'Hide the bundle ID and team ID in everything printed. Always on when the CI variable is set.',
      )
      ..addFlag(
        'verbose',
        negatable: false,
        help: 'Also print each step, external command and HTTP request, with secrets redacted.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Send, write and run nothing, and print what would be done.',
      );
    for (final (name, summary, arguments, phase) in _planned) {
      addCommand(_NotImplemented(out, name, summary, arguments, phase));
    }
    addCommand(doctor);
    addCommand(preflight);
    addCommand(init);
    addCommand(sign);
  }

  final StringSink out;

  @override
  String get usageFooter => '''
Global options go before or after the command.

Exit codes:
  0   done
  1   failed: a check found a problem, an input is wrong, or Apple or GitHub refused the work
  64  usage error, or not implemented yet
  69  a tool, the SDK or the network is missing
  70  a bug in winCode
  77  Apple or GitHub refused the credentials
  78  wincode.yaml or an environment variable is wrong''';

  @override
  void printUsage() => out.writeln(usage);
}

abstract class _Command extends Command<int> {
  _Command(this.out);

  final StringSink out;

  /// Whether `--json` was given. Not called `json`: inside a subclass, that name finds `dart:convert`'s codec first.
  bool get jsonOutput => globalResults!.flag('json');

  @override
  void printUsage() => out.writeln(usage);
}

/// A command of ADR-0013 that a later phase implements.
class _NotImplemented extends _Command {
  _NotImplemented(
    super.out,
    this.name,
    String summary,
    this._arguments,
    int phase,
  ) : description =
          '$summary\n\nNot implemented yet, see ADR-0013 (phase $phase).';

  @override
  final String name;

  @override
  final String description;

  final String _arguments;

  @override
  String get invocation =>
      'wincode $name${_arguments.isEmpty ? '' : ' $_arguments'}';

  @override
  Never run() {
    final reason = writesOf[name];
    if (reason != null && globalResults!.flag('all')) {
      refuseAll(name, reason);
    }
    checkAppOptions(
      app: globalResults!.option('app'),
      all: globalResults!.flag('all'),
    );
    throw const WincodeException(
      ExitCode.usage,
      'not-implemented',
      'not implemented yet, see ADR-0013',
    );
  }
}

class _Doctor extends _Command {
  _Doctor(
    super.out,
    this.err,
    this.environment,
    this.redactor,
    this.runProcess,
  ) {
    argParser
      ..addOption(
        'binary',
        valueHelp: 'Mach-O file',
        help: 'The binary to check, such as Payload/Runner.app/Runner.',
      )
      ..addOption(
        'sdk',
        valueHelp: 'iPhoneOS.sdk folder',
        help: "Check the binary against the SDK's text stubs. Fails on a library or binding that its minimum OS lacks.",
      )
      ..addOption(
        'reference',
        valueHelp: 'Mach-O file',
        help: 'List how the binary differs from a reference build, such as an Xcode-built copy. This does not fail.',
      )
      ..addFlag(
        'sign',
        negatable: false,
        help:
            'Also check what wincode sign needs: WSL2 version 2, the pinned zsign and its recorded SHA-256 (recorded '
            'by the first check that finds it), and where the distribution key is.',
      );
  }

  final StringSink err;
  final Map<String, String> environment;
  final Redactor redactor;
  final RunProcess runProcess;

  @override
  final name = 'doctor';

  @override
  final description =
      'Check the setup, or a Mach-O binary against the SDK or a reference build.\n\n'
      'Without options, doctor checks the setup of the app in wincode.yaml and sends nothing: that the file loads, '
      'and that the app\'s App Store Connect key is where its credentials say (a folder with one AuthKey_<Key ID>.p8 '
      'and an issuer-id, outside git working trees and OneDrive). With --sign, it also checks WSL2, the pinned zsign '
      '$zsignVersion (${zsignCommit.substring(0, 8)}), whose build commands it prints, and where the distribution '
      'key is; the first check that finds zsign records its SHA-256 outside the repository, and wincode sign runs '
      'only that binary. To check a binary, give --binary and at least one of --sdk and --reference.';

  @override
  bool get takesArguments => false;

  @override
  Future<int> run() async {
    final binary = argResults!.option('binary');
    final sdk = argResults!.option('sdk');
    final reference = argResults!.option('reference');
    if (binary == null && sdk == null && reference == null) {
      if (argResults!.flag('sign') && globalResults!.flag('dry-run')) {
        usageException(
          'doctor --sign runs read-only commands in WSL2 and records the SHA-256 of zsign; it has no --dry-run.',
        );
      }
      return _setup();
    }
    if (argResults!.flag('sign')) {
      usageException(
        '--sign checks the setup. The binary checks read no settings.',
      );
    }
    if (globalResults!.option('app') != null || globalResults!.flag('all')) {
      usageException(
        '--app and --all choose the app of the setup check. The binary checks read no settings.',
      );
    }
    if (binary == null || (sdk == null && reference == null)) {
      usageException(
        'Give --binary and at least one of --sdk and --reference.',
      );
    }
    final file = _read(binary);
    final lines = <String>[];
    final result = <String, List<String>>{};
    var failed = false;
    if (sdk != null) {
      if (!File('$sdk/SDKSettings.json').existsSync()) {
        throw WincodeException(
          ExitCode.unavailable,
          'sdk-missing',
          '$sdk is not an iPhoneOS SDK folder: it has no SDKSettings.json',
          why:
              '--sdk names the iPhoneOS.sdk that `xtool sdk` builds in WSL2 from your own Xcode.xip. winCode ships no '
              'SDK files.',
          next:
              r'build it with tools/setup-wsl-toolchain.sh in WSL2, then pass \\wsl.localhost\<distribution>\home\<user>'
              r'\.swiftpm\swift-sdks\darwin.artifactbundle\Developer\Platforms\iPhoneOS.platform\Developer\SDKs'
              r'\iPhoneOS.sdk',
        );
      }
      final violations = _about(
        binary,
        () => checkAgainstSdk(file, Directory(sdk)),
      );
      result['violations'] = [for (final v in violations) '$v'];
      lines
        ..add(
          '${violations.length} violation(s) of the minimum OS ${file.buildVersion!.minOS} in $binary',
        )
        ..addAll(result['violations']!.map((v) => '  $v'));
      failed = violations.isNotEmpty;
    }
    if (reference != null) {
      final differences = diffMachO(file, _read(reference));
      result['differences'] = differences;
      lines
        ..add('${differences.length} difference(s) from $reference')
        ..addAll(differences.map((d) => '  $d'));
    }
    final code = failed ? ExitCode.failed : ExitCode.ok;
    if (jsonOutput) {
      out.writeln(
        jsonEncode({
          'command': name,
          'ok': !failed,
          'exitCode': code.code,
          ...result,
        }),
      );
    } else {
      lines.forEach(out.writeln);
    }
    return code.code;
  }
}

extension on _Doctor {
  /// The setup check (ADR-0014, section 3): the settings, and where the App Store Connect key is of each app that the
  /// command names. Sends nothing and reads no key: it checks that the folder holds one `AuthKey_<Key ID>.p8` and an
  /// `issuer-id` with an Issuer ID, and that they lie where the rules allow.
  Future<int> _setup() async {
    final all = globalResults!.flag('all');
    final path = globalResults!.option('config')!;
    final report = jsonOutput ? err : out;
    final WincodeSettings settings;
    try {
      settings = loadSettings(path, redactor: redactor);
    } on WincodeException catch (e) {
      final findings = [Finding.fail('settings', e)];
      writeReport(findings, report, command: 'doctor');
      if (jsonOutput) {
        out.writeln(jsonEncode(jsonOf(findings, command: 'doctor')));
      }
      return exitCodeOf(findings).code;
    }
    final apps = selectApps(
      settings,
      path: path,
      app: globalResults!.option('app'),
      all: all,
      readOnly: true,
      redactor: redactor,
    );
    Future<AppOutcome> one(WincodeConfig app) async {
      final findings = [const Finding.pass('settings', 'wincode.yaml loads')];
      try {
        final key = await locateAscKeyFiles(
          app,
          environment: environment,
          redactor: redactor,
          run: this.runProcess,
        );
        readAscKeyIds(key!, redactor);
        findings.add(
          const Finding.pass(
            'credentials',
            'the App Store Connect key folder holds one AuthKey_<Key ID>.p8 and an issuer-id, outside git working trees '
                'and OneDrive',
          ),
        );
      } on WincodeException catch (e) {
        findings.add(Finding.fail('credentials', e));
      }
      if (argResults!.flag('sign')) {
        findings.addAll(
          await signSetupFindings(
            app,
            environment: environment,
            redactor: redactor,
            run: this.runProcess,
            log: globalResults!.flag('verbose') ? err.writeln : null,
          ),
        );
      }
      writeReport(findings, report, command: 'doctor');
      final code = exitCodeOf(findings).code;
      return (
        app: app,
        code: code,
        firstFailure: findings
            .where((f) => f.status == 'FAIL')
            .firstOrNull
            ?.problem
            ?.id,
        json: {...jsonOf(findings, command: 'doctor', app: app.name)}
          ..remove('command'),
      );
    }

    if (!all) {
      final outcome = await one(apps.single);
      if (jsonOutput) {
        out.writeln(jsonEncode({'command': name, ...outcome.json}));
      }
      return outcome.code;
    }
    final outcomes = <AppOutcome>[];
    for (final (i, app) in apps.indexed) {
      if (i > 0) {
        report.writeln();
      }
      report.writeln('== ${app.name ?? path} ==');
      outcomes.add(await one(app));
    }
    report
      ..writeln()
      ..writeln(summaryTable(outcomes, redactor))
      ..writeln(summaryLine(name, path, outcomes));
    if (jsonOutput) {
      out.writeln(jsonEncode(allJson(name, outcomes)));
    }
    return combinedCode(outcomes);
  }
}

class _Init extends _Command {
  _Init(
    super.out,
    this.err,
    this.environment,
    this.redactor,
    this.clock,
    this.workingDirectory,
    this.readLine,
    this.terminal,
  ) {
    argParser
      ..addOption(
        'bundle-id',
        valueHelp: 'id',
        help: "The app's bundle ID. Default: read from ios/Runner.xcodeproj.",
      )
      ..addOption(
        'team-id',
        valueHelp: 'id',
        help: 'The team ID (10 capital letters and digits). Default: from the profile or the Xcode project.',
      )
      ..addOption(
        'profile',
        valueHelp: 'file',
        help: 'The App Store profile (.mobileprovision). It must lie outside git working trees, or be ignored by git.',
      )
      ..addOption(
        'profile-dir',
        valueHelp: 'folder',
        help: 'A folder to list the App Store profiles of this app in. Nothing else is searched.',
      )
      ..addOption(
        'entitlements',
        valueHelp: 'file',
        help: 'The .entitlements file. Default: the one of the Xcode project.',
      )
      ..addOption(
        'workflow-ref',
        valueHelp: 'ref',
        help: 'The CI workflow for wincode build: <owner>/<repository>/.github/workflows/<file>@<branch or tag>.',
      )
      ..addOption(
        'output',
        valueHelp: 'folder',
        help: 'Where the IPAs go (default build/wincode).',
      )
      ..addOption(
        'flavor',
        valueHelp: 'name',
        help: 'The Flutter flavor of the app: read the Release-<name> configuration of the Xcode project, the App Store build, and record the flavor. Can be combined with --configuration.',
      )
      ..addOption(
        'configuration',
        valueHelp: 'name',
        help: 'Read exactly this build configuration of the Xcode project, such as Release-demo, and do not compare Debug and Profile with it. With --flavor it overrides the default Release-<name>.',
      )
      ..addOption(
        'credentials',
        valueHelp: 'name',
        help: 'The credentials reference of the app: the folder of your keys folder that holds its keys. Required for an app of a file of apps.',
      )
      ..addFlag(
        'workflow',
        negatable: false,
        help: 'Copy the reference workflow to .github/workflows/wincode-ios.yml. It never replaces a file.',
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Ask nothing: accept what init found.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Replace an existing wincode.yaml.',
      );
  }

  final StringSink err;
  final Map<String, String> environment;
  final Redactor redactor;
  final DateTime Function() clock;
  final Directory workingDirectory;
  final ReadLine readLine;
  final bool terminal;

  @override
  final name = 'init';

  @override
  final description =
      'Write wincode.yaml for the Flutter project in this folder.\n\n'
      'init reads ios/Runner.xcodeproj for the bundle ID and the entitlements, and the .mobileprovision files of a folder '
      'that you name, shows what it found, and asks you to confirm each value. It never writes a key or the key folder '
      '(WINCODE_ASC_KEY_DIR), and it never edits .gitignore.\n\n'
      'It asks only at a terminal. In CI (the CI variable), with --yes or with --json it asks nothing: give every field '
      'as an option, or --yes to accept what it found. Without --force it does not replace a wincode.yaml.\n\n'
      'With --app <name> it adds that app to a file of apps (or starts one), or updates its entry in place, keeping the '
      'comments and the layout of the rest, after showing the changes and asking you to confirm (--yes where it cannot '
      'ask); a value that the entry already has is replaced only with --force. On a flat wincode.yaml, --app moves the '
      'file under apps: as the app that it describes, keeps the original as wincode.yaml.bak, and needs a yes too '
      '(ADR-0014). After a write, init loads the file again and puts the old one back if it does not load.';

  @override
  Future<int> run() async {
    if (globalResults!.flag('all')) {
      refuseAll(name, writesOf[name]!);
    }
    checkAppOptions(
      app: globalResults!.option('app'),
      all: globalResults!.flag('all'),
    );
    final yes = argResults!.flag('yes');
    final interactive =
        !yes && !jsonOutput && !runsInCi(environment) && terminal;
    final report = jsonOutput ? err : out;
    final result = await Initializer(
      options: InitOptions(
        config: globalResults!.wasParsed('config')
            ? globalResults!.option('config')
            : null,
        bundleId: argResults!.option('bundle-id'),
        teamId: argResults!.option('team-id'),
        profile: argResults!.option('profile'),
        profileDir: argResults!.option('profile-dir'),
        entitlements: argResults!.option('entitlements'),
        workflowRef: argResults!.option('workflow-ref'),
        output: argResults!.option('output'),
        flavor: argResults!.option('flavor'),
        configuration: argResults!.option('configuration'),
        app: globalResults!.option('app'),
        credentials: argResults!.option('credentials'),
        yes: yes,
        force: argResults!.flag('force'),
        copyWorkflow: argResults!.flag('workflow'),
        dryRun: globalResults!.flag('dry-run'),
      ),
      cwd: workingDirectory,
      redactor: redactor,
      report: report,
      readLine: readLine,
      interactive: interactive,
      clock: clock,
    ).execute();
    if (jsonOutput) {
      out.writeln(jsonEncode(result));
    }
    return ExitCode.ok.code;
  }
}

class _Preflight extends _Command {
  _Preflight(
    super.out,
    this.err,
    this.environment,
    this.redactor,
    this.clock,
    this.connect,
    this.runProcess,
  );

  final StringSink err;
  final Map<String, String> environment;
  final Redactor redactor;
  final DateTime Function() clock;
  final AscConnect connect;
  final RunProcess runProcess;

  @override
  final name = 'preflight';

  @override
  final description =
      'Check the signed IPA and App Store Connect before an upload. Read-only.\n\n'
      'On this PC: the API key and the profile lie outside git working trees, the profile in wincode.yaml, and the '
      'IPA (signed.ipa in the output folder by default) with its bundle ID, version, build number and signature. In '
      "App Store Connect, with GET requests only: the key works, the app record exists, the build number is above every "
      "existing build's, and the App ID has an active App Store profile.\n\n"
      'The API key is read from the folder that WINCODE_ASC_KEY_DIR names: AuthKey_<Key ID>.p8 and issuer-id.';

  @override
  String get invocation => 'wincode preflight [<signed .ipa>]';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length > 1) {
      usageException('Give at most one IPA.');
    }
    final all = globalResults!.flag('all');
    if (all && rest.isNotEmpty) {
      usageException(
        '--all checks the signed.ipa in the output folder of each app: do not name an IPA.',
      );
    }
    final path = globalResults!.option('config')!;
    final settings = loadSettings(path, redactor: redactor);
    final apps = selectApps(
      settings,
      path: path,
      app: globalResults!.option('app'),
      all: all,
      readOnly: true,
      redactor: redactor,
    );
    // With --json, stdout carries the JSON object only.
    final report = jsonOutput ? err : out;
    if (!all) {
      final outcome = await _one(apps.single, rest.firstOrNull, report);
      if (jsonOutput) {
        out.writeln(jsonEncode({'command': name, ...outcome.json}));
      }
      return outcome.code;
    }
    final outcomes = <AppOutcome>[];
    for (final (i, app) in apps.indexed) {
      if (i > 0) {
        report.writeln();
      }
      report.writeln('== ${app.name ?? path} ==');
      outcomes.add(await _one(app, null, report));
    }
    report
      ..writeln()
      ..writeln(summaryTable(outcomes, redactor))
      ..writeln(summaryLine(name, path, outcomes));
    if (jsonOutput) {
      out.writeln(jsonEncode(allJson(name, outcomes)));
    }
    return combinedCode(outcomes);
  }

  /// Checks [app]: its report goes to [report], and its object for `--json` (without `command`) comes back.
  Future<AppOutcome> _one(
    WincodeConfig app,
    String? ipa,
    StringSink report,
  ) async {
    final preflight = Preflight(
      config: app,
      ipa: File(ipa ?? '${app.output.path}${Platform.pathSeparator}signed.ipa'),
      environment: environment,
      redactor: redactor,
      clock: clock,
      connect: connect,
      log: globalResults!.flag('verbose') ? err.writeln : null,
      run: runProcess,
    );
    final List<Finding> findings;
    if (globalResults!.flag('dry-run')) {
      final dry = await preflight.dryRun();
      if (dry.failures.isEmpty) {
        for (final request in dry.requests) {
          report
            ..writeln(request)
            ..writeln('    Authorization: Bearer <${dry.authorization}>');
        }
        return (
          app: app,
          code: ExitCode.ok.code,
          firstFailure: null,
          json: {
            'app': app.name,
            'ok': true,
            'exitCode': ExitCode.ok.code,
            'dryRun': true,
            'requests': dry.requests,
          },
        );
      }
      findings = dry.failures;
    } else {
      findings = await preflight.check();
    }
    writeReport(findings, report);
    return (
      app: app,
      code: exitCodeOf(findings).code,
      firstFailure: findings
          .where((f) => f.status == 'FAIL')
          .firstOrNull
          ?.problem
          ?.id,
      json: {...jsonOf(findings, app: app.name)}..remove('command'),
    );
  }
}

class _Sign extends _Command {
  _Sign(
    super.out,
    this.err,
    this.environment,
    this.redactor,
    this.clock,
    this.connect,
    this.runProcess,
    this.zsign,
  ) {
    argParser
      ..addFlag(
        'offline',
        negatable: false,
        help:
            'Do not ask App Store Connect whether the certificate is still a valid distribution certificate. The run '
            'warns that it was not asked.',
      )
      ..addFlag(
        'verify-only',
        negatable: false,
        help:
            'Sign nothing: check the signatures of a signed IPA (signed.ipa in the output folder by default) against '
            'the profile, the certificate of the distribution key and the entitlements, then run preflight\'s local '
            'checks. Needs no WSL2 and no network.',
      );
  }

  final StringSink err;
  final Map<String, String> environment;
  final Redactor redactor;
  final DateTime Function() clock;
  final AscConnect connect;
  final RunProcess runProcess;
  final ZsignRunner zsign;

  @override
  final name = 'sign';

  @override
  final description =
      'Sign the IPA for the App Store with zsign in WSL2, and check the result (ADR-0013, phase 3a).\n\n'
      'Before zsign runs: the unsigned IPA (unsigned.ipa in the output folder by default) holds the app of '
      'wincode.yaml in Payload/ only, without extensions; the profile is an App Store profile of the team and app, '
      'not expired; the distribution key, found through the app\'s credentials (or WINCODE_DIST_KEY for a file '
      'without them), is an unencrypted RSA PEM key whose certificate is in the profile, an Apple Distribution '
      'certificate of the team that has not expired and that App Store Connect still lists; and the entitlements '
      'are allowed by the profile. zsign then reads the key in place through wslpath and never gets a password. '
      'After it: every signature is checked and preflight\'s local checks run, and only then is the IPA moved to '
      'signed.ipa in the output folder. Its temporary files there are deleted whatever happens.';

  @override
  String get invocation => 'wincode sign [<unsigned .ipa>]';

  @override
  Future<int> run() async {
    if (globalResults!.flag('all')) {
      refuseAll(name, writesOf[name]!);
    }
    final rest = argResults!.rest;
    if (rest.length > 1) {
      usageException('Give at most one IPA.');
    }
    final path = globalResults!.option('config')!;
    final settings = loadSettings(path, redactor: redactor);
    final app = selectApps(
      settings,
      path: path,
      app: globalResults!.option('app'),
      all: false,
      readOnly: false,
      redactor: redactor,
    ).single;
    final signer = Signer(
      config: app,
      environment: environment,
      redactor: redactor,
      clock: clock,
      connect: connect,
      run: runProcess,
      runner: zsign,
      log: globalResults!.flag('verbose') ? err.writeln : null,
    );
    final verifyOnly = argResults!.flag('verify-only');
    final findings = verifyOnly
        ? await signer.verify(rest.isEmpty ? signer.output : File(rest.single))
        : await signer.sign(
            rest.isEmpty ? signer.defaultInput : File(rest.single),
            offline: argResults!.flag('offline'),
            dryRun: globalResults!.flag('dry-run'),
          );
    // With --json, stdout carries the JSON object only.
    writeReport(findings, jsonOutput ? err : out, command: name);
    if (jsonOutput) {
      out.writeln(
        jsonEncode({
          ...jsonOf(findings, command: name, app: app.name),
          if (verifyOnly) 'verifyOnly': true,
        }),
      );
    }
    return exitCodeOf(findings).code;
  }
}

MachO _read(String path) {
  try {
    return _about(path, () => readMachO(File(path).readAsBytesSync()));
  } on FileSystemException catch (e) {
    throw WincodeException(
      ExitCode.failed,
      'unreadable',
      'cannot read $path: ${e.osError?.message ?? e.message}',
      why: 'doctor reads the files that --binary and --reference name.',
      next: r'check the path. From Windows, a file inside WSL2 is \\wsl.localhost\<distribution>\<its Linux path>.',
    );
  }
}

/// Runs [work], naming [path] in the message of a [FormatException] it throws.
T _about<T>(String path, T Function() work) {
  try {
    return work();
  } on FormatException catch (e) {
    throw WincodeException(
      ExitCode.failed,
      'unreadable',
      '$path: ${e.message}',
      why:
          "doctor reads an iOS app's 64-bit Mach-O files, with LC_BUILD_VERSION and chained fixups, and the SDK's "
          'text stubs.',
      next:
          'give a binary from inside the app bundle, such as Payload/Runner.app/Runner, and the SDK that '
          '`xtool sdk` built.',
    );
  }
}
