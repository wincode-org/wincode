import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wincode_core/wincode_core.dart';

import 'config.dart';
import 'credentials.dart';
import 'failure.dart';
import 'preflight.dart' show Finding;
import 'redact.dart';
import 'zsign_native.dart';
import 'zsign_output.dart' show zsignProblemLine;

/// zsign as `wincode sign` runs it (ADR-0013, section 4, as built in phase 3a, and the Linux addendum of section 11):
/// the source of the commit that xtool pins, built by the user at a fixed path, and run without a shell: through
/// `wsl.exe --exec` on Windows ([WslZsignRunner]), directly on Linux ([NativeZsignRunner]).

/// `xtool-org/zsign` 1.9.0, as `third_party/xtool/Package.resolved` pins it.
const zsignCommit = 'f6158be9e62a5ce2a53d72b1a6d880880da956c8';

/// The SHA-256 of GitHub's archive of [zsignCommit] (spike C, `build-zsign.sh`).
const zsignSourceSha256 =
    '423ebe2f4dd3380367461c03e6de3b9e9f31adcbe9a2f0237493c8f0bf9b7c5d';

const zsignVersion = '1.9.0';

/// The variable that names the WSL2 distribution to use. Unset, `wsl.exe` uses its default distribution.
const distroVariable = 'WINCODE_WSL_DISTRO';

/// Where the pinned zsign is, inside WSL2, for the home folder [home].
String zsignPath(String home) =>
    '$home/.wincode/zsign/zsign-$zsignCommit/bin/zsign';

/// The commands that build the pinned zsign in [folder], as `wincode doctor --sign` prints them. winCode runs none of
/// them.
List<String> zsignBuildCommandsIn(String folder) => [
  'sudo apt-get install -y make g++ pkg-config libssl-dev   # if they are missing',
  'mkdir -p $folder && cd $folder',
  'curl -fL -o zsign-$zsignCommit.tar.gz https://github.com/xtool-org/zsign/archive/$zsignCommit.tar.gz',
  'echo "$zsignSourceSha256  zsign-$zsignCommit.tar.gz" | sha256sum -c -',
  'tar -xzf zsign-$zsignCommit.tar.gz',
  'make -C zsign-$zsignCommit/build/linux VERSION=$zsignVersion   # without g++: add CXX=clang++ CC=clang',
];

/// The same, for the distribution of WSL2.
final zsignBuildCommands = zsignBuildCommandsIn('~/.wincode/zsign');

/// Runs commands inside WSL2 with `wsl.exe [-d <distribution>] --exec`, so that no shell reads the arguments.
class Wsl {
  Wsl(Map<String, String> environment, this.run, {this.log})
    : distro = switch (environment[distroVariable]) {
        final String d when d.trim().isNotEmpty => d.trim(),
        _ => null,
      };

  /// The distribution that [distroVariable] names, or null for the default one.
  final String? distro;

  final RunProcess run;

  /// Gets each command with `--verbose`.
  final void Function(String line)? log;

  /// The name of the distribution in messages.
  String get name => distro ?? 'the default WSL2 distribution';

  /// The arguments of `wsl.exe` that run [command] inside the distribution, in [cd] when given (a Linux path).
  List<String> arguments(List<String> command, {String? cd}) => [
    if (distro case final d?) ...['-d', d],
    if (cd != null) ...['--cd', cd],
    '--exec',
    ...command,
  ];

  /// Runs [command] and returns its result, or null when `wsl.exe` cannot be started.
  Future<ProcessResult?> exec(List<String> command) async {
    final args = arguments(command);
    log?.call('wsl.exe ${args.join(' ')}');
    try {
      return await run('wsl.exe', args);
    } on ProcessException {
      return null;
    }
  }

  /// The output of [command] when it succeeds, trimmed; null otherwise.
  Future<String?> output(List<String> command) async {
    final result = await exec(command);
    if (result == null || result.exitCode != 0) {
      return null;
    }
    final text = '${result.stdout}'.trim();
    return text.isEmpty ? null : text;
  }

