import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wincode_asc/testing.dart';
import 'package:wincode_asc/wincode_asc.dart';
import 'package:wincode_cli/wincode_cli.dart';
import 'package:wincode_core/testing.dart';
import 'package:wincode_core/wincode_core.dart'
    show
        PlistMap,
        ZipArchive,
        parsePlist,
        readCertificate,
        readProvisioningProfile,
        runProcess,
        writePlist,
        writePlistBinary;

final _now = DateTime.utc(2026, 11, 11, 12);
final _expires = _now.add(const Duration(days: 300));
const _team = 'TEAM000000';
const _bundleId = 'com.example.app';
const _distro = 'Ubuntu-test';
const _home = '/home/me';
final _hash = 'a' * 64;

/// The unsigned app of [bundleId], as the reference workflow packs it.
Map<String, List<int>> _unsigned({
  String bundleId = _bundleId,
  bool extension = false,
}) => {
  'Payload/': [],
  'Payload/Runner.app/': [],
  'Payload/Runner.app/Info.plist': writePlistBinary({
    'CFBundleIdentifier': bundleId,
    'CFBundleExecutable': 'Runner',
    'CFBundleShortVersionString': '1.0',
    'CFBundleVersion': '14',
  }),
  'Payload/Runner.app/Runner': [
    ...executable(signed: false),
    ...List.filled(5000, 7),
  ],
  'Payload/Runner.app/Frameworks/App.framework/Info.plist': writePlistBinary({
    'CFBundleIdentifier': 'io.flutter.flutter.app',
    'CFBundleExecutable': 'App',
  }),
  'Payload/Runner.app/Frameworks/App.framework/App': executable(signed: false),
  if (extension)
    'Payload/Runner.app/PlugIns/Share.appex/Share': executable(signed: false),
};

/// The profile of [bundleId] for [team], listing [certificates], allowing [entitlements] besides the usual ones.
Uint8List _profile(
  List<Uint8List> certificates, {
  String team = _team,
  String bundleId = _bundleId,
  PlistMap? entitlements,
}) {
  final plist = appStoreProfile(
    teamId: team,
    bundleId: bundleId,
    expires: _expires,
  );
  return profileOf({
    ...plist,
    'DeveloperCertificates': certificates,
    'Entitlements': {...plist['Entitlements']! as PlistMap, ...?entitlements},
  });
}

/// The contents of [file], a zip archive, by name.
Map<String, List<int>> _unzip(File file) {
  final zip = ZipArchive.open(file);
  try {
    return {
      for (final n in zip.names) n: n.endsWith('/') ? <int>[] : zip.read(n),
    };
  } finally {
    zip.close();
  }
}

/// WSL2 as the tests see it: one distribution, [_distro], that reaches the host's files under `/mnt/host`.
class _FakeWsl {
  final commands = <List<String>>[];
  var installed = true;
  var version = 2;
  String? zsignVersion = 'version: 1.9.0';
  var zsignHash = _hash;
  bool Function(String path) translates = (_) => true;

  static const prefix = '/mnt/host';

  String toWsl(String host) =>
      '$prefix/${host.replaceAll(r'\', '/').replaceFirst(RegExp('^/'), '')}';

  String toHost(String wsl) {
    final rest = wsl.substring(prefix.length + 1);
    return Platform.isWindows ? rest.replaceAll('/', r'\') : '/$rest';
  }

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    if (executable != 'wsl.exe') {
      return runProcess(
        executable,
        arguments,
        workingDirectory: workingDirectory,
      );
    }
    if (!installed) {
      throw const ProcessException(
        'wsl.exe',
        [],
        'The system cannot find the file specified.',
      );
    }
    commands.add(arguments);
    ProcessResult result(int code, [String out = '']) =>
        ProcessResult(0, code, out, '');
    if (arguments case ['-l', '-v']) {
      // wsl.exe writes this list in UTF-16, which a single-byte decoder leaves with a NUL after each character.
      return result(
        0,
        [
          '  NAME              STATE           VERSION',
          '* $_distro       Running         $version',
          '  docker-desktop    Stopped         2',
          '',
        ].join('\r\n').split('').map((c) => '$c\u0000').join(),
      );
    }
    final command = arguments.sublist(arguments.indexOf('--exec') + 1);
    return switch (command) {
      ['printenv', 'HOME'] => result(0, '$_home\n'),
      [final zsign, '-v'] when zsign == zsignPath(_home) =>
        zsignVersion == null ? result(127) : result(0, '$zsignVersion\n'),
      ['sha256sum', _] => result(0, '$zsignHash  ${command[1]}\n'),
      ['wslpath', '-u', final path] =>
        translates(path) ? result(0, '${toWsl(path)}\n') : result(1),
      ['test', '-r', final path] => result(
        File(toHost(path)).existsSync() ? 0 : 1,
      ),
      _ => result(127),
    };
  }
}

