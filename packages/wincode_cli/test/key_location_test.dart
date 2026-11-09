import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_cli/wincode_cli.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('key_location_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  final sep = Platform.pathSeparator;
  String key(String folder) => '$folder${sep}dist.key';

  Future<void> git(Directory folder, List<String> args) async {
    final result = await Process.run('git', ['-C', folder.path, ...args]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  Future<WincodeException> refused(String path) async {
    try {
      await requireOutsideGit(path, source: 'WINCODE_DIST_KEY');
    } on WincodeException catch (e) {
      return e;
    }
    fail('no failure for a file the check should refuse');
  }

  group('with git', () {
    test('a file outside any repository passes', () async {
      File(key(dir.path)).writeAsStringSync('x');
      await requireOutsideGit(key(dir.path), source: 'WINCODE_DIST_KEY');
    });

    test('a file in a working tree is refused, and the message says where to move it', () async {
      await git(dir, ['init', '-q']);
      File(key(dir.path)).writeAsStringSync('x');
      final e = await refused(key(dir.path));
      expect(e.exitCode, ExitCode.config);
      expect(e.id, 'key-in-git-tree');
      expect(
        e.what,
        startsWith('WINCODE_DIST_KEY points inside a git working tree'),
      );
      expect(e.next, contains(r'%USERPROFILE%\.wincode'));
      expect(e.next, contains('~/.wincode'));
      expect(e.next, contains('point WINCODE_DIST_KEY at the new place'));
    });

    test('the path is never repeated in the message', () async {
      await git(dir, ['init', '-q']);
      File(key(dir.path)).writeAsStringSync('x');
      final e = await refused(key(dir.path));
      expect(e.describe('wincode sign'), isNot(contains(dir.path)));
    });

    test('a file that git ignores passes', () async {
      await git(dir, ['init', '-q']);
      File(key(dir.path)).writeAsStringSync('x');
      File('${dir.path}$sep.gitignore').writeAsStringSync('*.key\n');
      await requireOutsideGit(key(dir.path), source: 'WINCODE_DIST_KEY');
    });

    test(
      'a file in a subfolder is judged by the repository above it',
      () async {
        await git(dir, ['init', '-q']);
        final sub = Directory('${dir.path}${sep}signing')..createSync();
        File(key(sub.path)).writeAsStringSync('x');
        expect((await refused(key(sub.path))).id, 'key-in-git-tree');
      },
    );

    test(
      'a tracked file is refused although a pattern ignores its name',
      () async {
        await git(dir, ['init', '-q']);
        File(key(dir.path)).writeAsStringSync('x');
        await git(dir, ['add', '-f', 'dist.key']);
        File('${dir.path}$sep.gitignore').writeAsStringSync('*.key\n');
        expect((await refused(key(dir.path))).id, 'key-in-git-tree');
      },
    );
  });

  group('with a fake git', () {
    Future<ProcessResult> Function(
      String,
      List<String>, {
      String? workingDirectory,
    })
    fake(List<ProcessResult> answers, [List<List<String>>? calls]) {
      final queue = [...answers];
      return (exe, args, {workingDirectory}) async {
        calls?.add([exe, ...args]);
        return queue.removeAt(0);
      };
    }

    ProcessResult result(int code, [String out = '', String err = '']) =>
        ProcessResult(0, code, out, err);

    test(
      'runs git in the folder of the file, whatever kind of path it is',
      () async {
        final calls = <List<String>>[];
        await requireOutsideGit(
          '/home/me/.wincode/dist.key',
          source: 'WINCODE_DIST_KEY',
          run: fake([result(128, '', 'fatal: not a git repository')], calls),
        );
        expect(calls.single, [
          'git',
          '-C',
          '/home/me/.wincode/',
          'rev-parse',
          '--is-inside-work-tree',
        ]);
        await requireOutsideGit(
          r'C:\keys\AuthKey_X.p8',
          source: 'WINCODE_ASC_KEY_DIR',
          run: fake([result(128, '', 'fatal: not a git repository')], calls),
        );
        expect(calls.last[2], r'C:\keys\');
      },
    );

    test('a missing git fails closed with the install step', () async {
      Future<ProcessResult> missing(
        String exe,
        List<String> args, {
        String? workingDirectory,
      }) => throw const ProcessException('git', []);
      try {
        await requireOutsideGit(
          '/home/me/dist.key',
          source: 'WINCODE_DIST_KEY',
          run: missing,
        );
        fail('no failure');
      } on WincodeException catch (e) {
        expect(e.exitCode, ExitCode.unavailable);
        expect(e.id, 'git-unavailable');
        expect(e.next, contains('install Git'));
      }
    });

    test(
      'an error from git other than "not a repository" fails closed',
      () async {
        try {
          await requireOutsideGit(
            '/home/me/dist.key',
            source: 'WINCODE_DIST_KEY',
            run: fake([result(128, '', 'fatal: detected dubious ownership')]),
          );
          fail('no failure');
        } on WincodeException catch (e) {
          expect(e.id, 'git-unavailable');
          expect(e.what, isNot(contains('dubious')));
        }
      },
    );

    test('a failure of check-ignore itself fails closed', () async {
      try {
        await requireOutsideGit(
          '/home/me/dist.key',
          source: 'WINCODE_DIST_KEY',
          run: fake([result(0, 'true\n'), result(128)]),
        );
        fail('no failure');
      } on WincodeException catch (e) {
        expect(e.id, 'git-unavailable');
      }
    });

    test('a path that ends in a separator is a programming error', () {
      expect(
        requireOutsideGit(
          '/home/me/',
          source: 'WINCODE_DIST_KEY',
          run: fake([]),
        ),
        throwsArgumentError,
      );
    });
  });
}
