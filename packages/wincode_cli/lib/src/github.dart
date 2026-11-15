import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wincode_core/wincode_core.dart';

import 'config.dart';
import 'failure.dart';
import 'redact.dart';

/// The version of GitHub's REST API that winCode asks for in every request (ADR-0015, section 4). With it, the dispatch
/// of a workflow answers with the run it started.
const githubApiVersion = '2026-03-10';

/// Why a request to GitHub failed.
enum GithubFailure {
  /// HTTP 401: GitHub did not accept the token.
  unauthorized,

  /// HTTP 403 that is not a rate limit: the token may not do this.
  forbidden,

  /// HTTP 404: there is no such thing, or the token cannot see it.
  notFound,

  /// HTTP 422: GitHub understood the request and refused its content, such as a branch that does not exist.
  unprocessable,

  /// A rate limit that did not clear within the time winCode waits.
  rateLimited,

  /// No answer, after the retries: no connection, or none within the timeout.
  offline,

  /// HTTP 5xx, after the retries.
  unavailable,

  /// Any other answer: another status, a redirect, or something that is not GitHub's JSON.
  refused,
}

/// A request that GitHub did not answer with data.
class GithubException implements Exception {
  const GithubException(
    this.failure,
    this.request,
    this.message, {
    this.retryAfter,
  });

  final GithubFailure failure;

  /// The request, such as `GET /repos/example-org/example-app`, without the query.
  final String request;

  /// What happened: `HTTP 404`, or the system's message, followed by GitHub's own `message` when it sent one.
  final String message;

  /// For [GithubFailure.rateLimited], how long GitHub said to wait.
  final Duration? retryAfter;

  @override
  String toString() => '$request: $message';
}

/// What a conditional read of GitHub answered.
class GithubRead {
  const GithubRead(this.json, this.etag);

  /// The JSON object, or null when the resource has not changed since the `ETag` that the request sent.
  final Map<String, Object?>? json;

  /// The `ETag` of the answer, to send with the next read; the one that was sent when [json] is null.
  final String? etag;

  bool get notModified => json == null;
}

/// What GitHub answered to a write.
class GithubWrite {
  const GithubWrite(this.status, this.json);

  /// The HTTP status, 200 to 299.
  final int status;

  /// The JSON object of the answer, or null when it holds none (a 202 or a 204 has no body).
  final Map<String, Object?>? json;
}

/// Talks to GitHub's REST API (ADR-0015, sections 4 and 5). Every method sends the token to the API host and nowhere
/// else.
abstract interface class GithubClient {
  /// The JSON object that `GET` [path] (starting with `/`) answers. Throws a [GithubException] for any other outcome.
  Future<Map<String, Object?>> getJson(
    String path, [
    Map<String, String> query = const {},
  ]);

  /// The text of the file that `GET` [path] answers with its raw contents, as the Contents API gives a file.
  Future<String> getText(String path, [Map<String, String> query = const {}]);

  /// `GET` [path] with [etag] as `If-None-Match`: the object when it changed, else a [GithubRead] with no object. A
  /// 304 answer is not counted against GitHub's primary rate limit, so a wait that asks again and again costs little.
  Future<GithubRead> getJsonIfChanged(
    String path, {
    Map<String, String> query = const {},
    String? etag,
  });

  /// `POST` [path] with [body], if there is one, as JSON, once: a write is never sent twice, whatever happens to its answer. A network
  /// failure or a 5xx is a [GithubException] that says nothing about whether GitHub did the work.
  Future<GithubWrite> post(String path, [Map<String, Object?>? body]);

  /// `DELETE` [path], once.
  Future<void> delete(String path);

  /// Downloads what `GET` [path] points to, which GitHub answers with a redirect to a signed link in its storage, to
  /// [file]; returns the number of bytes. The link is requested without the token, and registered with [hide] before
  /// the request. A download that fails is tried again from the redirect, as a read is. It stops, as `offline`, once
  /// [stop] completes.
  Future<int> download(
    String path,
    File file, {
    required void Function(String secret) hide,
    Future<void>? stop,
  });
}

