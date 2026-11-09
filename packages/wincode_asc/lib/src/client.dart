import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One resource of an App Store Connect answer, with `type`, `id` and `attributes`, as Apple sends it.
typedef AscResource = Map<String, Object?>;

/// The read requests that winCode sends to App Store Connect.
abstract interface class AscClient {
  /// Every resource of the collection at [path], such as `/v1/apps`, with [query], page after page.
  Future<List<AscResource>> getAll(String path, Map<String, String> query);
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

  /// The request, such as `GET /v1/apps`, without the query.
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
///   followed, and a next page outside [api] is refused.
/// - An attempt that cannot connect, gets no answer within [timeout], or gets HTTP 5xx is tried again after each of
///   [retryDelays]. Nothing else is tried again.
/// - [log] gets one line per attempt: method, host, path, query, outcome and time. Never the token or a header.
class HttpAscClient implements AscClient {
  HttpAscClient({
    required this.token,
    Uri? api,
    this.timeout = const Duration(seconds: 20),
    this.retryDelays = const [Duration(seconds: 1), Duration(seconds: 2)],
    this.log,
  }) : api = api ?? Uri.https('api.appstoreconnect.apple.com');

  final Uri api;
  final String Function() token;
  final Duration timeout;
  final List<Duration> retryDelays;
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

  Future<(List<AscResource>, Uri?)> _get(Uri url) async {
    final request = 'GET ${url.path}';
    final shown =
        'GET ${url.host}${url.path}${url.hasQuery ? '?${Uri.decodeQueryComponent(url.query)}' : ''}';
    for (var attempt = 0; ; attempt++) {
      final clock = Stopwatch()..start();
      int? status;
      var body = '';
      String outcome;
      try {
        (status, body) = await _send(url);
        outcome = 'HTTP $status';
      } on TimeoutException {
        outcome =
            'no answer within ${timeout.inMilliseconds % 1000 == 0 ? '${timeout.inSeconds} s' : '${timeout.inMilliseconds} ms'}';
      } on IOException catch (e) {
        outcome = switch (e) {
          SocketException(:final osError?) => osError.message,
          SocketException(:final message) => message,
          TlsException(:final message, :final osError) =>
            '$message${osError == null ? '' : ': ${osError.message}'}',
          HttpException(:final message) => message,
          _ => '$e',
        };
      }
      final retry =
          (status == null || status >= 500) && attempt < retryDelays.length;
      log?.call(
        '$shown: $outcome, ${clock.elapsedMilliseconds} ms'
        '${retry ? ', trying again in ${retryDelays[attempt].inSeconds} s' : ''}',
      );
      if (retry) {
        await Future<void>.delayed(retryDelays[attempt]);
        continue;
      }
      if (status == null) {
        throw AscException(AscFailure.offline, request, outcome);
      }
      if (status == 200) {
        return _page(body, request);
      }
      throw AscException(
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
    }
  }

  Future<(int, String)> _send(Uri url) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      // As urllib in the spike's script: HTTPS_PROXY and NO_PROXY apply. TLS still runs end to end.
      ..findProxy = HttpClient.findProxyFromEnvironment;
    try {
      return await () async {
        final request = await client.getUrl(url);
        request
          ..followRedirects = false
          ..headers.set(HttpHeaders.authorizationHeader, 'Bearer ${token()}')
          ..headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response = await request.close();
        final body = await response
            .transform(const Utf8Decoder(allowMalformed: true))
            .join();
        return (response.statusCode, body);
      }().timeout(timeout);
    } finally {
      // Also ends a request that ran out of time.
      client.close(force: true);
    }
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
