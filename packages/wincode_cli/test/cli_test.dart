import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_cli/wincode_cli.dart';

const _planned = ['build', 'status'];

/// (exit code, stdout, stderr) of `wincode` with [args].
Future<(int, String, String)> wincode(List<String> args) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final code = await runWincode(args, out, err);
  return (code, '$out', '$err');
}

void main() {
  test('--help of wincode and of each command is test/goldens/help.txt (UPDATE_GOLDENS=1 rewrites it)', () async {
    final help = StringBuffer();
    for (final args in [
      ['--help'],
      for (final command in [
        ..._planned,
        'doctor',
        'init',
        'preflight',
        'sign',
        'upload',
      ]..sort())
        ['help', command],
    ]) {
      final (code, out, err) = await wincode(args);
      expect((code, err), (0, ''), reason: '$args');
      help
        ..writeln('\$ wincode ${args.join(' ')}')
        ..writeln(out);
    }
    final golden = File('test/goldens/help.txt');
    if (Platform.environment['UPDATE_GOLDENS'] != null) {
      golden.writeAsStringSync('$help');
    }
    expect('$help', golden.readAsStringSync().replaceAll('\r\n', '\n'));
  });

  test(
    'each planned command says it is not implemented yet and exits 64',
    () async {
      for (final command in _planned) {
        expect(await wincode([command]), (
          64,
          '',
          'wincode $command: not implemented yet, see ADR-0013\n',
        ));
      }
    },
  );

  test(
    'the global options are accepted before and after the command',
    () async {
      for (final args in [
        [
          'build',
          '--config',
          'other.yaml',
          '--verbose',
          '--dry-run',
          'app.ipa',
        ],
        [
          '--config',
          'other.yaml',
          '--verbose',
          '--dry-run',
          'build',
          'app.ipa',
        ],
      ]) {
        expect(await wincode(args), (
          64,
          '',
          'wincode build: not implemented yet, see ADR-0013\n',
        ), reason: '$args');
      }
    },
  );

  test(
    'with --json, stdout is one JSON object that carries the failure',
    () async {
      final (code, out, err) = await wincode(['build', '--json']);
      expect(code, 64);
      expect(jsonDecode(out), {
        'command': 'build',
        'ok': false,
        'exitCode': 64,
        'error': {
          'id': 'not-implemented',
          'what': 'not implemented yet, see ADR-0013',
        },
      });
      expect(err, 'wincode build: not implemented yet, see ADR-0013\n');
    },
  );

  test(
    'a misspelled command is a usage error that suggests the right one',
    () async {
      final (code, out, err) = await wincode(['sing', '--json']);
      expect(code, 64);
      expect(err, contains('Could not find a command named "sing".'));
      expect(err, contains('Did you mean one of these?\n  sign'));
      expect(
        (jsonDecode(out) as Map<String, Object?>)['error'],
        containsPair('id', 'usage'),
      );
    },
  );

  test(
    'an unexpected exception is a bug report (70), not a stack trace',
    () async {
      final err = StringBuffer();
      expect(await runWincode(['--help'], _BrokenSink(), err), 70);
      expect(
        '$err',
        startsWith(
          'wincode: internal error: Bad state: broken sink\n  why: this is a bug in winCode.\n',
        ),
      );
      expect('$err', contains('https://github.com/wincode-org/wincode/issues'));
    },
  );
}

/// A sink whose every write fails, to stand for any exception winCode does not expect.
class _BrokenSink implements StringSink {
  @override
  Never write(Object? object) => throw StateError('broken sink');

  @override
  Never writeAll(Iterable<Object?> objects, [String separator = '']) =>
      throw StateError('broken sink');

  @override
  Never writeCharCode(int charCode) => throw StateError('broken sink');

  @override
  Never writeln([Object? object = '']) => throw StateError('broken sink');
}
