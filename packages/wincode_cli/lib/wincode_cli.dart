/// The `wincode` command (ADR-0013).
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:wincode_core/wincode_core.dart';

import 'src/failure.dart';
import 'src/redact.dart';

export 'src/config.dart' show WincodeConfig, Workflow, loadConfig;
export 'src/failure.dart' show ExitCode, WincodeException;
export 'src/key_location.dart' show requireOutsideGit;
export 'src/redact.dart' show Redactor, runsInCi;

/// The commands that ADR-0013 designs and later phases implement: name, summary, arguments and phase.
const _planned = [
  ('init', 'Write wincode.yaml for the Flutter project in this folder.', '', 2),
  (
    'build',
    "Build the unsigned IPA on the app's macOS runner (GitHub Actions) and download it.",
    '',
    5,
  ),
  (
    'sign',
    'Sign the IPA for the App Store with zsign.',
    '[<unsigned .ipa>]',
    3,
  ),
  (
    'preflight',
    'Check the signed IPA and App Store Connect before an upload. Read-only.',
    '[<signed .ipa>]',
    2,
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
Future<int> runWincode(
  List<String> args,
  StringSink out,
  StringSink err, {
  Map<String, String>? environment,
}) async {
  // A usage error comes before the arguments are parsed, so the flags can only be looked up in the list itself.
  final flags = args.takeWhile((a) => a != '--');
  var json = flags.contains('--json');
  var verbose = flags.contains('--verbose');
  final redactor = Redactor.forRun(
    flag: flags.contains('--redact'),
    environment: environment ?? Platform.environment,
  );
  out = redactor.sink(out);
  err = redactor.sink(err);
  final runner = _Wincode(out);
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
  _Wincode(this.out)
    : super(
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
    addCommand(_Doctor(out));
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
  Never run() => throw const WincodeException(
    ExitCode.usage,
    'not-implemented',
    'not implemented yet, see ADR-0013',
  );
}

class _Doctor extends _Command {
  _Doctor(super.out) {
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
      );
  }

  @override
  final name = 'doctor';

  @override
  final description =
      'Check a Mach-O binary against the SDK or a reference build.\n\n'
      'Give --binary and at least one of --sdk and --reference.';

  @override
  bool get takesArguments => false;

  @override
  int run() {
    final binary = argResults!.option('binary');
    final sdk = argResults!.option('sdk');
    final reference = argResults!.option('reference');
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