  /// [path], a Windows path, as `wslpath -u` translates it inside the distribution; null when it cannot. A UNC path
  /// (`\\server\share`, `\\wsl.localhost\<distribution>`) is refused: wslpath turns it into a path under `/mnt/c` that
  /// does not exist.
  Future<String?> translate(String path) async {
    if (path.startsWith(r'\\') || path.startsWith('//')) {
      return null;
    }
    final out = await output(['wslpath', '-u', path]);
    return out != null && out.startsWith('/') && !out.contains('\n')
        ? out
        : null;
  }

  /// The home folder of the distribution's default user.
  Future<String?> home() => output(['printenv', 'HOME']);
}

/// The distributions that `wsl.exe -l -v` lists: name, version, and whether it is the default. `wsl.exe` writes this
/// list in UTF-16, so the NUL bytes that a decoder for single bytes leaves are dropped.
List<({String name, int version, bool isDefault})> parseWslList(String text) {
  final found = <({String name, int version, bool isDefault})>[];
  for (final line in text.replaceAll('\u0000', '').split(RegExp(r'\r?\n'))) {
    final match = RegExp(r'^\s*(\*)?\s*(\S+)\s+\S+\s+(\d+)\s*$')
        .firstMatch(line);
    if (match != null && match[2] != 'NAME') {
      found.add((
        name: match[2]!,
        version: int.parse(match[3]!),
        isDefault: match[1] != null,
      ));
    }
  }
  return found;
}

// The record of zsign's SHA-256 (ADR-0013, section 4, as built).

/// winCode's folder for what it keeps for the user, on Linux: `$XDG_DATA_HOME/wincode`, else `~/.local/share/wincode`
/// (the XDG base directory rule: a relative `XDG_DATA_HOME` is ignored).
Directory wincodeDataDirectory(Map<String, String> environment) {
  final s = Platform.pathSeparator;
  final xdg = environment['XDG_DATA_HOME'] ?? '';
  if (xdg.isNotEmpty && Directory(xdg).isAbsolute) {
    return Directory('$xdg${s}wincode');
  }
  final home = environment['HOME'] ?? environment['USERPROFILE'] ?? '.';
  return Directory('$home$s.local${s}share${s}wincode');
}

/// The local file that records the SHA-256 of the zsign that `wincode doctor --sign` checked first: on Windows
/// `%LOCALAPPDATA%\wincode\zsign.json` with one entry per WSL2 distribution, on Linux `zsign.json` in
/// [wincodeDataDirectory] with one entry for this machine. Outside every repository.
File zsignStateFile(Map<String, String> environment) {
  final base = environment['LOCALAPPDATA'];
  final s = Platform.pathSeparator;
  if (base != null && base.isNotEmpty) {
    return File('$base${s}wincode${s}zsign.json');
  }
  return File('${wincodeDataDirectory(environment).path}${s}zsign.json');
}

/// The entry of the record for zsign run on Linux itself (a WSL2 distribution has its own name as its entry).
const nativeStateKey = '(this machine)';

/// The recorded SHA-256 of the zsign at [path] under [key] (a distribution, or [nativeStateKey]), or null when none is
/// recorded for that path.
String? recordedZsignHash(
  Map<String, String> environment,
  String key,
  String path,
) {
  try {
    if (jsonDecode(zsignStateFile(environment).readAsStringSync()) case {
      'zsign': final Map<String, Object?> all,
    }) {
      if (all[key] case {'path': final String p, 'sha256': final String h}
          when p == path) {
        return h;
      }
    }
  } on Object {
    // No record, or one that cannot be read: nothing is recorded.
  }
  return null;
}

/// Records [hash] for the zsign at [path] under [key].
void recordZsignHash(
  Map<String, String> environment,
  String key,
  String path,
  String hash,
) {
  final file = zsignStateFile(environment);
  Map<String, Object?> all = {};
  try {
    if (jsonDecode(file.readAsStringSync()) case {
      'zsign': final Map<String, Object?> z,
    }) {
      all = {...z};
    }
  } on Object {
    // A new record.
  }
  all[key] = {'path': path, 'sha256': hash};
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'zsign': all})}\n',
  );
}

