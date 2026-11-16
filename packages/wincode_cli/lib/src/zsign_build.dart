import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wincode_core/wincode_core.dart';

import 'failure.dart';
import 'key_permissions.dart' show makePrivate;
import 'preflight.dart' show Finding;
import 'redact.dart';
import 'tar_unpack.dart';
import 'zsign.dart';
import 'zsign_native.dart';

/// `wincode doctor --sign --build-zsign` (ADR-0013, phase 3a.1, the Linux half): winCode builds the pinned zsign itself,
/// from the source archive of the pinned commit, so that the binary's provenance is known and its SHA-256 is recorded
/// from the build instead of from whatever was found in place.
///
/// What it does is the list of [zsignBuildCommandsIn], the commands that `doctor --sign` prints, with the three steps
/// that handle untrusted bytes done by winCode and not by a shell: the download (HTTPS only, with a timeout and a size
/// cap), the SHA-256 check (before anything is unpacked) and the unpacking ([unpackTarGz], which refuses a path outside
/// the folder and every link). The install line is never run: a missing tool stops the command with the line to run by
/// hand. The build is `make` as the list prints it, started as an argument list, as the user, with no shell and no
/// `sudo`.

/// Downloads [url] into [file]. Throws a [WincodeException] when it cannot: tests pass a fake one.
typedef ZsignFetch = Future<void> Function(
  Uri url,
  File file, {
  required int maxBytes,
  required Duration timeout,
});

/// What `--build-zsign` downloads and how far it trusts it. The defaults are the pin of winCode; tests inject their own.
class ZsignSource {
  ZsignSource({
    Uri? url,
    String? sha256,
    this.fetch = downloadArchive,
    this.maxDownload = 64 << 20,
    this.maxUnpacked = 256 << 20,
    this.timeout = const Duration(seconds: 30),
  }) : url = url ?? _printedPlan().url,
       sha256 = sha256 ?? zsignSourceSha256;

  /// GitHub's archive of the pinned commit: the address in the printed commands.
  final Uri url;

  /// The SHA-256 that the archive must have.
  final String sha256;

  final ZsignFetch fetch;

  /// The most bytes of the archive that are accepted.
  final int maxDownload;

  /// The most bytes that the archive may unpack to.
  final int maxUnpacked;

  /// How long a connection, an answer or a pause in the data may take.
  final Duration timeout;
}

/// What the commands of [zsignBuildCommandsIn] do that winCode does not leave to a shell, read from the list itself so
/// that there is one list: the address that `curl` fetches, and the `make` line without its comment.
({Uri url, List<String> make}) _printedPlan() {
  final commands = zsignBuildCommandsIn('<folder>');
  final curl = commands.firstWhere((c) => c.startsWith('curl '));
  final make = commands.firstWhere((c) => c.startsWith('make '));
  return (
    url: Uri.parse(RegExp(r'https://\S+').firstMatch(curl)!.group(0)!),
    make: make.split('#').first.trim().split(RegExp(r'\s+')),
  );
}

/// The refusal of `--build-zsign` where it is not built: on Windows (`not-implemented`, 64: it will build inside WSL2,
/// which is not built yet) and elsewhere (`platform-unsupported`, 69, as `wincode sign` says). Returns the runner of
/// Linux, which builds.
Future<NativeZsignRunner> zsignBuildRunner(ZsignRunner zsign) async {
  if (zsign is NativeZsignRunner) {
    return zsign;
  }
  if (zsign is WslZsignRunner) {
    throw const WincodeException(
      ExitCode.usage,
      'not-implemented',
      '--build-zsign is not built on Windows yet',
      why: 'on Windows it will build zsign inside WSL2 (ADR-0013, phase 3a.1), and only the Linux half is built.',
      next: 'build zsign with the commands that wincode doctor --sign prints, in WSL2, as before.',
    );
  }
  // The runner of an unsupported system fails with platform-unsupported (69), the refusal of wincode sign.
  await zsign.requirePinned();
  throw StateError('no runner builds zsign');
}

