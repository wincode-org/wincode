import 'dart:async';

import 'package:test/test.dart';
import 'package:wincode_asc/testing.dart';
import 'package:wincode_asc/wincode_asc.dart';

const _short = Duration(milliseconds: 1);

void main() {
  late FakeAppStoreConnect apple;
  late FakeAppStoreConnect store;
  late List<String> log;
  var tokens = 0;

  Future<HttpAscClient> client(
    FutureOr<FakeAnswer> Function(FakeRequest request) answer, {
    FutureOr<FakeAnswer> Function(FakeRequest request)? storeAnswer,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    apple = await FakeAppStoreConnect.start(answer);
    store = await FakeAppStoreConnect.start(
      storeAnswer ?? (_) => const FakeAnswer.raw(''),
    );
    return HttpAscClient(
      api: apple.uri,
      token: () => 'token-${++tokens}',
      timeout: timeout,
      writeTimeout: timeout,
      partTimeout: timeout,
      retryDelays: const [_short, _short],
      partRetryDelays: const [_short, _short, _short],
      log: log.add,
    );
  }

  AscUploadPart part({
    int number = 1,
    String path = '/part-1',
    Map<String, String> headers = const {
      'Content-Type': 'application/octet-stream',
    },
  }) => AscUploadPart(
    number: number,
    method: 'PUT',
    url: store.uri.replace(path: path, query: 'sig=SIGNEDVALUE'),
    offset: 0,
    length: 3,
    headers: headers,
  );

  setUp(() {
    log = [];
    tokens = 0;
  });
  tearDown(() async {
    await apple.close();
    await store.close();
  });

  group('getDocument', () {
    test('is Apple\'s JSON object, with its included resources, from one GET with the query', () async {
      final asc = await client(
        (r) => FakeAnswer({
          'data': fakeResource('buildUploads', 'U1', {}),
          'included': [
            fakeResource('builds', 'B1', {'processingState': 'VALID'}),
          ],
        }),
      );
      final document = await asc.getDocument('/v1/buildUploads/U1', {
        'include': 'build',
      });
      expect((document['data']! as Map)['id'], 'U1');
      expect(document['included'], hasLength(1));
      expect(apple.requests.single.method, 'GET');
      expect(apple.requests.single.query, {'include': 'build'});
      expect(apple.requests.single.authorization, 'Bearer token-1');
    });

    test(
      'is tried again after a 5xx, like a list, and not after a 4xx',
      () async {
        var asked = 0;
        final asc = await client(
          (r) => ++asked < 3
              ? FakeAnswer.error(503, 'UNAVAILABLE')
              : FakeAnswer({'data': <String, Object?>{}}),
        );
        await asc.getDocument('/v1/buildUploads/U1', {});
        expect(asked, 3);
        await apple.close();
        final refused = await client((r) => FakeAnswer.error(404, 'NOT_FOUND'));
        await expectLater(
          refused.getDocument('/v1/buildUploads/U1', {}),
          throwsA(
            isA<AscException>().having(
              (e) => e.failure,
              'failure',
              AscFailure.refused,
            ),
          ),
        );
        expect(apple.requests, hasLength(1));
      },
    );

    test('an answer that is not an object is refused', () async {
      final asc = await client((r) => const FakeAnswer(<Object?>[]));
      await expectLater(
        asc.getDocument('/v1/buildUploads/U1', {}),
        throwsA(
          isA<AscException>().having(
            (e) => e.message,
            'message',
            'the answer is not a JSON object',
          ),
        ),
      );
    });
  });

  group('write', () {
    test(
      'POSTs and PATCHes JSON with a token, and returns Apple\'s answer',
      () async {
        final asc = await client(
          (r) => FakeAnswer({
            'data': {'id': r.method},
          }, status: r.method == 'POST' ? 201 : 200),
        );
        final created = await asc.write('POST', '/v1/buildUploads', {
          'data': {'type': 'buildUploads'},
        });
        final patched = await asc.write('PATCH', '/v1/buildUploadFiles/F1', {
          'data': {'uploaded': true},
        });
        expect((created['data']! as Map)['id'], 'POST');
        expect((patched['data']! as Map)['id'], 'PATCH');
        expect(
          [for (final r in apple.requests) '${r.method} ${r.path}'],
          ['POST /v1/buildUploads', 'PATCH /v1/buildUploadFiles/F1'],
        );
        expect(apple.requests.first.json, {
          'data': {'type': 'buildUploads'},
        });
        expect(
          apple.requests.first.headers['content-type'],
          startsWith('application/json'),
        );
        expect(apple.requests.first.authorization, 'Bearer token-1');
        expect(apple.requests.last.authorization, 'Bearer token-2');
      },
    );

    test(
      'is never tried again: not after a 5xx, not after no answer',
      () async {
        final asc = await client((r) => FakeAnswer.error(503, 'UNAVAILABLE'));
        await expectLater(
          asc.write('POST', '/v1/buildUploads', {}),
          throwsA(
            isA<AscException>().having(
              (e) => e.failure,
              'failure',
              AscFailure.unavailable,
            ),
          ),
        );
        expect(apple.requests, hasLength(1));
        await apple.close();
        final slow = await client(
          (r) => const FakeAnswer(
            <String, Object?>{},
            delay: Duration(seconds: 1),
          ),
          timeout: const Duration(milliseconds: 100),
        );
        await expectLater(
          slow.write('POST', '/v1/buildUploads', {}),
          throwsA(
            isA<AscException>().having(
              (e) => e.failure,
              'failure',
              AscFailure.offline,
            ),
          ),
        );
        expect(apple.requests, hasLength(1));
        expect(log.where((l) => l.contains('trying again')), isEmpty);
      },
    );

    test(
      'a 4xx carries Apple\'s own words, and 401 and 403 are told apart',
      () async {
        final asc = await client((r) => FakeAnswer.error(409, 'DUPLICATE'));
        await expectLater(
          asc.write('POST', '/v1/buildUploads', {}),
          throwsA(
            isA<AscException>()
                .having((e) => e.failure, 'failure', AscFailure.refused)
                .having((e) => e.errors.single['code'], 'code', 'DUPLICATE'),
          ),
        );
        await apple.close();
        final forbidden = await client(
          (r) => FakeAnswer.error(403, 'FORBIDDEN'),
        );
        await expectLater(
          forbidden.write('POST', '/v1/buildUploads', {}),
          throwsA(
            isA<AscException>().having(
              (e) => e.failure,
              'failure',
              AscFailure.forbidden,
            ),
          ),
        );
      },
    );

    test(
      'the log names the request, and never the token or the body',
      () async {
        final asc = await client(
          (r) =>
              const FakeAnswer(<String, Object?>{'data': <String, Object?>{}}),
        );
        await asc.write('POST', '/v1/buildUploads', {
          'data': {'secret-ish': 'BODYVALUE'},
        });
        expect(
          log.single,
          startsWith('POST 127.0.0.1/v1/buildUploads: HTTP 200'),
        );
        expect(log.join(), isNot(contains('token-1')));
        expect(log.join(), isNot(contains('BODYVALUE')));
      },
    );
  });

  group('sendPart', () {
    test(
      'sends the bytes with Apple\'s headers and without the token',
      () async {
        final asc = await client((r) => FakeAnswer.error(500, 'NOPE'));
        await asc.sendPart(
          part(
            headers: const {
              'Content-Type': 'application/octet-stream',
              'x-grant': 'GRANT',
            },
          ),
          [1, 2, 3],
        );
        final sent = store.requests.single;
        expect(sent.method, 'PUT');
        expect(sent.body, [1, 2, 3]);
        expect(sent.authorization, isNull);
        expect(sent.headers['content-type'], 'application/octet-stream');
        expect(sent.headers['x-grant'], 'GRANT');
        expect(sent.query, {'sig': 'SIGNEDVALUE'});
        expect(apple.requests, isEmpty);
        expect(tokens, 0, reason: 'a token was made for a part');
      },
    );

    test('is tried again after a 5xx, a 429 and no answer, within the delays, and then stops', () async {
      final answers = [
        const FakeAnswer.raw('', status: 503),
        const FakeAnswer.raw('', status: 429),
        const FakeAnswer.raw('', status: 500),
      ];
      final asc = await client(
        (r) => FakeAnswer.error(500, 'NOPE'),
        storeAnswer: (r) =>
            answers.isEmpty ? const FakeAnswer.raw('') : answers.removeAt(0),
      );
      await asc.sendPart(part(), [1, 2, 3]);
      expect(store.requests, hasLength(4));
      expect(log.where((l) => l.contains('trying again')), hasLength(3));
      await store.close();
      // Four tries are all there are: the first and three delays.
      final always = await client(
        (r) => FakeAnswer.error(500, 'NOPE'),
        storeAnswer: (r) => const FakeAnswer.raw('', status: 503),
      );
      await expectLater(
        always.sendPart(part(), [1, 2, 3]),
        throwsA(
          isA<AscException>().having(
            (e) => e.failure,
            'failure',
            AscFailure.unavailable,
          ),
        ),
      );
      expect(store.requests, hasLength(4));
    });

    test('a 4xx is not tried again, and only the code and message of the store\'s error are kept', () async {
      final asc = await client(
        (r) => FakeAnswer.error(500, 'NOPE'),
        storeAnswer: (r) => FakeAnswer.raw(
          '<Error><Code>AccessDenied</Code><Message>Expired at ${store.uri}/part-1?sig=SIGNEDVALUE</Message>'
          '<SignatureProvided>SIGNEDVALUE</SignatureProvided></Error>',
          status: 403,
        ),
      );
      try {
        await asc.sendPart(part(), [1, 2, 3]);
        fail('a refused part did not throw');
      } on AscException catch (e) {
        expect(e.failure, AscFailure.refused);
        expect(e.request, 'PUT part 1');
        expect(e.errors.single['code'], 'AccessDenied');
        expect(e.errors.single['detail'], 'Expired at <URL>');
        final shown = '$e ${e.message} ${e.errors} ${log.join()}';
        expect(shown, isNot(contains('SIGNEDVALUE')));
        expect(shown, isNot(contains(store.uri.toString())));
      }
      expect(store.requests, hasLength(1));
    });

    test('a redirect is not followed', () async {
      final asc = await client(
        (r) => FakeAnswer.error(500, 'NOPE'),
        storeAnswer: (r) => const FakeAnswer.raw('', status: 307),
      );
      await expectLater(
        asc.sendPart(part(), [1, 2, 3]),
        throwsA(
          isA<AscException>().having(
            (e) => e.message,
            'message',
            contains('a redirect, which is not followed'),
          ),
        ),
      );
      expect(store.requests, hasLength(1));
    });

    test('a link on another scheme than the API is refused before anything is sent', () async {
      final asc = await client((r) => FakeAnswer.error(500, 'NOPE'));
      final elsewhere = AscUploadPart(
        number: 2,
        method: 'PUT',
        url: Uri.https('upload.example.invalid', '/x', {'sig': 'SIGNEDVALUE'}),
        offset: 0,
        length: 1,
      );
      await expectLater(
        asc.sendPart(elsewhere, [1]),
        throwsA(
          isA<AscException>().having(
            (e) => '$e',
            'text',
            isNot(contains('SIGNEDVALUE')),
          ),
        ),
      );
      expect(store.requests, isEmpty);
    });

    test('a connection that is lost is an offline failure whose text holds no link', () async {
      final asc = await client((r) => FakeAnswer.error(500, 'NOPE'));
      final lost = part();
      await store.close();
      try {
        await asc.sendPart(lost, [1, 2, 3]);
        fail('a lost connection did not throw');
      } on AscException catch (e) {
        expect(e.failure, AscFailure.offline);
        expect('$e ${log.join()}', isNot(contains('SIGNEDVALUE')));
        expect('$e ${log.join()}', isNot(contains('/part-1')));
      }
    });
  });

  group('uploadPartsOf', () {
    Map<String, Object?> file(Object? operations) => fakeResource(
      'buildUploadFiles',
      'F1',
      {'uploadOperations': operations},
    );

    test('reads each operation: part, method, link, range and headers', () {
      final parts = uploadPartsOf(
        file([
          {
            'method': 'PUT',
            'url': 'https://upload.example.invalid/a?sig=1',
            'partNumber': 2,
            'offset': 10,
            'length': 5,
            'requestHeaders': [
              {'name': 'Content-Type', 'value': 'application/octet-stream'},
              {'name': 'x-grant', 'value': 'G'},
            ],
          },
          {
            'method': 'PUT',
            'url': 'https://upload.example.invalid/b',
            'offset': 0,
            'length': 10,
          },
        ]),
      );
      expect(parts, hasLength(2));
      expect(parts[0].number, 2);
      expect(parts[0].url.host, 'upload.example.invalid');
      expect((parts[0].offset, parts[0].length), (10, 5));
      expect(parts[0].headers, {
        'Content-Type': 'application/octet-stream',
        'x-grant': 'G',
      });
      // As the spike's script reads one: a part without a number is the first, and no headers are none.
      expect(parts[1].number, 1);
      expect(parts[1].headers, isEmpty);
    });

    test(
      'no operations are none, and an entry that cannot be sent is refused',
      () {
        expect(uploadPartsOf(file(null)), isEmpty);
        expect(uploadPartsOf(file(<Object?>[])), isEmpty);
        for (final bad in <Object?>[
          'x',
          [1],
          [
            <String, Object?>{
              'url': 'https://x.example.invalid/',
              'offset': 0,
              'length': 1,
            },
          ],
          [
            <String, Object?>{
              'method': 'PUT',
              'url': 'nope',
              'offset': 0,
              'length': 1,
            },
          ],
          [
            <String, Object?>{
              'method': 'PUT',
              'url': 'https://x.example.invalid/',
              'offset': -1,
              'length': 1,
            },
          ],
          [
            <String, Object?>{
              'method': 'PUT',
              'url': 'https://x.example.invalid/',
              'offset': 0,
            },
          ],
          [
            <String, Object?>{
              'method': 'PUT',
              'url': 'https://x.example.invalid/',
              'offset': 0,
              'length': 1,
              'requestHeaders': [
                <String, Object?>{'name': 'a'},
              ],
            },
          ],
        ]) {
          expect(
            () => uploadPartsOf(file(bad)),
            throwsA(isA<AscException>()),
            reason: '$bad',
          );
        }
      },
    );
  });
}