/// Fails the test if App Store Connect is asked anything: only the tests of its own group allow it.
AscClient _noAppStoreConnect(
  String Function() token,
  void Function(String)? log,
) => throw StateError('App Store Connect was asked');

/// How the fake zsign behaves.
enum _Zsign { signs, fails, hangs, garbage, grows }

/// A process that the test drives: it says lines, writes files and ends when the test or [kill] says.
class _FakeProcess implements Process {
  final _out = StreamController<List<int>>();
  final _err = StreamController<List<int>>();
  final _exit = Completer<int>();
  var killed = false;

  @override
  Stream<List<int>> get stdout => _out.stream;

  @override
  Stream<List<int>> get stderr => _err.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  IOSink get stdin => throw UnsupportedError('zsign reads no input');

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    finish(-9);
    return true;
  }

  void say(String line) => _out.add(utf8.encode('$line\n'));

  void finish(int code) {
    if (!_exit.isCompleted) {
      unawaited(_out.close());
      unawaited(_err.close());
      _exit.complete(code);
    }
  }
}

void main() {
  late Directory temp;
  late Directory app;
  late File config;
  late File distKey;
  late File profile;
  late Directory state;
  late _FakeWsl wsl;
  late List<List<String>> started;
  late List<_FakeProcess> processes;
  late _Zsign behaviour;
  late ZsignRunner runner;
  late Map<String, String> environment;
  late TestRsaKey key;
  late Uint8List certificate;

  String inside(Directory folder, String name) =>
      '${folder.path}${Platform.pathSeparator}$name';
  Directory output() => Directory(inside(app, 'build'));
  File signed() => File(inside(output(), 'signed.ipa'));

  /// What is left of the signing in the output folder: nothing but the IPAs.
  List<String> leftovers() => [
    for (final e in output().listSync())
      e.uri.pathSegments.where((s) => s.isNotEmpty).last,
  ]..removeWhere((n) => n == 'unsigned.ipa' || n == 'signed.ipa');

  Future<Process> start(String executable, List<String> arguments) async {
    expect(executable, 'wsl.exe');
    started.add(arguments);
    final process = _FakeProcess();
    processes.add(process);
    final command = arguments.sublist(arguments.indexOf('--exec') + 1);
    String host(String flag) => wsl.toHost(command[command.indexOf(flag) + 1]);
    final out = File(host('-o'));
    switch (behaviour) {
      case _Zsign.signs:
        final entitlements =
            parsePlist(File(host('-e')).readAsStringSync())! as PlistMap;
        final pem = File(host('-c')).readAsStringSync();
        final der = base64.decode(
          pem.split('\n').where((l) => !l.startsWith('-----')).join(),
        );
        out.writeAsBytesSync(
          zipOf(
            signTestIpa(
              _unzip(File(wsl.toHost(command.last))),
              teamId: _team,
              entitlements: entitlements,
              key: key,
              certificate: der,
              profile: File(host('-m')).readAsBytesSync(),
            ),
          ),
        );
        process
          ..say('>>> Signing:  ${command.last}')
          ..say('>>> Done.')
          ..finish(0);
      case _Zsign.fails:
        out.writeAsBytesSync([1, 2, 3]);
        process
          ..say('>>> Can not find a certificate that matches the private key.')
          ..finish(1);
      case _Zsign.hangs:
        out.writeAsBytesSync([1, 2, 3]);
      case _Zsign.garbage:
        out.writeAsStringSync('this is not a zip archive');
        process.finish(0);
      case _Zsign.grows:
        File('${host('-t')}${Platform.pathSeparator}copy')
            .writeAsBytesSync(Uint8List(4096));
    }
    return process;
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('wincode_sign_');
    key = TestRsaKey();
    certificate = testCertificate(key, notAfter: _expires);
    app = Directory(inside(temp, 'app'))..createSync();
    config = File(inside(app, 'wincode.yaml'))
      ..writeAsStringSync(
        'bundle_id: $_bundleId\nteam_id: $_team\nprofile: App_Store.mobileprovision\noutput: build\n',
      );
    profile = File(inside(app, 'App_Store.mobileprovision'))
      ..writeAsBytesSync(_profile([certificate]));
    output().createSync();
    File(inside(output(), 'unsigned.ipa')).writeAsBytesSync(zipOf(_unsigned()));
    final keys = Directory(inside(temp, 'keys'))..createSync();
    distKey = File(inside(keys, 'dist.key'))..writeAsStringSync(key.pem());
    state = Directory(inside(temp, 'state'));
    wsl = _FakeWsl();
    started = [];
    processes = [];
    behaviour = _Zsign.signs;
    runner = ZsignRunner(
      start: start,
      poll: const Duration(milliseconds: 5),
      timeout: const Duration(milliseconds: 400),
      limit: 1024 * 1024,
    );
    environment = {
      'WINCODE_DIST_KEY': distKey.path,
      distroVariable: _distro,
      'LOCALAPPDATA': state.path,
    };
    // What wincode doctor --sign records the first time it finds zsign.
    zsignStateFile(environment)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'zsign': {
            _distro: {'path': zsignPath(_home), 'sha256': _hash},
          },
        }),
      );
  });

  tearDown(() => temp.deleteSync(recursive: true));

  /// Runs wincode with [args] and checks that neither the key nor where it lies was printed.
  Future<(int, String, String)> wincode(
    List<String> args, {
    AscConnect connect = _noAppStoreConnect,
    String configPath = '',
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runWincode(
      [
        args.first,
        '--config',
        configPath.isEmpty ? config.path : configPath,
        ...args.skip(1),
      ],
      out,
      err,
      environment: environment,
      clock: () => _now,
      connect: connect,
      run: wsl.run,
      zsign: runner,
    );
    final printed = '$out$err';
    for (final secret in [
      distKey.path,
      wsl.toWsl(distKey.path),
      key.pem().split('\n')[1],
    ]) {
      expect(
        printed,
        isNot(contains(secret)),
        reason: 'the key or its path was printed',
      );
    }
    return (code, '$out', '$err');
  }

  String errorId(String json) =>
      ((jsonDecode(json) as Map<String, Object?>)['error']!
              as Map<String, Object?>)['id']!
          as String;

  group(
    'entitlements, as the spike\'s sign.py builds them (its self-test)',
    () {
      final allowed = {
        'application-identifier': '$_team.org.example.app',
        'get-task-allow': false,
        'com.apple.developer.team-identifier': _team,
        'beta-reports-active': true,
        'keychain-access-groups': ['$_team.*', 'com.apple.token'],
      };
      final siwa = {
        'com.apple.developer.applesignin': ['Default'],
      };
      ({PlistMap want, List<({String key, String problem})> problems}) build(
        PlistMap entitlements, [
        PlistMap extra = const {},
      ]) {
        final plist = appStoreProfile(
          teamId: _team,
          bundleId: 'org.example.app',
          expires: _expires,
        );
        return signingEntitlements(
          readProvisioningProfile(
            profileOf({...plist, 'Entitlements': entitlements}),
          ),
          'org.example.app',
          extra,
        );
      }

      test('the four keys of ADR-0011 rule 6, built from the profile', () {
        final (:want, :problems) = build(allowed);
        expect(problems, isEmpty);
        expect(
          writePlist(want),
          writePlist({
            'application-identifier': '$_team.org.example.app',
            'com.apple.developer.team-identifier': _team,
            'get-task-allow': false,
            'keychain-access-groups': ['$_team.org.example.app'],
          }),
        );
      });

      test('permits: wildcards, lists and types as Python compares them', () {
        expect(permits('$_team.*', 'OTHER00000.org.example.app'), isFalse);
        expect(
          permits(['$_team.org.example.app'], ['$_team.org.example.other']),
          isFalse,
        );
        expect(permits(false, 0), isFalse);
        expect(permits(true, false), isFalse);
        expect(permits('a', 'ab'), isFalse);
        expect(permits('$_team.*', '$_team.org.example.app'), isTrue);
        expect(
          permits(['$_team.*', 'com.apple.token'], ['$_team.org.example.app']),
          isTrue,
        );
      });

      for (final change in [
        {'get-task-allow': true},
        {
          'keychain-access-groups': ['OTHER00000.*'],
        },
        {'application-identifier': '$_team.org.example.other'},
      ]) {
        test(
          'a profile that does not allow ${change.keys.single} is refused',
          () {
            expect(build({...allowed, ...change}).problems, isNotEmpty);
          },
        );
      }

      test("the app's own entitlements are signed when allowed, and never replace the four", () {
        final (:want, :problems) = build(
          {...allowed, ...siwa},
          {...siwa, 'get-task-allow': true},
        );
        expect(problems, isEmpty);
        expect(want['com.apple.developer.applesignin'], ['Default']);
        expect(want['get-task-allow'], isFalse);
        expect(build(allowed, siwa).problems.map((p) => p.problem), [
          'the profile does not allow com.apple.developer.applesignin',
        ]);
        expect(
          build({...allowed}..remove('keychain-access-groups')).problems
              .map((p) => p.problem),
          ['the profile does not allow keychain-access-groups'],
        );
        expect(
          build({...allowed, 'get-task-allow': true}).problems
              .map((p) => p.problem),
          ['the profile does not allow this get-task-allow'],
        );
      });
    },
  );

  group('wincode sign', () {
    test('signs in a temporary folder, checks every signature, then keeps signed.ipa', () async {
      final (code, out, err) = await wincode(['sign', '--offline']);
      expect(code, 0, reason: '$out$err');
      expect(signed().existsSync(), isTrue);
      expect(leftovers(), isEmpty);
      expect(
        out,
        contains(
          'PASS  every signature checks out: 2 Mach-O files and 2 bundles',
        ),
      );
      expect(
        out,
        contains('PASS  the IPA holds $_bundleId, version 1.0, build 14'),
      );
      expect(out, contains('PASS  wrote ${signed().path}'));

      // zsign got paths only, all translated by wslpath, through wsl.exe --exec in the chosen distribution.
      final arguments = started.single;
      expect(arguments.take(2), ['-d', _distro]);
      expect(arguments, contains('--exec'));
      final command = arguments.sublist(arguments.indexOf('--exec') + 1);
      expect(command.first, zsignPath(_home));
      expect(command, isNot(contains('-p')));
      expect(command[command.indexOf('-k') + 1], wsl.toWsl(distKey.path));
      for (final flag in ['-k', '-c', '-m', '-e', '-o']) {
        expect(
          command[command.indexOf(flag) + 1],
          startsWith('${_FakeWsl.prefix}/'),
          reason: flag,
        );
      }
      expect(
        command.last,
        wsl.toWsl(File(inside(output(), 'unsigned.ipa')).path),
      );
      expect(arguments.join(' '), isNot(contains('PRIVATE KEY')));
      // Nothing was written inside WSL2: every command that wincode ran there only reads.
      for (final c in wsl.commands.where((c) => c.contains('--exec'))) {
        expect(
          c.sublist(c.indexOf('--exec') + 1).first,
          isIn(['printenv', 'wslpath', 'test', 'sha256sum', zsignPath(_home)]),
        );
      }

      // The result passes --verify-only, which needs no WSL2.
      final before = wsl.commands.length;
      final (verified, verifyOut, _) = await wincode(['sign', '--verify-only']);
      expect(verified, 0, reason: verifyOut);
      expect(wsl.commands.length, before);
    });

    test('the report under --redact is test/goldens/sign.txt (UPDATE_GOLDENS=1 rewrites it)', () async {
      final (code, out, _) = await wincode(['sign', '--offline', '--redact']);
      expect(code, 0);
      for (final hidden in [_bundleId, _team, temp.path]) {
        expect(out, isNot(contains(hidden)));
      }
      final golden = File('test/goldens/sign.txt');
      if (Platform.environment['UPDATE_GOLDENS'] != null) {
        golden.writeAsStringSync(out.replaceAll(r'\', '/'));
      }
      expect(
        out.replaceAll(r'\', '/'),
        golden.readAsStringSync().replaceAll('\r\n', '\n'),
      );
    });

    for (final (how, id, said) in [
      (
        _Zsign.fails,
        'zsign-failed',
        'zsign said: >>> Can not find a certificate that matches the private key.',
      ),
      (_Zsign.hangs, 'zsign-timeout', 'zsign printed nothing.'),
      (_Zsign.garbage, 'signature-invalid', ''),
      (_Zsign.grows, 'zsign-too-big', ''),
    ]) {
      test(
        'when zsign ${how.name}, it fails with $id and leaves nothing behind',
        () async {
          behaviour = how;
          if (how == _Zsign.grows) {
            runner = ZsignRunner(
              start: start,
              poll: const Duration(milliseconds: 5),
              limit: 1024,
            );
          }
          final (code, out, err) = await wincode([
            'sign',
            '--offline',
            '--json',
          ]);
          expect(code, 1, reason: err);
          expect(errorId(out), id);
          expect(err, contains(said));
          expect(signed().existsSync(), isFalse);
          expect(leftovers(), isEmpty);
          if (how == _Zsign.hangs || how == _Zsign.grows) {
            expect(processes.single.killed, isTrue);
          }
        },
      );
    }

    test(
      'an earlier signed.ipa is replaced only by one that passed the checks',
      () async {
        signed().writeAsStringSync('earlier');
        behaviour = _Zsign.fails;
        expect((await wincode(['sign', '--offline'])).$1, 1);
        expect(signed().readAsStringSync(), 'earlier');
        behaviour = _Zsign.signs;
        expect((await wincode(['sign', '--offline'])).$1, 0);
        expect(signed().readAsBytesSync().take(2), [0x50, 0x4B]);
      },
    );

    test('--dry-run checks everything that needs neither App Store Connect nor WSL2 and starts nothing', () async {
      final (code, out, _) = await wincode(['sign', '--dry-run']);
      expect(code, 0);
      expect(
        out,
        contains(
          'would run: wsl.exe -d $_distro --cd <temporary folder> --exec <zsign> -k <distribution key>',
        ),
      );
      expect(started, isEmpty);
      expect(wsl.commands, isEmpty);
    });

    test('--all is refused: sign writes', () async {
      final (code, _, err) = await wincode(['sign', '--all']);
      expect(code, 64);
      expect(err, contains('--all'));
    });

    group('stops before zsign', () {
      Future<String> fails(
        int code, {
        List<String> args = const ['--offline'],
      }) async {
        final (got, out, err) = await wincode(['sign', ...args, '--json']);
        expect(got, code, reason: err);
        expect(started, isEmpty);
        expect(leftovers(), isEmpty);
        return errorId(out);
      }

      test('an encrypted key, a .p12 and a key of another kind', () async {
        distKey.writeAsStringSync(pemOf('ENCRYPTED PRIVATE KEY', [0x30, 0]));
        expect(await fails(78), 'key-encrypted');
        distKey.writeAsBytesSync([0x30, 3, 0x02, 1, 3]);
        expect(await fails(78), 'key-encrypted');
        distKey.writeAsStringSync(pemOf('EC PRIVATE KEY', [0x30, 0]));
        expect(await fails(1), 'key-not-rsa');
        distKey.writeAsStringSync('garbage');
        expect(await fails(78), 'key-invalid');
      });

      test('WINCODE_DIST_KEY unset or naming no file', () async {
        environment.remove('WINCODE_DIST_KEY');
        expect(await fails(78), 'dist-key-missing');
        environment['WINCODE_DIST_KEY'] = inside(temp, 'none.key');
        expect(await fails(78), 'dist-key-missing');
      });

      test('a key whose certificate the profile does not list', () async {
        distKey.writeAsStringSync(TestRsaKey().pem());
        expect(await fails(1), 'certificate-not-in-profile');
      });

      for (final (what, made, id) in [
        (
          'expired',
          () => testCertificate(
            key,
            notAfter: _now.subtract(const Duration(days: 1)),
          ),
          'certificate-expired',
        ),
        (
          'of another team',
          () => testCertificate(
            key,
            notAfter: _expires,
            organizationalUnit: 'OTHER00000',
          ),
          'certificate-team-mismatch',
        ),
        (
          'not for distribution',
          () => testCertificate(
            key,
            notAfter: _expires,
            commonName: 'Apple Development: Example',
          ),
          'certificate-not-distribution',
        ),
      ]) {
        test('a certificate $what', () async {
          profile.writeAsBytesSync(_profile([made()]));
          expect(await fails(1), id);
        });
      }

      test('an entitlement that the profile does not allow', () async {
        final entitlements = File(inside(app, 'Runner.entitlements'))
          ..writeAsStringSync(
            writePlist({
              'com.apple.developer.applesignin': ['Default'],
            }),
          );
        config.writeAsStringSync(
          '${config.readAsStringSync()}entitlements: ${entitlements.path}\n',
        );
        expect(await fails(1), 'entitlement-not-allowed');
      });

      test('an app extension', () async {
        File(inside(output(), 'unsigned.ipa'))
            .writeAsBytesSync(zipOf(_unsigned(extension: true)));
        expect(await fails(1), 'extensions-unsupported');
      });

      test('an IPA of another app', () async {
        File(inside(output(), 'unsigned.ipa'))
            .writeAsBytesSync(zipOf(_unsigned(bundleId: 'com.example.other')));
        expect(await fails(1), 'bundle-id-mismatch');
      });

      test('a key that WSL2 cannot read', () async {
        wsl.translates = (path) => path != distKey.path;
        expect(await fails(78), 'dist-key-unreachable');
      });

      test('no zsign, an unrecorded one, a changed one, no WSL2', () async {
        wsl.zsignVersion = null;
        expect(await fails(69), 'zsign-missing');
        wsl.zsignVersion = 'version: 1.8.0';
        expect(await fails(1), 'zsign-changed');
        wsl
          ..zsignVersion = 'version: 1.9.0'
          ..zsignHash = 'b' * 64;
        expect(await fails(1), 'zsign-changed');
        zsignStateFile(environment).deleteSync();
        expect(await fails(1), 'zsign-unverified');
        wsl.installed = false;
        expect(await fails(69), 'wsl-missing');
      });
    });

    group(
      'asks App Store Connect about the certificate (GET /v1/certificates)',
      () {
        late Directory ascKeys;
        late ThrowawayKey ascKey;
        FakeAppStoreConnect? apple;

        setUp(() {
          ascKey = ThrowawayKey();
          ascKeys = Directory(inside(temp, 'asc'))..createSync();
          File(inside(ascKeys, 'AuthKey_ABCDE12345.p8'))
              .writeAsStringSync(ascKey.pem());
          File(inside(ascKeys, 'issuer-id'))
              .writeAsStringSync('00000000-0000-0000-0000-000000000001\n');
          environment['WINCODE_ASC_KEY_DIR'] = ascKeys.path;
        });

        tearDown(() async => apple?.close());

        Future<(int, String)> signAgainst(
          List<Map<String, Object?>> certificates,
        ) async {
          final server = apple = await FakeAppStoreConnect.start(
            (request) => request.path == '/v1/certificates'
                ? FakeAnswer.page(certificates)
                : FakeAnswer.error(404, 'NOT_FOUND'),
            key: ascKey,
            now: () => _now,
          );
          final (code, out, _) = await wincode(
            ['sign', '--json'],
            connect: (token, log) =>
                HttpAscClient(api: server.uri, token: token, log: log),
          );
          expect(server.requests.map((r) => '${r.method} ${r.path}'), [
            'GET /v1/certificates',
          ]);
          return (code, out);
        }

        Map<String, Object?> listed(
          String type,
          DateTime expires, {
          String? serial,
        }) => fakeResource('certificates', 'CERT000001', {
          // App Store Connect may write the serial number with leading zeros and in lower case.
          'serialNumber':
              serial ??
              '00${readCertificate(certificate).serialHex.toLowerCase()}',
          'certificateType': type,
          'expirationDate':
              '${expires.toIso8601String().substring(0, 19)}.000+0000',
        });

        test('a listed distribution certificate passes', () async {
          final (code, out) = await signAgainst([
            listed('DISTRIBUTION', _expires),
          ]);
          expect(code, 0, reason: out);
        });

        for (final (what, certificates, id) in [
          (
            'not listed',
            () => <Map<String, Object?>>[],
            'certificate-not-in-asc',
          ),
          (
            'listed as a development certificate',
            () => [listed('IOS_DEVELOPMENT', _expires)],
            'certificate-not-distribution',
          ),
          (
            'expired there',
            () => [
              listed('DISTRIBUTION', _now.subtract(const Duration(days: 1))),
            ],
            'certificate-expired',
          ),
        ]) {
          test('a certificate $what fails before zsign', () async {
            final (code, out) = await signAgainst(certificates());
            expect(code, 1);
            expect(errorId(out), id);
            expect(started, isEmpty);
          });
        }
      },
    );

    group('a file of apps', () {
      late Directory root;

      setUp(() {
        root = Directory(inside(temp, 'keys-root'))..createSync();
        for (final reference in ['team-one', 'team-two']) {
          Directory(inside(root, reference)).createSync();
        }
        File(inside(Directory(inside(root, 'team-one')), 'dist.key'))
            .writeAsStringSync(key.pem());
        File(inside(Directory(inside(root, 'team-two')), 'dist.key'))
            .writeAsStringSync('not this one');
        environment
          ..remove('WINCODE_DIST_KEY')
          ..['WINCODE_KEYS_DIR'] = root.path;
        config.writeAsStringSync(
          'apps:\n'
          '  alpha:\n    bundle_id: $_bundleId\n    team_id: $_team\n    credentials: team-one\n'
          '    profile: App_Store.mobileprovision\n    output: build\n'
          '  beta:\n    bundle_id: com.example.beta\n    team_id: TEAM000002\n    credentials: team-two\n'
          '    profile: Beta.mobileprovision\n    output: build-beta\n',
        );
        File(inside(app, 'Beta.mobileprovision')).writeAsBytesSync(
          _profile(
            [certificate],
            team: 'TEAM000002',
            bundleId: 'com.example.beta',
          ),
        );
        final betaOutput = Directory(inside(app, 'build-beta'))..createSync();
        File(inside(betaOutput, 'unsigned.ipa'))
            .writeAsBytesSync(zipOf(_unsigned(bundleId: 'com.example.beta')));
      });

      test("each app signs with the key of its own credentials", () async {
        final (alpha, out, err) = await wincode([
          'sign',
          '--app',
          'alpha',
          '--offline',
        ]);
        expect(alpha, 0, reason: '$out$err');
        expect(
          started.single[started.single.indexOf('-k') + 1],
          wsl.toWsl(inside(Directory(inside(root, 'team-one')), 'dist.key')),
        );
        final (beta, json, _) = await wincode([
          'sign',
          '--app',
          'beta',
          '--offline',
          '--json',
        ]);
        expect(beta, 78);
        expect(errorId(json), 'key-invalid');
      });

      test('without --app, sign does not choose', () async {
        expect((await wincode(['sign', '--offline'])).$1, 64);
      });
    });

    test('--verify-only finds a changed IPA and says why', () async {
      expect((await wincode(['sign', '--offline'])).$1, 0);
      final files = _unzip(signed())
        ..['Payload/Runner.app/Frameworks/App.framework/App'] = executable(
          signed: false,
        );
      signed().writeAsBytesSync(zipOf(files));
      final (code, out, _) = await wincode(['sign', '--verify-only', '--json']);
      expect(code, 1);
      expect(errorId(out), 'signature-invalid');
    });
  });

  group('wincode doctor --sign', () {
    Future<(int, String)> doctor() async {
      final (code, out, err) = await wincode(['doctor', '--sign']);
      return (code, '$out$err');
    }

    test(
      'records the SHA-256 of zsign the first time, then checks it',
      () async {
        zsignStateFile(environment).deleteSync();
        var (_, out) = await doctor();
        expect(
          out,
          contains(
            'PASS  zsign 1.9.0 is built; its SHA-256 aaaaaaaaaaaa... is now recorded in',
          ),
        );
        expect(out, contains('PASS  $_distro is a WSL 2 distribution'));
        expect(
          out,
          contains(
            'PASS  the distribution key of WINCODE_DIST_KEY is where zsign in WSL2 can read it',
          ),
        );
        (_, out) = await doctor();
        expect(out, contains('PASS  zsign 1.9.0 has the SHA-256 recorded in'));
        wsl.zsignHash = 'b' * 64;
        (_, out) = await doctor();
        expect(
          out,
          contains('FAIL  the zsign in WSL2 is not the one winCode pins'),
        );
      },
    );

    test(
      'prints the build commands when zsign is missing, and runs none of them',
      () async {
        wsl.zsignVersion = null;
        final (code, out) = await doctor();
        expect(code, isNot(0));
        expect(out, contains('FAIL  zsign is not installed in $_distro'));
        expect(out, contains('sha256sum -c -'));
        expect(
          out,
          contains(
            'make -C zsign-$zsignCommit/build/linux VERSION=$zsignVersion',
          ),
        );
        expect(
          wsl.commands.any(
            (c) =>
                c.contains('make') || c.contains('curl') || c.contains('sudo'),
          ),
          isFalse,
        );
      },
    );

    test(
      'WSL 1, a distribution that does not exist, and no WSL2 at all',
      () async {
        wsl.version = 1;
        expect((await doctor()).$2, contains('FAIL  $_distro runs on WSL 1'));
        wsl.version = 2;
        environment[distroVariable] = 'Missing-1';
        expect(
          (await doctor()).$2,
          contains('FAIL  WSL2 has no distribution named Missing-1'),
        );
        wsl.installed = false;
        expect(
          (await doctor()).$2,
          contains('FAIL  wsl.exe cannot be started: WSL2 is not installed'),
        );
      },
    );

    test('a key that WSL2 cannot read, and no key at all', () async {
      wsl.translates = (path) => path != distKey.path;
      expect(
        (await doctor()).$2,
        contains(
          'FAIL  the distribution key of WINCODE_DIST_KEY lies where WSL2 cannot read it',
        ),
      );
      environment.remove('WINCODE_DIST_KEY');
      expect(
        (await doctor()).$2,
        contains('FAIL  WINCODE_DIST_KEY is not set'),
      );
    });

    test('--sign has no --dry-run', () async {
      final (code, _, _) = await wincode(['doctor', '--sign', '--dry-run']);
      expect(code, 64);
    });
  });

  test('winCode pins the zsign that xtool pins, and CI builds that one', () {
    final resolved = jsonDecode(
      File('../../third_party/xtool/Package.resolved').readAsStringSync(),
    ) as Map<String, Object?>;
    final pins = [
      for (final p in resolved['pins']! as List<Object?>)
        p! as Map<String, Object?>,
    ];
    final state =
        pins.singleWhere((p) => p['identity'] == 'zsign')['state']!
            as Map<String, Object?>;
    expect((state['revision'], state['version']), (zsignCommit, zsignVersion));
    final workflow = File('../../.github/workflows/dart.yml')
        .readAsStringSync();
    expect(workflow, contains('ZSIGN_COMMIT: $zsignCommit'));
    expect(workflow, contains('ZSIGN_SHA256: $zsignSourceSha256'));
    expect(workflow, contains('VERSION=$zsignVersion'));
  });

  test('parseWslList reads the UTF-16 list of wsl.exe -l -v', () {
    final text = '  NAME   STATE   VERSION\r\n* Ubuntu-24.04   Running   2\r\n  Legacy   Stopped   1\r\n'
        .split('')
        .map((c) => '$c\u0000')
        .join();
    expect(parseWslList(text).map((d) => (d.name, d.version, d.isDefault)), [
      ('Ubuntu-24.04', 2, true),
      ('Legacy', 1, false),
    ]);
  });
}