String _stateKey(Wsl wsl) => wsl.distro ?? '(default)';

/// The SHA-256 of the file at [path] inside [wsl]'s distribution, by `sha256sum`; null when it cannot be read.
Future<String?> zsignHash(Wsl wsl, String path) async {
  final out = await wsl.output(['sha256sum', path]);
  final hash = out?.split(RegExp(r'\s')).first ?? '';
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ? hash : null;
}

WincodeException wslMissing(String what) => WincodeException(
  ExitCode.unavailable,
  'wsl-missing',
  what,
  why: 'wincode sign runs zsign inside WSL2 (ADR-0013, section 4).',
  next:
      'run `wsl --install -d Ubuntu-24.04` in an administrator terminal and restart; then build zsign with the '
      'commands that wincode doctor --sign prints.',
);

/// zsign is not where `wincode sign` looks for it. [where] is `in <distribution>` or `on this machine`; [at] is the
/// folder it is built in.
WincodeException zsignMissingAt(
  String where,
  String at,
  String next,
) => WincodeException(
  ExitCode.unavailable,
  'zsign-missing',
  'zsign is not installed $where',
  why:
      'winCode signs with the zsign of the commit that xtool pins ($zsignVersion, ${zsignCommit.substring(0, 8)}), '
      'built on this PC from its checked source, at $at.',
  next: next,
);

WincodeException zsignMissing(Wsl wsl) => zsignMissingAt(
  'in ${wsl.name}',
  '~/.wincode/zsign',
  'run wincode doctor --sign, which prints the commands that build it; or set $distroVariable to the distribution '
      'where it is built.',
);

WincodeException zsignChanged(
  String found, {
  String where = 'in WSL2',
}) => WincodeException(
  ExitCode.failed,
  'zsign-changed',
  'the zsign $where is not the one winCode pins',
  why:
      'wincode sign signs the app with it, and a changed binary could sign anything. $found',
  next:
      'if you rebuilt it with the commands that wincode doctor --sign prints, delete the record named above and run '
      'wincode doctor --sign to record the new one; otherwise build it again with those commands.',
);

/// The checks of `wincode sign` on the zsign at [path], wherever it runs: it is there ([missing] says what to do if it
/// is not), prints the pinned version, and has the SHA-256 that `wincode doctor --sign` recorded under [key]. [version]
/// is what `zsign -v` printed, null when it did not run; [hash] reads the file's SHA-256, null when it cannot.
Future<String> checkPinnedZsign(
  Map<String, String> environment, {
  required String key,
  required String where,
  required String path,
  required String? version,
  required Future<String?> Function() hash,
  required WincodeException missing,
}) async {
  if (version == null) {
    throw missing;
  }
  if (version != 'version: $zsignVersion') {
    throw zsignChanged(
      'It prints "$version", not version $zsignVersion.',
      where: where,
    );
  }
  final found = await hash();
  final recorded = recordedZsignHash(environment, key, path);
  if (recorded == null) {
    throw WincodeException(
      ExitCode.failed,
      'zsign-unverified',
      'no SHA-256 of the zsign $where is recorded',
      why:
          'wincode sign runs only the zsign whose SHA-256 wincode doctor --sign recorded, so that a binary changed '
          'later is noticed.',
      next: 'run wincode doctor --sign, which checks zsign and records it.',
    );
  }
  if (found != recorded) {
    throw zsignChanged(
      'Its SHA-256 is not the one recorded in ${zsignStateFile(environment).path}.',
      where: where,
    );
  }
  return path;
}

