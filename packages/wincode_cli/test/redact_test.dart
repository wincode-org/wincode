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

  test('secrets are hidden always, even when the IDs are shown', () {
    final out = StringBuffer();
    (_redactor()..secret('token-1', '<token>'))
        .sink(out)
        .writeln('TEAM000000 token-1');
    expect('$out', 'TEAM000000 <token>\n');
  });

  test(
    'a value keeps its first placeholder, and stays hidden once it is a secret',
    () {
      final redactor = _redactor()
        ..hide('com.example.app', '<other bundle ID>')
        ..secret('TEAM000000', '<secret>')
        ..hide('TEAM000000', '<team ID>');
      expect(
        redactor.apply(_message),
        'wincode sign: the IPA is for com.example.app.beta, but wincode.yaml says com.example.app (team <team ID>)',
      );
    },
  );

  group('names (ADR-0014, section 4)', () {
    Redactor names(Map<String, String> values) {
      final redactor = Redactor(active: true);
      values.forEach(redactor.hideName);
      return redactor;
    }

    test('are replaced as whole words, whatever their case', () {
      final redactor = names({'alpha': 'app-1'});
      expect(
        redactor.apply(
          'alpha Alpha ALPHA, Release-alpha build/wincode/alpha/x alpha_1 alphabet xalpha alpha2 1alpha',
        ),
        'app-1 app-1 app-1, Release-app-1 build/wincode/app-1/x app-1_1 alphabet xalpha alpha2 1alpha',
      );
    });

    test('are shown while redaction is off, and hidden in a report', () {
      final redactor = Redactor(active: false)..hideName('alpha', 'app-1');
      expect(redactor.apply('alpha'), 'alpha');
      expect(redactor.forReport('alpha'), 'app-1');
    });

    test('are replaced in one pass: a placeholder is never replaced again', () {
      final redactor = names({'bundle': 'app-1'})
        ..hide('com.example.bundle', '<bundle ID 1>')
        ..hide('TEAM000001', '<team ID>')
        ..hide('com.example.app', '<bundle ID>');
      expect(
        redactor.apply('bundle com.example.app com.example.bundle TEAM000001'),
        'app-1 <bundle ID> <bundle ID 1> <team ID>',
      );
      final chain = names({'alpha': 'beta', 'beta': 'gamma'});
      expect(chain.apply('alpha beta'), 'beta gamma');
    });

    test('the longest value wins where two start together', () {
      final redactor = names({'team': 'x-1', 'team-one': 'credentials-1'});
      expect(redactor.apply('team-one and team'), 'credentials-1 and x-1');
    });

    test('a name keeps its first placeholder, whatever the case it is registered in', () {
      final redactor = names({'alpha': 'app-1'})..hideName('Alpha', 'flavor-1');
      expect(redactor.apply('alpha'), 'app-1');
    });

    test('a variable form is replaced as an exact string and wins a tie with the name', () {
      final redactor = names({'teamone': 'credentials-1'})
        ..hide('TEAMONE', 'CREDENTIALS_1');
      expect(
        redactor.apply('WINCODE_ASC_KEY_DIR_TEAMONE and teamone'),
        'WINCODE_ASC_KEY_DIR_CREDENTIALS_1 and credentials-1',
      );
    });

    test(
      'regular-expression characters in a name or a path are plain text',
      () {
        final redactor = names({'a.b': 'app-1'})..hide('x(1)+[2]', '<path>');
        expect(
          redactor.apply('a.b axb x(1)+[2] x1+2'),
          'app-1 axb <path> x1+2',
        );
      },
    );
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
        ['--redact', 'build'],
        ['build', '--redact'],
      ]) {
        expect(await run(args), (
          64,
          '',
          'wincode build: not implemented yet, see ADR-0013\n',
        ), reason: '$args');
      }
    });

    test('behaves the same under CI, with no ID to hide', () async {
      expect(await run(['build'], env: {'CI': 'true'}), (
        64,
        '',
        'wincode build: not implemented yet, see ADR-0013\n',
      ));
    });
  });
}
