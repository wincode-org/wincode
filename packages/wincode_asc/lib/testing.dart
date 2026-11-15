/// Test support for winCode's packages: a throwaway API key, and a fake App Store Connect on 127.0.0.1 that answers
/// in the shapes of Apple's API with made-up IDs. Not for use outside tests.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

final _curve = ECCurve_secp256r1();

/// A P-256 key made for one test. [pem] is its `.p8`, as App Store Connect delivers one.
class ThrowawayKey {
  /// A new random key.
  factory ThrowawayKey() {
    final random = Random.secure();
    BigInt d;
    do {
      d = List.generate(
        32,
        (_) => random.nextInt(256),
      ).fold(BigInt.zero, (n, b) => n << 8 | BigInt.from(b));
    } while (d == BigInt.zero || d >= _curve.n);
    return ThrowawayKey.of(d);
  }

  /// The key whose private scalar is [d], such as the one of a published test vector.
  ThrowawayKey.of(this.d);

  final BigInt d;

  /// The public key, uncompressed: 0x04, then X and Y.
  Uint8List get publicKey => (_curve.G * d)!.getEncoded(false);

  /// The PKCS #8 DER of the key: version 0, id-ecPublicKey with prime256v1, and the ECPrivateKey, which carries the
  /// public key too when [withPublicKey], as Apple's `.p8` files do.
  Uint8List der({bool withPublicKey = true}) {
    final ecKey = [
      0x02, 0x01, 0x01, // version 1
      0x04, 0x20, ..._bytes32(d),
      if (withPublicKey) ...[0xA1, 0x44, 0x03, 0x42, 0x00, ...publicKey],
    ];
    final body = [
      0x02, 0x01, 0x00, // version 0
      0x30, 0x13, //
      0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
      0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
      0x04, ecKey.length + 2, 0x30, ecKey.length, ...ecKey,
    ];
    return Uint8List.fromList([
      0x30,
      if (body.length > 0x7F) 0x81,
      body.length,
      ...body,
    ]);
  }

  /// [der] in PEM, with lines of 64 characters and Windows line ends, under [label].
  String pem({bool withPublicKey = true, String label = 'PRIVATE KEY'}) {
    final text = base64.encode(der(withPublicKey: withPublicKey));
    final lines = [
      for (var i = 0; i < text.length; i += 64)
        text.substring(i, min(i + 64, text.length)),
    ];
    return [
      '-----BEGIN $label-----',
      ...lines,
      '-----END $label-----',
      '',
    ].join('\r\n');
  }

  /// Whether [signature] (R and S, 32 bytes each) is this key's ES256 signature of [message].
  bool verifies(List<int> message, List<int> signature) {
    if (signature.length != 64) {
      return false;
    }
    BigInt number(List<int> bytes) =>
        bytes.fold(BigInt.zero, (n, b) => n << 8 | BigInt.from(b));
    final verifier = ECDSASigner(SHA256Digest())
      ..init(
        false,
        PublicKeyParameter<ECPublicKey>(ECPublicKey(_curve.G * d, _curve)),
      );
    return verifier.verifySignature(
      Uint8List.fromList(message),
      ECSignature(
        number(signature.sublist(0, 32)),
        number(signature.sublist(32)),
      ),
    );
  }

  /// Whether [token] is a JWT of this key, valid at [now], with the claims Apple wants.
  bool signed(String token, DateTime now) {
    final parts = token.split('.');
    if (parts.length != 3) {
      return false;
    }
    Object? json(String part) =>
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(part))));
    final claims = json(parts[1]);
    final seconds = now.millisecondsSinceEpoch ~/ 1000;
    return claims is Map<String, Object?> &&
        (json(parts[0]) as Map<String, Object?>)['alg'] == 'ES256' &&
        claims['aud'] == 'appstoreconnect-v1' &&
        (claims['iat']! as int) <= seconds &&
        seconds < (claims['exp']! as int) &&
        (claims['exp']! as int) - (claims['iat']! as int) <= 20 * 60 &&
        verifies(
          utf8.encode('${parts[0]}.${parts[1]}'),
          base64Url.decode(base64Url.normalize(parts[2])),
        );
  }
}

List<int> _bytes32(BigInt value) => [
  for (var i = 31; i >= 0; i--) (value >> (8 * i)).toUnsigned(8).toInt(),
];

/// A request that [FakeAppStoreConnect] received.
class FakeRequest {
  const FakeRequest({
    required this.method,
    required this.path,
    required this.query,
    required this.authorization,
    this.headers = const {},
    this.body = const [],
  });

