import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_cli/src/config.dart';
import 'package:wincode_cli/src/failure.dart';
import 'package:wincode_cli/src/github.dart';
import 'package:wincode_cli/src/redact.dart';

import 'fake_github.dart';

/// A made-up token with the shape of a fine-grained one.
const token = 'github_pat_FAKE0123456789abcdefghijklmnop';

void main() {
  FakeGithub? github;
  tearDown(() async {
    await github?.close();
    github = null;
  });

  final slept = <Duration>[];
  final logged = <String>[];
  setUp(() {
    slept.clear();
    logged.clear();
  });

  Future<HttpGithubClient> client(
    FutureOr<GhAnswer> Function(GhRequest) answer, {
    String? only = token,
  }) async {
    final server = github = await FakeGithub.start(answer, token: only);
    return HttpGithubClient(
      api: server.uri,
      token: token,
      timeout: const Duration(seconds: 2),
      retryDelays: const [Duration(milliseconds: 1), Duration(milliseconds: 1)],
      sleep: (d) async => slept.add(d),
      clock: () => DateTime.utc(2026, 11, 15, 12),
      log: logged.add,
    );
  }

  Future<GithubException> failure(Future<Object?> request) async {
    try {
      await request;
    } on GithubException catch (e) {
      return e;
    }
    fail('the request did not fail');
  }

  group('a read', () {
    test(
      'sends the token, the API version and a user agent to the API only',
      () async {
        final api = await client((_) => const GhAnswer({'ok': true}));
        expect(await api.getJson('/repos/example-org/example-app'), {
          'ok': true,
        });
        final r = github!.requests.single;
        expect(r.token, token);
        expect(r.headers['x-github-api-version'], githubApiVersion);
        expect(githubApiVersion, '2026-03-10');
        expect(r.headers['accept'], 'application/vnd.github+json');
        expect(r.headers['user-agent'], 'wincode');
        expect(r.method, 'GET');
      },
    );

    test('asks for the raw contents of a file, and sends the query', () async {
      final api = await client((_) => const GhAnswer.text('name: demo\n'));
      expect(
        await api.getText('/repos/o/r/contents/pubspec.yaml', {'ref': 'abc'}),
        'name: demo\n',
      );
      final r = github!.requests.single;
      expect(r.headers['accept'], 'application/vnd.github.raw+json');
      expect(r.query, {'ref': 'abc'});
    });

    test('logs the request and its outcome, never the token', () async {
      final api = await client((_) => const GhAnswer({}));
      await api.getJson('/repos/o/r', {'a': 'b c'});
      expect(
        logged.single,
        matches(r'^GET 127\.0\.0\.1/repos/o/r\?a=b c: HTTP 200, \d+ ms$'),
      );
      expect(logged.join(), isNot(contains(token)));
    });

    test('a path that does not start with a slash is a bug', () async {
      final api = await client((_) => const GhAnswer({}));
      expect(() => api.getJson('repos/o/r'), throwsArgumentError);
    });

    test('an answer that is not a JSON object is refused', () async {
      final api = await client((_) => const GhAnswer.text('<html>'));
      expect((await failure(api.getJson('/x'))).failure, GithubFailure.refused);
      final list = await client((_) => const GhAnswer([1]));
      expect(
        (await failure(list.getJson('/x'))).message,
        'the answer is not a JSON object',
      );
    });
  });

  group('the answers GitHub refuses with', () {
    for (final (status, expected) in [
      (401, GithubFailure.unauthorized),
      (403, GithubFailure.forbidden),
      (404, GithubFailure.notFound),
      (422, GithubFailure.unprocessable),
      (418, GithubFailure.refused),
    ]) {
      test('$status is $expected, with GitHub\'s own message', () async {
        final api = await client(
          (_) => GhAnswer.error(status, 'Said by GitHub'),
        );
        final e = await failure(api.getJson('/repos/o/r'));
        expect(e.failure, expected);
        expect(e.request, 'GET /repos/o/r');
        expect(e.message, 'HTTP $status: Said by GitHub');
      });
    }

    test('a wrong token gets the 401 of the server', () async {
      final api = await client((_) => const GhAnswer({}), only: 'another');
      expect(
        (await failure(api.getJson('/x'))).failure,
        GithubFailure.unauthorized,
      );
    });

    test(
      'a redirect is not followed, and the token goes nowhere else',
      () async {
        var elsewhere = 0;
        final other = await FakeGithub.start((_) {
          elsewhere++;
          return const GhAnswer({});
        });
        addTearDown(other.close);
        final api = await client(
          (_) => GhAnswer(
            null,
            status: 301,
            headers: {'location': '${other.uri}/moved'},
          ),
        );
        final e = await failure(api.getJson('/repos/o/r'));
        expect(e.failure, GithubFailure.refused);
        expect(e.message, 'HTTP 301, a redirect, which is not followed');
        expect(elsewhere, 0);
        expect(other.requests, isEmpty);
      },
    );

    test('5xx is tried again, and then succeeds or is unavailable', () async {
      var calls = 0;
      final api = await client(
        (_) => ++calls < 3
            ? GhAnswer.error(502, 'Bad gateway')
            : const GhAnswer({'ok': 1}),
      );
      expect(await api.getJson('/x'), {'ok': 1});
      expect(calls, 3);
      expect(slept, hasLength(2));
      final down = await client((_) => GhAnswer.error(503, 'Down'));
      final e = await failure(down.getJson('/x'));
      expect(e.failure, GithubFailure.unavailable);
      expect(github!.requests, hasLength(3));
    });

    test('no server at all is offline, after the retries', () async {
      final api = await client((_) => const GhAnswer({}));
      await github!.close();
      final e = await failure(api.getJson('/x'));
      expect(e.failure, GithubFailure.offline);
      expect(slept, hasLength(2));
    });

    test('no answer within the timeout is offline too', () async {
      final api = await client(
        (_) => Future.delayed(
          const Duration(seconds: 5),
          () => const GhAnswer({}),
        ),
      );
      final short = HttpGithubClient(
        api: github!.uri,
        token: token,
        timeout: const Duration(milliseconds: 100),
        retryDelays: const [],
      );
      final e = await failure(short.getJson('/x'));
      expect(e.failure, GithubFailure.offline);
      expect(e.message, 'no answer within 100 ms');
      expect(api, isNotNull);
    });
  });

  group('a rate limit', () {
    test('that clears soon is waited out, by retry-after', () async {
      var calls = 0;
      final api = await client(
        (_) => ++calls == 1
            ? GhAnswer.error(
                429,
                'Too many requests',
                headers: {'retry-after': '7'},
              )
            : const GhAnswer({'ok': 1}),
      );
      expect(await api.getJson('/x'), {'ok': 1});
      expect(slept, [const Duration(seconds: 7)]);
      expect(logged.first, contains('rate limited: waiting 7 s'));
    });

    test('a 403 with no calls left waits until x-ratelimit-reset', () async {
      var calls = 0;
      final reset =
          DateTime.utc(2026, 11, 15, 12, 0, 30).millisecondsSinceEpoch ~/ 1000;
      final api = await client(
        (_) => ++calls == 1
            ? GhAnswer.error(
                403,
                'API rate limit exceeded',
                headers: {
                  'x-ratelimit-remaining': '0',
                  'x-ratelimit-reset': '$reset',
                },
              )
            : const GhAnswer({'ok': 1}),
      );
      expect(await api.getJson('/x'), {'ok': 1});
      expect(slept, [const Duration(seconds: 31)]);
    });

    test(
      'a secondary limit of a 403 that says so is a rate limit, not a refusal',
      () async {
        final api = await client(
          (_) => GhAnswer.error(
            403,
            'You have exceeded a secondary rate limit.',
            headers: {'retry-after': '600'},
          ),
        );
        final e = await failure(api.getJson('/x'));
        expect(e.failure, GithubFailure.rateLimited);
        expect(e.retryAfter, const Duration(minutes: 10));
        expect(
          slept,
          isEmpty,
          reason: 'ten minutes is longer than winCode waits',
        );
        expect(github!.requests, hasLength(1));
      },
    );

    test('that does not clear after two waits fails', () async {
      final api = await client(
        (_) => GhAnswer.error(429, 'Too many', headers: {'retry-after': '1'}),
      );
      final e = await failure(api.getJson('/x'));
      expect(e.failure, GithubFailure.rateLimited);
      expect(github!.requests, hasLength(3));
      expect(slept, hasLength(2));
    });

    test('a plain 403 is forbidden', () async {
      final api = await client(
        (_) => GhAnswer.error(
          403,
          'Resource not accessible by personal access token',
        ),
      );
      expect(
        (await failure(api.getJson('/x'))).failure,
        GithubFailure.forbidden,
      );
    });
  });

  group('githubProblem', () {
    test('names the stable ids and exit codes', () {
      WincodeException problem(GithubFailure f, {Duration? retry}) =>
          githubProblem(
            GithubException(f, 'GET /repos/o/r', 'HTTP 000', retryAfter: retry),
            what: 'read o/r',
          );
      expect(
        {
          for (final f in GithubFailure.values)
            f: (
              problem(f, retry: const Duration(minutes: 3)).id,
              problem(f).exitCode.code,
            ),
        },
        {
          GithubFailure.unauthorized: ('github-unauthorized', 77),
          GithubFailure.forbidden: ('github-forbidden', 77),
          GithubFailure.notFound: ('github-error', 1),
          GithubFailure.unprocessable: ('github-error', 1),
          GithubFailure.rateLimited: ('github-rate-limited', 69),
          GithubFailure.offline: ('offline', 69),
          GithubFailure.unavailable: ('github-unavailable', 69),
          GithubFailure.refused: ('github-error', 1),
        },
      );
      for (final f in GithubFailure.values) {
        final p = problem(f, retry: const Duration(minutes: 3));
        expect([p.why, p.next], everyElement(isNotEmpty));
        expect(p.next, contains('Nothing was started'));
      }
    });
  });

  group('findGithubToken', () {
    late Redactor redactor;
    setUp(() => redactor = Redactor(active: false));

    WincodeConfig app({String? name}) => WincodeConfig(
      file: File('wincode.yaml'),
      name: name,
      bundleId: 'com.example.alpha',
      teamId: 'TEAM000001',
      output: Directory('out'),
      workflow: (
        repository: 'example-org/example-app',
        file: 'wincode-ios.yml',
        ref: 'main',
      ),
    );

    Future<ProcessResult> Function(
      String,
      List<String>, {
      String? workingDirectory,
    })
    gh(String? stdout, {int exitCode = 0, List<List<String>>? calls}) =>
        (exe, args, {workingDirectory}) async {
          calls?.add([exe, ...args]);
          if (stdout == null) {
            throw ProcessException(exe, args, 'not found', 2);
          }
          return ProcessResult(1, exitCode, stdout, '');
        };

    Future<GithubToken> find(
      Map<String, String> environment, {
      String? name,
      Future<ProcessResult> Function(
        String,
        List<String>, {
        String? workingDirectory,
      })?
      run,
    }) => findGithubToken(
      app(name: name),
      environment: environment,
      redactor: redactor,
      run: run ?? gh(null),
    );

    test('the variable of the app comes first, then GH_TOKEN, then GITHUB_TOKEN, then gh', () async {
      const a = 'ghp_APPAPPAPPAPPAPPAPPAPPAPPAPPAPPAPP';
      const b = 'ghp_GHGHGHGHGHGHGHGHGHGHGHGHGHGHGHGHGH';
      const c = 'ghp_ACTIONSACTIONSACTIONSACTIONSACTIONS';
      const d = 'gho_FROMGHFROMGHFROMGHFROMGHFROMGHFROMGH';
      final all = {
        'WINCODE_GH_TOKEN_ALPHA_DEV': a,
        'GH_TOKEN': b,
        'GITHUB_TOKEN': c,
      };
      expect((await find(all, name: 'alpha-dev')).value, a);
      expect(
        (await find(all, name: 'alpha')).value,
        b,
        reason: 'the variable of another app',
      );
      expect(
        (await find(all)).value,
        b,
        reason: 'a flat file has no app variable',
      );
      expect((await find({'GITHUB_TOKEN': c})).value, c);
      final calls = <List<String>>[];
      final fromGh = await find({}, run: gh('$d\n', calls: calls));
      expect((fromGh.value, fromGh.source), (d, ghLoginSource));
      expect(calls.single, ['gh', 'auth', 'token', '--hostname', 'github.com']);
      expect(calls, hasLength(1));
    });

    test('gh is not asked when a variable gives a token', () async {
      final calls = <List<String>>[];
      await find({'GH_TOKEN': token}, run: gh('x', calls: calls));
      expect(calls, isEmpty);
    });

    test('an empty variable is not set', () async {
      final found = await find({'GH_TOKEN': '  ', 'GITHUB_TOKEN': token});
      expect(found.source, 'GITHUB_TOKEN');
    });

    test('registers the token with the redactor', () async {
      final found = await find({'GH_TOKEN': token});
      expect(redactor.apply('sent $token'), 'sent <GitHub token>');
      expect(found.kind, 'a fine-grained token');
      expect(found.broad, isFalse);
    });

    test('says what kind of token it is', () {
      expect(const GithubToken('ghp_x', 'GH_TOKEN').kind, 'a classic token');
      expect(const GithubToken('ghp_x', 'GH_TOKEN').broad, isTrue);
      expect(const GithubToken('gho_x', 'GH_TOKEN').kind, 'an OAuth token');
      expect(
        const GithubToken('ghs_x', 'GH_TOKEN').kind,
        'an installation token',
      );
      expect(const GithubToken('ghu_x', 'GH_TOKEN').kind, 'a user token');
      expect(
        const GithubToken('abc', 'GH_TOKEN').kind,
        'a token of an unknown kind',
      );
      expect(const GithubToken('github_pat_x', ghLoginSource).broad, isTrue);
    });

    test('a value that cannot be a token is refused, and not shown', () async {
      for (final bad in [
        'short',
        'has space in it 0123456789',
        'new\nline0123456789012345',
        '"$token"',
      ]) {
        try {
          await find({'GH_TOKEN': bad});
          fail('accepted $bad');
        } on WincodeException catch (e) {
          expect(e.id, 'github-token-invalid');
          expect(e.exitCode, ExitCode.config);
          expect(e.toJson().values.join(), isNot(contains(bad.trim())));
        }
      }
    });

    test('no token anywhere is github-token-missing (77), and the message says why gh gave none', () async {
      WincodeException? missing;
      Future<void> run(Future<GithubToken> Function() f) async {
        try {
          await f();
        } on WincodeException catch (e) {
          missing = e;
        }
      }

      await run(() => find({}, name: 'alpha'));
      expect(missing!.id, 'github-token-missing');
      expect(missing!.exitCode.code, 77);
      expect(
        missing!.what,
        'no GitHub token: WINCODE_GH_TOKEN_ALPHA, GH_TOKEN and GITHUB_TOKEN are not set, and gh is not installed',
      );
      expect(missing!.next, contains('limited to example-org/example-app'));
      expect(
        missing!.next,
        contains('(WINCODE_GH_TOKEN_ALPHA for this app only)'),
      );
      expect(missing!.next, contains('or install gh and run gh auth login.'));

      await run(() => find({}, run: gh('', exitCode: 1)));
      expect(
        missing!.what,
        'no GitHub token: GH_TOKEN and GITHUB_TOKEN are not set, and gh is installed but not logged in to github.com',
      );
      expect(missing!.next, isNot(contains('install gh')));
      expect(missing!.next, isNot(contains('this app only')));
    });
  });

  test('githubTokenVariable writes the name in capitals with _ for -', () {
    expect(githubTokenVariable('alpha-dev'), 'WINCODE_GH_TOKEN_ALPHA_DEV');
    expect(githubTokenVariable(null), isNull);
  });
}