/// `--build-zsign` on Linux: [build] does it, [plan] says what it would do.
class ZsignBuilder {
  ZsignBuilder(this.runner, this.source, this.redactor, {this.log});

  final NativeZsignRunner runner;
  final ZsignSource source;
  final Redactor redactor;

  /// Gets each external command with `--verbose`.
  final void Function(String line)? log;

  Map<String, String> get _environment => runner.environment;
  final _s = Platform.pathSeparator;

  Directory get _folder => nativeZsignFolder(_environment);

  void _hidePaths() {
    redactor
      ..hide(_folder.path, '<zsign folder>')
      ..hide(zsignStateFile(_environment).path, '<zsign record>');
  }

  /// What `--dry-run` prints: the steps, the address and the folder, and the printed commands. Nothing is run or read.
  List<Finding> plan() {
    _hidePaths();
    final record = zsignStateFile(_environment);
    return [
      Finding.info(
        'zsign-build',
        'dry run: nothing is downloaded, built or written. wincode doctor --sign --build-zsign would:\n'
            '    1. download ${source.url} (HTTPS only; at most ${source.maxDownload >> 20} MiB; ${source.timeout.inSeconds} s without data)\n'
            '    2. refuse the archive unless its SHA-256 is ${source.sha256}, before unpacking anything\n'
            '    3. unpack it in a private folder under ${_folder.path}, refusing a path outside it and every link\n'
            '    4. run ${_printedPlan().make.join(' ')} there, as you (never sudo; nothing is installed: a missing tool stops it with the command to run by hand)\n'
            '    5. check that the zsign it built prints version: $zsignVersion\n'
            '    6. put it at ${nativeZsignPath(_environment)}, keeping the old one until then, and record its SHA-256 in ${record.path}',
      ),
      Finding.info(
        'zsign-build-commands',
        'the commands of wincode doctor --sign that this stands for (winCode does the download, the check and the unpacking itself, and never runs the install line):\n'
            '${zsignBuildCommandsIn('"${_folder.path}"').map((c) => '    $c').join('\n')}',
      ),
    ];
  }

