/// GitHub's REST API on 127.0.0.1, for tests: a server that answers in the shapes of the real one, and a made-up
/// repository with a Flutter project in it. Not for use outside tests.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One request that [FakeGithub] received.
class GhRequest {
  GhRequest({
    required this.method,
    required this.path,
    required this.query,
    required this.headers,
  });

  final String method;
  final String path;
  final Map<String, String> query;

  /// The headers, with their names in lower case.
  final Map<String, String> headers;

  /// The token of the `Authorization: Bearer` header, or null.
  String? get token => (headers['authorization'] ?? '').startsWith('Bearer ')
      ? headers['authorization']!.substring('Bearer '.length)
      : null;

  @override
  String toString() =>
      '$method $path${query.isEmpty ? '' : '?${Uri(queryParameters: query).query}'}';
}

/// What [FakeGithub] answers to one request.
class GhAnswer {
  const GhAnswer(
    this.json, {
    this.status = 200,
    this.headers = const {},
    this.raw,
  });

  /// [text] as it is, as the Contents API gives a file.
  const GhAnswer.text(String text) : this(null, raw: text);

  /// GitHub's 404.
  const GhAnswer.notFound()
    : this(const {
        'message': 'Not Found',
        'documentation_url': 'https://docs.github.com/rest',
        'status': '404',
      }, status: 404);

  /// An error with [status] and GitHub's own [message].
  GhAnswer.error(int status, String message, {Map<String, String>? headers})
    : this({'message': message}, status: status, headers: headers ?? const {});

  final Object? json;
  final int status;
  final Map<String, String> headers;
  final String? raw;
}

/// GitHub on 127.0.0.1: [answer] decides what each request gets, and [requests] records them. With [token], a request
/// that does not carry it gets 401, as from GitHub.
class FakeGithub {
  FakeGithub._(this._server, this.answer, this.token) {
    _server.listen(_handle);
  }

  static Future<FakeGithub> start(
    FutureOr<GhAnswer> Function(GhRequest request) answer, {
    String? token,
  }) async => FakeGithub._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    answer,
    token,
  );

  final HttpServer _server;
  final FutureOr<GhAnswer> Function(GhRequest request) answer;
  final String? token;
  final requests = <GhRequest>[];

  /// The base URL of the API, such as `http://127.0.0.1:1234`.
  Uri get uri => Uri.http('${_server.address.address}:${_server.port}');

  Future<void> _handle(HttpRequest request) async {
    final headers = <String, String>{};
    request.headers.forEach(
      (name, values) => headers[name.toLowerCase()] = values.join(', '),
    );
    final received = GhRequest(
      method: request.method,
      path: request.uri.path,
      query: request.uri.queryParameters,
      headers: headers,
    );
    requests.add(received);
    final given = token == null || received.token == token
        ? await answer(received)
        : GhAnswer.error(401, 'Bad credentials');
    try {
      request.response.statusCode = given.status;
      given.headers.forEach(request.response.headers.set);
      request.response.headers.contentType = given.raw == null
          ? ContentType.json
          : ContentType.text;
      request.response.write(given.raw ?? jsonEncode(given.json));
      await request.response.close();
    } on Object {
      // The client gave up waiting.
    }
  }

  Future<void> close() => _server.close(force: true);
}

/// The workflow file of the made-up repository: contract 2, the seven inputs of `wincode build`, Xcode 26.6.
const workflowText = '''
# wincode-workflow-contract: 2
name: wincode-ios
run-name: wincode \${{ inputs.request_id }}

on:
  workflow_dispatch:
    inputs:
      request_id:
        description: Set by wincode build
        required: true
        type: string
      build_name:
        required: true
        type: string
      build_number:
        required: true
        type: string
      flutter_version:
        required: true
        type: string
      min_xcode_version:
        required: true
        type: string
      flavor:
        required: false
        type: string
        default: ""
      target:
        required: false
        type: string
        default: ""

permissions:
  contents: read

jobs:
  unsigned-ipa:
    runs-on: macos-26
    timeout-minutes: 45
    env:
      XCODE_APP: /Applications/Xcode_26.6.app
    steps:
      - run: echo build
''';

String _pubspec(String environment) =>
    'name: demo\nversion: 2.3.0+57\nenvironment:\n  sdk: ^3.5.0\n$environment';