/// Makes the client that `wincode build` talks to GitHub with, from the token and the `--verbose` log. Tests connect to
/// a fake server.
typedef GithubConnect = GithubClient Function(
  String token,
  void Function(String line)? log,
);

/// The [GithubConnect] of a real run: `https://api.github.com`.
GithubClient connectToGithub(String token, void Function(String line)? log) =>
    HttpGithubClient(token: token, log: log);

/// What GitHub answered to a request that got an answer: the status, the headers (names in lower case), the body, and
/// the status as a message names it.
class _Answer {
  const _Answer(this.status, this.headers, this.body, this.outcome);

  final int status;
  final Map<String, String> headers;
  final String body;
  final String outcome;
}

/// [GithubClient] over HTTPS.
///
/// - The token goes in the `Authorization` header to [api] only: every URL is built from [api], and a redirect is not
///   followed. The one address of an answer that is requested is the signed link of an artifact's download, which is
///   requested without the token.
/// - A read that cannot connect, gets no answer within [timeout], or gets HTTP 5xx is tried again after each of
///   [retryDelays]. A write is never tried again.
/// - A rate limit is waited out when GitHub says it clears within [maxRateWait], up to [maxRateRetries] times in a
///   read. Otherwise the request fails with [GithubFailure.rateLimited].
/// - [log] gets one line per attempt: method, host, path, query, outcome and time. Never the token, a header or a body,
///   and for the download link only its host.
class HttpGithubClient implements GithubClient {
  HttpGithubClient({
    required this.token,
    Uri? api,
    this.timeout = const Duration(seconds: 20),
    this.retryDelays = const [Duration(seconds: 1), Duration(seconds: 2)],
    this.maxRateWait = const Duration(seconds: 60),
    this.maxRateRetries = 2,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? clock,
    this.log,
  }) : api = api ?? Uri.https('api.github.com'),
       _sleep = sleep ?? Future<void>.delayed,
       _clock = clock ?? DateTime.now;

  final String token;
  final Uri api;
  final Duration timeout;
  final List<Duration> retryDelays;
  final Duration maxRateWait;
  final int maxRateRetries;
  final void Function(String line)? log;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _clock;

  @override
  Future<Map<String, Object?>> getJson(
    String path, [
    Map<String, String> query = const {},
  ]) async {
    final (url, request) = _target('GET', path, query);
    final answer = await _exchange(
      'GET',
      url,
      request,
      'application/vnd.github+json',
    );
    if (answer.status != 200) {
      throw _refusal(answer.status, request, answer.outcome, answer.body);
    }
    return _object(answer.body, request);
  }

  @override
  Future<String> getText(
    String path, [
    Map<String, String> query = const {},
  ]) async {
    final (url, request) = _target('GET', path, query);
    final answer = await _exchange(
      'GET',
      url,
      request,
      'application/vnd.github.raw+json',
    );
    if (answer.status != 200) {
      throw _refusal(answer.status, request, answer.outcome, answer.body);
    }
    return answer.body;
  }

  @override
  Future<GithubRead> getJsonIfChanged(
    String path, {
    Map<String, String> query = const {},
    String? etag,
  }) async {
    final (url, request) = _target('GET', path, query);
    final answer = await _exchange(
      'GET',
      url,
      request,
      'application/vnd.github+json',
      headers: {'If-None-Match': ?etag},
    );
    if (answer.status == 304 && etag != null) {
      // The ETag of a 304 is written in another form (strong, where the 200 had a weak one); the one that was sent is kept.
      return GithubRead(null, etag);
    }
    if (answer.status != 200) {
      throw _refusal(answer.status, request, answer.outcome, answer.body);
    }
    return GithubRead(_object(answer.body, request), answer.headers['etag']);
  }

