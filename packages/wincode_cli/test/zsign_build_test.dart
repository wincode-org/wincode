import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wincode_cli/wincode_cli.dart';
import 'package:wincode_core/wincode_core.dart' show digestsOfFile, runProcess;

import 'private.dart';
import 'tar_unpack_test.dart' show TarEntry, tarOf;

/// ADR-0013, phase 3a.1 (the Linux half): `wincode doctor --sign --build-zsign` downloads the pinned source archive, checks
/// its SHA-256 before it unpacks anything, builds it as the printed commands do, and records the binary it built. The
/// download, the pin and every program are fakes here: nothing reaches the network or a compiler.
void main() {
  final sep = Platform.pathSeparator;
  final posix = Platform.isWindows ? 'the check is for POSIX systems' : null;
  final pinnedUrl = Uri.parse(
    'https://github.com/xtool-org/zsign/archive/$zsignCommit.tar.gz',
  );
  late Directory temp;
  late Directory data;
  late Map<String, String> environment;
  late File config;
  late File binary;
  late File record;

  // What the fakes see and do.
  late List<List<String>> asked;
  late List<({List<String> arguments, String? cwd, int? mode})> builds;
  late List<Uri> fetched;
  late Set<String> missing;
  var sslFound = true;
  var makeExit = 0;
  var makeWritesBinary = true;
  var printedVersion = 'version: $zsignVersion';
  var builtBytes = 'the zsign that the fake make built';
  WincodeException? fetchFails;
  late Uint8List archive;
  late String archiveHash;
  late ZsignSource source;

  Uint8List sourceTree() => tarOf([
    const TarEntry('zsign-$zsignCommit/', type: '5'),
    TarEntry(
      'zsign-$zsignCommit/build/linux/Makefile',
      body: utf8.encode('all:\n'),
    ),
    TarEntry('zsign-$zsignCommit/src/main.cpp', body: utf8.encode('int main;')),
  ]);

  /// Makes [bytes] the archive that the fake download serves, and pins its SHA-256.
  Future<String> serve(List<int> bytes) async {
    archive = Uint8List.fromList(gzip.encode(bytes));
    final probe = File('${temp.path}${sep}probe.tar.gz')
      ..writeAsBytesSync(archive);
    final hash = (await digestsOfFile(probe)).sha256;
    probe.deleteSync();
    return hash;
  }

  ZsignSource sourceFor(String hash) => ZsignSource(
    sha256: hash,
    fetch: (url, file, {required maxBytes, required timeout}) async {
      fetched.add(url);
      if (fetchFails != null) {
        throw fetchFails!;
      }
      file.writeAsBytesSync(archive);
    },
  );

  /// The programs that the build starts: the checks of the tools, `make`, and `zsign -v`. Anything else is a failure of the
  /// test, since winCode must start nothing else.
  Future<ProcessResult> tool(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    if (executable == 'git') {
      // The key-location rule of every command asks git, as in the other tests of doctor.
      return runProcess(
        executable,
        arguments,
        workingDirectory: workingDirectory,
      );
    }
    asked.add([executable, ...arguments]);
    if (executable.endsWith('${sep}bin${sep}zsign') && arguments.length == 1) {
      if (!File(executable).existsSync()) {
        throw ProcessException(executable, arguments, 'No such file');
      }
      return ProcessResult(0, 0, '$printedVersion\n', '');
    }
    if (executable == 'make' && arguments.contains('-C')) {
      builds.add((
        arguments: arguments,
        cwd: workingDirectory,
        mode: posix == null
            ? FileStat.statSync(workingDirectory!).mode & 0x1ff
            : null,
      ));
      if (makeExit != 0) {
        return ProcessResult(
          0,
          makeExit,
          'compiling main.cpp\n',
          'main.cpp:1: error: boom\n',
        );
      }
      if (makeWritesBinary) {
        File('$workingDirectory${sep}zsign-$zsignCommit${sep}bin${sep}zsign')
          ..createSync(recursive: true)
          ..writeAsStringSync(builtBytes);
      }
      return ProcessResult(0, 0, '>>> Build OK!\n', '');
    }
    if (!{
      'g++',
      'clang++',
      'clang',
      'make',
      'pkg-config',
    }.contains(executable)) {
      fail('unexpected program: $executable ${arguments.join(' ')}');
    }
    if (missing.contains(executable)) {
      throw ProcessException(executable, arguments, 'No such file');
    }
    if (executable == 'pkg-config' && arguments.first == '--exists') {
      return ProcessResult(0, sslFound ? 0 : 1, '', '');
    }
    return ProcessResult(0, 0, '$executable 1.0\n', '');
  }

  /// The keys of the credentials [reference] that `doctor` reads: a folder closed to others, as the check requires.
  void keys(String reference) {
    final folder = privateFolders(
      Directory('${environment['HOME']}$sep.wincode${sep}keys$sep$reference')
        ..createSync(recursive: true),
      temp,
    );
    private(
      File('${folder.path}${sep}AuthKey_ABCDE12345.p8')..writeAsStringSync('x'),
    );
    File('${folder.path}${sep}issuer-id')
        .writeAsStringSync('00000000-0000-4000-8000-000000000001\n');
    private(File('${folder.path}${sep}dist.key')..writeAsStringSync('x'));
  }

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('wincode_build_');
    data = Directory('${temp.path}${sep}data');
    environment = {
      'XDG_DATA_HOME': data.path,
      'HOME': '${temp.path}${sep}home',
      'USERPROFILE': '${temp.path}${sep}home',
    };
    binary = File(nativeZsignPath(environment));
    record = zsignStateFile(environment);
    config = File('${temp.path}${sep}wincode.yaml')
      ..writeAsStringSync(
        'bundle_id: com.example.alpha\nteam_id: TEAM000001\ncredentials: team-one\n',
      );
    keys('team-one');
    asked = [];
    builds = [];
    fetched = [];
    missing = {'clang++', 'clang'};
    sslFound = true;
    makeExit = 0;
    makeWritesBinary = true;
    printedVersion = 'version: $zsignVersion';
    builtBytes = 'the zsign that the fake make built';
    fetchFails = null;
    archiveHash = await serve(sourceTree());
    source = sourceFor(archiveHash);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<(int, String, String)> doctor({
    List<String> more = const [],
    String platform = 'linux',
    ZsignSource? from,
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runWincode(
      ['doctor', '--sign', '--build-zsign', '--config', config.path, ...more],
      out,
      err,
      environment: environment,
      run: tool,
      platform: platform,
      zsignSource: from ?? source,
    );
    expect('$out$err', isNot(contains('PRIVATE KEY')));
    return (code, '$out', '$err');
  }

  /// Everything in the folder that winCode owns for zsign, one name each.
  List<String> folder() {
    final zsign = Directory(binary.parent.parent.parent.path);
    return zsign.existsSync()
        ? ([
            for (final e in zsign.listSync())
              e.path.substring(zsign.path.length + 1),
          ]..sort())
        : const [];
  }

  String sha12(String hash) => hash.substring(0, 12);

  /// An install that something else made: a binary and the record that an earlier `doctor --sign` wrote for it.
  Future<String> oldInstall({Map<String, Object?> extra = const {}}) async {
    binary
      ..createSync(recursive: true)
      ..writeAsStringSync('the zsign that was there');
    final hash = (await digestsOfFile(binary)).sha256;
    record.parent.createSync(recursive: true);
    record.writeAsStringSync(
      jsonEncode({
        'zsign': {
          nativeStateKey: {'path': binary.path, 'sha256': hash, ...extra},
        },
      }),
    );
    return hash;
  }

  Map<String, Object?> recorded() =>
      (jsonDecode(record.readAsStringSync()) as Map<String, Object?>)['zsign']!
          as Map<String, Object?>;

  group('it builds the pinned zsign', () {
    test('and records the hash of the binary it built, one PASS line per step', () async {
      final (code, out, err) = await doctor();
      expect(code, 0, reason: '$out$err');
      final lines = out.split('\n');
      for (final prefix in [
        'PASS  the tools that build zsign are there: g++, make, pkg-config and the OpenSSL development files',
        'PASS  downloaded the zsign source (',
        'PASS  unpacked 2 files, none outside the build folder and no link',
        'PASS  built zsign with make -C zsign-$zsignCommit/build/linux VERSION=$zsignVersion in ',
        'PASS  the zsign that was built prints version: $zsignVersion',
        'PASS  installed at ${binary.path}; its SHA-256 ',
        'PASS  zsign $zsignVersion has the SHA-256 recorded in ',
      ]) {
        expect(
          lines.where((l) => l.startsWith(prefix)),
          hasLength(1),
          reason: '$prefix\n$out',
        );
      }
      expect(out, contains('is the pinned one'));
      expect(out, contains('wincode sign runs this binary only'));
      final hash = (await digestsOfFile(binary)).sha256;
      expect(binary.readAsStringSync(), builtBytes);
      expect(recorded(), {
        nativeStateKey: {
          'path': binary.path,
          'sha256': hash,
          'built': {'commit': zsignCommit, 'sourceSha256': archiveHash},
        },
      });
      // Only the finished tree is left: no build folder, no archive.
      expect(folder(), ['zsign-$zsignCommit']);
      // wincode sign accepts it as it is.
      expect(
        await NativeZsignRunner(
          environment: environment,
          runTool: tool,
        ).requirePinned(),
        binary.path,
      );
    });

    test('with the address and the make line of the printed commands, as the user, in a private folder', () async {
      await doctor();
      expect(fetched, [pinnedUrl]);
      final printed = zsignBuildCommandsIn('"folder"');
      expect(printed.any((c) => c.contains('$pinnedUrl')), isTrue);
      final build = builds.single;
      expect(
        printed.singleWhere((c) => c.startsWith('make ')),
        startsWith('make ${build.arguments.join(' ')}'),
      );
      expect(build.arguments, [
        '-C',
        'zsign-$zsignCommit/build/linux',
        'VERSION=$zsignVersion',
      ]);
      expect(
        build.cwd,
        startsWith('${binary.parent.parent.parent.path}$sep.build-'),
      );
      // The folder of this one build is closed to other users (dart:io makes it with the umask, so it is chmod-ed).
      expect(build.mode, posix == null ? 0x1c0 : isNull);
      // Only the checks of the tools, make and zsign -v ran: no shell, no sudo, no installer.
      expect(
        {for (final a in asked) a.first.split(sep).last},
        {'g++', 'make', 'pkg-config', 'zsign'},
      );
      expect(
        asked.where(
          (a) => a.any((x) => x.contains('sudo') || x.contains('apt')),
        ),
        isEmpty,
      );
    });

    test('the pins are those of winCode unless a test gives its own', () {
      final real = ZsignSource();
      expect(real.sha256, zsignSourceSha256);
      expect(real.url, pinnedUrl);
      expect(real.url.scheme, 'https');
      expect(real.maxDownload, 64 << 20);
      expect(real.maxUnpacked, 256 << 20);
    });

    test('replacing the record that doctor --sign made from a binary it found, and the binary with it', () async {
      final before = await oldInstall();
      final (code, out, err) = await doctor();
      expect(code, 0, reason: '$out$err');
      final now = recorded()[nativeStateKey]! as Map<String, Object?>;
      expect(now['sha256'], isNot(before));
      expect(now['sha256'], (await digestsOfFile(binary)).sha256);
      expect(now['built'], isNotNull);
      expect(binary.readAsStringSync(), builtBytes);
      expect(out, contains('(replacing ${sha12(before)}...)'));
      expect(folder(), ['zsign-$zsignCommit']);
    });

    test('and keeps the entries of the record that are not its own', () async {
      await oldInstall();
      final other =
          jsonDecode(record.readAsStringSync()) as Map<String, Object?>;
      (other['zsign']! as Map<String, Object?>)['Ubuntu-24.04'] = {
        'path': '/x/zsign',
        'sha256': 'a' * 64,
      };
      record.writeAsStringSync(jsonEncode(other));
      await doctor();
      expect(recorded()['Ubuntu-24.04'], {
        'path': '/x/zsign',
        'sha256': 'a' * 64,
      });
    });

    test(
      'without g++ it builds with clang, as the printed make line says',
      () async {
        missing = {'g++'};
        final (code, out, _) = await doctor();
        expect(code, 0, reason: out);
        expect(builds.single.arguments.skip(3), ['CXX=clang++', 'CC=clang']);
        expect(out, contains('clang++ and clang (no g++'));
      },
    );

    test('and says so, doing nothing, when this command built it before', () async {
      expect((await doctor()).$1, 0);
      final once = record.readAsStringSync();
      final (code, out, err) = await doctor();
      expect(code, 0, reason: '$out$err');
      expect(
        out,
        contains(
          'PASS  zsign $zsignVersion was built by this command and is unchanged',
        ),
      );
      expect(out, contains('nothing to do. To build it again, delete '));
      expect(
        out,
        contains('${binary.parent.parent.path} and run this command again'),
      );
      expect(fetched, hasLength(1));
      expect(builds, hasLength(1));
      expect(record.readAsStringSync(), once);
    });

    test('and builds again when the built binary changed since', () async {
      expect((await doctor()).$1, 0);
      binary.writeAsStringSync('something else');
      builtBytes = 'a second build';
      final (code, out, _) = await doctor();
      expect(code, 0, reason: out);
      expect(fetched, hasLength(2));
      expect(binary.readAsStringSync(), 'a second build');
    });

    test('and builds again when the record names another archive', () async {
      expect((await doctor()).$1, 0);
      final hash = await serve(
        tarOf([
          TarEntry('zsign-$zsignCommit/build/linux/Makefile', body: [1]),
        ]),
      );
      builtBytes = 'built from the new pin';
      expect((await doctor(from: sourceFor(hash))).$1, 0);
      expect(fetched, hasLength(2));
      expect(binary.readAsStringSync(), 'built from the new pin');
    });
  });

  group('it refuses a download that is not the pinned one', () {
    test('before it unpacks anything: nothing is built, the download is deleted, and the install and its record stay', () async {
      final before = await oldInstall();
      final recordBefore = record.readAsStringSync();
      // Unpacking this would be refused, so only a check of the hash that comes first can give the error below.
      archive = Uint8List.fromList(
        gzip.encode(
          tarOf([
            const TarEntry('../outside.txt', body: [1]),
          ]),
        ),
      );
      final probe = File('${temp.path}${sep}other.gz')
        ..writeAsBytesSync(archive);
      final otherHash = (await digestsOfFile(probe)).sha256;
      final (code, out, err) = await doctor(more: ['--json']);
      expect(code, 1, reason: '$out$err');
      final json = jsonDecode(out) as Map<String, Object?>;
      expect(
        (json['error']! as Map<String, Object?>)['id'],
        'zsign-archive-mismatch',
      );
      expect(
        err,
        contains(
          'FAIL  the zsign source that was downloaded is not the pinned one',
        ),
      );
      expect(err, contains('its SHA-256 is $otherHash, not $archiveHash'));
      expect(err, contains('Nothing from it was unpacked or built'));
      expect(builds, isEmpty);
      expect(fetched, hasLength(1));
      expect(folder(), ['zsign-$zsignCommit']);
      expect(binary.readAsStringSync(), 'the zsign that was there');
      expect(record.readAsStringSync(), recordBefore);
      expect(
        ((recorded()[nativeStateKey]! as Map<String, Object?>)['sha256']),
        before,
      );
      expect(
        temp
            .listSync(recursive: true)
            .where((e) => e.path.endsWith('outside.txt')),
        isEmpty,
      );
    });

    test('and leaves no folder at all when there was no install', () async {
      archive = Uint8List.fromList(gzip.encode(tarOf([const TarEntry('a')])));
      final (code, out, _) = await doctor();
      expect(code, 1, reason: out);
      expect(
        out,
        contains(
          'FAIL  the zsign source that was downloaded is not the pinned one',
        ),
      );
      expect(folder(), isEmpty);
      expect(record.existsSync(), isFalse);
    });

    test(
      'and one that is larger than the limit, or empty, is refused too',
      () async {
        final tiny = ZsignSource(
          sha256: archiveHash,
          maxDownload: 10,
          fetch: (url, file, {required maxBytes, required timeout}) async =>
              file.writeAsBytesSync(archive),
        );
        final (code, out, _) = await doctor(from: tiny, more: ['--json']);
        expect(code, 1);
        expect(
          (jsonDecode(out) as Map<String, Object?>)['error'],
          containsPair('id', 'zsign-download-refused'),
        );
        final none = ZsignSource(
          sha256: archiveHash,
          fetch: (url, file, {required maxBytes, required timeout}) async {},
        );
        expect((await doctor(from: none)).$1, 1);
        expect(folder(), isEmpty);
      },
    );

    test(
      'an unreachable network is 69 (offline), and nothing was changed',
      () async {
        await oldInstall();
        final recordBefore = record.readAsStringSync();
        fetchFails = const WincodeException(
          ExitCode.unavailable,
          'offline',
          'cannot download the zsign source from github.com: no answer',
        );
        final (code, out, _) = await doctor();
        expect(code, 69, reason: out);
        expect(
          out,
          contains('FAIL  cannot download the zsign source from github.com'),
        );
        expect(builds, isEmpty);
        expect(binary.readAsStringSync(), 'the zsign that was there');
        expect(record.readAsStringSync(), recordBefore);
        expect(folder(), ['zsign-$zsignCommit']);
      },
    );
  });

  group('it refuses an archive that could write outside its folder, after the hash was right', () {
    final unsafe = {
      'a path with ..': const TarEntry('../outside.txt', body: [1]),
      'an absolute path': const TarEntry('/tmp/outside.txt', body: [1]),
      'a symbolic link out': const TarEntry(
        'zsign-$zsignCommit/link',
        type: '2',
        link: '../../..',
      ),
      'a hard link': const TarEntry(
        'zsign-$zsignCommit/link',
        type: '1',
        link: '/etc/passwd',
      ),
    };
    for (final MapEntry(:key, :value) in unsafe.entries) {
      test(key, () async {
        final before = await oldInstall();
        final recordBefore = record.readAsStringSync();
        source = sourceFor(await serve(tarOf([value])));
        final (code, out, err) = await doctor(more: ['--json']);
        expect(code, 1, reason: '$out$err');
        expect(
          (jsonDecode(out) as Map<String, Object?>)['error'],
          containsPair('id', 'zsign-archive-unsafe'),
        );
        expect(builds, isEmpty);
        expect(binary.readAsStringSync(), 'the zsign that was there');
        expect(record.readAsStringSync(), recordBefore);
        expect((await digestsOfFile(binary)).sha256, before);
        expect(folder(), ['zsign-$zsignCommit']);
        expect(
          temp
              .listSync(recursive: true)
              .where((e) => e.path.endsWith('outside.txt')),
          isEmpty,
        );
      });
    }

    test('and one that unpacks to more than the limit', () async {
      final big = ZsignSource(
        sha256: await serve(tarOf([TarEntry('a', body: Uint8List(300000))])),
        maxUnpacked: 100000,
        fetch: (url, file, {required maxBytes, required timeout}) async =>
            file.writeAsBytesSync(archive),
      );
      final (code, out, _) = await doctor(from: big);
      expect(code, 1, reason: out);
      expect(
        out,
        contains(
          'cannot be unpacked safely: the archive unpacks to more than 100000 bytes',
        ),
      );
      expect(folder(), isEmpty);
    });
  });

  group('a missing tool stops it before anything is downloaded', () {
    test(
      'and says which, with the command to run by hand, installing nothing',
      () async {
        missing = {'g++', 'pkg-config', 'clang++', 'clang'};
        final (code, out, _) = await doctor();
        expect(code, 1, reason: out);
        expect(
          out,
          contains(
            'FAIL  cannot build zsign: g++, pkg-config, the OpenSSL development files ',
          ),
        );
        expect(out, contains('are missing'));
        expect(
          out,
          contains(
            'next: install them with your package manager, then run this command again. On Debian or Ubuntu: sudo apt-get install g++ pkg-config libssl-dev',
          ),
        );
        expect(out, contains('winCode installs nothing and never runs sudo'));
        expect(fetched, isEmpty);
        expect(builds, isEmpty);
        expect(folder(), isEmpty);
        expect(
          asked.where((a) => a.first == 'sudo' || a.first == 'apt-get'),
          isEmpty,
        );
      },
    );

    test('make alone', () async {
      missing = {'make', 'clang++', 'clang'};
      final (code, out, _) = await doctor(more: ['--json']);
      expect(code, 1);
      final error =
          (jsonDecode(out) as Map<String, Object?>)['error']!
              as Map<String, Object?>;
      expect(error['id'], 'zsign-build-tools-missing');
      expect(error['what'], 'cannot build zsign: make is missing');
      expect(error['next'], endsWith('sudo apt-get install make'));
      expect(fetched, isEmpty);
    });

    test('the OpenSSL development files', () async {
      sslFound = false;
      final (code, out, _) = await doctor();
      expect(code, 1);
      expect(
        out,
        contains(
          'the OpenSSL development files (pkg-config does not find openssl) is missing',
        ),
      );
      expect(out, contains('sudo apt-get install libssl-dev'));
      expect(fetched, isEmpty);
    });

    test('a compiler: neither g++ nor clang', () async {
      missing = {'g++', 'clang++', 'clang'};
      final (code, out, _) = await doctor();
      expect(code, 1);
      expect(out, contains('FAIL  cannot build zsign: g++ is missing'));
      expect(fetched, isEmpty);
    });

    test(
      'clang++ without clang is no compiler for the C files of zsign',
      () async {
        missing = {'g++', 'clang'};
        expect((await doctor()).$1, 1);
        expect(fetched, isEmpty);
      },
    );
  });

  group('a build that fails leaves the previous install in place', () {
    test('make fails: its last lines are shown', () async {
      final before = await oldInstall();
      final recordBefore = record.readAsStringSync();
      makeExit = 2;
      final (code, out, _) = await doctor();
      expect(code, 1, reason: out);
      expect(
        out,
        contains(
          'FAIL  the zsign build failed: make -C zsign-$zsignCommit/build/linux VERSION=$zsignVersion exited with 2',
        ),
      );
      expect(out, contains('main.cpp:1: error: boom'));
      expect(
        out,
        contains('the zsign that was there, with its record, is as it was'),
      );
      expect(binary.readAsStringSync(), 'the zsign that was there');
      expect((await digestsOfFile(binary)).sha256, before);
      expect(record.readAsStringSync(), recordBefore);
      expect(folder(), ['zsign-$zsignCommit']);
    });

    test('make ends without a binary', () async {
      final before = await oldInstall();
      makeWritesBinary = false;
      final (code, out, _) = await doctor();
      expect(code, 1, reason: out);
      expect(out, contains('ended without a zsign binary'));
      expect((await digestsOfFile(binary)).sha256, before);
      expect(folder(), ['zsign-$zsignCommit']);
    });

    test('the binary prints another version: it is not installed', () async {
      final before = await oldInstall();
      printedVersion = 'version: 1.8.0';
      final (code, out, _) = await doctor();
      // The old binary does not print the pinned version either, so only the build is judged here.
      expect(code, 1, reason: out);
      expect(
        out,
        contains(
          'FAIL  the zsign build failed: the zsign that was built prints "version: 1.8.0", not version $zsignVersion',
        ),
      );
      expect(binary.readAsStringSync(), 'the zsign that was there');
      expect((await digestsOfFile(binary)).sha256, before);
      expect(folder(), ['zsign-$zsignCommit']);
    });

    test('the record cannot be written: the old binary is put back', () async {
      final before = await oldInstall();
      // A record that its owner cannot write to: the new binary is in place by then, and has to go.
      Process.runSync('chmod', ['444', record.path]);
      final (code, out, _) = await doctor();
      expect(code, 1, reason: out);
      expect(out, contains('cannot put the new zsign in place'));
      expect(out, contains('(it was put back)'));
      expect(binary.readAsStringSync(), 'the zsign that was there');
      expect((await digestsOfFile(binary)).sha256, before);
      expect(folder(), ['zsign-$zsignCommit']);
    }, skip: posix);

    test('a first build that fails leaves no install and no record', () async {
      makeExit = 1;
      expect((await doctor()).$1, 1);
      expect(folder(), isEmpty);
      expect(record.existsSync(), isFalse);
    });
  });

  group('--dry-run prints the plan and does nothing', () {
    test('no download, no program, no folder, no record', () async {
      final (code, out, err) = await doctor(more: ['--dry-run']);
      expect(code, 0, reason: '$out$err');
      expect(
        out,
        contains('INFO  dry run: nothing is downloaded, built or written.'),
      );
      expect(out, contains('download $pinnedUrl'));
      expect(out, contains('unless its SHA-256 is $archiveHash'));
      expect(out, contains('put it at ${binary.path}'));
      expect(
        out,
        contains(
          'make -C zsign-$zsignCommit/build/linux VERSION=$zsignVersion',
        ),
      );
      expect(
        out,
        contains('mkdir -p "${binary.parent.parent.parent.path}" && cd'),
      );
      expect(out, contains('never runs the install line'));
      expect(out, contains('wincode doctor: passed'));
      expect(asked, isEmpty);
      expect(fetched, isEmpty);
      expect(data.existsSync(), isFalse);
    });

    test('--json gives the same findings, with the report on stderr', () async {
      final (code, out, err) = await doctor(more: ['--dry-run', '--json']);
      expect(code, 0);
      final json = jsonDecode(out) as Map<String, Object?>;
      expect(json['ok'], isTrue);
      expect(
        [
          for (final c in json['checks']! as List<Object?>)
            (c! as Map)['check'],
        ],
        ['zsign-build', 'zsign-build-commands'],
      );
      expect(err, contains('INFO  dry run'));
    });

    test('--redact hides the folders', () async {
      final (code, out, _) = await doctor(more: ['--dry-run', '--redact']);
      expect(code, 0);
      expect(out, isNot(contains(temp.path)));
      expect(out, contains('<zsign folder>'));
      expect(out, contains('<zsign record>'));
    });

    test('needs no wincode.yaml and no keys', () async {
      config.deleteSync();
      expect((await doctor(more: ['--dry-run'])).$1, 0);
    });
  });

  group('--redact hides the paths of a real run', () {
    test('in the report', () async {
      final (code, out, err) = await doctor(more: ['--redact']);
      expect(code, 0, reason: '$out$err');
      expect(out, isNot(contains(temp.path)));
      expect(out, contains('installed at <zsign folder>'));
      expect(out, contains('<zsign record>'));
    });

    test('in a failure that quotes the output of make', () async {
      makeExit = 2;
      final (code, out, _) = await doctor(more: ['--redact']);
      expect(code, 1);
      expect(out, isNot(contains(temp.path)));
    });
  });

  group('other platforms', () {
    for (final more in [
      <String>[],
      ['--dry-run'],
      ['--json'],
    ]) {
      test(
        'Windows says that it will build in WSL2, and that this is not built: ${more.join(' ')}',
        () async {
          final (code, out, err) = await doctor(
            platform: 'windows',
            more: more,
          );
          expect(code, 64, reason: '$out$err');
          expect(
            err,
            contains(
              'wincode doctor: --build-zsign is not built on Windows yet',
            ),
          );
          expect(err, contains('on Windows it will build zsign inside WSL2'));
          expect(
            err,
            contains(
              'next: build zsign with the commands that wincode doctor --sign prints, in WSL2, as before.',
            ),
          );
          if (more.contains('--json')) {
            expect(
              (jsonDecode(out) as Map<String, Object?>)['error'],
              containsPair('id', 'not-implemented'),
            );
          }
          expect(asked, isEmpty);
          expect(fetched, isEmpty);
          expect(data.existsSync(), isFalse);
        },
      );
    }

    for (final more in [
      <String>[],
      ['--dry-run'],
    ]) {
      test(
        'macOS has the message of wincode sign: ${more.join(' ')}',
        () async {
          final (code, out, err) = await doctor(platform: 'macos', more: more);
          expect(code, 69, reason: '$out$err');
          expect(
            err,
            contains('wincode doctor: wincode sign does not run on macos'),
          );
          expect(asked, isEmpty);
          expect(fetched, isEmpty);
          expect(data.existsSync(), isFalse);
        },
      );
    }

    test('--build-zsign needs --sign, and no binary check', () async {
      for (final (args, message) in [
        (['doctor', '--build-zsign'], 'give --sign as well'),
        (
          ['doctor', '--sign', '--build-zsign', '--binary', 'x', '--sdk', 'y'],
          '--sign and --build check the setup',
        ),
        (
          ['doctor', '--build-zsign', '--binary', 'x', '--sdk', 'y'],
          '--build-zsign builds the zsign that --sign checks',
        ),
      ]) {
        final err = StringBuffer();
        expect(
          await runWincode(
            args,
            StringBuffer(),
            err,
            environment: environment,
            run: tool,
            platform: 'linux',
            zsignSource: source,
          ),
          64,
          reason: args.join(' '),
        );
        expect('$err', contains(message));
      }
      expect(fetched, isEmpty);
      expect(asked, isEmpty);
    });

    test(
      'doctor --sign --dry-run, without --build-zsign, is still refused',
      () async {
        final err = StringBuffer();
        expect(
          await runWincode(
            ['doctor', '--sign', '--dry-run', '--config', config.path],
            StringBuffer(),
            err,
            environment: environment,
            run: tool,
            platform: 'linux',
          ),
          64,
        );
        expect(
          '$err',
          contains('With --build-zsign, --dry-run prints the plan'),
        );
      },
    );
  });

  group('--all builds once', () {
    test('and puts its findings at the head of the first app', () async {
      keys('team-two');
      config.writeAsStringSync(
        'apps:\n'
        '  one:\n    bundle_id: com.example.one\n    team_id: TEAM000001\n    credentials: team-one\n'
        '  two:\n    bundle_id: com.example.two\n    team_id: TEAM000002\n    credentials: team-two\n',
      );
      final (code, out, err) = await doctor(more: ['--all']);
      expect(code, 0, reason: '$out$err');
      expect(fetched, hasLength(1));
      expect(builds, hasLength(1));
      expect('PASS  installed at'.allMatches(out), hasLength(1));
      expect(
        out.indexOf('PASS  installed at'),
        lessThan(out.indexOf('== two ==')),
      );
    });
  });

  group('the build folder is closed to other users', () {
    test('mode 0700, from the fake make', () async {
      await doctor();
      expect(builds.single.mode, 0x1c0);
    }, skip: posix);
  });

  group('the download', () {
    late HttpServer server;
    late File target;
    var served = 0;

    Uri at(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

    /// [downloadArchive] for a test: `http` on 127.0.0.1 is allowed, and nothing else is.
    Future<void> download(
      Uri url, {
      int maxBytes = 1 << 20,
      Duration timeout = const Duration(seconds: 5),
      Duration overall = const Duration(seconds: 20),
      bool loopbackHttp = true,
    }) => downloadArchive(
      url,
      target,
      maxBytes: maxBytes,
      timeout: timeout,
      overall: overall,
      loopbackHttp: loopbackHttp,
    );

    Future<WincodeException> refused(Future<void> download) async {
      try {
        await download;
      } on WincodeException catch (e) {
        expect(
          target.existsSync(),
          isFalse,
          reason: 'a partial download is deleted',
        );
        return e;
      }
      fail('the download was accepted');
    }

    setUp(() async {
      served = 0;
      target = File('${temp.path}${sep}zsign.tar.gz');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        served++;
        final response = request.response;
        try {
          switch (request.uri.path) {
            case '/ok':
              response.add(archive);
            case '/gone':
              response.statusCode = 404;
            case '/down':
              response.statusCode = 503;
            case '/declares-big':
              response.contentLength = 1 << 30;
              response.add([1, 2, 3]);
            case '/endless':
              response.headers.chunkedTransferEncoding = true;
              // More than any cap of the tests, and it ends if the client never goes.
              for (var i = 0; i < 300; i++) {
                response.add(Uint8List(4096));
                await response.flush();
              }
            case '/stalls':
              response.add([1, 2, 3]);
              await response.flush();
              await Future<void>.delayed(const Duration(seconds: 10));
            case '/slow-start':
              await Future<void>.delayed(const Duration(seconds: 10));
            case '/redirect':
              response.statusCode = 302;
              response.headers.set('location', '/ok');
            case '/redirect-to-http':
              response.statusCode = 302;
              response.headers.set(
                'location',
                'http://example.invalid/zsign.tar.gz',
              );
            case '/redirect-loop':
              response.statusCode = 302;
              response.headers.set('location', '/redirect-loop');
          }
          await response.close();
        } on Object {
          // The client went away, which is what the tests of the limits want.
        }
      });
    });
    tearDown(() => server.close(force: true));

    test(
      'writes what the server sends, and follows a redirect to the same server',
      () async {
        await download(at('/ok'));
        expect(target.readAsBytesSync(), archive);
        target.deleteSync();
        await download(at('/redirect'));
        expect(target.readAsBytesSync(), archive);
      },
    );

    test('is for https addresses only: http, file and ftp are refused before any connection', () async {
      for (final url in [
        at('/ok'),
        Uri.parse('file:///etc/passwd'),
        Uri.parse('ftp://example.invalid/x'),
      ]) {
        final e = await refused(download(url, loopbackHttp: false));
        expect(e.id, 'zsign-download-refused', reason: '$url');
        expect(e.what, contains('only https addresses are used'));
      }
      expect(served, 0);
    });

    test('and an http address that is not this machine is refused even when a test allows loopback', () async {
      final e = await refused(download(Uri.parse('http://example.invalid/x')));
      expect(e.id, 'zsign-download-refused');
    });

    test(
      'a redirect to http is refused, and so is a redirect that never ends',
      () async {
        expect(
          (await refused(download(at('/redirect-to-http')))).what,
          contains('only https addresses are used'),
        );
        final e = await refused(download(at('/redirect-loop')));
        expect(e.id, 'zsign-download-refused');
        expect(e.what, contains('HTTP 302'));
      },
    );

    test('a size that the server declares above the cap is refused before a byte is read', () async {
      final e = await refused(download(at('/declares-big'), maxBytes: 1000));
      expect(e.id, 'zsign-download-refused');
      expect(e.what, contains('larger than'));
    });

    test('a stream without end stops at the cap, and the file goes', () async {
      final e = await refused(download(at('/endless'), maxBytes: 20000));
      expect(e.id, 'zsign-download-refused');
      expect(e.what, contains('larger than'));
    });

    test('a pause in the data is a timeout: offline, 69', () async {
      final e = await refused(
        download(at('/stalls'), timeout: const Duration(milliseconds: 300)),
      );
      expect(e.id, 'offline');
      expect(e.exitCode, ExitCode.unavailable);
      expect(
        e.what,
        contains('cannot download the zsign source from 127.0.0.1'),
      );
      expect(e.what, contains('no answer or no data within'));
    });

    test('no answer at all is a timeout too, and so is a download that takes too long', () async {
      expect(
        (await refused(
          download(
            at('/slow-start'),
            timeout: const Duration(milliseconds: 300),
          ),
        )).id,
        'offline',
      );
      expect(
        (await refused(
          download(at('/stalls'), overall: const Duration(milliseconds: 300)),
        )).id,
        'offline',
      );
    });

    test('a server that is not there is offline', () async {
      final url = at('/ok');
      await server.close(force: true);
      final e = await refused(download(url));
      expect(e.id, 'offline');
      expect(e.exitCode, ExitCode.unavailable);
    });

    test('HTTP 404 is refused (1), and HTTP 5xx is unavailable (69)', () async {
      final gone = await refused(download(at('/gone')));
      expect(
        (gone.id, gone.exitCode),
        ('zsign-download-refused', ExitCode.failed),
      );
      expect(gone.what, contains('HTTP 404'));
      final down = await refused(download(at('/down')));
      expect(
        (down.id, down.exitCode),
        ('github-unavailable', ExitCode.unavailable),
      );
    });

    test('through doctor: the real download, the hash and the build, and the limits as 1 and 69', () async {
      Future<(int, String)> run(ZsignSource from, [String path = '/ok']) async {
        final (code, out, _) = await doctor(
          from: ZsignSource(
            url: at(path),
            sha256: from.sha256,
            maxDownload: from.maxDownload,
            timeout: from.timeout,
            fetch: (url, file, {required maxBytes, required timeout}) =>
                downloadArchive(
                  url,
                  file,
                  maxBytes: maxBytes,
                  timeout: timeout,
                  loopbackHttp: true,
                ),
          ),
        );
        return (code, out);
      }

      final (declared, outDeclared) = await run(
        ZsignSource(sha256: archiveHash, maxDownload: 10),
      );
      expect(declared, 1, reason: outDeclared);
      expect(builds, isEmpty);
      final (stalled, _) = await run(
        ZsignSource(
          sha256: archiveHash,
          timeout: const Duration(milliseconds: 300),
        ),
        '/stalls',
      );
      expect(stalled, 69);
      expect(folder(), isEmpty);
      final (ok, outOk) = await run(ZsignSource(sha256: archiveHash));
      expect(ok, 0, reason: outOk);
      expect(
        outOk,
        contains(
          'PASS  downloaded the zsign source (${archive.length} bytes) from 127.0.0.1',
        ),
      );
      expect(binary.readAsStringSync(), builtBytes);
    });
  });
}