  final String method;
  final String path;
  final Map<String, String> query;
  final String? authorization;

  /// Every header, by its lower-case name.
  final Map<String, String> headers;

  /// The body as it was sent.
  final List<int> body;

  /// The body as text, such as the JSON of a write.
  String get text => utf8.decode(body, allowMalformed: true);

  /// The body as the JSON object that a write sends.
  Map<String, Object?> get json => jsonDecode(text) as Map<String, Object?>;
}

/// What [FakeAppStoreConnect] answers to one request.
class FakeAnswer {
  /// [json] with [status], after [delay].
  const FakeAnswer(
    this.json, {
    this.status = 200,
    this.delay = Duration.zero,
    this.location,
    this.raw,
  });

  /// [text] with [status], as it is: what the upload store answers, which is not Apple's JSON.
  const FakeAnswer.raw(String text, {int status = 200})
    : this(null, status: status, raw: text);

  /// Apple's error answer: one error with [status], [code], a title and a detail.
  FakeAnswer.error(int status, String code)
    : this({
        'errors': [
          {
            'id': '00000000-0000-0000-0000-000000000000',
            'status': '$status',
            'code': code,
            'title': 'The request was refused: $code',
            'detail': 'A made-up detail for $code.',
          },
        ],
      }, status: status);

  /// A page of [resources], with a link to the [next] page when there is one.
  FakeAnswer.page(List<Map<String, Object?>> resources, {String? next})
    : this({
        'data': resources,
        'links': {'self': 'https://example.invalid/self', 'next': ?next},
        'meta': {
          'paging': {'total': resources.length, 'limit': 200},
        },
      });

  final Object? json;
  final int status;
  final Duration delay;

  /// The `Location` header of a redirect.
  final String? location;

  /// The body as text, instead of [json].
  final String? raw;
}

/// A resource as App Store Connect sends one.
Map<String, Object?> fakeResource(
  String type,
  String id,
  Map<String, Object?> attributes,
) => {
  'type': type,
  'id': id,
  'attributes': attributes,
  'links': {'self': 'https://example.invalid/v1/$type/$id'},
};

/// App Store Connect on 127.0.0.1, for tests: [answer] decides what each request gets, and [requests] records them.
///
/// With [key], a request whose `Authorization` header does not carry a token of that key, valid at [now], gets HTTP
/// 401 NOT_AUTHORIZED, as from Apple.
class FakeAppStoreConnect {
  FakeAppStoreConnect._(this._server, this.answer, this.key, this.now) {
    _server.listen(_handle);
  }

  /// Starts the server on a free port.
  static Future<FakeAppStoreConnect> start(
    FutureOr<FakeAnswer> Function(FakeRequest request) answer, {
    ThrowawayKey? key,
    DateTime Function()? now,
  }) async => FakeAppStoreConnect._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    answer,
    key,
    now ?? DateTime.now,
  );

  final HttpServer _server;
  final FutureOr<FakeAnswer> Function(FakeRequest request) answer;
  final ThrowawayKey? key;
  final DateTime Function() now;
  final requests = <FakeRequest>[];

  /// The base URL of the API, such as `http://127.0.0.1:1234`.
  Uri get uri => Uri.http('${_server.address.address}:${_server.port}');

  Future<void> _handle(HttpRequest request) async {
    final authorization = request.headers.value(
      HttpHeaders.authorizationHeader,
    );
    final headers = <String, String>{};
    request.headers.forEach(
      (name, values) => headers[name] = values.join(', '),
    );
    final received = FakeRequest(
      method: request.method,
      path: request.uri.path,
      query: request.uri.queryParameters,
      authorization: authorization,
      headers: headers,
      body: await request.fold<List<int>>(
        [],
        (all, chunk) => all..addAll(chunk),
      ),
    );
    requests.add(received);
    final token = authorization?.startsWith('Bearer ') ?? false
        ? authorization!.substring(7)
        : '';
    final answer = key != null && !key!.signed(token, now())
        ? FakeAnswer.error(401, 'NOT_AUTHORIZED')
        : await this.answer(received);
    await Future<void>.delayed(answer.delay);
    try {
      request.response.statusCode = answer.status;
      if (answer.location != null) {
        request.response.headers.set(
          HttpHeaders.locationHeader,
          answer.location!,
        );
      }
      request.response.headers.contentType = answer.raw == null
          ? ContentType.json
          : ContentType.text;
      request.response.write(answer.raw ?? jsonEncode(answer.json));
      await request.response.close();
    } on Object {
      // The client gave up waiting.
    }
  }

  Future<void> close() => _server.close(force: true);
}
