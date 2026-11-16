/// The `wincode` command (ADR-0013).
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:wincode_core/wincode_core.dart';

import 'src/build.dart';
import 'src/build_number.dart' show isDottedNumber;
import 'src/build_run.dart';
import 'src/config.dart';
import 'src/credentials.dart';
import 'src/events.dart';
import 'src/failure.dart';
import 'src/github.dart';
import 'src/init.dart';
import 'src/preflight.dart';
import 'src/redact.dart';
import 'src/select.dart';
import 'src/sign.dart';
import 'src/upload.dart';
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
export 'src/github.dart'
    show
        GithubClient,
        GithubConnect,
        GithubException,
        GithubFailure,
        HttpGithubClient,
        githubApiVersion,
        githubTokenVariable;
export 'src/key_location.dart' show requireOutsideGit;
export 'src/key_permissions.dart' show KeyTarget, makePrivate, requirePrivate;
export 'src/init.dart' show ReadLine;
export 'src/preflight.dart' show AscConnect;
export 'src/redact.dart' show Redactor, runsInCi;
export 'src/sign.dart' show permits, signingEntitlements;
export 'src/upload.dart' show defaultUploadTimeout;
export 'src/zsign.dart'
    show
        StartProcess,
        UnsupportedZsignRunner,
        WslZsignRunner,
        ZsignCommand,
        ZsignEnd,
        ZsignRunner,
        distroVariable,
        nativeStateKey,
        parseWslList,
        wincodeDataDirectory,
        zsignCommit,
        zsignPath,
        zsignRunnerFor,
        zsignSourceSha256,
        zsignStateFile,
        zsignVersion;
export 'src/zsign_native.dart' show NativeZsignRunner, nativeZsignPath;