  @override
  Future<GithubWrite> post(String path, [Map<String, Object?>? body]) async {
    final (url, request) = _target('POST', path, const {});
    final answer = await _exchange(
      'POST',
      url,
      request,
      'application/vnd.github+json',
      json: body == null ? null : jsonEncode(body),
      again: false,
    );
    if (answer.status < 200 || answer.status > 299) {
      throw _refusal(answer.status, request, answer.outcome, answer.body);
    }
    Map<String, Object?>? json;
    try {
      json = answer.body.trim().isEmpty ? null : _object(answer.body, request);
    } on GithubException {
      // A write that GitHub did has an answer whose content is of no use here; the status says what happened.
      json = null;
    }
    return GithubWrite(answer.status, json);
  }

  @override
  Future<void> delete(String path) async {
    final (url, request) = _target('DELETE', path, const {});
    final answer = await _exchange(
      'DELETE',
      url,
      request,
      'application/vnd.github+json',
      again: false,
    );
    if (answer.status != 204 && answer.status != 200) {
      throw _refusal(answer.status, request, answer.outcome, answer.body);
    }
  }

  @override
  Future<int> download(
    String path,
    File file, {
    required void Function(String secret) hide,
    Future<void>? stop,
  }) async {
    final (url, request) = _target('GET', path, const {});
    var stopped = false;
    unawaited(stop?.then((_) => stopped = true));
    for (var attempt = 0; ; attempt++) {
      try {
        return await _downloadOnce(url, request, file, hide, stop);
      } on GithubException catch (e) {
        final again =
            !stopped &&
            (e.failure == GithubFailure.offline ||
                e.failure == GithubFailure.unavailable) &&
            attempt < retryDelays.length;
        if (!again) rethrow;
        log?.call(
          '$request: ${e.message}, trying again in ${retryDelays[attempt].inSeconds} s',
        );
        await _sleep(retryDelays[attempt]);
      }
    }
  }

  (Uri, String) _target(String method, String path, Map<String, String> query) {
    if (!path.startsWith('/')) {
      throw ArgumentError.value(path, 'path', 'must start with /');
    }
    final url = api.replace(
      path: path,
      queryParameters: query.isEmpty ? null : query,
    );
    return (url, '$method ${url.path}');
  }

  String _shown(String method, Uri url) =>
      '$method ${url.host}${url.path}${url.hasQuery ? '?${Uri.decodeQueryComponent(url.query)}' : ''}';