/// A made-up GitHub repository with a Flutter project in it, and the routes of GitHub's API that `wincode build` reads.
/// A test changes [files], [schemes] and the other fields before it runs, to make one thing wrong.
///
/// The Xcode project is the flavored sample of `wincode_core` (flavors `alpha` and `beta`).
class FakeRepo {
  FakeRepo() {
    final sample = Directory('../wincode_core/test/fixtures/flavored_sample');
    for (final entity in sample.listSync(recursive: true)) {
      if (entity is File) {
        files[entity.path
            .substring(sample.path.length + 1)
            .replaceAll(r'\', '/')] = entity
            .readAsStringSync();
      }
    }
    files['pubspec.yaml'] = _pubspec('  flutter: ">=3.27.0 <4.0.0"\n');
    files['.github/workflows/wincode-ios.yml'] = workflowText;
    for (final f in ['lib/main.dart', 'lib/main_alpha.dart']) {
      files[f] = 'void main() {}\n';
    }
  }

  String owner = 'example-org';
  String name = 'example-app';
  bool isPrivate = true;
  String defaultBranch = 'main';

  /// The commit that `main` points to, and the one a tag `v1` points to.
  String commit = '1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d';
  String tree = 'f6a02bb33f00397012764b451153e6ab987f01e5';

  /// The files of the commit, by path. A file that is only listed (a scheme) has an empty text.
  final files = <String, String>{};

  /// The shared schemes of the project, which [tree] lists as `.xcscheme` files.
  List<String> schemes = ['Runner', 'Alpha', 'Beta'];

  /// The state GitHub reports for the workflow, and whether it is on the default branch at all.
  String workflowState = 'active';
  bool workflowExists = true;

  /// The refs (branches and tags) and the commit each points to.
  late final refs = <String, String>{'main': commit};

  /// The tags of `flutter/flutter`.
  final flutterTags = <String>{'3.47.7', '3.48.0-0.1.pre'};

  /// The runs that the workflow's list shows: `id`, `display_title`, `status`, `conclusion`, `event`, `created_at`.
  final runs = <Map<String, Object?>>[];

  /// Whether the tree listing says it was cut short.
  bool truncated = false;

  /// What each file name answers instead of the file, by path: for tests of a failing read.
  final failing = <String, GhAnswer>{};

  String get _repo => '/repos/$owner/$name';

  Map<String, String> get _allFiles => {
    ...files,
    for (final s in schemes)
      'ios/Runner.xcodeproj/xcshareddata/xcschemes/$s.xcscheme': '',
  };

  /// The answer to [r].
  GhAnswer call(GhRequest r) {
    final path = r.path;
    if (path == '/repos/flutter/flutter/git/ref/tags/${path.split('/').last}') {
      final tag = path.split('/').last;
      return flutterTags.contains(tag)
          ? GhAnswer({
              'ref': 'refs/tags/$tag',
              'object': {'type': 'commit', 'sha': 'a' * 40},
            })
          : const GhAnswer.notFound();
    }
    if (path == _repo) {
      return GhAnswer({
        'full_name': '$owner/$name',
        'private': isPrivate,
        'visibility': isPrivate ? 'private' : 'public',
        'default_branch': defaultBranch,
        'archived': false,
        'disabled': false,
      });
    }
    const workflowFile = 'wincode-ios.yml';
    if (path == '$_repo/actions/workflows/$workflowFile') {
      return workflowExists
          ? GhAnswer({
              'id': 419286522,
              'name': 'wincode-ios',
              'path': '.github/workflows/$workflowFile',
              'state': workflowState,
            })
          : const GhAnswer.notFound();
    }
    if (path == '$_repo/actions/workflows/$workflowFile/runs') {
      return _runs(r);
    }
    if (path.startsWith('$_repo/commits/')) {
      final ref = path.substring('$_repo/commits/'.length);
      final sha = refs[ref] ?? (ref == commit ? commit : null);
      return sha == null
          ? const GhAnswer.notFound()
          : GhAnswer({
              'sha': sha,
              'commit': {
                'tree': {'sha': tree},
                'message': 'a commit',
              },
            });
    }
    if (path == '$_repo/git/trees/$tree') {
      final entries = <Map<String, Object?>>[];
      final seen = <String>{};
      for (final MapEntry(:key, :value) in _allFiles.entries) {
        final parts = key.split('/');
        for (var i = 1; i < parts.length; i++) {
          final dir = parts.sublist(0, i).join('/');
          if (seen.add(dir)) {
            entries.add({'path': dir, 'type': 'tree', 'sha': 'b' * 40});
          }
        }
        entries.add({
          'path': key,
          'type': 'blob',
          'size': value.length,
          'sha': 'c' * 40,
        });
      }
      return GhAnswer({'sha': tree, 'truncated': truncated, 'tree': entries});
    }
    if (path.startsWith('$_repo/contents/')) {
      final file = path.substring('$_repo/contents/'.length);
      if (r.query['ref'] != commit) {
        return GhAnswer.error(
          404,
          'No commit found for the ref ${r.query['ref']}',
        );
      }
      return failing[file] ??
          (_allFiles.containsKey(file)
              ? GhAnswer.text(_allFiles[file]!)
              : const GhAnswer.notFound());
    }
    return const GhAnswer.notFound();
  }

  GhAnswer _runs(GhRequest r) {
    final since = DateTime.tryParse(
      (r.query['created'] ?? '').replaceFirst('>=', ''),
    );
    final matching = [
      for (final run in runs)
        if ((r.query['event'] == null || run['event'] == r.query['event']) &&
            (since == null ||
                !DateTime.parse('${run['created_at']}').isBefore(since)))
          run,
    ];
    final per = int.parse(r.query['per_page'] ?? '30');
    final page = int.parse(r.query['page'] ?? '1');
    return GhAnswer({
      'total_count': matching.length,
      'workflow_runs': matching.skip((page - 1) * per).take(per).toList(),
    });
  }
}

/// A run of the workflow as GitHub lists it, named `wincode <request ID>`.
Map<String, Object?> fakeRun(
  int id,
  String requestId, {
  String status = 'completed',
  String? conclusion = 'success',
  DateTime? created,
  String event = 'workflow_dispatch',
}) => {
  'id': id,
  'name': 'wincode $requestId',
  'display_title': 'wincode $requestId',
  'status': status,
  'conclusion': conclusion,
  'event': event,
  'created_at': (created ?? DateTime.utc(2026, 11, 15, 10)).toIso8601String(),
  'html_url': 'https://github.com/example-org/example-app/actions/runs/$id',
};
