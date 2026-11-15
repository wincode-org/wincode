import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One resource of an App Store Connect answer, with `type`, `id` and `attributes`, as Apple sends it.
typedef AscResource = Map<String, Object?>;

/// The requests that winCode sends to App Store Connect.
abstract interface class AscClient {
  /// Every resource of the collection at [path], such as `/v1/apps`, with [query], page after page.
  Future<List<AscResource>> getAll(String path, Map<String, String> query);

  /// The answer to GET [path] with [query], as Apple's JSON object with its `data` and `included`. Tried again like
  /// [getAll].
  Future<Map<String, Object?>> getDocument(
    String path,
    Map<String, String> query,
  );

  /// POST or PATCH [body] (the JSON object of Apple's request) to [path], and Apple's answer. **Never tried again**: a
  /// repeated request could make a second resource, and a request that got no answer may have been done.
  Future<Map<String, Object?>> write(
    String method,
    String path,
    Map<String, Object?> body,
  );

  /// Sends [bytes], which are [part] of the file, to the upload store that Apple named, without the token. Tried again
  /// after a failure that a repeat can mend, since a part sent twice lands in the same place.
  Future<void> sendPart(AscUploadPart part, List<int> bytes);
}

/// One part of a file that Apple wants sent to its upload store, as an entry of `uploadOperations` of a build upload
/// file.
class AscUploadPart {
  const AscUploadPart({
    required this.number,
    required this.method,
    required this.url,
    required this.offset,
    required this.length,
    this.headers = const {},
  });

  final int number;
  final String method;

  /// A signed, temporary link. It is a secret: it is never printed.
  final Uri url;

  /// Where the part starts in the file, and how many bytes it holds.
  final int offset;
  final int length;

  /// The headers that Apple wants on the request, which can be signed too.
  final Map<String, String> headers;
}

/// The parts that the build upload file [resource] lists in its `uploadOperations`, as Apple's answer to POST
/// `/v1/buildUploadFiles` gives it. A part without a `partNumber` is the first, as the spike's script reads it. Throws
/// an [AscException] when an entry is not one that can be sent.
List<AscUploadPart> uploadPartsOf(AscResource resource) {
  AscException wrong(String what) => AscException(
    AscFailure.refused,
    'POST /v1/buildUploadFiles',
    "Apple's answer lists an upload operation $what",
  );
  final attributes = resource['attributes'];
  final operations = attributes is Map<String, Object?>
      ? attributes['uploadOperations']
      : null;
  if (operations == null) {
    return const [];
  }
  if (operations is! List<Object?>) {
    throw wrong('that is not a list');
  }
  Map<String, String> headersOf(Object? headers) {
    if (headers == null) {
      return const {};
    }
    if (headers is! List<Object?>) {
      throw wrong('with request headers that are not a list');
    }
    final found = <String, String>{};
    for (final h in headers) {
      if (h is! Map<String, Object?> ||
          h['name'] is! String ||
          h['value'] is! String) {
        throw wrong('with a header that is not a name and a value');
      }
      found[h['name']! as String] = h['value']! as String;
    }
    return found;
  }

  return [
    for (final operation in operations)
      if (operation is! Map<String, Object?>)
        throw wrong('that is not an object')
      else
        AscUploadPart(
          number: switch (operation['partNumber']) {
            final int n => n,
            null => 1,
            _ => throw wrong('with a part number that is not a number'),
          },
          method: switch (operation['method']) {
            final String m when m.isNotEmpty => m,
            _ => throw wrong('without a method'),
          },
          url: switch (operation['url']) {
            final String u when Uri.tryParse(u)?.hasAuthority ?? false =>
              Uri.parse(u),
            _ => throw wrong('without a URL'),
          },
          offset: switch (operation['offset']) {
            final int o when o >= 0 => o,
            _ => throw wrong('without an offset'),
          },
          length: switch (operation['length']) {
            final int l when l >= 0 => l,
            _ => throw wrong('without a length'),
          },
          headers: headersOf(operation['requestHeaders']),
        ),
  ];
}