  Map<String, Object?> _object(String body, String request) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw GithubException(
        GithubFailure.refused,
        request,
        'the answer is not JSON',
      );
    }
    if (json is! Map<String, Object?>) {
      throw GithubException(
        GithubFailure.refused,
        request,
        'the answer is not a JSON object',
      );
    }
    return json;
  }

  /// What went wrong with a request that got no answer, in words that never carry its URL.
  String _why(Object e) {
    if (e is TimeoutException) {
      return 'no answer within ${timeout.inMilliseconds % 1000 == 0 ? '${timeout.inSeconds} s' : '${timeout.inMilliseconds} ms'}';
    }
    // The message only: an HttpException's toString carries the URL.
    return switch (e) {
      SocketException(:final osError?) => osError.message,
      SocketException(:final message) => message,
      TlsException(:final message, :final osError) =>
        '$message${osError == null ? '' : ': ${osError.message}'}',
      HttpException(:final message) => message,
      _ => e.runtimeType.toString(),
    };
  }

  /// The answer to a request of [method] to [url], after the retries of a read. With [again] false (a write), the
  /// request is sent once, and neither a failure nor a rate limit sends it again. Whatever status GitHub answers with
  /// is returned, except that a rate limit or no answer at all is thrown.
  Future<_Answer> _exchange(
    String method,
    Uri url,
    String request,
    String accept, {
    String? json,
    Map<String, String> headers = const {},
    bool again = true,
  }) async {
    var rateWaits = 0;
    for (var attempt = 0; ; attempt++) {
      final clock = Stopwatch()..start();
      int? status;
      var body = '';
      Map<String, String> got = const {};
      String outcome;
      try {
        (status, got, body) = await _http(
          method,
          url,
          accept,
          json: json,
          extraHeaders: headers,
        );
        outcome = 'HTTP $status';
      } on TimeoutException catch (e) {
        outcome = _why(e);
      } on IOException catch (e) {
        outcome = _why(e);
      }
      final limit = status == null ? null : _rateLimit(status, got, body);
      final retry =
          again &&
          (status == null || status >= 500) &&
          attempt < retryDelays.length;
      final waitForLimit =
          again &&
          limit != null &&
          limit <= maxRateWait &&
          rateWaits < maxRateRetries &&
          !retry;
      log?.call(
        '${_shown(method, url)}: $outcome, ${clock.elapsedMilliseconds} ms'
        '${retry ? ', trying again in ${retryDelays[attempt].inSeconds} s' : ''}'
        '${limit != null ? (waitForLimit ? ', rate limited: waiting ${limit.inSeconds} s' : ', rate limited') : ''}',
      );
      if (retry) {
        await _sleep(retryDelays[attempt]);
        continue;
      }
      if (waitForLimit) {
        rateWaits++;
        await _sleep(limit);
        continue;
      }
      if (status == null) {
        throw GithubException(GithubFailure.offline, request, outcome);
      }
      if (limit != null) {
        throw GithubException(
          GithubFailure.rateLimited,
          request,
          '$outcome, rate limited${_said(body)}',
          retryAfter: limit,
        );
      }
      return _Answer(status, got, body, outcome);
    }
  }

  /// One try at the download: the address from the API's redirect, then the file from that address without the token.
  Future<int> _downloadOnce(
    Uri url,
    String request,
    File file,
    void Function(String secret) hide,
    Future<void>? stop,
  ) async {
    final redirect = await _exchange(
      'GET',
      url,
      request,
      'application/vnd.github+json',
    );
    final location = redirect.headers['location'];
    if (redirect.status != 302 || location == null) {
      throw redirect.status == 200 || redirect.status == 302
          ? GithubException(
              GithubFailure.refused,
              request,
              'HTTP ${redirect.status}, and no redirect to the file',
            )
          : _refusal(redirect.status, request, redirect.outcome, redirect.body);
    }
    final link = api.resolve(location);
    if (link.scheme != api.scheme ||
        !link.hasAuthority ||
        link.userInfo != '') {
      throw GithubException(
        GithubFailure.refused,
        request,
        'the redirect does not name a ${api.scheme} address',
      );
    }
    // The link is signed: whoever has it can download the file until it expires, so it is never printed.
    hide('$link');
    if (link.hasQuery) hide(link.query);
    final clock = Stopwatch()..start();
    final storage = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = HttpClient.findProxyFromEnvironment
      ..userAgent = 'wincode';
    unawaited(stop?.then((_) => storage.close(force: true)));
    var bytes = 0;
    try {
      final get = await storage.getUrl(link);
      // No Authorization header: the token is for api.github.com only, and the link carries its own proof.
      get.followRedirects = false;
      final response = await get.close().timeout(timeout);
      if (response.statusCode != 200) {
        await response.drain<void>().catchError((Object _) {});
        final status = response.statusCode;
        log?.call(
          'GET ${link.host}: HTTP $status, ${clock.elapsedMilliseconds} ms',
        );
        throw GithubException(
          status >= 500 ? GithubFailure.unavailable : GithubFailure.refused,
          request,
          'the download link answered HTTP $status',
        );
      }
      final sink = file.openWrite();
      try {
        await sink.addStream(
          response.timeout(timeout).map((chunk) {
            bytes += chunk.length;
            return chunk;
          }),
        );
      } finally {
        await sink.close();
      }
      log?.call(
        'GET ${link.host}: HTTP 200, $bytes bytes, ${clock.elapsedMilliseconds} ms',
      );
      return bytes;
    } on TimeoutException catch (e) {
      throw GithubException(GithubFailure.offline, request, _why(e));
    } on IOException catch (e) {
      throw GithubException(GithubFailure.offline, request, _why(e));
    } finally {
      storage.close(force: true);
    }
  }

  /// How long a rate limit says to wait, or null when [status] is no rate limit. A 429, or a 403 that says so, with
  /// GitHub's `retry-after` or `x-ratelimit-reset` (seconds since 1970); a minute when it says nothing.
  Duration? _rateLimit(int status, Map<String, String> headers, String body) {
    final limited =
        status == 429 ||
        (status == 403 &&
            (headers['x-ratelimit-remaining'] == '0' ||
                headers.containsKey('retry-after') ||
                RegExp('rate limit', caseSensitive: false).hasMatch(body)));
    if (!limited) {
      return null;
    }
    final after = int.tryParse(headers['retry-after'] ?? '');
    if (after != null) {
      return Duration(seconds: after < 1 ? 1 : after);
    }
    final reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
    if (reset != null) {
      final wait = DateTime.fromMillisecondsSinceEpoch(
        reset * 1000,
        isUtc: true,
      ).difference(_clock().toUtc());
      return wait < const Duration(seconds: 1)
          ? const Duration(seconds: 1)
          : wait + const Duration(seconds: 1);
    }
    return const Duration(minutes: 1);
  }

  /// One HTTP exchange: the status, the headers (names in lower case) and the body. A redirect is not followed.
  Future<(int, Map<String, String>, String)> _http(
    String method,
    Uri url,
    String accept, {
    String? json,
    Map<String, String> extraHeaders = const {},
  }) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      // As the App Store Connect client: HTTPS_PROXY and NO_PROXY apply. TLS still runs end to end.
      ..findProxy = HttpClient.findProxyFromEnvironment
      ..userAgent = 'wincode';
    try {
      return await () async {
        final request = await client.openUrl(method, url);
        request.followRedirects = false;
        request.headers
          ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
          ..set(HttpHeaders.acceptHeader, accept)
          ..set('X-GitHub-Api-Version', githubApiVersion);
        extraHeaders.forEach(request.headers.set);
        if (json != null) {
          final bytes = utf8.encode(json);
          request.headers.contentType = ContentType(
            'application',
            'json',
            charset: 'utf-8',
          );
          request.contentLength = bytes.length;
          request.add(bytes);
        } else if (method == 'POST') {
          request.contentLength = 0;
        }
        final response = await request.close();
        final body = await response
            .transform(const Utf8Decoder(allowMalformed: true))
            .join();
        final headers = <String, String>{};
        response.headers.forEach(
          (name, values) => headers[name.toLowerCase()] = values.join(', '),
        );
        return (response.statusCode, headers, body);
      }().timeout(timeout);
    } finally {
      // Also ends a request that ran out of time.
      client.close(force: true);
    }
  }

  GithubException _refusal(
    int status,
    String request,
    String outcome,
    String body,
  ) => GithubException(
    switch (status) {
      401 => GithubFailure.unauthorized,
      403 => GithubFailure.forbidden,
      404 => GithubFailure.notFound,
      422 => GithubFailure.unprocessable,
      >= 500 => GithubFailure.unavailable,
      _ => GithubFailure.refused,
    },
    request,
    status >= 300 && status < 400
        ? '$outcome, a redirect, which is not followed'
        : '$outcome${_said(body)}',
  );

  /// GitHub's own `message`, when [body] is its error JSON, after a colon; else nothing.
  String _said(String body) {
    try {
      final message = (jsonDecode(body) as Map<String, Object?>)['message'];
      return message is String && message.isNotEmpty
          ? ': ${message.length > 200 ? message.substring(0, 200) : message}'
          : '';
    } on Object {
      return '';
    }
  }
}

