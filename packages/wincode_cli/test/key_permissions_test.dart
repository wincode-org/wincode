import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_asc/testing.dart';
import 'package:wincode_cli/wincode_cli.dart';
import 'package:wincode_core/wincode_core.dart' show RunProcess, runProcess;

import 'private.dart';

/// ADR-0013, section 11: a key, or a folder of keys, that other users of a Linux machine can reach is refused, like
/// ssh refuses a private key that others can read. Skipped on Windows, where the check is too.
void main() {
  final posix = Platform.isWindows ? 'the check is for POSIX systems' : null;
  late Directory temp;
  final sep = Platform.pathSeparator;

  setUp(() => temp = Directory.systemTemp.createTempSync('wincode_perms_'));
  tearDown(() => temp.deleteSync(recursive: true));

  String chmod(String mode, FileSystemEntity entity) {
    final result = Process.runSync('chmod', [mode, entity.path]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return mode;
  }

  File key([String content = 'not really a key\n']) =>
      File('${temp.path}${sep}the.key')..writeAsStringSync(content);

  KeyTarget fileTarget(File file) => (
    path: file.path,
    folder: false,
    label: 'the file that WINCODE_DIST_KEY names',
    where: r'"$WINCODE_DIST_KEY"',
  );

  KeyTarget folderTarget(Directory folder) => (
    path: folder.path,
    folder: true,
    label: 'the folder that WINCODE_ASC_KEY_DIR names',
    where: r'"$WINCODE_ASC_KEY_DIR"',
  );

  Future<WincodeException> refused(
    Iterable<KeyTarget> targets, {
    Future<String?> Function(String, List<String>)? tool,
  }) async {
    try {
      await (tool == null
          ? requirePrivate(targets)
          : requirePrivate(targets, tool: tool));
    } on WincodeException catch (e) {
      return e;
    }
    fail('the keys were accepted');
  }

  group('modes', () {
    for (final mode in ['600', '400', '200', '000']) {
      test('a file at $mode passes', () async {
        final file = key();
        chmod(mode, file);
        await requirePrivate([fileTarget(file)]);
      }, skip: posix);
    }

    for (final mode in ['700', '500', '100']) {
      test('a folder at $mode passes', () async {
        final folder = Directory('${temp.path}${sep}keys')..createSync();
        chmod(mode, folder);
        await requirePrivate([folderTarget(folder)]);
        chmod('700', folder);
      }, skip: posix);
    }

    // One bit for the group or for others is enough to refuse.
    for (final mode in [
      '640',
      '604',
      '660',
      '606',
      '644',
      '666',
      '620',
      '602',
    ]) {
      test('a file at $mode is refused, with the chmod that fixes it', () async {
        final file = key();
        chmod(mode, file);
        final e = await refused([fileTarget(file)]);
        expect(e.id, 'keys-permissions');
        expect(e.exitCode, ExitCode.config);
        expect(
          e.what,
          'the file that WINCODE_DIST_KEY names can be reached by other users (mode 0$mode)',
        );
        expect(e.next, r'run: chmod 600 "$WINCODE_DIST_KEY"');
      }, skip: posix);
    }

    for (final mode in ['750', '705', '755', '770', '707']) {
      test(
        'a folder at $mode is refused, with the chmod that fixes it',
        () async {
          final folder = Directory('${temp.path}${sep}keys')..createSync();
          chmod(mode, folder);
          final e = await refused([folderTarget(folder)]);
          expect(e.id, 'keys-permissions');
          expect(e.what, contains('(mode 0$mode)'));
          expect(e.next, r'run: chmod 700 "$WINCODE_ASC_KEY_DIR"');
          chmod('700', folder);
        },
        skip: posix,
      );
    }

    test('the first target that fails stops the check, and a missing one is left to the caller', () async {
      final folder = Directory('${temp.path}${sep}keys')..createSync();
      final loose = key();
      chmod('644', loose);
      chmod('700', folder);
      final e = await refused([
        fileTarget(File('${temp.path}${sep}none.key')),
        folderTarget(folder),
        fileTarget(loose),
      ]);
      expect(e.what, contains('the file that WINCODE_DIST_KEY names'));
    }, skip: posix);

    test('a link to a key is checked as the key it points to', () async {
      final target = key();
      final link = Link('${temp.path}${sep}link')..createSync(target.path);
      chmod('644', target);
      expect(
        (await refused([fileTarget(File(link.path))])).id,
        'keys-permissions',
      );
      chmod('600', target);
      await requirePrivate([fileTarget(File(link.path))]);
    }, skip: posix);

    test('a message names the file by its role and prints neither its path nor its content', () async {
      final file = key('the content of a key: SECRETSECRET\n');
      chmod('644', file);
      final e = await refused([fileTarget(file)]);
      final printed = e.describe('wincode sign');
      expect(printed, isNot(contains(file.path)));
      expect(printed, isNot(contains(temp.path)));
      expect(printed, isNot(contains('SECRETSECRET')));
      expect(printed, isNot(contains('PRIVATE KEY')));
    }, skip: posix);
  });

  group('owner', () {
    Future<String?> Function(String, List<String>) answers({
      String? me = '1000',
      String? gnu,
      String? bsd,
    }) =>
        (executable, arguments) async =>
            switch ((executable, arguments.first)) {
              ('id', _) => me,
              ('stat', '-c') => gnu,
              ('stat', '-f') => bsd,
              _ => fail('unexpected $executable $arguments'),
            };

    test(
      'a file that another user owns is refused, with the chown that fixes it',
      () async {
        final file = key();
        chmod('600', file);
        final e = await refused([fileTarget(file)], tool: answers(gnu: '0'));
        expect(e.id, 'keys-permissions');
        expect(e.exitCode, ExitCode.config);
        expect(
          e.what,
          'the file that WINCODE_DIST_KEY names is owned by another user (uid 0, not 1000)',
        );
        expect(
          e.next,
          r'run: sudo chown "$(id -un)" "$WINCODE_DIST_KEY" && chmod 600 "$WINCODE_DIST_KEY"',
        );
      },
      skip: posix,
    );

    test('the user that runs wincode may own it', () async {
      final file = key();
      chmod('600', file);
      await requirePrivate([fileTarget(file)], tool: answers(gnu: '1000'));
    }, skip: posix);

    test('BSD and macOS stat answer to -f', () async {
      final file = key();
      chmod('600', file);
      await requirePrivate([fileTarget(file)], tool: answers(bsd: '1000'));
      expect(
        (await refused([fileTarget(file)], tool: answers(bsd: '501'))).what,
        contains('owned by another user (uid 501, not 1000)'),
      );
    }, skip: posix);

    test('fails closed when who owns it cannot be told', () async {
      final file = key();
      chmod('600', file);
      for (final tool in [answers(me: null, gnu: '1000'), answers()]) {
        final e = await refused([fileTarget(file)], tool: tool);
        expect(e.id, 'stat-unavailable');
        expect(e.exitCode, ExitCode.unavailable);
      }
    }, skip: posix);

    test(
      'the real id and stat agree that the user owns what the user made',
      () async {
        final file = key();
        chmod('600', file);
        await requirePrivate([fileTarget(file)]);
      },
      skip: posix,
    );

    test('a folder that root owns is refused (the real stat)', () async {
      final root = Directory('/root');
      final me = Process.runSync('id', ['-u']).stdout.toString().trim();
      final owner = Process.runSync('stat', ['-c', '%u', '/root']);
      if (me == '0' || owner.exitCode != 0 || '${owner.stdout}'.trim() != '0') {
        markTestSkipped('/root is not a folder that another user owns');
        return;
      }
      final e = await refused([
        (path: root.path, folder: true, label: 'a folder', where: '/root'),
      ]);
      expect(e.id, 'keys-permissions');
      // A /root that is open to others is refused for its mode first; both are keys-permissions.
      expect(e.what, anyOf(contains('other users'), contains('another user')));
    }, skip: posix);
  });

  group('the temporary folder of a signing', () {
    test('is made mode 0700 whatever the umask left it', () async {
      final folder = Directory('${temp.path}${sep}work')..createSync();
      chmod('755', folder);
      await makePrivate(folder);
      expect(FileStat.statSync(folder.path).mode & 511, 448); // 0700
    }, skip: posix);

    test('fails closed (69) when chmod cannot be run', () async {
      final folder = Directory('${temp.path}${sep}work')..createSync();
      Object? thrown;
      try {
        await makePrivate(
          folder,
          chmod: (arguments) async {
            expect(arguments, ['700', '--', folder.path]);
            return false;
          },
        );
      } on WincodeException catch (e) {
        thrown = e;
      }
      expect(thrown, isA<WincodeException>());
      expect((thrown! as WincodeException).id, 'chmod-unavailable');
      expect((thrown as WincodeException).exitCode, ExitCode.unavailable);
    }, skip: posix);
  });

  test('on Windows nothing is checked', () async {
    final file = key();
    await requirePrivate([fileTarget(file)]);
  }, skip: Platform.isWindows ? null : 'Windows only');

  group('every source of keys, in every command', () {
    const keyId = 'ABCDE12345';
    const issuer = '00000000-0000-4000-8000-000000000001';
    final throwaway = ThrowawayKey();
    late String home;

    setUp(() {
      home = '${temp.path}${sep}home';
      Directory(home).createSync();
    });

    String defaultRoot() => '$home$sep.wincode${sep}keys';

    Map<String, String> env([Map<String, String> more = const {}]) => {
      'USERPROFILE': home,
      ...more,
    };

    WincodeConfig app({String? reference = 'team-one'}) {
      final file = File('${temp.path}${sep}wincode.yaml')
        ..writeAsStringSync(
          'bundle_id: com.example.alpha\nteam_id: TEAM000001\n'
          '${reference == null ? '' : 'credentials: $reference\n'}',
        );
      return loadConfig(file.path);
    }

    /// A folder of keys that passes: private, with a `.p8`, an `issuer-id` and a `dist.key`.
    Directory keyFolder(String path) {
      final folder = privateFolders(
        Directory(path)..createSync(recursive: true),
        temp,
      );
      private(
        File('$path${sep}AuthKey_$keyId.p8')
          ..writeAsStringSync(throwaway.pem()),
      );
      File('$path${sep}issuer-id').writeAsStringSync('$issuer\n');
      private(File('$path${sep}dist.key')..writeAsStringSync(throwaway.pem()));
      return folder;
    }

    Future<WincodeException> locateRefused(
      WincodeConfig app,
      Map<String, String> environment,
    ) async {
      try {
        await locateAscKeyFiles(
          app,
          environment: environment,
          redactor: Redactor(active: false),
        );
      } on WincodeException catch (e) {
        return e;
      }
      fail('the key folder was accepted');
    }

    Future<WincodeException> distRefused(
      WincodeConfig app,
      Map<String, String> environment,
    ) async {
      try {
        await resolveDistKey(
          app,
          environment: environment,
          redactor: Redactor(active: false),
        );
      } on WincodeException catch (e) {
        return e;
      }
      fail('the distribution key was accepted');
    }

    /// Checks what a refusal says: the id, the code, the fix, and that nothing secret or personal was printed.
    void expectRefusal(WincodeException e, String what, String next) {
      expect(e.id, 'keys-permissions');
      expect(e.exitCode, ExitCode.config);
      expect(e.what, contains(what));
      expect(e.next, next);
      final printed = e.describe('wincode preflight');
      for (final secret in [temp.path, home, keyId, issuer, 'PRIVATE KEY']) {
        expect(printed, isNot(contains(secret)), reason: 'printed $secret');
      }
    }

    group('the keys root and the folder of a reference', () {
      test('the default keys folder', () async {
        keyFolder('${defaultRoot()}${sep}team-one');
        chmod('755', Directory(defaultRoot()));
        expectRefusal(
          await locateRefused(app(), env()),
          'the default keys folder can be reached by other users (mode 0755)',
          'run: chmod 700 ~/.wincode/keys',
        );
        expectRefusal(
          await distRefused(app(), env()),
          'the default keys folder',
          'run: chmod 700 ~/.wincode/keys',
        );
      }, skip: posix);

      test('the keys folder that WINCODE_KEYS_DIR names', () async {
        final root = '${temp.path}${sep}root';
        keyFolder('$root${sep}team-one');
        chmod('750', Directory(root));
        final environment = env({keysRootVariable: root});
        expectRefusal(
          await locateRefused(app(), environment),
          'the folder that WINCODE_KEYS_DIR names can be reached by other users (mode 0750)',
          r'run: chmod 700 "$WINCODE_KEYS_DIR"',
        );
      }, skip: posix);

      test('the folder of the credentials', () async {
        final folder = keyFolder('${defaultRoot()}${sep}team-one');
        chmod('705', folder);
        expectRefusal(
          await locateRefused(app(), env()),
          'the folder of the credentials team-one can be reached by other users (mode 0705)',
          'run: chmod 700 ~/.wincode/keys/team-one',
        );
        chmod('700', folder);
        final root = '${temp.path}${sep}root';
        chmod('755', keyFolder('$root${sep}team-one'));
        expect(
          (await locateRefused(app(), env({keysRootVariable: root}))).next,
          r'run: chmod 700 "$WINCODE_KEYS_DIR"/team-one',
        );
      }, skip: posix);
    });

    group('the files', () {
      test('the .p8 of a reference, without its Key ID', () async {
        final folder = keyFolder('${defaultRoot()}${sep}team-one');
        chmod('644', File('${folder.path}${sep}AuthKey_$keyId.p8'));
        expectRefusal(
          await locateRefused(app(), env()),
          'the .p8 in the folder of the credentials team-one can be reached by other users (mode 0644)',
          'run: chmod 600 ~/.wincode/keys/team-one/AuthKey_*.p8',
        );
      }, skip: posix);

      test('the dist.key of a reference', () async {
        final folder = keyFolder('${defaultRoot()}${sep}team-one');
        chmod('640', File('${folder.path}${sep}dist.key'));
        expectRefusal(
          await distRefused(app(), env()),
          'the distribution key of the credentials team-one can be reached by other users (mode 0640)',
          'run: chmod 600 ~/.wincode/keys/team-one/dist.key',
        );
        // The App Store Connect half does not need dist.key, and passes.
        expect(
          await locateAscKeyFiles(
            app(),
            environment: env(),
            redactor: Redactor(active: false),
          ),
          isNotNull,
        );
      }, skip: posix);
    });

    group('the variables', () {
      test('WINCODE_ASC_KEY_DIR_<REF>: the folder and its .p8', () async {
        final folder = keyFolder('${temp.path}${sep}ci');
        final environment = env({ascOverrideVariable('team-one'): folder.path});
        chmod('755', folder);
        expectRefusal(
          await locateRefused(app(), environment),
          'the folder that WINCODE_ASC_KEY_DIR_TEAM_ONE names can be reached by other users (mode 0755)',
          r'run: chmod 700 "$WINCODE_ASC_KEY_DIR_TEAM_ONE"',
        );
        chmod('700', folder);
        chmod('644', File('${folder.path}${sep}AuthKey_$keyId.p8'));
        expectRefusal(
          await locateRefused(app(), environment),
          'the .p8 in the folder that WINCODE_ASC_KEY_DIR_TEAM_ONE names',
          r'run: chmod 600 "$WINCODE_ASC_KEY_DIR_TEAM_ONE"/AuthKey_*.p8',
        );
      }, skip: posix);

      test('WINCODE_DIST_KEY_<REF>', () async {
        final file = private(
          File('${temp.path}${sep}other.key')..writeAsStringSync('x'),
        );
        final environment = env({distOverrideVariable('team-one'): file.path});
        keyFolder('${defaultRoot()}${sep}team-one');
        chmod('644', file);
        expectRefusal(
          await distRefused(app(), environment),
          'the file that WINCODE_DIST_KEY_TEAM_ONE names can be reached by other users',
          r'run: chmod 600 "$WINCODE_DIST_KEY_TEAM_ONE"',
        );
      }, skip: posix);

      test('the legacy WINCODE_ASC_KEY_DIR and WINCODE_DIST_KEY, for a file without credentials', () async {
        final asc = keyFolder('${temp.path}${sep}asc');
        final environment = env({'WINCODE_ASC_KEY_DIR': asc.path});
        chmod('755', asc);
        expectRefusal(
          await locateRefused(app(reference: null), environment),
          'the folder that WINCODE_ASC_KEY_DIR names',
          r'run: chmod 700 "$WINCODE_ASC_KEY_DIR"',
        );
        chmod('700', asc);
        chmod('664', File('${asc.path}${sep}AuthKey_$keyId.p8'));
        expectRefusal(
          await locateRefused(app(reference: null), environment),
          'the .p8 in the folder that WINCODE_ASC_KEY_DIR names',
          r'run: chmod 600 "$WINCODE_ASC_KEY_DIR"/AuthKey_*.p8',
        );
        final dist = File('${asc.path}${sep}dist.key');
        chmod('666', dist);
        expectRefusal(
          await distRefused(
            app(reference: null),
            env({'WINCODE_DIST_KEY': dist.path}),
          ),
          'the file that WINCODE_DIST_KEY names',
          r'run: chmod 600 "$WINCODE_DIST_KEY"',
        );
      }, skip: posix);
    });

    group('the commands', () {
      Future<(int, String, String)> wincode(
        List<String> args,
        Map<String, String> environment, {
        RunProcess run = runProcess,
      }) async {
        final out = StringBuffer();
        final err = StringBuffer();
        final code = await runWincode(
          args,
          out,
          err,
          environment: environment,
          clock: () => DateTime.utc(2026, 11, 11, 12),
          run: run,
        );
        for (final secret in [keyId, issuer, home, 'PRIVATE KEY']) {
          expect(
            '$out$err',
            isNot(contains(secret)),
            reason: 'printed $secret',
          );
        }
        return (code, '$out', '$err');
      }

      Map<String, Object?> errorOf(String out) =>
          (jsonDecode(out) as Map<String, Object?>)['error']!
              as Map<String, Object?>;

      test('preflight, upload and doctor refuse alike, with 78', () async {
        final folder = keyFolder('${defaultRoot()}${sep}team-one');
        chmod('644', File('${folder.path}${sep}AuthKey_$keyId.p8'));
        app();
        for (final args in [
          ['preflight', '--dry-run'],
          ['preflight'],
          ['upload', '--yes'],
          ['doctor'],
        ]) {
          final (code, out, err) = await wincode([
            ...args,
            '--config',
            '${temp.path}${sep}wincode.yaml',
            '--json',
          ], env());
          expect(code, 78, reason: '${args.join(' ')}: $out$err');
          final error = errorOf(out);
          expect(error['id'], 'keys-permissions', reason: args.join(' '));
          expect(
            error['next'],
            'run: chmod 600 ~/.wincode/keys/team-one/AuthKey_*.p8',
          );
        }
      }, skip: posix);

      test(
        'doctor reports it as a failed check, and the others still run',
        () async {
          final folder = keyFolder('${defaultRoot()}${sep}team-one');
          chmod('644', File('${folder.path}${sep}AuthKey_$keyId.p8'));
          app();
          final (code, out, _) = await wincode([
            'doctor',
            '--config',
            '${temp.path}${sep}wincode.yaml',
          ], env());
          expect(code, 78);
          expect(out, contains('PASS  wincode.yaml loads'));
          expect(
            out,
            contains(
              'FAIL  the .p8 in the folder of the credentials team-one can be reached by other users (mode 0644)',
            ),
          );
          expect(
            out,
            contains(
              'next: run: chmod 600 ~/.wincode/keys/team-one/AuthKey_*.p8',
            ),
          );
        },
        skip: posix,
      );
    });
  });
}
