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

/// Reads from GitHub's REST API (ADR-0015, sections 4 and 5). It only reads: `wincode build` sends no write in this part
/// of its work, and a client for a write is added with the dispatch.
abstract interface class GithubClient {
  /// The JSON object that `GET` [path] (starting with `/`) answers. Throws a [GithubException] for any other outcome.
  Future<Map<String, Object?>> getJson(
    String path, [
    Map<String, String> query = const {},
  ]);

  /// The text of the file that `GET` [path] answers with its raw contents, as the Contents API gives a file.
  Future<String> getText(String path, [Map<String, String> query = const {}]);
}

/// Makes the client that `wincode build` reads GitHub with, from the token and the `--verbose` log. Tests connect to a
/// fake server.
typedef GithubConnect = GithubClient Function(
  String token,
  void Function(String line)? log,
);

/// The [GithubConnect] of a real run: `https://api.github.com`.
GithubClient connectToGithub(String token, void Function(String line)? log) =>
    HttpGithubClient(token: token, log: log);

/// [GithubClient] over HTTPS.
///
/// - The token goes in the `Authorization` header to [api] only: every URL is built from [api], a redirect is not
///   followed, and no address that GitHub's answers name is ever requested.
/// - A read that cannot connect, gets no answer within [timeout], or gets HTTP 5xx is tried again after each of
///   [retryDelays].
/// - A rate limit is waited out when GitHub says it clears within [maxRateWait], up to [maxRateRetries] times in a
///   request. Otherwise the request fails with [GithubFailure.rateLimited].
/// - [log] gets one line per attempt: method, host, path, query, outcome and time. Never the token, a header or a body.
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
    final (url, request) = _target(path, query);
    final body = await _read(url, request, 'application/vnd.github+json');
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

  @override
  Future<String> getText(
    String path, [
    Map<String, String> query = const {},
  ]) async {
    final (url, request) = _target(path, query);
    return _read(url, request, 'application/vnd.github.raw+json');
  }

  (Uri, String) _target(String path, Map<String, String> query) {
    if (!path.startsWith('/')) {
      throw ArgumentError.value(path, 'path', 'must start with /');
    }
    final url = api.replace(
      path: path,
      queryParameters: query.isEmpty ? null : query,
    );
    return (url, 'GET ${url.path}');
  }

  String _shown(Uri url) =>
      'GET ${url.host}${url.path}${url.hasQuery ? '?${Uri.decodeQueryComponent(url.query)}' : ''}';

  /// The body of the 200 answer to a read of [url], after the retries.
  Future<String> _read(Uri url, String request, String accept) async {
    var rateWaits = 0;
    for (var attempt = 0; ; attempt++) {
      final clock = Stopwatch()..start();
      int? status;
      var body = '';
      Map<String, String> headers = const {};
      String outcome;
      try {
        (status, headers, body) = await _http(url, accept);
        outcome = 'HTTP $status';
      } on TimeoutException {
        outcome =
            'no answer within ${timeout.inMilliseconds % 1000 == 0 ? '${timeout.inSeconds} s' : '${timeout.inMilliseconds} ms'}';
      } on IOException catch (e) {
        // The message only: an HttpException's toString carries the URL.
        outcome = switch (e) {
          SocketException(:final osError?) => osError.message,
          SocketException(:final message) => message,
          TlsException(:final message, :final osError) =>
            '$message${osError == null ? '' : ': ${osError.message}'}',
          HttpException(:final message) => message,
          _ => e.runtimeType.toString(),
        };
      }
      final limit = status == null ? null : _rateLimit(status, headers, body);
      final retry =
          (status == null || status >= 500) && attempt < retryDelays.length;
      final waitForLimit =
          limit != null &&
          limit <= maxRateWait &&
          rateWaits < maxRateRetries &&
          !retry;
      log?.call(
        '${_shown(url)}: $outcome, ${clock.elapsedMilliseconds} ms'
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
      if (status == 200) {
        return body;
      }
      throw _refusal(status, request, outcome, body);
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
    Uri url,
    String accept,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      // As the App Store Connect client: HTTPS_PROXY and NO_PROXY apply. TLS still runs end to end.
      ..findProxy = HttpClient.findProxyFromEnvironment
      ..userAgent = 'wincode';
    try {
      return await () async {
        final request = await client.getUrl(url);
        request.followRedirects = false;
        request.headers
          ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
          ..set(HttpHeaders.acceptHeader, accept)
          ..set('X-GitHub-Api-Version', githubApiVersion);
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

/// The failure of a request to GitHub as a message, in the form of ADR-0013 (section 6). [what] says what the request
/// was for, such as `read example-org/example-app`.
WincodeException githubProblem(GithubException e, {required String what}) {
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
          'GH_TOKEN, and run the command again. Nothing was started.',
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
          'approve it. Nothing was started.',
    ),
    GithubFailure.rateLimited => WincodeException(
      ExitCode.unavailable,
      'github-rate-limited',
      'GitHub is limiting the requests of this token: ${e.message}',
      why:
          'a token has a number of requests an hour, and GitHub says it clears in '
          '${e.retryAfter == null ? 'a while' : _wait(e.retryAfter!)}, which is longer than winCode waits.',
      next: 'run the command again after that. Nothing was started.',
    ),
    GithubFailure.offline => WincodeException(
      ExitCode.unavailable,
      'offline',
      'cannot reach api.github.com: ${e.message}',
      why: "there is no network, a proxy or a firewall is in the way, or GitHub's service is down.",
      next:
          "check the connection (and HTTPS_PROXY, if you use one) and GitHub's status page, then run the command "
          'again. Nothing was started.',
    ),
    GithubFailure.unavailable => WincodeException(
      ExitCode.unavailable,
      'github-unavailable',
      'GitHub kept answering ${e.request} with ${e.message}',
      why: "GitHub's service is down or overloaded.",
      next: "check GitHub's status page, then run the command again. Nothing was started.",
    ),
    GithubFailure.notFound ||
    GithubFailure.unprocessable ||
    GithubFailure.refused => WincodeException(
      ExitCode.failed,
      'github-error',
      "GitHub's answer to ${e.request} is not what wincode build expects: ${e.message}",
      why:
          'wincode build sends only read requests that GitHub documents, to $what, so this answer is unexpected.',
      next:
          'run the command again with --verbose --redact; if the answer comes again, report it with that output at '
          'https://github.com/wincode-org/wincode/issues. Nothing was started.',
    ),
  };
}

String _wait(Duration d) => d.inMinutes >= 1
    ? '${d.inMinutes} minute${d.inMinutes == 1 ? '' : 's'}'
    : '${d.inSeconds} seconds';
