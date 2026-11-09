import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_asc/testing.dart';
import 'package:wincode_asc/wincode_asc.dart';

const _short = Duration(milliseconds: 1);

void main() {
  late FakeAppStoreConnect apple;
  late List<String> log;
  var tokens = 0;

  Future<HttpAscClient> client(
    FutureOr<FakeAnswer> Function(FakeRequest request) answer, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    apple = await FakeAppStoreConnect.start(answer);
    return HttpAscClient(
      api: apple.uri,
      token: () => 'token-${++tokens}',
      timeout: timeout,
      retryDelays: const [_short, _short],
      log: log.add,
    );
  }

  setUp(() {
    log = [];
    tokens = 0;
  });
  tearDown(() => apple.close());

  test(
    'follows links.next, sends GET only, a new token each time, and the query',
    () async {
      final asc = await client(
        (r) => r.query['cursor'] == null
            ? FakeAnswer.page([
                fakeResource('apps', '1', {'bundleId': 'com.example.app'}),
              ], next: '${apple.uri}/v1/apps?cursor=2&limit=200')
            : FakeAnswer.page([
                fakeResource('apps', '2', {'bundleId': 'com.example.app.beta'}),
              ]),
      );
      final apps = await asc.getAll('/v1/apps', {
        'filter[bundleId]': 'com.example.app',
        'limit': '200',
      });
      expect([for (final a in apps) a['id']], ['1', '2']);
      expect([for (final r in apple.requests) r.method], ['GET', 'GET']);
      expect(
        [for (final r in apple.requests) r.authorization],
        ['Bearer token-1', 'Bearer token-2'],
      );
      expect(apple.requests.first.query, {
        'filter[bundleId]': 'com.example.app',
        'limit': '200',
      });
      expect(log, [
        matches(
          r'^GET 127\.0\.0\.1/v1/apps\?filter\[bundleId\]=com\.example\.app&limit=200: HTTP 200, \d+ ms$',
        ),
        matches(
          r'^GET 127\.0\.0\.1/v1/apps\?cursor=2&limit=200: HTTP 200, \d+ ms$',
        ),
      ]);
    },
  );

  for (final (status, failure) in [
    (401, AscFailure.unauthorized),
    (403, AscFailure.forbidden),
    (404, AscFailure.refused),
  ]) {
    test(
      'HTTP $status is $failure, with Apple\'s errors, and not tried again',
      () async {
        final asc = await client(
          (_) => FakeAnswer.error(status, 'CODE_$status'),
        );
        await expectLater(
          asc.getAll('/v1/apps', {}),
          throwsA(
            isA<AscException>()
                .having((e) => e.failure, 'failure', failure)
                .having((e) => e.request, 'request', 'GET /v1/apps')
                .having((e) => e.message, 'message', 'HTTP $status')
                .having((e) => e.errors, 'errors', [
                  {
                    'status': '$status',
                    'code': 'CODE_$status',
                    'title': 'The request was refused: CODE_$status',
                    'detail': 'A made-up detail for CODE_$status.',
                  },
                ]),
          ),
        );
        expect(apple.requests, hasLength(1));
      },
    );
  }

  test('HTTP 5xx is tried twice more, and then is unavailable', () async {
    var calls = 0;
    final asc = await client(
      (_) => ++calls < 3
          ? FakeAnswer.error(503, 'UNAVAILABLE')
          : FakeAnswer.page([]),
    );
    expect(await asc.getAll('/v1/apps', {}), isEmpty);
    expect(log, [
      contains('HTTP 503, '),
      contains('HTTP 503, '),
      contains('HTTP 200, '),
    ]);
    expect(log.first, endsWith('trying again in 0 s'));

    calls = -10;
    await expectLater(
      asc.getAll('/v1/apps', {}),
      throwsA(
        isA<AscException>().having(
          (e) => e.failure,
          'failure',
          AscFailure.unavailable,
        ),
      ),
    );
    expect(apple.requests, hasLength(6));
  });

  test(
    'no answer within the timeout is tried twice more, and then is offline',
    () async {
      final asc = await client(
        (_) => const FakeAnswer(null, delay: Duration(seconds: 2)),
        timeout: const Duration(milliseconds: 200),
      );
      await expectLater(
        asc.getAll('/v1/apps', {}),
        throwsA(
          isA<AscException>()
              .having((e) => e.failure, 'failure', AscFailure.offline)
              .having((e) => e.message, 'message', 'no answer within 200 ms'),
        ),
      );
      expect(apple.requests, hasLength(3));
    },
  );

  test('a refused connection is offline, with the system\'s message', () async {
    final asc = await client((_) => FakeAnswer.page([]));
    await apple.close();
    await expectLater(
      asc.getAll('/v1/apps', {}),
      throwsA(
        isA<AscException>()
            .having((e) => e.failure, 'failure', AscFailure.offline)
            .having((e) => e.message, 'message', isNotEmpty),
      ),
    );
    expect(log, hasLength(3));
  });

  test('a redirect is not followed, so the token goes nowhere else', () async {
    final elsewhere = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final reached = <String?>[];
    elsewhere.listen((r) {
      reached.add(r.headers.value(HttpHeaders.authorizationHeader));
      r.response.close();
    });
    final asc = await client(
      (_) => FakeAnswer(
        null,
        status: 302,
        location: 'http://127.0.0.1:${elsewhere.port}/',
      ),
    );
    await expectLater(
      asc.getAll('/v1/apps', {}),
      throwsA(
        isA<AscException>()
            .having((e) => e.failure, 'failure', AscFailure.refused)
            .having(
              (e) => e.message,
              'message',
              'HTTP 302, a redirect, which is not followed',
            ),
      ),
    );
    await elsewhere.close(force: true);
    expect(reached, isEmpty);
  });

  test(
    'a next page on another host is refused before it is asked for',
    () async {
      final asc = await client(
        (_) => FakeAnswer.page(
          [],
          next: 'https://example.invalid/v1/apps?cursor=2',
        ),
      );
      await expectLater(
        asc.getAll('/v1/apps', {}),
        throwsA(
          isA<AscException>()
              .having((e) => e.failure, 'failure', AscFailure.refused)
              .having(
                (e) => e.message,
                'message',
                contains('not on 127.0.0.1'),
              ),
        ),
      );
      expect(apple.requests, hasLength(1));
    },
  );

  test('an answer that is not Apple\'s JSON is refused', () async {
    final asc = await client((_) => const FakeAnswer({'unexpected': true}));
    await expectLater(
      asc.getAll('/v1/apps', {}),
      throwsA(
        isA<AscException>()
            .having((e) => e.failure, 'failure', AscFailure.refused)
            .having(
              (e) => e.message,
              'message',
              'the answer holds no list of resources',
            ),
      ),
    );
  });

  test('the log never holds the token', () async {
    final asc = await client((_) => FakeAnswer.error(401, 'NOT_AUTHORIZED'));
    await expectLater(asc.getAll('/v1/apps', {}), throwsA(isA<AscException>()));
    expect(log.join('\n'), isNot(contains('token-')));
    expect(log.join('\n'), isNot(contains('Bearer')));
  });
}
