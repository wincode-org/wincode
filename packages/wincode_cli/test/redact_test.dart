import 'package:test/test.dart';
import 'package:wincode_cli/wincode_cli.dart';

const _message =
    'wincode sign: the IPA is for com.example.app.beta, but wincode.yaml says com.example.app (team TEAM000000)';

Redactor _redactor({bool flag = false, Map<String, String> env = const {}}) =>
    Redactor.forRun(flag: flag, environment: env)
      ..hide('com.example.app', '<bundle ID>')
      ..hide('com.example.app.beta', '<bundle ID>')
      ..hide('TEAM000000', '<team ID>');

void main() {
  test('IDs are shown by default', () {
    expect(_redactor().apply(_message), _message);
  });

  test('--redact hides the registered IDs, the longest value first', () {
    expect(
      _redactor(flag: true).apply(_message),
      'wincode sign: the IPA is for <bundle ID>, but wincode.yaml says <bundle ID> (team <team ID>)',
    );
  });

  test('the CI variable hides them without the flag', () {
    expect(
      _redactor(env: {'CI': 'true'}).apply(_message),
      isNot(contains('com.example')),
    );
    expect(
      _redactor(env: {'CI': 'true'}).apply(_message),
      isNot(contains('TEAM000000')),
    );
  });

  test('CI that is empty, 0 or false does not count', () {
    for (final value in ['', '0', 'false', 'FALSE']) {
      expect(runsInCi({'CI': value}), isFalse, reason: value);
    }
    expect(runsInCi({}), isFalse);
    for (final value in ['true', '1', 'yes']) {
      expect(runsInCi({'CI': value}), isTrue, reason: value);
    }
  });

  test(
    'text for an issue report is redacted even when nothing asks for it',
    () {
      final redactor = _redactor();
      expect(redactor.active, isFalse);
      expect(redactor.forReport(_message), isNot(contains('TEAM000000')));
    },
  );

  test('a sink passes every kind of write through the redactor', () {
    final out = StringBuffer();
    _redactor(flag: true).sink(out)
      ..write('a TEAM000000 ')
      ..writeAll(['b', 'TEAM000000'], ' ')
      ..writeln(' c TEAM000000')
      ..writeCharCode(0x21);
    expect('$out', 'a <team ID> b <team ID> c <team ID>\n!');
  });

  test('an inactive redactor hands back the sink it was given', () {
    final out = StringBuffer();
    expect(identical(_redactor().sink(out), out), isTrue);
  });

  group('runWincode', () {
    Future<(int, String, String)> run(
      List<String> args, {
      Map<String, String> env = const {},
    }) async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runWincode(args, out, err, environment: env);
      return (code, '$out', '$err');
    }

    test('accepts --redact before and after the command', () async {
      for (final args in [
        ['--redact', 'sign'],
        ['sign', '--redact'],
      ]) {
        expect(await run(args), (
          64,
          '',
          'wincode sign: not implemented yet, see ADR-0013\n',
        ), reason: '$args');
      }
    });

    test('behaves the same under CI, with no ID to hide', () async {
      expect(await run(['sign'], env: {'CI': 'true'}), (
        64,
        '',
        'wincode sign: not implemented yet, see ADR-0013\n',
      ));
    });
  });
}