/// The commands that ADR-0013 designs and later phases implement: name, summary, arguments and phase.
const _planned = [
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
/// [clock] (default: the system's), [connect] (default: App Store Connect), [connectGithub] (default: GitHub's API at
/// api.github.com; only tests connect to a fake server), [workingDirectory] (default: the current
/// folder), [readLine] and [terminal] (default: standard input, which is a terminal only if it can be read), [run]
/// (default: starts the program), [zsign] (default: the runner for [platform], which runs zsign through `wsl.exe` on
/// Windows and directly on Linux),
/// [platform] (default: `Platform.operatingSystem`), [pollInterval] (default: 30 s, how often `upload` asks Apple for
/// the state of the processing and `build` asks GitHub for the state of the run), [sleep] (default: waits), [interrupts]
/// (default: Ctrl-C, and SIGTERM where there is one) and [answer] (default: the next line of standard input, which a
/// signal can also answer; the question of `build`) are there for tests.
Future<int> runWincode(
  List<String> args,
  StringSink out,
  StringSink err, {
  Map<String, String>? environment,
  DateTime Function()? clock,
  AscConnect connect = connectToApple,
  GithubConnect connectGithub = connectToGithub,
  Directory? workingDirectory,
  ReadLine? readLine,
  bool? terminal,
  RunProcess run = runProcess,
  ZsignRunner? zsign,
  String? platform,
  Duration pollInterval = const Duration(seconds: 30),
  Future<void> Function(Duration)? sleep,
  Stream<ProcessSignal> Function()? interrupts,
  Future<String?> Function()? answer,
}) async {
  environment ??= Platform.environment;
  zsign ??= zsignRunnerFor(
    platform ?? Platform.operatingSystem,
    environment: environment,
    runTool: run,
  );
  // A terminal whose line mode cannot be read is no terminal: asking there would end in "The handle is invalid".
  final atTerminal = terminal ?? stdinIsTerminal();
  // A usage error comes before the arguments are parsed, so the flags can only be looked up in the list itself.
  final flags = args.takeWhile((a) => a != '--');
  var json = flags.contains('--json');
  var events = flags.contains('--events');
  var verbose = flags.contains('--verbose');
  final redactor = Redactor.forRun(
    flag: flags.contains('--redact'),
    environment: environment,
  );
  out = redactor.sink(out);
  err = redactor.sink(err);
  final runner = _Wincode(
    out,
    _Doctor(
      out,
      err,
      environment,
      redactor,
      run,
      zsign,
      clock ?? DateTime.now,
      connect,
      connectGithub,
    ),
    _Build(
      out,
      err,
      environment,
      redactor,
      clock ?? DateTime.now,
      connect,
      connectGithub,
      run,
      answer,
      atTerminal,
      pollInterval,
      sleep ?? Future<void>.delayed,
      interrupts ?? systemInterrupts,
    ),
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
      atTerminal,
    ),
    _Sign(
      out,
      err,
      environment,
      redactor,
      clock ?? DateTime.now,
      connect,
      run,
      zsign,
    ),
    _Upload(
      out,
      err,
      environment,
      redactor,
      clock ?? DateTime.now,
      connect,
      run,
      readLine ?? stdin.readLineSync,
      atTerminal,
      pollInterval,
    ),
  );
  var command = '';

  int report(WincodeException e) {
    err.writeln(e.describe(command.isEmpty ? 'wincode' : 'wincode $command'));
    if (json || events) {
      out.writeln(
        jsonEncode({
          if (!json) 'event': 'result',
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
    events =
        results.command?.options.contains('events') == true &&
        results.command!.flag('events');
    return await runner.runCommand(results) ?? ExitCode.ok.code;
  } on UsageException catch (e) {
    err
      ..writeln(e.message)
      ..writeln()
      ..writeln(e.usage);
    if (json || events) {
      out.writeln(
        jsonEncode({
          if (!json) 'event': 'result',
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
    _Build build,
    _Preflight preflight,
    _Init init,
    _Sign sign,
    _Upload upload,
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
    addCommand(build);
    addCommand(preflight);
    addCommand(init);
    addCommand(sign);
    addCommand(upload);
  }

  final StringSink out;

  @override
  String get usageFooter => '''
Global options go before or after the command.

Exit codes:
  0   done
  1   failed: a check found a problem, an input is wrong, or Apple or GitHub refused the work
  64  usage error, or not implemented yet
  65  upload: Apple took the IPA and then failed its processing
  69  a tool, the SDK or the network is missing
  70  a bug in winCode
  75  upload or build: Apple had not finished processing, or the run was still going, when winCode stopped waiting (--timeout)
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

  /// Adds `--events` to the command (ADR-0015, section 9). `build`, `sign` and `upload` take it. With [asks], the
  /// command asks a question, which then needs `--yes`.
  void addEventsFlag({bool asks = false}) => argParser.addFlag(
    'events',
    negatable: false,
    help:
        'Write progress as JSON lines on stdout, one event each as it happens, and the result as the last line: the '
        'object that --json prints, with "event": "result". The messages for people go to stderr.'
        '${asks ? ' The question needs --yes, as with --json.' : ''} Cannot be combined with --json.',
  );

  /// Whether `--events` was given. Only a command that called [addEventsFlag] may ask.
  bool get eventsOutput => argResults!.flag('events');

  /// `--timeout`: minutes, or seconds with an `s`.
  Duration timeoutOf(String text) {
    final match = RegExp(r'^(\d+)(s?)$').firstMatch(text.trim());
    final n = int.tryParse(match?[1] ?? '');
    if (match == null || n == null || n == 0) {
      usageException(
        '--timeout is a number of minutes, such as 20, or of seconds with an s, such as 90s: got $text',
      );
    }
    return match[2] == 's' ? Duration(seconds: n) : Duration(minutes: n);
  }

  /// Refuses `--events` together with `--json`: stdout would then have two shapes.
  void checkEventsOption() {
    if (eventsOutput && jsonOutput) {
      usageException(
        '--events and --json cannot be given together: --json prints one object when the command ends, and --events '
        'prints one object per line as it runs, ending with that same object.',
      );
    }
  }

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
    this.zsign,
    this.clock,
    this.connect,
    this.connectGithub,
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
            'Also check what wincode sign needs: on Windows WSL2 version 2, on Linux nothing but zsign itself; the '
            'pinned zsign and its recorded SHA-256 (recorded by the first check that finds it), and where the '
            'distribution key is.',
      )
      ..addFlag(
        'build',
        negatable: false,
        help:
            'Also make every check that wincode build makes before it starts a run, with real reads of GitHub and, for '
            'the build number, of App Store Connect, and start nothing (ADR-0015, section 10).',
      );
  }

  final StringSink err;
  final Map<String, String> environment;
  final Redactor redactor;
  final RunProcess runProcess;
  final ZsignRunner zsign;
  final DateTime Function() clock;
  final AscConnect connect;
  final GithubConnect connectGithub;

  @override
  final name = 'doctor';

  @override
  final description =
      'Check the setup, or a Mach-O binary against the SDK or a reference build.\n\n'
      'Without options, doctor checks the setup of the app in wincode.yaml and sends nothing: that the file loads, '
      'and that the app\'s App Store Connect key is where its credentials say (a folder with one AuthKey_<Key ID>.p8 '
      'and an issuer-id, outside git working trees and OneDrive, and on Linux closed to other users). With --sign, it '
      'also checks WSL2 on Windows, the pinned zsign $zsignVersion (${zsignCommit.substring(0, 8)}), whose build '
      'commands it prints, and where the distribution key is; the first check that finds zsign records its SHA-256 '
      'outside the repository, and wincode sign runs only that binary. To check a binary, give --binary and at least '
      'one of --sdk and --reference.';

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
          'doctor --sign runs read-only commands (in WSL2 on Windows) and records the SHA-256 of zsign; it has no --dry-run.',
        );
      }
      if (argResults!.flag('build') && globalResults!.flag('dry-run')) {
        usageException(
          'doctor --build reads GitHub, and App Store Connect for the build number; it has no --dry-run. wincode build '
          '--dry-run prints the plan without any request.',
        );
      }
      return _setup();
    }
    if (argResults!.flag('sign') || argResults!.flag('build')) {
      usageException(
        '--sign and --build check the setup. The binary checks read no settings.',
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
          await zsign.setupFindings(
            app,
            redactor: redactor,
            log: globalResults!.flag('verbose') ? err.writeln : null,
          ),
        );
      }
      if (argResults!.flag('build')) {
        findings.addAll(
          (await BuildChecker(
            config: app,
            options: const BuildOptions(),
            environment: environment,
            redactor: redactor,
            clock: clock,
            github: connectGithub,
            connect: connect,
            run: this.runProcess,
            doctor: true,
            log: globalResults!.flag('verbose') ? err.writeln : null,
          ).check()).findings,
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
        help: 'Write the reference workflow to .github/workflows/wincode-ios.yml, or update the one there after a diff and a question, keeping its XCODE_APP, runs-on and timeout-minutes, with the old file kept as wincode-ios.yml.bak. Changes the workflow only (and adds flutter_version to wincode.yaml), and runs no git command.',
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
        help: 'Replace an existing wincode.yaml, or the wincode-ios.yml.bak of a workflow update.',
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
      '(ADR-0014). After a write, init loads the file again and puts the old one back if it does not load.\n\n'
      'With --workflow and no --app, a workflow that is already there is updated to the reference workflow: init shows the '
      'differences, asks [y/N] (--yes where it cannot ask), keeps the old file as wincode-ios.yml.bak, keeps its XCODE_APP, '
      'runs-on and timeout-minutes, and moves its FLUTTER_VERSION to flutter_version in wincode.yaml when that has none '
      '(ADR-0015). It writes no other file and runs no git command; pushing the workflow stays your step.';

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
    addEventsFlag();
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
            'the profile, the certificate that signed it (one of the profile\'s, and listed in App Store Connect '
            'unless --offline) and the entitlements, then run preflight\'s local checks. Needs no WSL2 and no '
            'private key.',
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
      'Sign the IPA for the App Store with zsign (in WSL2 on Windows, directly on Linux), and check the result '
      '(ADR-0013, phase 3a).\n\n'
      'Before zsign runs: the unsigned IPA (unsigned.ipa in the output folder by default) holds the app of '
      'wincode.yaml in Payload/ only, without extensions; the profile is an App Store profile of the team and app, '
      'not expired; the distribution key, found through the app\'s credentials (or WINCODE_DIST_KEY for a file '
      'without them), is an unencrypted RSA PEM key whose certificate is in the profile, an Apple Distribution '
      'certificate of the team that has not expired and that App Store Connect still lists; and the entitlements '
      'are allowed by the profile. On Linux the key and its folders must also be closed to other users (mode 0600 and '
      '0700). zsign then reads the key in place (through wslpath, in WSL2) and never gets a password. '
      'After it: every signature is checked and preflight\'s local checks run, and only then is the IPA moved to '
      'signed.ipa in the output folder. Its temporary files there are deleted whatever happens.';

  @override
  String get invocation => 'wincode sign [<unsigned .ipa>]';

  @override
  Future<int> run() async {
    if (globalResults!.flag('all')) {
      refuseAll(name, writesOf[name]!);
    }
    checkEventsOption();
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
    final events = eventsOutput ? EventWriter(out, clock, app: app.name) : null;
    final signer = Signer(
      config: app,
      environment: environment,
      redactor: redactor,
      clock: clock,
      connect: connect,
      run: runProcess,
      zsignRunner: zsign,
      log: globalResults!.flag('verbose') ? err.writeln : null,
      events: events,
    );
    final verifyOnly = argResults!.flag('verify-only');
    final offline = argResults!.flag('offline');
    final dryRun = globalResults!.flag('dry-run');
    final findings = verifyOnly
        ? await signer.verify(
            rest.isEmpty ? signer.output : File(rest.single),
            offline: offline,
            dryRun: dryRun,
          )
        : await signer.sign(
            rest.isEmpty ? signer.defaultInput : File(rest.single),
            offline: offline,
            dryRun: dryRun,
          );
    // With --json or --events, stdout carries the JSON only.
    writeReport(
      findings,
      jsonOutput || events != null ? err : out,
      command: name,
    );
    final result = {
      ...jsonOf(findings, command: name, app: app.name),
      if (verifyOnly) 'verifyOnly': true,
    };
    if (jsonOutput) {
      out.writeln(jsonEncode(result));
    }
    events?.result(result);
    return exitCodeOf(findings).code;
  }
}

class _Upload extends _Command {
  _Upload(
    super.out,
    this.err,
    this.environment,
    this.redactor,
    this.clock,
    this.connect,
    this.runProcess,
    this.readLine,
    this.terminal,
    this.pollInterval,
  ) {
    addEventsFlag(asks: true);
    argParser
      ..addOption(
        'ipa',
        valueHelp: 'file',
        help: 'The signed IPA to upload. Default: signed.ipa in the output folder of the app.',
      )
      ..addOption(
        'timeout',
        valueHelp: 'minutes',
        defaultsTo: '${defaultUploadTimeout.inMinutes}',
        help:
            "How long to wait for Apple's processing result after the upload: a number of minutes, such as 20, or of "
            'seconds with an s, such as 90s. When it passes, the exit code is 75 and the upload is not lost.',
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Do not ask for the name of the app. Needed in CI, with --json and without a terminal.',
      );
  }

  final StringSink err;
  final Map<String, String> environment;
  final Redactor redactor;
  final DateTime Function() clock;
  final AscConnect connect;
  final RunProcess runProcess;
  final ReadLine readLine;
  final bool terminal;
  final Duration pollInterval;

  @override
  final name = 'upload';

  @override
  final description =
      'Upload the signed IPA to App Store Connect and wait for its processing (ADR-0013, phase 4). The only command that '
      'writes to Apple.\n\n'
      'Every check runs first, and one that fails stops the command before a single upload request: the IPA (signed.ipa '
      'in the output folder by default) must be signed, its signatures must verify against the profile in wincode.yaml '
      'and a distribution certificate that App Store Connect lists, and its build number must be above every build the '
      'app has. Then it prints what it will send and asks you to type the name of the app (the bundle ID for a file '
      'without names); --yes skips that, and without a terminal, in CI or with --json, --yes is required.\n\n'
      'It then creates the build upload, sends the file in the parts that Apple names, marks it uploaded with its MD5, '
      'and asks for the state every 30 s until the build is valid or failed, or --timeout has passed. A build number '
      'that Apple has taken stays used, so nothing that creates an upload is repeated; the parts and the questions '
      'about the state are, with a short backoff. The token, the key and the signed links of the parts are never '
      'printed.\n\n'
      '--dry-run sends nothing: it checks what needs no network, and prints the plan and the requests.\n\n'
      'Exit codes: 0 valid, 1 a check failed or Apple refused, 65 Apple failed the processing, 69 no network, 75 not '
      'finished within --timeout, 77 Apple refused the key.';

  @override
  String get invocation => 'wincode upload [--ipa <file>] [<signed .ipa>]';

  @override
  Future<int> run() async {
    if (globalResults!.flag('all')) {
      refuseAll(name, writesOf[name]!);
    }
    checkEventsOption();
    final rest = argResults!.rest;
    if (rest.length > 1) {
      usageException('Give at most one IPA.');
    }
    if (rest.isNotEmpty && argResults!.wasParsed('ipa')) {
      usageException('Name the IPA once: either --ipa <file> or <file>.');
    }
    final timeout = timeoutOf(argResults!.option('timeout')!);
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
    final dryRun = globalResults!.flag('dry-run');
    final yes = argResults!.flag('yes');
    final interactive =
        !yes &&
        !jsonOutput &&
        !eventsOutput &&
        !runsInCi(environment) &&
        terminal;
    if (!dryRun && !yes && !interactive) {
      throw uploadConfirmationRequired;
    }
    final ipa =
        argResults!.option('ipa') ??
        rest.firstOrNull ??
        '${app.output.path}${Platform.pathSeparator}signed.ipa';
    // With --json or --events, stdout carries the JSON only.
    final report = jsonOutput || eventsOutput ? err : out;
    final events = eventsOutput ? EventWriter(out, clock, app: app.name) : null;
    final result = await Uploader(
      config: app,
      environment: environment,
      redactor: redactor,
      clock: clock,
      connect: connect,
      run: runProcess,
      report: report,
      readLine: readLine,
      timeout: timeout,
      pollInterval: pollInterval,
      log: globalResults!.flag('verbose') ? err.writeln : null,
      events: events,
    ).upload(File(ipa), dryRun: dryRun, yes: yes);
    final object = {
      ...jsonOf(result.findings, command: name, app: app.name),
      ...result.json,
    };
    if (jsonOutput) {
      out.writeln(jsonEncode(object));
    }
    events?.result(object);
    return exitCodeOf(result.findings).code;
  }
}

class _Build extends _Command {
  _Build(
    super.out,
    this.err,
    this.environment,
    this.redactor,
    this.clock,
    this.connect,
    this.connectGithub,
    this.runProcess,
    this.answer,
    this.terminal,
    this.pollInterval,
    this.sleep,
    this.interrupts,
  ) {
    addEventsFlag();
    argParser
      ..addOption(
        'ref',
        valueHelp: 'branch or tag',
        help:
            'Build this branch or tag instead of the @<ref> of workflow: in wincode.yaml. A commit SHA is refused: GitHub '
            'starts a workflow on a branch or a tag.',
      )
      ..addOption(
        'build-name',
        valueHelp: 'x.y.z',
        help:
            'The version (CFBundleShortVersionString), for this build only. Without it: build_name in wincode.yaml, '
            "else pubspec.yaml's version at the ref.",
      )
      ..addOption(
        'build-number',
        valueHelp: 'n|auto',
        help:
            'The build number, or auto: one above the highest that App Store Connect and the last day\'s runs of the app '
            "know. Without it: auto for a file of apps, and pubspec.yaml's number at the ref for a flat file.",
      )
      ..addFlag(
        'allow-public',
        negatable: false,
        help:
            'Build in a public repository, whose artifacts anyone with a GitHub account can download until they expire. '
            'winCode deletes the artifact as soon as it has downloaded and checked it.',
      )
      ..addOption(
        'timeout',
        valueHelp: 'minutes',
        defaultsTo: '${defaultBuildTimeout.inMinutes}',
        help:
            'How long to wait for the run, from the dispatch: a number of minutes, such as 60, or of seconds with an s. '
            'When it passes, the exit code is 75 and the run goes on: this ends the wait, never the run.',
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Start the run without asking. Needed in CI, with --json or --events, and without a terminal.',
      )
      ..addOption(
        'run',
        valueHelp: 'id',
        help:
            'Start nothing: wait for this run, which an earlier wincode build started, then download and check its '
            'IPA. Cannot be combined with --ref, --build-name or --build-number: the run has them.',
      );
  }

  final StringSink err;
  final Map<String, String> environment;
  final Redactor redactor;
  final DateTime Function() clock;
  final AscConnect connect;
  final GithubConnect connectGithub;
  final RunProcess runProcess;
  final Future<String?> Function()? answer;
  final bool terminal;
  final Duration pollInterval;
  final Future<void> Function(Duration) sleep;
  final Stream<ProcessSignal> Function() interrupts;

  @override
  final name = 'build';

  @override
  final description =
      "Build the app's unsigned IPA on a GitHub macOS runner (ADR-0015).\n\n"
      'Before a run is paid for, winCode reads the project at the commit of the ref through GitHub\'s API and checks '
      'it: the token and the repository, the workflow and its contract and inputs, the Flutter release against '
      'pubspec.yaml and flutter/flutter\'s tags, the Xcode against min_xcode_version, the scheme, the configuration '
      'and the bundle ID that Flutter would build, the entry point, the version, and the build number (auto asks App '
      'Store Connect and the last 24 hours of runs). It prints its plan and asks before it starts the run: --yes '
      'skips that, and without a terminal, in CI or with --json or --events, --yes is required.\n\n'
      'It then starts the workflow, once, and reads the run every 30 s until it ends, or --timeout has passed. The run '
      'is never cancelled unasked: Ctrl-C at a terminal asks whether to cancel it, and answers no by default. When it '
      'succeeded, winCode downloads the artifact, checks the hash that the workflow recorded and GitHub\'s digest, and '
      'that the IPA is the app, version and build number that were asked for and is not signed, and puts it in the '
      'output folder as unsigned.ipa. With --allow-public, in a public repository, it then deletes the artifact.\n\n'
      '--dry-run sends no request at all: it prints the plan from wincode.yaml and the options, and the dispatch '
      'request as it would go out. wincode doctor --build makes the checks without starting anything.\n\n'
      'Exit codes: 0 the IPA is in the output folder, 1 a check or the run failed, 64 usage, 69 GitHub cannot be '
      'reached, 75 the run was still going when winCode stopped waiting (collect it with --run), 77 GitHub refused '
      'the token, 78 the setup is wrong.';

  @override
  String get invocation => 'wincode build [--app <name>]';

  @override
  bool get takesArguments => false;

  @override
  Future<int> run() async {
    if (globalResults!.flag('all')) {
      refuseAll(name, writesOf[name]!);
    }
    checkEventsOption();
    final options = _options();
    final collecting = _runId();
    final dry = globalResults!.flag('dry-run');
    if (collecting != null) {
      for (final option in ['ref', 'build-name', 'build-number']) {
        if (argResults!.wasParsed(option)) {
          usageException(
            '--run and --$option cannot be given together: the run was started with its ref, version and build number, '
            'and carries them in its name.',
          );
        }
      }
      if (dry) {
        usageException(
          '--run and --dry-run cannot be given together: --run starts nothing, and there is no plan to print.',
        );
      }
    }
    final timeout = timeoutOf(argResults!.option('timeout')!);
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
    // The question is asked at a terminal only, and never in CI or where stdout is for a program.
    final yes = argResults!.flag('yes');
    final canAsk =
        !jsonOutput && !eventsOutput && !runsInCi(environment) && terminal;
    if (!dry && collecting == null && !yes && !canAsk) {
      throw buildConfirmationRequired;
    }
    final events = eventsOutput ? EventWriter(out, clock, app: app.name) : null;
    // With --json or --events, stdout carries the JSON only.
    final report = jsonOutput || events != null ? err : out;
    final checker = BuildChecker(
      config: app,
      options: options,
      environment: environment,
      redactor: redactor,
      clock: clock,
      github: connectGithub,
      connect: connect,
      run: runProcess,
      log: globalResults!.flag('verbose') ? err.writeln : null,
      events: events,
    );
    final List<Finding> findings;
    final BuildPlan plan;
    GithubClient? client;
    int? workflowId;
    var request = const <String>[];
    if (dry) {
      final result = checker.dryRun();
      findings = result.report.findings;
      plan = result.report.plan;
      request = result.request;
    } else {
      final result = collecting == null
          ? await checker.check()
          : await checker.collect();
      findings = result.findings;
      plan = result.plan;
      client = result.client;
      workflowId = result.workflowId;
    }
    final failed = findings.any((f) => f.status == 'FAIL');
    if (!failed) {
      // The plan of a run that is collected is the run's own: it holds the little that its name says.
      if (collecting == null) events?.emit('plan', plan.toEvent());
      if (dry) {
        findings.add(
          const Finding.info(
            'dry-run',
            'dry run: nothing was sent, and nothing was started',
          ),
        );
      }
    }
    writeFindings(findings, report);
    final written = findings.length;
    if (!failed && collecting == null) {
      report
        ..writeln()
        ..writeAll(plan.lines(), '\n')
        ..writeln();
      request.forEach(report.writeln);
    }
    BuildRun? build;
    if (!failed && !dry) {
      build = BuildRun(
        config: app,
        plan: plan,
        client: client!,
        findings: findings,
        redactor: redactor,
        clock: clock,
        sleep: sleep,
        report: report,
        progress: err,
        signals: interrupts(),
        readAnswer: answer ?? stdinLines(),
        canAsk: canAsk,
        timeout: timeout,
        pollInterval: pollInterval,
        cleanup: plan.private == false && options.allowPublic,
        events: events,
      );
      if (collecting == null) {
        await build.start(yes: yes);
      } else {
        await build.collect(collecting, workflowId: workflowId!);
      }
      writeFindings(findings.sublist(written), report);
    }
    writeSummary(findings, report, command: name);
    final result = {
      ...jsonOf(findings, command: name, app: app.name),
      'repository': plan.repository,
      'workflow': plan.workflow,
      'ref': plan.ref,
      'commit': plan.commit,
      'requestId': plan.requestId,
      'runId': build?.runId,
      'runUrl': build?.runUrl,
      'conclusion': build?.conclusion,
      'buildName': plan.buildName,
      'buildNumber': plan.buildNumber,
      'ipa': build?.ipa,
      'minutes': build?.minutes,
      'plan': plan.toJson(),
      if (dry) ...{'dryRun': true, 'request': request},
    };
    if (jsonOutput) {
      out.writeln(jsonEncode(result));
    }
    events?.result(result);
    return exitCodeOf(findings).code;
  }

  /// `--run`: the number of the run to collect, or null.
  int? _runId() {
    final text = argResults!.option('run');
    if (text == null) return null;
    final id = int.tryParse(text);
    if (id == null || id <= 0 || !RegExp(r'^\d+$').hasMatch(text)) {
      usageException(
        '--run is the number of a run, as it ends the address of the run: .../actions/runs/<id>.',
      );
    }
    return id;
  }

  /// The options of the command line, checked.
  BuildOptions _options() {
    final ref = argResults!.option('ref');
    if (ref != null) {
      if (RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(ref)) {
        throw const WincodeException(
          ExitCode.usage,
          'ref-is-commit',
          '--ref names a commit, and GitHub starts a workflow on a branch or a tag',
          why: 'a dispatch takes a ref, which is a branch or a tag, and runs the workflow file as it is at the tip of it.',
          next:
              'give the branch or tag that points to the commit, or push one.',
        );
      }
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._/+-]{0,254}$').hasMatch(ref)) {
        usageException(
          '--ref is a branch or tag name: letters, digits, ., _, -, + and /, starting with a letter or digit.',
        );
      }
    }
    final name = argResults!.option('build-name');
    if (name != null && !isDottedNumber(name)) {
      usageException(
        '--build-name is one to three whole numbers joined by dots, such as 2.4.0.',
      );
    }
    final number = argResults!.option('build-number');
    if (number != null && number != 'auto' && !isDottedNumber(number)) {
      usageException(
        '--build-number is a number such as 58 (or 1.2.3), or auto.',
      );
    }
    return BuildOptions(
      ref: ref,
      buildName: name,
      buildNumber: number,
      allowPublic: argResults!.flag('allow-public'),
    );
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