/// The pinned zsign in [wsl]'s distribution, checked for `wincode sign`: it is there, prints the pinned version, and
/// has the SHA-256 that `wincode doctor --sign` recorded. Returns its path; throws the failure otherwise.
Future<String> requirePinnedZsign(
  Map<String, String> environment,
  Wsl wsl,
) async {
  final listed = await wsl.exec(['printenv', 'HOME']);
  if (listed == null) {
    throw wslMissing('wsl.exe cannot be started: WSL2 is not installed');
  }
  final home = listed.exitCode == 0 ? '${listed.stdout}'.trim() : '';
  if (home.isEmpty) {
    throw WincodeException(
      ExitCode.unavailable,
      'wsl-unreachable',
      '${wsl.name} does not start',
      why: 'wincode sign runs zsign inside it.',
      next:
          'run wincode doctor --sign, which checks WSL2; set $distroVariable to the distribution where zsign is built.',
    );
  }
  final path = zsignPath(home);
  return checkPinnedZsign(
    environment,
    key: _stateKey(wsl),
    where: 'in WSL2',
    path: path,
    version: await wsl.output([path, '-v']),
    hash: () => zsignHash(wsl, path),
    missing: zsignMissing(wsl),
  );
}

/// The checks of `wincode doctor --sign` for [app] (ADR-0013 phase 3a): WSL2 is there and runs version 2, the
/// distribution starts, the pinned zsign is built and prints its version, its SHA-256 is the one recorded (recorded now
/// when none is), and the app's distribution key lies where WSL2 can read it. Each failure carries its next step.
Future<List<Finding>> signSetupFindings(
  WincodeConfig app, {
  required Map<String, String> environment,
  required Redactor redactor,
  required RunProcess run,
  void Function(String line)? log,
}) async {
  final findings = <Finding>[];
  final wsl = Wsl(environment, run, log: log);
  findings.addAll(await _zsignFindings(wsl, environment, redactor, run, log));
  final wslReady = !findings.any((f) => f.check == 'wsl' && f.status == 'FAIL');
  findings.add(
    await _distKeyFinding(app, wsl, environment, redactor, run, wslReady),
  );
  return findings;
}

Future<List<Finding>> _zsignFindings(
  Wsl wsl,
  Map<String, String> environment,
  Redactor redactor,
  RunProcess run,
  void Function(String line)? log,
) async {
  ProcessResult? listed;
  try {
    log?.call('wsl.exe -l -v');
    listed = await run('wsl.exe', ['-l', '-v']);
  } on ProcessException {
    // No WSL.
  }
  if (listed == null) {
    return [
      Finding.fail(
        'wsl',
        wslMissing('wsl.exe cannot be started: WSL2 is not installed'),
      ),
    ];
  }
  final distros = listed.exitCode == 0
      ? parseWslList('${listed.stdout}')
      : const <({String name, int version, bool isDefault})>[];
  if (distros.isEmpty) {
    return [Finding.fail('wsl', wslMissing('WSL2 has no Linux distribution'))];
  }
  final chosen = distros
      .where((d) => wsl.distro == null ? d.isDefault : d.name == wsl.distro)
      .firstOrNull;
  if (chosen == null) {
    return [
      Finding.fail(
        'wsl',
        WincodeException(
          ExitCode.unavailable,
          'wsl-distro-missing',
          wsl.distro == null
              ? 'WSL2 has no default distribution'
              : 'WSL2 has no distribution named ${wsl.distro}',
          why:
              'wincode sign runs zsign in the distribution that $distroVariable names, else in the default one.',
          next:
              'set $distroVariable to one of ${distros.map((d) => d.name).join(', ')}, the one where zsign is built.',
        ),
      ),
    ];
  }
  if (chosen.version != 2) {
    return [
      Finding.fail(
        'wsl',
        WincodeException(
          ExitCode.unavailable,
          'wsl-version',
          '${chosen.name} runs on WSL 1',
          why: 'wincode sign is tested with zsign in WSL 2 only.',
          next:
              'run `wsl --set-version ${chosen.name} 2`, or set $distroVariable to a WSL 2 distribution.',
        ),
      ),
    ];
  }
  final findings = [
    Finding.pass(
      'wsl',
      '${chosen.name} is a WSL 2 distribution${wsl.distro == null ? ' (the default one; $distroVariable is not set)' : ''}',
    ),
  ];
  final home = await wsl.home();
  if (home == null) {
    return findings..add(
      Finding.fail(
        'wsl',
        WincodeException(
          ExitCode.unavailable,
          'wsl-unreachable',
          '${chosen.name} does not start, or has no home folder',
          why: 'wincode sign runs zsign inside it.',
          next:
              'start it once with `wsl -d ${chosen.name}` and finish its setup, then run doctor again.',
        ),
      ),
    );
  }
  final path = zsignPath(home);
  final version = await wsl.output([path, '-v']);
  return findings..addAll(
    zsignFindings(
      environment,
      redactor,
      key: _stateKey(wsl),
      where: 'in WSL2',
      path: path,
      version: version,
      hash: version == null ? null : await zsignHash(wsl, path),
      missing: zsignMissing(wsl),
      commands: Finding.info(
        'zsign-build',
        'the commands that build the pinned zsign, to run yourself inside ${chosen.name} (winCode runs none of them):\n'
            '${zsignBuildCommands.map((c) => '    $c').join('\n')}',
      ),
    ),
  );
}