/// A GitHub token, and where winCode found it.
class GithubToken {
  const GithubToken(this.value, this.source);

  final String value;

  /// Where it came from, as a message names it: `GH_TOKEN`, `WINCODE_GH_TOKEN_ALPHA`, or `gh auth token`.
  final String source;

  /// What GitHub's prefix says the token is.
  String get kind => switch (value) {
    final v when v.startsWith('github_pat_') => 'a fine-grained token',
    final v when v.startsWith('ghp_') => 'a classic token',
    final v when v.startsWith('gho_') => 'an OAuth token',
    final v when v.startsWith('ghs_') => 'an installation token',
    final v when v.startsWith('ghu_') => 'a user token',
    _ => 'a token of an unknown kind',
  };

  /// Whether the token can do far more than `wincode build` needs: a classic token or `gh`'s login need the `repo`
  /// scope, which reaches every repository of the account (ADR-0015, section 5).
  bool get broad =>
      source == ghLoginSource ||
      value.startsWith('ghp_') ||
      value.startsWith('gho_');
}

/// How `gh`'s login is named as the source of a token.
const ghLoginSource = 'gh auth token';

/// The variable that holds the token of the app [name] only: `WINCODE_GH_TOKEN_` and the name in capitals with `-`
/// written as `_`, as ADR-0014 names the variables of a credentials reference (ADR-0015, section 5). A flat file has no
/// app name, so it has none.
String? githubTokenVariable(String? name) => name == null
    ? null
    : 'WINCODE_GH_TOKEN_${name.toUpperCase().replaceAll('-', '_')}';