  Future<bool> _runs(String tool, List<String> arguments) async {
    log?.call('$tool ${arguments.join(' ')}');
    try {
      return (await runner.runTool(tool, arguments)).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// Builds the pinned zsign. Each step is a finding, PASS or FAIL, and the first FAIL ends it: the previous install and
  /// its record are as they were. Does nothing, with a PASS, when this command built the pinned zsign before.
  Future<List<Finding>> build() async {
    _hidePaths();
    final binary = nativeZsignPath(_environment);
    final record = zsignStateFile(_environment);
    if (await _builtBefore(binary)) {
      return [
        Finding.pass(
          'zsign-build',
          'zsign $zsignVersion was built by this command and is unchanged (SHA-256 recorded in ${record.path}): nothing '
              'to do. To build it again, delete ${_folder.path}${_s}zsign-$zsignCommit and run this command again',
        ),
      ];
    }
    final findings = <Finding>[];
    List<Finding> stop(String check, WincodeException e) => [
      ...findings,
      Finding.fail(check, e),
    ];

    // The tools come first: a missing one stops it before anything is downloaded.
    final (:tools, :compiler) = await _checkTools();
    if (tools != null) {
      return stop('zsign-build-tools', tools);
    }
    findings.add(
      Finding.pass(
        'zsign-build-tools',
        'the tools that build zsign are there: ${compiler.isEmpty ? 'g++' : 'clang++ and clang (no g++, so make gets CXX=clang++ CC=clang)'}, '
            'make, pkg-config and the OpenSSL development files',
      ),
    );

    _folder.createSync(recursive: true);
    // A new folder for this build inside the folder that winCode owns, so that the finished tree is moved into place by
    // a rename. dart:io makes it with the umask, so it is closed to other users (mode 0700) before anything goes in.
    final staging = await _folder.createTemp('.build-');
    final backup = Directory('${staging.path}.old');
    try {
      try {
        await makePrivate(staging);
      } on WincodeException catch (e) {
        return stop('zsign-build', e);
      }
      final archive = File('${staging.path}${_s}zsign-$zsignCommit.tar.gz');
      try {
        log?.call('GET ${source.url.host} (${source.url.path})');
        await source.fetch(
          source.url,
          archive,
          maxBytes: source.maxDownload,
          timeout: source.timeout,
        );
      } on WincodeException catch (e) {
        return stop('zsign-archive', e);
      }
      final size = archive.existsSync() ? archive.lengthSync() : -1;
      if (size < 0 || size > source.maxDownload) {
        return stop(
          'zsign-archive',
          _refused(
            size < 0
                ? 'the download left no file'
                : 'the zsign source is larger than ${source.maxDownload >> 20} MiB',
          ),
        );
      }
      final found = (await digestsOfFile(archive)).sha256;
      if (found != source.sha256) {
        // Nothing is unpacked and nothing is built: the download goes, and the install and its record stay as they are.
        archive.deleteSync();
        return stop(
          'zsign-archive',
          WincodeException(
            ExitCode.failed,
            'zsign-archive-mismatch',
            'the zsign source that was downloaded is not the pinned one',
            why:
                'its SHA-256 is $found, not ${source.sha256}. Nothing from it was unpacked or built, the download was '
                'deleted, and the zsign that was there, with its record, is as it was.',
            next:
                'run the command again. If it fails the same way, do not build from this archive: either '
                '${source.url.host} serves other bytes than the pinned commit had, or something on the way changes them. '
                'Report it at https://github.com/wincode-org/wincode/issues.',
          ),
        );
      }
      findings.add(
        Finding.pass(
          'zsign-archive',
          'downloaded the zsign source ($size bytes) from ${source.url.host}; its SHA-256 ${found.substring(0, 12)}... is the pinned one',
        ),
      );

      final int files;
      try {
        files = await unpackTarGz(
          archive,
          staging,
          maxBytes: source.maxUnpacked,
        );
      } on TarRefused catch (e) {
        return stop(
          'zsign-unpack',
          WincodeException(
            ExitCode.failed,
            'zsign-archive-unsafe',
            'the zsign source cannot be unpacked safely: ${e.message}',
            why:
                'winCode unpacks only files and folders under the build folder. The archive had the pinned SHA-256, so '
                'this is a bug in winCode or in its pin. Nothing was built, and the zsign that was there is as it was.',
            next:
                'report it at https://github.com/wincode-org/wincode/issues, and build zsign with the commands that '
                'wincode doctor --sign prints in the meantime.',
          ),
        );
      }
      findings.add(
        Finding.pass(
          'zsign-unpack',
          'unpacked $files files, none outside the build folder and no link',
        ),
      );

      final staged = '${staging.path}${_s}zsign-$zsignCommit${_s}bin${_s}zsign';
      final make = [..._printedPlan().make, ...compiler];
      final clock = Stopwatch()..start();
      final ProcessResult made;
      try {
        log?.call('${make.join(' ')} (in ${staging.path})');
        made = await runner.runTool(
          make.first,
          make.skip(1).toList(),
          workingDirectory: staging.path,
        );
      } on ProcessException catch (e) {
        return stop(
          'zsign-build',
          _buildFailed('make cannot be started: ${e.message}'),
        );
      }
      if (made.exitCode != 0 || !File(staged).existsSync()) {
        return stop(
          'zsign-build',
          _buildFailed(
            made.exitCode != 0
                ? '${make.join(' ')} exited with ${made.exitCode}'
                : '${make.join(' ')} ended without a zsign binary',
            tail: '${made.stderr}\n${made.stdout}',
          ),
        );
      }
      findings.add(
        Finding.pass(
          'zsign-build',
          'built zsign with ${make.join(' ')} in ${clock.elapsed.inSeconds} s',
        ),
      );

      // The new binary has to pass the check that wincode sign makes before anything of the old install is touched.
      final printed = await _version(staged);
      if (printed != 'version: $zsignVersion') {
        return stop(
          'zsign-version',
          _buildFailed(
            'the zsign that was built prints ${printed == null ? 'nothing' : '"$printed"'}, not version $zsignVersion',
          ),
        );
      }
      findings.add(
        Finding.pass(
          'zsign-version',
          'the zsign that was built prints version: $zsignVersion',
        ),
      );

      final hash = (await digestsOfFile(File(staged))).sha256;
      final before = recordedZsignHash(_environment, nativeStateKey, binary);
      final failure = _install(staging, backup, hash, record, binary: binary);
      if (failure != null) {
        return stop('zsign-record', failure);
      }
      findings.add(
        Finding.pass(
          'zsign-record',
          'installed at $binary; its SHA-256 ${hash.substring(0, 12)}... is recorded in ${record.path}'
              '${before != null && before != hash ? ' (replacing ${before.substring(0, 12)}...)' : ''}: '
              'wincode sign runs this binary only',
        ),
      );
      return findings;
    } finally {
      for (final folder in [staging, backup]) {
        try {
          if (folder.existsSync()) {
            folder.deleteSync(recursive: true);
          }
        } on FileSystemException {
          // Nothing depends on it; the next run makes its own folder.
        }
      }
    }
  }

  /// Puts the tree built in [staging] where `wincode sign` looks for it and records [hash]. The old tree goes to [backup]
  /// first and comes back, with the old record, when anything fails. Returns the failure, or null.
  WincodeException? _install(
    Directory staging,
    Directory backup,
    String hash,
    File record, {
    required String binary,
  }) {
    final target = Directory('${_folder.path}${_s}zsign-$zsignCommit');
    final hadRecord = record.existsSync();
    final oldRecord = hadRecord ? _tryRead(record) : null;
    var movedOld = false;
    var placed = false;
    try {
      if (target.existsSync()) {
        target.renameSync(backup.path);
        movedOld = true;
      }
      Directory('${staging.path}${_s}zsign-$zsignCommit')
          .renameSync(target.path);
      placed = true;
      recordZsignHash(
        _environment,
        nativeStateKey,
        binary,
        hash,
        extra: {
          'built': {'commit': zsignCommit, 'sourceSha256': source.sha256},
        },
      );
      return null;
    } on FileSystemException catch (e) {
      try {
        if (placed) {
          target.deleteSync(recursive: true);
        }
        if (movedOld) {
          backup.renameSync(target.path);
        }
        if (oldRecord != null) {
          record.writeAsStringSync(oldRecord);
        } else if (!hadRecord && record.existsSync()) {
          record.deleteSync();
        }
      } on FileSystemException {
        // The failure below says what state it is in.
      }
      return _buildFailed(
        'cannot put the new zsign in place: ${e.osError?.message ?? e.message}',
        restored: true,
      );
    }
  }

  String? _tryRead(File file) {
    try {
      return file.readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  /// What `zsign -v` prints at [path], trimmed; null when it cannot be started, fails or prints nothing.
  Future<String?> _version(String path) async {
    log?.call('$path -v');
    try {
      final result = await runner.runTool(path, ['-v']);
      final text = '${result.stdout}'.trim();
      return result.exitCode == 0 && text.isNotEmpty ? text : null;
    } on ProcessException {
      return null;
    }
  }

  /// Whether the pinned zsign that `wincode sign` would run was built by this command from this pin: it passes the
  /// checks of `sign` (the pinned version, the recorded SHA-256), and the record says that it was built.
  Future<bool> _builtBefore(String binary) async {
    try {
      await runner.requirePinned(log: log);
    } on WincodeException {
      return false;
    }
    try {
      if (jsonDecode(zsignStateFile(_environment).readAsStringSync()) case {
        'zsign': {
          nativeStateKey: {
            'built': {
              'commit': final String commit,
              'sourceSha256': final String archive,
            },
          },
        },
      }) {
        return commit == zsignCommit && archive == source.sha256;
      }
    } on Object {
      // No record, or one that cannot be read.
    }
    return false;
  }

  /// Which of the tools that the build needs are missing: null when none is, else the failure with the command to run by
  /// hand. [compiler] is what `make` gets to use clang, as the printed commands say, where there is no g++.
  Future<({WincodeException? tools, List<String> compiler})>
  _checkTools() async {
    final gpp = await _runs('g++', ['--version']);
    final clang =
        !gpp &&
        await _runs('clang++', ['--version']) &&
        await _runs('clang', ['--version']);
    final make = await _runs('make', ['--version']);
    final pkg = await _runs('pkg-config', ['--version']);
    final ssl = pkg && await _runs('pkg-config', ['--exists', 'openssl']);
    final missing = <(String, String)>[
      if (!gpp && !clang) ('g++', 'g++'),
      if (!make) ('make', 'make'),
      if (!pkg) ('pkg-config', 'pkg-config'),
      if (!ssl)
        (
          pkg
              ? 'the OpenSSL development files (pkg-config does not find openssl)'
              : 'the OpenSSL development files (they cannot be looked for without pkg-config)',
          'libssl-dev',
        ),
    ];
    final compiler = clang ? ['CXX=clang++', 'CC=clang'] : const <String>[];
    if (missing.isEmpty) {
      return (tools: null, compiler: compiler);
    }
    return (
      tools: WincodeException(
        ExitCode.failed,
        'zsign-build-tools-missing',
        'cannot build zsign: ${missing.map((m) => m.$1).join(', ')} ${missing.length == 1 ? 'is' : 'are'} missing',
        why:
            'zsign is built from its source with g++ (or clang), make, pkg-config and the OpenSSL development files, as '
            'the commands of wincode doctor --sign do. winCode installs nothing and never runs sudo, so it stopped before '
            'downloading anything.',
        next:
            'install them with your package manager, then run this command again. On Debian or Ubuntu: '
            'sudo apt-get install ${missing.map((m) => m.$2).join(' ')}',
      ),
      compiler: compiler,
    );
  }

  WincodeException _refused(String what) => WincodeException(
    ExitCode.failed,
    'zsign-download-refused',
    what,
    why: 'winCode downloads only the pinned source archive, and only as far as its limits.',
    next: 'run the command again; nothing was changed.',
  );

  /// A failure of the build or of putting its result in place. The zsign that was there is as it was.
  WincodeException _buildFailed(
    String what, {
    String tail = '',
    bool restored = false,
  }) {
    final lines = tail
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.isNotEmpty)
        .toList();
    return WincodeException(
      ExitCode.failed,
      'zsign-build-failed',
      'the zsign build failed: $what',
      why:
          'the zsign that was there, with its record, is as it was${restored ? ' (it was put back)' : ''}.'
          '${lines.isEmpty ? '' : ' The last lines of the build:\n    ${lines.skip(lines.length > 8 ? lines.length - 8 : 0).join('\n    ')}'}',
      next:
          'fix what the lines above say, and run the command again; or build zsign by hand with the commands that '
          'wincode doctor --sign prints.',
    );
  }
}

/// The real [ZsignFetch]: a GET over HTTPS, the only way that winCode downloads the zsign source. A redirect is followed
/// by hand, up to five times, and only to an HTTPS address, so that the download never leaves TLS; no credential is sent.
/// The answer is written to [file] as it comes and stops, with the file deleted, at [maxBytes]. [timeout] limits the
/// connection, the wait for the answer and every pause in the data, and [overall] the whole download. [loopbackHttp] lets
/// a test use `http` on 127.0.0.1; nothing else sets it.
///
/// Throws `offline` (69) when there is no answer, `github-unavailable` (69) for HTTP 5xx, and `zsign-download-refused`
/// (1) for another answer, an address that is not HTTPS, or too many bytes.
Future<void> downloadArchive(
  Uri url,
  File file, {
  required int maxBytes,
  required Duration timeout,
  Duration overall = const Duration(minutes: 10),
  bool loopbackHttp = false,
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..findProxy = HttpClient.findProxyFromEnvironment
    ..userAgent = 'wincode';
  WincodeException refused(String what) => WincodeException(
    ExitCode.failed,
    'zsign-download-refused',
    what,
    why: 'winCode downloads only the pinned source archive, over HTTPS, and only as far as its limits.',
    next: 'run the command again; nothing was changed.',
  );
  final work = () async {
    var at = url;
    for (var hops = 0; ; hops++) {
      final plain =
          loopbackHttp &&
          at.scheme == 'http' &&
          (at.host == 'localhost' ||
              InternetAddress.tryParse(at.host)?.isLoopback == true);
      if ((at.scheme != 'https' && !plain) ||
          !at.hasAuthority ||
          at.userInfo.isNotEmpty) {
        throw refused(
          'the zsign source is not fetched from ${at.scheme}://${at.host}: only https addresses are used',
        );
      }
      final request = await client.getUrl(at);
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      final status = response.statusCode;
      if (status != 200) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>().timeout(timeout).catchError((Object _) {});
        if (status >= 300 && status < 400 && location != null && hops < 5) {
          at = at.resolve(location);
          continue;
        }
        throw status >= 500
            ? WincodeException(
                ExitCode.unavailable,
                'github-unavailable',
                '${at.host} answered the download of the zsign source with HTTP $status',
                why: "GitHub's service is down or overloaded.",
                next: "check GitHub's status page, then run the command again; nothing was changed.",
              )
            : refused(
                '${at.host} answered the download of the zsign source with HTTP $status',
              );
      }
      if (response.contentLength > maxBytes) {
        throw refused(
          'the zsign source is larger than ${maxBytes >> 20} MiB: ${at.host} says ${response.contentLength} bytes',
        );
      }
      var bytes = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in response.timeout(timeout)) {
          bytes += chunk.length;
          if (bytes > maxBytes) {
            throw refused(
              'the zsign source is larger than ${maxBytes >> 20} MiB',
            );
          }
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      return;
    }
  }();
  try {
    await work.timeout(overall);
  } on WincodeException {
    _deleteQuietly(file);
    rethrow;
  } on TimeoutException {
    // The download may still be running (the whole took too long): end it, and let it close the file before it goes.
    client.close(force: true);
    await work.then<void>((_) {}, onError: (Object _) {});
    _deleteQuietly(file);
    throw _offline(
      url,
      'no answer or no data within ${timeout.inSeconds} s, or the download took longer than ${overall.inMinutes} minutes',
    );
  } on IOException catch (e) {
    _deleteQuietly(file);
    // The message only: an HttpException's toString carries the address.
    throw _offline(url, switch (e) {
      SocketException(:final osError?) => osError.message,
      SocketException(:final message) => message,
      TlsException(:final message, :final osError) =>
        '$message${osError == null ? '' : ': ${osError.message}'}',
      HttpException(:final message) => message,
      _ => e.runtimeType.toString(),
    });
  } finally {
    client.close(force: true);
  }
}

WincodeException _offline(Uri url, String why) => WincodeException(
  ExitCode.unavailable,
  'offline',
  'cannot download the zsign source from ${url.host}: $why',
  why: "there is no network, a proxy or a firewall is in the way, or GitHub's service is down.",
  next: 'check the connection (and HTTPS_PROXY, if you use one), then run the command again; nothing was changed.',
);

void _deleteQuietly(File file) {
  try {
    if (file.existsSync()) {
      file.deleteSync();
    }
  } on FileSystemException {
    // The folder is deleted by the caller.
  }
}