/// The `zsign` findings of `wincode doctor --sign` for the binary at [path], wherever it runs: built and printing the
/// pinned version ([version], null when it did not run), and its SHA-256 [hash] the one recorded under [key]. The first
/// time, it is recorded now (trust on first use); a binary that differs fails with the build [commands] as INFO.
List<Finding> zsignFindings(
  Map<String, String> environment,
  Redactor redactor, {
  required String key,
  required String where,
  required String path,
  required String? version,
  required String? hash,
  required WincodeException missing,
  required Finding commands,
}) {
  if (version == null) {
    return [Finding.fail('zsign', missing), commands];
  }
  if (version != 'version: $zsignVersion') {
    return [
      Finding.fail(
        'zsign',
        zsignChanged(
          'It prints "$version", not version $zsignVersion.',
          where: where,
        ),
      ),
      commands,
    ];
  }
  if (hash == null) {
    return [Finding.fail('zsign', missing), commands];
  }
  final state = zsignStateFile(environment);
  redactor.hide(state.path, '<zsign record>');
  final recorded = recordedZsignHash(environment, key, path);
  if (recorded == null) {
    recordZsignHash(environment, key, path, hash);
    return [
      Finding.pass(
        'zsign',
        'zsign $zsignVersion is built; its SHA-256 ${hash.substring(0, 12)}... is now recorded in ${state.path}',
      ),
    ];
  }
  if (recorded != hash) {
    return [
      Finding.fail(
        'zsign',
        zsignChanged(
          'Its SHA-256 ${hash.substring(0, 12)}... is not the one recorded in ${state.path} '
          '(${recorded.substring(0, 12)}...).',
          where: where,
        ),
      ),
      commands,
    ];
  }
  return [
    Finding.pass(
      'zsign',
      'zsign $zsignVersion has the SHA-256 recorded in ${state.path}',
    ),
  ];
}

/// The distribution key file of [app] for `doctor --sign`: its [file], where [source] names the credentials or the
/// variable it comes from, or the failing [problem] when it is refused, not set or not there. Where it lies and who may
/// read it are checked by [resolveDistKey]; whether zsign can read it is for the runner.
Future<({File? file, String source, Finding? problem})> findDistKey(
  WincodeConfig app, {
  required Map<String, String> environment,
  required Redactor redactor,
  required RunProcess run,
}) async {
  final reference = app.credentials;
  final source = reference == null
      ? 'WINCODE_DIST_KEY'
      : 'the credentials $reference';
  final where = reference == null
      ? 'set WINCODE_DIST_KEY to the distribution key, a PEM file on a local drive outside git working trees and '
            'OneDrive'
      : 'put dist.key in the folder $reference of the keys folder, or set ${distOverrideVariable(reference)} to the '
            'file';
  Finding missing(String what) => Finding.fail(
    'dist-key',
    WincodeException(
      ExitCode.config,
      'dist-key-missing',
      what,
      why: 'wincode sign signs with it, and finds it only there (ADR-0014, section 2).',
      next: '$where.',
    ),
  );
  final File? file;
  try {
    file = await resolveDistKey(
      app,
      environment: environment,
      redactor: redactor,
      run: run,
    );
  } on WincodeException catch (e) {
    return (file: null, source: source, problem: Finding.fail('dist-key', e));
  }
  if (file == null) {
    return (
      file: null,
      source: source,
      problem: missing('WINCODE_DIST_KEY is not set'),
    );
  }
  redactor.secret(file.path, '<distribution key>');
  if (!file.existsSync()) {
    return (
      file: null,
      source: source,
      problem: missing('the distribution key of $source does not exist'),
    );
  }
  return (file: file, source: source, problem: null);
}