final _tokenShape = RegExp(r'^[A-Za-z0-9_.-]{20,255}$');

/// Finds the GitHub token of [app], in this order, and registers it with [redactor] as a secret before anything can
/// print it (ADR-0015, section 5):
///
/// 1. `WINCODE_GH_TOKEN_<APP>`, the token of this app only;
/// 2. `GH_TOKEN`;
/// 3. `GITHUB_TOKEN`;
/// 4. `gh auth token --hostname github.com`, when `gh` is installed and logged in.
///
/// An empty variable is not set. A value that cannot be a token is refused without printing it: it would otherwise go
/// into a request header. When none gives a token, the failure is `github-token-missing` (77); [repository] and the
/// source names make its message.
Future<GithubToken> findGithubToken(
  WincodeConfig app, {
  required Map<String, String> environment,
  required Redactor redactor,
  required RunProcess run,
}) async {
  final own = githubTokenVariable(app.name);
  GithubToken accept(String variable, String value) {
    if (!_tokenShape.hasMatch(value)) {
      throw WincodeException(
        ExitCode.config,
        'github-token-invalid',
        '$variable does not hold a GitHub token',
        why:
            'a GitHub token is 20 to 255 letters, digits, _, - and . on one line, and anything else cannot go in a '
            'request header. Its value is not shown.',
        next:
            'set $variable to the token as GitHub shows it once, with no quotes or spaces around it.',
      );
    }
    redactor.secret(value, '<GitHub token>');
    return GithubToken(value, variable);
  }

  for (final variable in [?own, 'GH_TOKEN', 'GITHUB_TOKEN']) {
    final value = environment[variable]?.trim() ?? '';
    if (value.isNotEmpty) {
      return accept(variable, value);
    }
  }
  var ghState = 'is not installed';
  try {
    final result = await run('gh', const [
      'auth',
      'token',
      '--hostname',
      'github.com',
    ]);
    final value = '${result.stdout}'.trim();
    if (result.exitCode == 0 && value.isNotEmpty) {
      return accept(ghLoginSource, value);
    }
    ghState = 'is installed but not logged in to github.com';
  } on ProcessException {
    // gh is not installed.
  }
  final sources = [?own, 'GH_TOKEN', 'GITHUB_TOKEN'];
  throw WincodeException(
    ExitCode.permission,
    'github-token-missing',
    'no GitHub token: ${sources.length == 3 ? '${sources[0]}, ${sources[1]}' : sources[0]} and ${sources.last} are not set, and gh $ghState',
    why:
        "winCode starts the workflow through GitHub's API, which needs a token with Actions (read and write) and "
        'Contents (read) on the repository.',
    next:
        'set GH_TOKEN to a fine-grained token limited to ${app.workflow?.repository ?? 'the repository of the workflow'} '
        'with those permissions${own == null ? '' : ' ($own for this app only)'}, or '
        '${ghState == 'is not installed' ? 'install gh and ' : ''}run gh auth login.',
  );
}

