import 'package:test/test.dart';
import 'package:wincode_cli/src/redact.dart';
import 'package:wincode_cli/src/zsign_output.dart';

/// What a failure of zsign shows of its output (ADR-0013, section 4): the lines that name a problem, then the last ten
/// lines, redacted, cleared of anything that looks like a key, and cut to a size.
void main() {
  String why(List<String> said, [Redactor? redactor]) =>
      zsignWhy(said, redactor ?? Redactor(active: false));

  group('which lines', () {
    test('none, or only blank ones: zsign printed nothing', () {
      expect(why([]), 'zsign printed nothing.');
      expect(why(['', '  ', '\t']), 'zsign printed nothing.');
    });

    test('one line is on the line of "zsign said:"', () {
      expect(why(['>>> Done.']), 'zsign said: >>> Done.');
      expect(why(['', '>>> Done.', '']), 'zsign said: >>> Done.');
    });

    test('an output of ten lines or fewer is shown whole, in order', () {
      final said = [for (var i = 1; i <= 10; i++) 'line $i'];
      expect(why(said), 'zsign said:\n${said.map((l) => '    $l').join('\n')}');
    });

    test('the lines with a problem, in order, then the last ten', () {
      final said = [
        'noise 1',
        'ERROR: first',
        'noise 2',
        'Signing failed for x',
        for (var i = 3; i <= 20; i++) 'noise $i',
        'the signature is Invalid',
        for (var i = 21; i <= 29; i++) 'noise $i',
        '>>> Done.',
      ];
      expect(why(said).split('\n'), [
        'zsign said:',
        '    ERROR: first',
        '    Signing failed for x',
        // Printed after the second one and before the last ten lines, so it follows the second one.
        '    the signature is Invalid',
        for (var i = 21; i <= 29; i++) '    noise $i',
        '    >>> Done.',
      ]);
    });

    test('a line that says the same twice is shown once', () {
      expect(
        why(['failed: x', 'noise', for (var i = 0; i < 12; i++) 'failed: y'])
            .split('\n'),
        ['zsign said:', '    failed: x', '    failed: y'],
      );
    });

    test(
      'error, failed and invalid are found in any case, inside any word',
      () {
        for (final line in [
          'Error',
          'FAILED',
          'iNvAlId',
          'xerrorx',
          'unfailed',
        ]) {
          expect(zsignProblemLine.hasMatch(line), isTrue, reason: line);
        }
        for (final line in ['>>> Done.', 'Signing: a', 'valid']) {
          expect(zsignProblemLine.hasMatch(line), isFalse, reason: line);
        }
      },
    );
  });

  group('the size', () {
    test('at most 40 lines, then "... (cut)"', () {
      final lines = why([for (var i = 1; i <= 100; i++) 'failed $i'])
          .split('\n');
      expect(lines, [
        'zsign said:',
        for (var i = 1; i <= 40; i++) '    failed $i',
        '    ... (cut)',
      ]);
    });

    test('exactly 40 lines are not cut', () {
      final lines = why([for (var i = 1; i <= 40; i++) 'failed $i'])
          .split('\n');
      expect(lines, hasLength(41));
      expect(lines.last, '    failed 40');
    });

    test('a line is cut at 300 characters, and says so', () {
      final long = 'failed ${'word ' * 100}';
      final line = why([long]).substring('zsign said: '.length);
      expect(line, '${long.trim().substring(0, 300)} ... (cut)');
      expect(
        why(['failed ${'x ' * 150}'.substring(0, 300)]),
        isNot(contains('(cut)')),
      );
    });

    test('at most 4,000 characters of lines', () {
      // Lines of 200 characters: 20 of them with their line ends are 4,020.
      final said = [for (var i = 100; i < 140; i++) 'failed $i${' a' * 95}'];
      expect(said.first.length, 200);
      final lines = why(said).split('\n');
      expect(lines.first, 'zsign said:');
      expect(lines.last, '    ... (cut)');
      expect(lines, hasLength(1 + 19 + 1));
      final total = lines
          .skip(1)
          .take(19)
          .fold<int>(0, (n, l) => n + l.trim().length + 1);
      expect(total, lessThanOrEqualTo(4000));
    });
  });

  group('what is hidden', () {
    test('the IDs, names and secrets that the redactor knows, always', () {
      final redactor = Redactor(active: false)
        ..hide('com.example.alpha', '<bundle ID>')
        ..hide('TEAM000001', '<team ID>')
        ..hideName('alpha', 'app-1')
        ..secret('/home/me/keys/dist.key', '<distribution key>');
      expect(
        why([
          'cannot sign com.example.alpha for TEAM000001 with /home/me/keys/dist.key',
          'failed in the app Alpha',
        ], redactor),
        'zsign said:\n'
        '    cannot sign <bundle ID> for <team ID> with <distribution key>\n'
        '    failed in the app app-1',
      );
    });

    test('anything that looks like a key, a password or a token', () {
      final base64Line = 'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7';
      for (final (line, shown) in [
        ('-----BEGIN ${'PRIVATE'} KEY-----', '<hidden>'),
        ('-----END RSA PRIVATE KEY-----', '<hidden>'),
        (base64Line, '<hidden>'),
        ('error: password=hunter2 refused', 'error: <hidden> refused'),
        ('error: Password: hunter2 refused', 'error: <hidden> refused'),
        ('error: passphrase = hunter2 refused', 'error: <hidden> refused'),
        ('error: token: abc123 refused', 'error: <hidden> refused'),
        ('error: api_key=abc123 refused', 'error: <hidden> refused'),
        (
          'error: Authorization: Bearer abc123 refused',
          'error: <hidden> refused',
        ),
        ('error: bearer abc123 refused', 'error: <hidden> refused'),
        (
          'error: eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJhIn0.c2ln refused',
          'error: <hidden> refused',
        ),
        (
          'error: cdhash ${'0123456789abcdef' * 3} refused',
          'error: cdhash <hidden> refused',
        ),
      ]) {
        expect(why([line]), 'zsign said: $shown', reason: line);
      }
    });

    test(
      'an ordinary line, a long path or a hash-free sentence is left as it is',
      () {
        for (final line in [
          '>>> Can not find a certificate that matches the private key.',
          'error: no such file /home/me/work/build/wincode/some-long-folder/and-another-one/App.framework/App',
          'failed: the token expired',
          'error: password is wrong',
          'Invalid argument (os error 22)',
        ]) {
          expect(why([line]), 'zsign said: $line', reason: line);
        }
      },
    );
  });
}