Future<Finding> _distKeyFinding(
  WincodeConfig app,
  Wsl wsl,
  Map<String, String> environment,
  Redactor redactor,
  RunProcess run,
  bool wslReady,
) async {
  final (:file, :source, :problem) = await findDistKey(
    app,
    environment: environment,
    redactor: redactor,
    run: run,
  );
  if (problem != null) {
    return problem;
  }
  final reference = app.credentials;
  if (!wslReady) {
    return Finding.info(
      'dist-key',
      'the distribution key of $source exists; whether WSL2 can read it was not checked, since WSL2 is not ready',
    );
  }
  final translated = await wsl.translate(file!.absolute.path);
  if (translated != null) {
    redactor.secret(translated, '<distribution key>');
  }
  if (translated == null ||
      (await wsl.exec(['test', '-r', translated]))?.exitCode != 0) {
    return Finding.fail('dist-key', wslKeyUnreachable(source, reference));
  }
  return Finding.pass(
    'dist-key',
    'the distribution key of $source is where zsign in WSL2 can read it (its content is checked by wincode sign)',
  );
}

// Running zsign.

/// Starts a program and returns it while it runs: [Process.start] in a real run, a fake in tests.
typedef StartProcess = Future<Process> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
});

/// How a run of zsign ended.
enum ZsignEnd { ok, failed, timedOut, tooBig }

/// A program to start: its [arguments] are a list that the operating system passes as they are, never text that a
/// shell reads.
typedef ZsignCommand = ({
  String executable,
  List<String> arguments,
  String? workingDirectory,
});

/// Where zsign runs, and how a command reaches it (ADR-0013, sections 4 and 11): through `wsl.exe` on Windows
/// ([WslZsignRunner]), directly on Linux ([NativeZsignRunner]). [zsignRunnerFor] chooses.
///
/// `wincode sign` is the same on both: the runner checks the pinned binary, turns the paths of the files into the ones
/// zsign sees, and builds the command line. The base class starts that command, stops it after [timeout] or when the
/// folder it works in passes [limit] bytes (sign.py's 1 GB stop: zsign once zipped its own output in a loop), and keeps
/// the last lines it printed.
abstract class ZsignRunner {
  ZsignRunner({
    required this.environment,
    required this.runTool,
    this.start = Process.start,
    this.timeout = const Duration(minutes: 20),
    this.limit = 1 << 30,
    this.poll = const Duration(milliseconds: 500),
  });

  final Map<String, String> environment;

  /// Runs the short tools that the checks use (`wsl.exe`, `sha256sum`, `zsign -v`) and waits for their output.
  final RunProcess runTool;

  /// Starts zsign itself, which runs long enough to be watched.
  final StartProcess start;
  final Duration timeout;
  final int limit;
  final Duration poll;

  /// Where zsign runs, as a message says it: `in <distribution>` or `on this machine`.
  String get where;

  /// The pinned zsign, checked for `wincode sign` (it is there, prints the pinned version, and has the SHA-256 that
  /// `wincode doctor --sign` recorded): the path that [command] starts. Throws the failure otherwise.
  Future<String> requirePinned({void Function(String line)? log});

  /// [path], a path on this machine, as zsign sees it; null when it cannot reach it.
  Future<String?> translate(String path, {void Function(String line)? log});