/// A run that is going on GitHub while a request to GitHub fails: where to see it, and the command that collects it.
typedef GoingRun = ({String url, String collect});

/// The failure of a request to GitHub as a message, in the form of ADR-0013 (section 6). [what] says what the request
/// was for, such as `read example-org/example-app`. Before a run is started, the next step is to run the command again
/// and nothing was started; with a [run] that is going, it is to collect that run, which goes on meanwhile.
WincodeException githubProblem(
  GithubException e, {
  required String what,
  GoingRun? run,
}) {
  /// What to do once the cause is gone, and where the run stands.
  String then(String again, String collect) => run == null
      ? '$again Nothing was started.'
      : '$collect The run goes on at ${run.url}.';
  final collect = run == null ? '' : 'collect the run with ${run.collect}.';
  return switch (e.failure) {
    GithubFailure.unauthorized => WincodeException(
      ExitCode.permission,
      'github-unauthorized',
      'GitHub refused the token: ${e.message}',
      why:
          'the token is wrong, expired or revoked. GitHub answers 401 to a token that it does not know, whichever '
          'repository the request was for.',
      next:
          'make a new fine-grained token with Actions (read and write) and Contents (read) on the repository, set it in '
          'GH_TOKEN, and ${then('run the command again.', 'then $collect')}',
    ),
    GithubFailure.forbidden => WincodeException(
      ExitCode.permission,
      'github-forbidden',
      'GitHub refused ${e.request} to the token: ${e.message}',
      why:
          'the token lacks a permission that this request needs, or the repository blocks it (an organisation may '
          'restrict fine-grained tokens, or require single sign-on for a classic one).',
      next:
          'give the token Actions (read and write) and Contents (read) on the repository, or have the organisation '
          'approve it. ${then('', 'Then $collect').trim()}',
    ),
    GithubFailure.rateLimited => WincodeException(
      ExitCode.unavailable,
      'github-rate-limited',
      'GitHub is limiting the requests of this token: ${e.message}',
      why:
          'a token has a number of requests an hour, and GitHub says it clears in '
          '${e.retryAfter == null ? 'a while' : _wait(e.retryAfter!)}, which is longer than winCode waits.',
      next: then('run the command again after that.', 'After that, $collect'),
    ),
    GithubFailure.offline => WincodeException(
      ExitCode.unavailable,
      'offline',
      'cannot reach api.github.com: ${e.message}',
      why: "there is no network, a proxy or a firewall is in the way, or GitHub's service is down.",
      next:
          "check the connection (and HTTPS_PROXY, if you use one) and GitHub's status page, then "
          "${then('run the command again.', collect)}",
    ),
    GithubFailure.unavailable => WincodeException(
      ExitCode.unavailable,
      'github-unavailable',
      'GitHub kept answering ${e.request} with ${e.message}',
      why: "GitHub's service is down or overloaded.",
      next:
          "check GitHub's status page, then ${then('run the command again.', collect)}",
    ),
    GithubFailure.notFound ||
    GithubFailure.unprocessable ||
    GithubFailure.refused => WincodeException(
      ExitCode.failed,
      'github-error',
      "GitHub's answer to ${e.request} is not what wincode build expects: ${e.message}",
      why:
          'wincode build follows the requests that GitHub documents, to $what, so this answer is unexpected.',
      next: run == null
          ? 'run the command again with --verbose --redact; if the answer comes again, report it with that output at '
                'https://github.com/wincode-org/wincode/issues. Nothing was started.'
          : 'collect the run again with ${run.collect} --verbose --redact; if the answer comes again, report it with '
                'that output at https://github.com/wincode-org/wincode/issues. The run goes on at ${run.url}.',
    ),
  };
}

String _wait(Duration d) => d.inMinutes >= 1
    ? '${d.inMinutes} minute${d.inMinutes == 1 ? '' : 's'}'
    : '${d.inSeconds} seconds';
