import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_cli/wincode_cli.dart';
import 'package:wincode_core/wincode_core.dart'
    show RunProcess, digestsOfFile, runProcess;

import 'private.dart';

/// ADR-0013, section 11 (Linux signing): which runner a platform gets, the command line and the pinned binary of the
/// native one, the record of its SHA-256 under the XDG data folder, and `doctor --sign` on Linux.
void main() {
  final sep = Platform.pathSeparator;
  final posix = Platform.isWindows ? 'the check is for POSIX systems' : null;
  late Directory temp;
  late Directory data;
  late Map<String, String> environment;
  late File binary;
  late String printedVersion;
  late List<List<String>> asked;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('wincode_native_');
    data = Directory('${temp.path}${sep}data');
    environment = {
      'XDG_DATA_HOME': data.path,
      'HOME': '${temp.path}${sep}home',
    };
    binary = File(nativeZsignPath(environment))
      ..createSync(recursive: true)
      ..writeAsStringSync('the bytes of a zsign');
    printedVersion = 'version: $zsignVersion';
    asked = [];
  });
  tearDown(() => temp.deleteSync(recursive: true));

  /// The short tools of the checks: the fake zsign prints [printedVersion]; anything else is run for real.
  Future<ProcessResult> tool(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    if (executable == binary.path) {
      if (!binary.existsSync()) {
        throw ProcessException(executable, arguments, 'No such file');
      }
      asked.add([executable, ...arguments]);
      return arguments.length == 1 && arguments.first == '-v'
          ? ProcessResult(0, 0, '$printedVersion\n', '')
          : ProcessResult(0, 64, '', 'unexpected');
    }
    return runProcess(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
  }

  NativeZsignRunner native() =>
      NativeZsignRunner(environment: environment, runTool: tool);

  Future<String> sha256Of(File file) async =>
      (await digestsOfFile(file)).sha256;

  /// What `wincode doctor --sign` records the first time it finds zsign.
  Future<void> record({String? hash, String key = nativeStateKey}) async {
    final file = zsignStateFile(environment)
      ..parent.createSync(recursive: true);
    file.writeAsStringSync(
      jsonEncode({
        'zsign': {
          key: {'path': binary.path, 'sha256': hash ?? await sha256Of(binary)},
        },
      }),
    );
  }

  Future<WincodeException> refused(ZsignRunner runner) async {
    try {
      await runner.requirePinned();
    } on WincodeException catch (e) {
      return e;
    }
    fail('the pinned zsign was accepted');
  }

  group('the runner follows the platform', () {
    RunProcess none = runProcess;

    test(
      'Windows gets WSL2, Linux gets zsign itself, anything else is refused',
      () {
        ZsignRunner runnerFor(String os) =>
            zsignRunnerFor(os, environment: environment, runTool: none);
        expect(runnerFor('windows'), isA<WslZsignRunner>());
        expect(runnerFor('linux'), isA<NativeZsignRunner>());
        for (final os in ['macos', 'freebsd', 'android', 'fuchsia']) {
          expect(runnerFor(os), isA<UnsupportedZsignRunner>(), reason: os);
        }
      },
    );

    test('the refusal is platform-unsupported (69), at every step', () async {
      final runner = zsignRunnerFor(
        'macos',
        environment: environment,
        runTool: none,
      );
      final e = await refused(runner);
      expect(e.id, 'platform-unsupported');
      expect(e.exitCode, ExitCode.unavailable);
      expect(e.what, 'wincode sign does not run on macos');
      expect(
        e.next,
        contains('--verify-only, preflight and upload work on macos'),
      );
      expect(
        () => runner.command('zsign', [], cd: '.'),
        throwsA(isA<WincodeException>()),
      );
      await expectLater(
        runner.translate('a'),
        throwsA(isA<WincodeException>()),
      );
    });
  });

  group('the command line of the native runner', () {
    test('is the pinned binary with the arguments as given, in the folder it works in: no shell, no WSL2', () {
      final command = native().command(binary.path, [
        '-k',
        '/home/me/keys/dist.key',
        '-o',
        '/work/signed.ipa',
        '/in.ipa',
      ], cd: '/work');
      expect(command.executable, binary.path);
      expect(command.arguments, [
        '-k',
        '/home/me/keys/dist.key',
        '-o',
        '/work/signed.ipa',
        '/in.ipa',
      ]);
      expect(command.workingDirectory, '/work');
      expect(
        command.executable,
        isNot(isIn(['sh', 'bash', 'dash', 'zsh', 'cmd', 'wsl.exe'])),
      );
    });

    test('a path needs no translation, and a file is readable when this user may open it', () async {
      final runner = native();
      expect(
        await runner.translate('/home/me/keys/dist.key'),
        '/home/me/keys/dist.key',
      );
      expect(await runner.canRead(binary.path), isTrue);
      expect(await runner.canRead('${temp.path}${sep}none'), isFalse);
    });

    test('the WSL2 runner puts the same arguments after wsl.exe --exec', () {
      final wsl = WslZsignRunner(environment: environment, runTool: tool);
      final command = wsl.command('/usr/zsign', ['-k', '/k'], cd: '/work');
      expect(command.executable, 'wsl.exe');
      expect(command.arguments, [
        '--cd',
        '/work',
        '--exec',
        '/usr/zsign',
        '-k',
        '/k',
      ]);
      expect(command.workingDirectory, isNull);
    });
  });

  group('the pinned zsign on Linux', () {
    test('is the binary in the data folder that prints the pinned version and has the recorded SHA-256', () async {
      await record();
      expect(await native().requirePinned(), binary.path);
      expect(
        binary.path,
        '${data.path}${sep}wincode${sep}zsign${sep}zsign-$zsignCommit${sep}bin${sep}zsign',
      );
      expect(asked, [
        [binary.path, '-v'],
      ]);
    });

    test('is missing when there is no binary: zsign-missing (69), with where it is built', () async {
      binary.deleteSync();
      final e = await refused(native());
      expect(e.id, 'zsign-missing');
      expect(e.exitCode, ExitCode.unavailable);
      expect(e.what, 'zsign is not installed on this machine');
      expect(e.why, contains(data.path));
      expect(e.next, contains('wincode doctor --sign'));
    });

    test('is unverified when nothing is recorded, or only another machine\'s entry: zsign-unverified', () async {
      expect((await refused(native())).id, 'zsign-unverified');
      await record(key: 'Ubuntu-24.04');
      final e = await refused(native());
      expect(e.id, 'zsign-unverified');
      expect(e.what, 'no SHA-256 of the zsign on this machine is recorded');
    });

    test(
      'is changed when its bytes are not the recorded ones: zsign-changed',
      () async {
        await record();
        binary.writeAsStringSync('a binary that something else put here');
        final e = await refused(native());
        expect(e.id, 'zsign-changed');
        expect(e.exitCode, ExitCode.failed);
        expect(e.what, 'the zsign on this machine is not the one winCode pins');
        expect(
          e.why,
          contains(
            'not the one recorded in ${zsignStateFile(environment).path}',
          ),
        );
      },
    );

    test(
      'is changed when it prints another version, even with the right bytes',
      () async {
        await record();
        printedVersion = 'version: 1.8.0';
        final e = await refused(native());
        expect(e.id, 'zsign-changed');
        expect(
          e.why,
          contains('It prints "version: 1.8.0", not version $zsignVersion'),
        );
      },
    );

    test('is missing when it cannot be started, whatever the reason', () async {
      await record();
      final broken = NativeZsignRunner(
        environment: environment,
        runTool: (executable, arguments, {workingDirectory}) =>
            throw const ProcessException('zsign', [], 'Exec format error'),
      );
      expect((await refused(broken)).id, 'zsign-missing');
    });
  });

  group('where winCode keeps its record', () {
    test('XDG_DATA_HOME, when it is absolute', () {
      expect(
        zsignStateFile({'XDG_DATA_HOME': data.path}).path,
        '${data.path}${sep}wincode${sep}zsign.json',
      );
    });

    test('~/.local/share when it is not set, empty or relative', () {
      final expected =
          '${temp.path}$sep.local${sep}share${sep}wincode${sep}zsign.json';
      for (final xdg in [null, '', 'relative${sep}path']) {
        expect(
          zsignStateFile({'HOME': temp.path, 'XDG_DATA_HOME': ?xdg}).path,
          expected,
          reason: '$xdg',
        );
      }
    });

    test('%LOCALAPPDATA% on Windows, where the WSL2 entries stay', () {
      expect(
        zsignStateFile({'LOCALAPPDATA': temp.path, 'XDG_DATA_HOME': data.path})
            .path,
        '${temp.path}${sep}wincode${sep}zsign.json',
      );
    });
  });

  group('wincode doctor --sign on Linux', () {
    const keyId = 'ABCDE12345';
    late File config;

    Directory keys(String reference) {
      final folder = privateFolders(
        Directory('${environment['HOME']}$sep.wincode${sep}keys$sep$reference')
          ..createSync(recursive: true),
        temp,
      );
      private(
        File('${folder.path}${sep}AuthKey_$keyId.p8')..writeAsStringSync('x'),
      );
      File('${folder.path}${sep}issuer-id')
          .writeAsStringSync('00000000-0000-4000-8000-000000000001\n');
      private(File('${folder.path}${sep}dist.key')..writeAsStringSync('x'));
      return folder;
    }

    setUp(() {
      config = File('${temp.path}${sep}wincode.yaml')
        ..writeAsStringSync(
          'bundle_id: com.example.alpha\nteam_id: TEAM000001\ncredentials: team-one\n',
        );
      environment['USERPROFILE'] = environment['HOME']!;
    });

    Future<(int, String)> doctor([List<String> more = const []]) async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runWincode(
        ['doctor', '--sign', '--config', config.path, ...more],
        out,
        err,
        environment: environment,
        run: tool,
        platform: 'linux',
      );
      expect('$out$err', isNot(contains('PRIVATE KEY')));
      return (code, '$out');
    }

    test('records the SHA-256 of the binary it finds (trust on first use), and then keeps it', () async {
      keys('team-one');
      final (first, out) = await doctor();
      expect(first, 0, reason: out);
      expect(out, contains('PASS  zsign runs on this machine, without WSL2'));
      expect(out, contains('PASS  zsign $zsignVersion is built; its SHA-256 '));
      expect(
        out,
        contains('is now recorded in ${zsignStateFile(environment).path}'),
      );
      expect(jsonDecode(zsignStateFile(environment).readAsStringSync()), {
        'zsign': {
          nativeStateKey: {
            'path': binary.path,
            'sha256': await sha256Of(binary),
          },
        },
      });
      expect(
        out,
        contains(
          'PASS  the distribution key of the credentials team-one is where zsign can read it',
        ),
      );
      final (second, again) = await doctor();
      expect(second, 0, reason: again);
      expect(
        again,
        contains('PASS  zsign $zsignVersion has the SHA-256 recorded in'),
      );
    });

    test('a binary that changed after it was recorded fails, with the commands that build it', () async {
      keys('team-one');
      await record();
      binary.writeAsStringSync('something else');
      final (code, out) = await doctor();
      expect(code, 1, reason: out);
      expect(
        out,
        contains('FAIL  the zsign on this machine is not the one winCode pins'),
      );
      expect(out, contains('INFO  the commands that build the pinned zsign'));
    });

    test('no binary: zsign-missing, and the commands to build it in the data folder, run by nobody', () async {
      keys('team-one');
      binary.deleteSync();
      final (code, out) = await doctor();
      expect(code, 69, reason: out);
      expect(out, contains('FAIL  zsign is not installed on this machine'));
      final zsignFolder = '${data.path}${sep}wincode${sep}zsign';
      expect(out, contains('mkdir -p "$zsignFolder" && cd "$zsignFolder"'));
      expect(
        out,
        contains(
          'curl -fL -o zsign-$zsignCommit.tar.gz https://github.com/xtool-org/zsign/archive/$zsignCommit.tar.gz',
        ),
      );
      expect(
        out,
        contains(
          'echo "$zsignSourceSha256  zsign-$zsignCommit.tar.gz" | sha256sum -c -',
        ),
      );
      expect(zsignStateFile(environment).existsSync(), isFalse);
      expect(asked, isEmpty);
    });

    test(
      'a distribution key that other users can read is a failed check, with 78',
      () async {
        final folder = keys('team-one');
        Process.runSync('chmod', ['644', '${folder.path}${sep}dist.key']);
        final (code, out) = await doctor();
        expect(code, 78, reason: out);
        expect(
          out,
          contains(
            'FAIL  the distribution key of the credentials team-one can be reached by other users (mode 0644)',
          ),
        );
        expect(
          out,
          contains('next: run: chmod 600 ~/.wincode/keys/team-one/dist.key'),
        );
      },
      skip: posix,
    );

    test(
      'no distribution key: dist-key-missing, with where to put it',
      () async {
        final folder = keys('team-one');
        File('${folder.path}${sep}dist.key').deleteSync();
        final (code, out) = await doctor();
        expect(code, 78, reason: out);
        expect(
          out,
          contains(
            'FAIL  the distribution key of the credentials team-one does not exist',
          ),
        );
      },
    );

    test(
      'on macOS it fails the platform check, and asks nothing of any binary',
      () async {
        keys('team-one');
        final result = StringBuffer();
        final code = await runWincode(
          ['doctor', '--sign', '--config', config.path],
          result,
          StringBuffer(),
          environment: environment,
          run: tool,
          platform: 'macos',
        );
        expect(code, 69, reason: '$result');
        expect('$result', contains('FAIL  wincode sign does not run on macos'));
        expect(asked, isEmpty);
      },
    );
  });
}