  /// Whether zsign can read the file at [path], a path that [translate] gave.
  Future<bool> canRead(String path, {void Function(String line)? log});

  /// The failure for a distribution key that [canRead] says zsign cannot read. [source] names where the key comes from,
  /// [reference] is the app's credentials reference, null for `WINCODE_DIST_KEY`.
  WincodeException keyUnreachable(String source, String? reference);

  /// The command that runs [zsign] (what [requirePinned] returned) with [arguments], working in [cd].
  ZsignCommand command(
    String zsign,
    List<String> arguments, {
    required String cd,
  });

  /// The checks of `wincode doctor --sign` for [app]: whether zsign can run here, the pinned binary with its recorded
  /// SHA-256 (recorded now when none is), and where the distribution key is. Each failure carries its next step.
  Future<List<Finding>> setupFindings(
    WincodeConfig app, {
    required Redactor redactor,
    void Function(String line)? log,
  });

  /// Starts [command] and watches [work]. Returns how it ended, its exit code, and what it said: the lines that say error,
  /// failed or invalid that came before its last 20 lines, then its last 20 lines.
  Future<({ZsignEnd end, int? exitCode, List<String> said})> run(
    ZsignCommand command, {
    required Directory work,
  }) async {
    final Process process;
    try {
      process = await start(
        command.executable,
        command.arguments,
        workingDirectory: command.workingDirectory,
      );
    } on ProcessException {
      return (
        end: ZsignEnd.failed,
        exitCode: null,
        said: ['${command.executable} cannot be started'],
      );
    }
    final said = <String>[];
    // The first 40 lines that say error, failed or invalid, kept when they scroll out of the last 20 lines.
    final problems = <(int, String)>[];
    var count = 0;
    void keep(String line) {
      count++;
      said.add(line);
      if (said.length > 20) {
        said.removeAt(0);
      }
      if (problems.length < 40 && zsignProblemLine.hasMatch(line)) {
        problems.add((count, line));
      }
    }

    final streams = [
      for (final s in [process.stdout, process.stderr])
        s
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .listen(keep)
            .asFuture<void>()
            .catchError((Object _) {}),
    ];
    final stopwatch = Stopwatch()..start();
    ZsignEnd? stopped;
    var exited = false;
    int? code;
    unawaited(
      process.exitCode.then((c) {
        code = c;
        exited = true;
      }),
    );
    while (!exited) {
      await Future<void>.delayed(poll);
      if (exited) {
        break;
      }
      if (stopwatch.elapsed > timeout) {
        stopped = ZsignEnd.timedOut;
      } else if (_size(work) > limit) {
        stopped = ZsignEnd.tooBig;
      }
      if (stopped != null) {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () => -1,
        );
        break;
      }
    }
    await Future.wait(streams)
        .timeout(const Duration(seconds: 5), onTimeout: () => const []);
    return (
      end: stopped ?? (code == 0 ? ZsignEnd.ok : ZsignEnd.failed),
      exitCode: code,
      said: [
        for (final (n, line) in problems)
          if (n <= count - said.length) line,
        ...said,
      ],
    );
  }
}

/// The distribution key lies where WSL2 cannot read it.
WincodeException wslKeyUnreachable(
  String source,
  String? reference,
) => WincodeException(
  ExitCode.config,
  'dist-key-unreachable',
  'the distribution key of $source lies where WSL2 cannot read it',
  why:
      'zsign runs inside WSL2 and reads the key in place, at the path that wslpath gives; a network share or a '
      'drive that WSL2 does not mount has none.',
  next: reference == null
      ? 'set WINCODE_DIST_KEY to a file on a local drive.'
      : 'move the keys root to a local drive, or set ${distOverrideVariable(reference)} to a file on one.',
);

/// zsign through `wsl.exe [-d <distribution>] --exec`, so that no shell reads the arguments (ADR-0013, section 4). The
/// paths go through `wslpath -u`, and the distribution key is read in place on the Windows side.
class WslZsignRunner extends ZsignRunner {
  WslZsignRunner({
    required super.environment,
    required super.runTool,
    super.start,
    super.timeout,
    super.limit,
    super.poll,
  });