/// Why a request failed.
enum AscFailure {
  /// HTTP 401: Apple did not accept the token.
  unauthorized,

  /// HTTP 403: the key may not do this.
  forbidden,

  /// No answer, after the retries: no connection, or none within the timeout.
  offline,

  /// HTTP 5xx, after the retries.
  unavailable,

  /// Any other answer: another status, a redirect, or something that is not Apple's JSON.
  refused,
}

/// A request that App Store Connect did not answer with data.
class AscException implements Exception {
  const AscException(
    this.failure,
    this.request,
    this.message, {
    this.errors = const [],
  });

  final AscFailure failure;

  /// The request, such as `GET /v1/apps`, without the query. For a part of a file, `PUT part 3`: never its URL.
  final String request;

  /// What happened, such as `HTTP 404` or the system's message.
  final String message;

  /// Apple's `errors`, each with the `status`, `code`, `title` and `detail` that Apple sent.
  final List<Map<String, String>> errors;

  @override
  String toString() => '$request: $message';
}

/// [AscClient] over HTTPS.
///
/// - Each attempt has its own token from [token], sent in the `Authorization` header to [api] only: a redirect is not
///   followed, and a next page outside [api] is refused. The token never goes with a part: [sendPart] has none.
/// - A read that cannot connect, gets no answer within [timeout], or gets HTTP 5xx is tried again after each of
///   [retryDelays]. A write ([write]) is never tried again, and has [writeTimeout]. A part is tried again after each of
///   [partRetryDelays] when it cannot connect, gets no answer within [partTimeout], or gets HTTP 5xx, 408 or 429.
/// - [log] gets one line per attempt: method, host, path, query, outcome and time. Never the token, a header, a body or
///   the URL of a part.
class HttpAscClient implements AscClient {
  HttpAscClient({
    required this.token,
    Uri? api,
    this.timeout = const Duration(seconds: 20),
    this.retryDelays = const [Duration(seconds: 1), Duration(seconds: 2)],
    this.writeTimeout = const Duration(seconds: 120),
    this.partTimeout = const Duration(seconds: 600),
    this.partRetryDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
    ],
    this.log,
  }) : api = api ?? Uri.https('api.appstoreconnect.apple.com');

  final Uri api;
  final String Function() token;
  final Duration timeout;
  final List<Duration> retryDelays;
  final Duration writeTimeout;
  final Duration partTimeout;
  final List<Duration> partRetryDelays;
  final void Function(String line)? log;

  @override
  Future<List<AscResource>> getAll(
    String path,
    Map<String, String> query,
  ) async {
    final resources = <AscResource>[];
    for (
      Uri? url = api.replace(path: path, queryParameters: query);
      url != null;
    ) {
      final (data, next) = await _get(url);
      resources.addAll(data);
      url = next;
    }
    return resources;
  }

  @override
  Future<Map<String, Object?>> getDocument(
    String path,
    Map<String, String> query,
  ) async {
    final url = api.replace(path: path, queryParameters: query);
    final request = 'GET ${url.path}';
    final (status, body, outcome) = await _exchange(
      request,
      _shown('GET', url),
      () => _http('GET', url, authorize: true, limit: timeout),
      retryDelays,
      timeout,
      (status) => status >= 500,
    );
    if (status != 200) {
      throw _refusal(status, request, outcome, body);
    }
    return _object(body, request);
  }

  @override
  Future<Map<String, Object?>> write(
    String method,
    String path,
    Map<String, Object?> body,
  ) async {
    final url = api.replace(path: path);
    final request = '$method ${url.path}';
    final json = utf8.encode(jsonEncode(body));
    final (status, answer, outcome) = await _exchange(
      request,
      _shown(method, url),
      () => _http(
        method,
        url,
        authorize: true,
        limit: writeTimeout,
        bytes: json,
        headers: const {HttpHeaders.contentTypeHeader: 'application/json'},
      ),
      const [],
      writeTimeout,
      (_) => false,
    );
    if (status != 200 && status != 201 && status != 204) {
      throw _refusal(status, request, outcome, answer);
    }
    return status == 204 || answer.trim().isEmpty
        ? const {}
        : _object(answer, request);
  }

  @override
  Future<void> sendPart(AscUploadPart part, List<int> bytes) async {
    final request = 'PUT part ${part.number}';
    if (part.url.scheme != api.scheme) {
      throw AscException(
        AscFailure.refused,
        request,
        'the upload link of part ${part.number} is not on ${api.scheme}, and nothing is sent to it',
      );
    }
    final (status, body, outcome) = await _exchange(
      request,
      'PUT part ${part.number} (${bytes.length} bytes)',
      () => _http(
        part.method,
        part.url,
        authorize: false,
        limit: partTimeout,
        bytes: bytes,
        headers: part.headers,
      ),
      partRetryDelays,
      partTimeout,
      (status) => status >= 500 || status == 408 || status == 429,
    );
    if (status >= 200 && status < 300) {
      return;
    }
    throw AscException(
      switch (status) {
        >= 500 => AscFailure.unavailable,
        _ => AscFailure.refused,
      },
      request,
      status >= 300 && status < 400
          ? '$outcome, a redirect, which is not followed'
          : outcome,
      errors: _storeErrors(body),
    );
  }

  String _shown(String method, Uri url) =>
      '$method ${url.host}${url.path}${url.hasQuery ? '?${Uri.decodeQueryComponent(url.query)}' : ''}';

  Future<(List<AscResource>, Uri?)> _get(Uri url) async {
    final request = 'GET ${url.path}';
    final (status, body, outcome) = await _exchange(
      request,
      _shown('GET', url),
      () => _http('GET', url, authorize: true, limit: timeout),
      retryDelays,
      timeout,
      (status) => status >= 500,
    );
    if (status == 200) {
      return _page(body, request);
    }
    throw _refusal(status, request, outcome, body);
  }

  /// Sends one request through [once], tries it again after each of [delays] when it cannot connect, gets no answer
  /// within [limit], or gets a status for which [again] is true, and returns the last answer: its status, its body and
  /// how the log says it ended. Throws an [AscException] when there was no answer at all.
  Future<(int, String, String)> _exchange(
    String request,
    String shown,
    Future<(int, String)> Function() once,
    List<Duration> delays,
    Duration limit,
    bool Function(int status) again,
  ) async {
    for (var attempt = 0; ; attempt++) {
      final clock = Stopwatch()..start();
      int? status;
      var body = '';
      String outcome;
      try {
        (status, body) = await once();
        outcome = 'HTTP $status';
      } on TimeoutException {
        outcome =
            'no answer within ${limit.inMilliseconds % 1000 == 0 ? '${limit.inSeconds} s' : '${limit.inMilliseconds} ms'}';
      } on IOException catch (e) {
        // The message only: an HttpException's toString carries the URL, which for a part is a secret.
        outcome = switch (e) {
          SocketException(:final osError?) => osError.message,
          SocketException(:final message) => message,
          TlsException(:final message, :final osError) =>
            '$message${osError == null ? '' : ': ${osError.message}'}',
          HttpException(:final message) => message,
          _ => e.runtimeType.toString(),
        };
      }
      final retry =
          (status == null || again(status)) && attempt < delays.length;
      log?.call(
        '$shown: $outcome, ${clock.elapsedMilliseconds} ms'
        '${retry ? ', trying again in ${delays[attempt].inSeconds} s' : ''}',
      );
      if (retry) {
        await Future<void>.delayed(delays[attempt]);
        continue;
      }
      if (status == null) {
        throw AscException(AscFailure.offline, request, outcome);
      }
      return (status, body, outcome);
    }
  }

  /// One HTTP exchange. With [authorize] it carries a new token, for [api] only; without it, nothing that identifies
  /// winCode or its key. A redirect is not followed.
  Future<(int, String)> _http(
    String method,
    Uri url, {
    required bool authorize,
    required Duration limit,
    List<int>? bytes,
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient()
      ..connectionTimeout = limit
      // As urllib in the spike's script: HTTPS_PROXY and NO_PROXY apply. TLS still runs end to end.
      ..findProxy = HttpClient.findProxyFromEnvironment;
    try {
      return await () async {
        final request = await client.openUrl(method, url);
        request.followRedirects = false;
        if (authorize) {
          request.headers
            ..set(HttpHeaders.authorizationHeader, 'Bearer ${token()}')
            ..set(HttpHeaders.acceptHeader, 'application/json');
        }
        for (final MapEntry(:key, :value) in headers.entries) {
          request.headers.set(key, value);
        }
        if (bytes != null) {
          request
            ..contentLength = bytes.length
            ..add(bytes);
        }
        final response = await request.close();
        final body = await response
            .transform(const Utf8Decoder(allowMalformed: true))
            .join();
        return (response.statusCode, body);
      }().timeout(limit);
    } finally {
      // Also ends a request that ran out of time.
      client.close(force: true);
    }
  }

  AscException _refusal(
    int status,
    String request,
    String outcome,
    String body,
  ) => AscException(
    switch (status) {
      401 => AscFailure.unauthorized,
      403 => AscFailure.forbidden,
      >= 500 => AscFailure.unavailable,
      _ => AscFailure.refused,
    },
    request,
    status >= 300 && status < 400
        ? '$outcome, a redirect, which is not followed'
        : outcome,
    errors: _errors(body),
  );

  Map<String, Object?> _object(String body, String request) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw AscException(AscFailure.refused, request, 'the answer is not JSON');
    }
    if (json is! Map<String, Object?>) {
      throw AscException(
        AscFailure.refused,
        request,
        'the answer is not a JSON object',
      );
    }
    return json;
  }

  (List<AscResource>, Uri?) _page(String body, String request) {
    AscException wrong(String what) =>
        AscException(AscFailure.refused, request, what);
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw wrong('the answer is not JSON');
    }
    if (json is! Map<String, Object?>) {
      throw wrong('the answer holds no list of resources');
    }
    final data = json['data'];
    if (data is! List<Object?> || data.any((r) => r is! Map<String, Object?>)) {
      throw wrong('the answer holds no list of resources');
    }
    final links = json['links'];
    final next = links is Map<String, Object?> ? links['next'] : null;
    if (next == null) {
      return (data.cast<AscResource>(), null);
    }
    if (next is! String || !next.startsWith('$api/')) {
      throw wrong(
        'the next page is not on ${api.host}, and the token goes nowhere else',
      );
    }
    return (data.cast<AscResource>(), Uri.parse(next));
  }
}

/// Apple's `errors` in [body], each with its `status`, `code`, `title` and `detail`; none when [body] is not Apple's
/// error JSON.
List<Map<String, String>> _errors(String body) {
  try {
    final errors = (jsonDecode(body) as Map<String, Object?>)['errors'];
    return [
      for (final e in errors! as List<Object?>)
        if (e is Map<String, Object?>)
          {
            for (final key in ['status', 'code', 'title', 'detail'])
              if (e[key] case final String value) key: value,
          },
    ];
  } on Object {
    return const [];
  }
}

/// The `Code` and `Message` of an error that the upload store answered in XML, as `code` and `detail`. Nothing else of
/// the body: it can echo the signed link and its signature.
List<Map<String, String>> _storeErrors(String body) {
  String? element(String name) {
    final text = RegExp('<$name>([^<]{1,200})</$name>').firstMatch(body)?[1];
    // Whatever looks like a link is left out, whole.
    return text?.replaceAll(RegExp(r'https?://\S+'), '<URL>');
  }

  final code = element('Code');
  final message = element('Message');
  return [
    if (code != null || message != null) {'code': ?code, 'detail': ?message},
  ];
}
