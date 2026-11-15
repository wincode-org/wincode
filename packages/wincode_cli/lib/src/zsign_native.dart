import 'dart:io';

import 'package:wincode_core/wincode_core.dart';

import 'config.dart';
import 'failure.dart';
import 'preflight.dart' show Finding;
import 'redact.dart';
import 'zsign.dart';

/// zsign on Linux (ADR-0013, section 11): the pinned binary, started directly, with an argument list and no shell.

/// The folder where the pinned zsign is built on Linux: `zsign` in [wincodeDataDirectory].
Directory nativeZsignFolder(Map<String, String> environment) {
  final s = Platform.pathSeparator;
  return Directory('${wincodeDataDirectory(environment).path}${s}zsign');
}

/// Where the pinned zsign is on Linux. `wincode sign` runs this binary and no other.
String nativeZsignPath(Map<String, String> environment) {
  final s = Platform.pathSeparator;
  return '${nativeZsignFolder(environment).path}${s}zsign-$zsignCommit${s}bin${s}zsign';
}

/// zsign run directly on this machine. The paths need no translation, and the distribution key is read in place, where
/// the permission check of [resolveDistKey] has looked at it. The record of the binary's SHA-256 is in
/// [wincodeDataDirectory], under [nativeStateKey].
class NativeZsignRunner extends ZsignRunner {
  NativeZsignRunner({
    required super.environment,
    required super.runTool,
    super.start,
    super.timeout,
    super.limit,
    super.poll,
  });

  @override
  String get where => 'on this machine';

  WincodeException get _missing => zsignMissingAt(
    where,
    nativeZsignFolder(environment).path,
    'run wincode doctor --sign, which prints the commands that build it.',
  );

  /// What `zsign -v` prints, trimmed; null when it cannot be started, fails or prints nothing.
  Future<String?> _version(String path, void Function(String)? log) async {
    log?.call('$path -v');
    try {
      final result = await runTool(path, ['-v']);
      final text = '${result.stdout}'.trim();
      return result.exitCode == 0 && text.isNotEmpty ? text : null;
    } on ProcessException {
      return null;
    }
  }

  /// The SHA-256 of the file at [path]; null when it cannot be read.
  Future<String?> _hash(String path) async {
    try {
      return (await digestsOfFile(File(path))).sha256;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<String> requirePinned({void Function(String line)? log}) async {
    final path = nativeZsignPath(environment);
    return checkPinnedZsign(
      environment,
      key: nativeStateKey,
      where: where,
      path: path,
      version: await _version(path, log),
      hash: () => _hash(path),
      missing: _missing,
    );
  }

  @override
  Future<String?> translate(
    String path, {
    void Function(String line)? log,
  }) async => path;

  @override
  Future<bool> canRead(String path, {void Function(String line)? log}) async {
    try {
      File(path).openSync().closeSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  WincodeException keyUnreachable(String source, String? reference) =>
      WincodeException(
        ExitCode.config,
        'dist-key-unreadable',
        'the distribution key of $source cannot be read',
        why: 'zsign runs as you and reads the key in place.',
        next: 'check that your user owns the key and may read it: chmod 600 on the file.',
      );

  @override
  ZsignCommand command(
    String zsign,
    List<String> arguments, {
    required String cd,
  }) => (executable: zsign, arguments: arguments, workingDirectory: cd);

  @override
  Future<List<Finding>> setupFindings(
    WincodeConfig app, {
    required Redactor redactor,
    void Function(String line)? log,
  }) async {
    final path = nativeZsignPath(environment);
    final version = await _version(path, log);
    final findings = <Finding>[
      const Finding.pass(
        'platform',
        'zsign runs on this machine, without WSL2',
      ),
      ...zsignFindings(
        environment,
        redactor,
        key: nativeStateKey,
        where: where,
        path: path,
        version: version,
        hash: version == null ? null : await _hash(path),
        missing: _missing,
        commands: Finding.info(
          'zsign-build',
          'the commands that build the pinned zsign, to run yourself (winCode runs none of them):\n'
              '${zsignBuildCommandsIn('"${nativeZsignFolder(environment).path}"').map((c) => '    $c').join('\n')}',
        ),
      ),
    ];
    final (:file, :source, :problem) = await findDistKey(
      app,
      environment: environment,
      redactor: redactor,
      run: runTool,
    );
    if (problem != null) {
      findings.add(problem);
    } else if (!await canRead(file!.path)) {
      findings.add(
        Finding.fail('dist-key', keyUnreachable(source, app.credentials)),
      );
    } else {
      findings.add(
        Finding.pass(
          'dist-key',
          'the distribution key of $source is where zsign can read it, and only its owner can reach it (its content is '
              'checked by wincode sign)',
        ),
      );
    }
    return findings;
  }
}