  Wsl _wsl([void Function(String line)? log]) =>
      Wsl(environment, runTool, log: log);

  @override
  String get where => 'in ${_wsl().name}';

  @override
  Future<String> requirePinned({void Function(String line)? log}) =>
      requirePinnedZsign(environment, _wsl(log));

  @override
  Future<String?> translate(String path, {void Function(String line)? log}) =>
      _wsl(log).translate(path);

  @override
  Future<bool> canRead(String path, {void Function(String line)? log}) async =>
      (await _wsl(log).exec(['test', '-r', path]))?.exitCode == 0;

  @override
  WincodeException keyUnreachable(String source, String? reference) =>
      wslKeyUnreachable(source, reference);

  @override
  ZsignCommand command(
    String zsign,
    List<String> arguments, {
    required String cd,
  }) => (
    executable: 'wsl.exe',
    arguments: _wsl().arguments([zsign, ...arguments], cd: cd),
    workingDirectory: null,
  );

  @override
  Future<List<Finding>> setupFindings(
    WincodeConfig app, {
    required Redactor redactor,
    void Function(String line)? log,
  }) => signSetupFindings(
    app,
    environment: environment,
    redactor: redactor,
    run: runTool,
    log: log,
  );
}

/// The runner for the operating system [os] (`Platform.operatingSystem`): WSL2 on Windows, zsign itself on Linux, and
/// none elsewhere (macOS is not tested: its runner refuses with `platform-unsupported`).
ZsignRunner zsignRunnerFor(
  String os, {
  required Map<String, String> environment,
  required RunProcess runTool,
  StartProcess start = Process.start,
}) => switch (os) {
  'windows' => WslZsignRunner(
    environment: environment,
    runTool: runTool,
    start: start,
  ),
  'linux' => NativeZsignRunner(
    environment: environment,
    runTool: runTool,
    start: start,
  ),
  _ => UnsupportedZsignRunner(
    os,
    environment: environment,
    runTool: runTool,
    start: start,
  ),
};

/// The runner on an operating system where `wincode sign` is not supported: it fails every check with
/// `platform-unsupported`. `sign --verify-only`, `preflight` and `upload` do not use a runner and work as on Linux.
class UnsupportedZsignRunner extends ZsignRunner {
  UnsupportedZsignRunner(
    this.os, {
    required super.environment,
    required super.runTool,
    super.start,
  });

  final String os;

  WincodeException get _refusal => WincodeException(
    ExitCode.unavailable,
    'platform-unsupported',
    'wincode sign does not run on $os',
    why: 'it signs with zsign in WSL2 on Windows and directly on Linux, and winCode has not tested it anywhere else.',
    next:
        'sign on Windows or Linux. wincode sign --verify-only, preflight and upload work on $os.',
  );

  @override
  String get where => 'on $os';

  @override
  Future<String> requirePinned({void Function(String line)? log}) =>
      Future.error(_refusal);

  @override
  Future<String?> translate(String path, {void Function(String line)? log}) =>
      Future.error(_refusal);

  @override
  Future<bool> canRead(String path, {void Function(String line)? log}) =>
      Future.error(_refusal);

  @override
  WincodeException keyUnreachable(String source, String? reference) => _refusal;

  @override
  ZsignCommand command(
    String zsign,
    List<String> arguments, {
    required String cd,
  }) => throw _refusal;

  @override
  Future<List<Finding>> setupFindings(
    WincodeConfig app, {
    required Redactor redactor,
    void Function(String line)? log,
  }) async => [Finding.fail('platform', _refusal)];
}

int _size(Directory folder) {
  var total = 0;
  try {
    for (final f in folder.listSync(recursive: true, followLinks: false)) {
      if (f is File) {
        total += f.lengthSync();
      }
    }
  } on FileSystemException {
    // A file that zsign removed while it was counted.
  }
  return total;
}
