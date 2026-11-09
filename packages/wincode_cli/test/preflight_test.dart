import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wincode_asc/testing.dart';
import 'package:wincode_asc/wincode_asc.dart';
import 'package:wincode_cli/src/preflight.dart' show buildNumberFindings;
import 'package:wincode_cli/wincode_cli.dart';
import 'package:wincode_core/testing.dart';
import 'package:wincode_core/wincode_core.dart' show PlistMap, writePlistBinary;

/// The time of every run: the tokens, the expiry dates and the fake server's check of the tokens use it.
final _now = DateTime.utc(2026, 11, 9, 12);

/// When the profiles of the fixture expire, unless a test says otherwise.
final _expires = _now.add(const Duration(days: 300));

const _bundleId = 'com.example.app';
const _teamId = 'TEAM000000';
const _keyId = 'ABCDE12345';

/// Apple's IDs of the app record and of the App ID in the fake App Store Connect.
const _appRecord = '1000000001';
const _appIdResource = 'BUNDLEID01';

/// [time] as App Store Connect writes it, such as 2027-09-05T12:00:00.000+0000.
String _appleDate(DateTime time) =>
    '${time.toUtc().toIso8601String().substring(0, 23)}+0000';

/// App Store Connect with the app record of com.example.app and its [builds], its App ID, a development profile, and an
/// active App Store profile that expires at [expires].
FakeAnswer Function(FakeRequest) _appStore({
  List<String> builds = const ['11', '12'],
  DateTime? expires,
}) =>
    (request) => switch (request.path) {
      '/v1/apps' => FakeAnswer.page([
        fakeResource('apps', _appRecord, {'bundleId': _bundleId}),
      ]),
      '/v1/apps/1000000001/builds' => FakeAnswer.page([
        for (final (i, version) in builds.indexed)
          fakeResource('builds', 'build-$i', {
            'version': version,
            'processingState': 'VALID',
          }),
      ]),
      '/v1/bundleIds' => FakeAnswer.page([
        fakeResource('bundleIds', _appIdResource, {
          'identifier': _bundleId,
          'platform': 'IOS',
        }),
      ]),
      '/v1/bundleIds/BUNDLEID01/profiles' => FakeAnswer.page([
        fakeResource('profiles', 'profile-1', {
          'profileType': 'IOS_APP_DEVELOPMENT',
          'profileState': 'ACTIVE',
          'expirationDate': _appleDate(_now.add(const Duration(days: 400))),
        }),
        fakeResource('profiles', 'profile-2', {
          'profileType': 'IOS_APP_STORE',
          'profileState': 'ACTIVE',
          'expirationDate': _appleDate(expires ?? _expires),
        }),
      ]),
      _ => FakeAnswer.error(404, 'NOT_FOUND'),
    };

PlistMap _profile({
  String teamId = _teamId,
  DateTime? expires,
  bool devices = false,
}) => appStoreProfile(
  teamId: teamId,
  bundleId: _bundleId,
  expires: expires ?? _expires,
  devices: devices,
);

/// An IPA as zsign signs one: the app's Info.plist, a framework's, the embedded App Store profile, and the executable
/// signed as [signedAs]. Without [signed], it has neither the profile nor a signature.
List<int> _ipa({
  String bundleId = _bundleId,
  String build = '13',
  String signedAs = '$_teamId.$_bundleId',
  bool signed = true,
}) => zipOf({
  'Payload/': [],
  'Payload/Runner.app/': [],
  'Payload/Runner.app/Info.plist': writePlistBinary({
    'CFBundleExecutable': 'Runner',
    'CFBundleIdentifier': bundleId,
    'CFBundleShortVersionString': '1.0.0',
    'CFBundleVersion': build,
  }),
  // As in the script's self-test: a framework's Info.plist is not the app's.
  'Payload/Runner.app/Frameworks/App.framework/Info.plist': writePlistBinary({
    'CFBundleIdentifier': 'io.flutter.flutter.app',
    'CFBundleVersion': '99',
  }),
  'Payload/Runner.app/Runner': executable(
    signed: signed,
    entitlements: signed
        ? {
            'application-identifier': signedAs,
            'com.apple.developer.team-identifier': _teamId,
            'get-task-allow': false,
          }
        : null,
  ),
  if (signed)
    'Payload/Runner.app/embedded.mobileprovision': profileOf(_profile()),
});

/// Compares [actual] with test/goldens/[name]; UPDATE_GOLDENS=1 rewrites the file.
void _expectGolden(String name, String actual) {
  final golden = File('test/goldens/$name');
  if (Platform.environment['UPDATE_GOLDENS'] != null) {
    golden.writeAsStringSync(actual);
  }
  expect(actual, golden.readAsStringSync().replaceAll('\r\n', '\n'));
}

void main() {
  late Directory temp;
  late Directory keys;
  late ThrowawayKey key;
  late String issuer;
  late File config;
  late File profile;
  late File ipa;
  FakeAppStoreConnect? apple;

  String inside(Directory folder, String name) =>
      '${folder.path}${Platform.pathSeparator}$name';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('wincode_preflight_');
    key = ThrowawayKey();
    final random = Random.secure();
    String hex(int length) =>
        [for (var i = 0; i < length; i++) random.nextInt(16).toRadixString(16)]
            .join();
    issuer = [hex(8), hex(4), hex(4), hex(4), hex(12)].join('-');
    keys = Directory(inside(temp, 'asc'))..createSync();
    File(inside(keys, 'AuthKey_$_keyId.p8')).writeAsStringSync(key.pem());
    File(inside(keys, 'issuer-id')).writeAsStringSync('$issuer\r\n');
    final app = Directory(inside(temp, 'app'))..createSync();
    config = File(inside(app, 'wincode.yaml'))
      ..writeAsStringSync(
        [
          'bundle_id: $_bundleId',
          'team_id: $_teamId',
          'profile: App_Store.mobileprovision',
          'output: build',
          '',
        ].join('\r\n'),
      );
    profile = File(inside(app, 'App_Store.mobileprovision'))
      ..writeAsBytesSync(profileOf(_profile()));
    final output = Directory(inside(app, 'build'))..createSync();
    ipa = File(inside(output, 'signed.ipa'))..writeAsBytesSync(_ipa());
  });

  tearDown(() async {
    await apple?.close();
    apple = null;
    temp.deleteSync(recursive: true);
  });

  /// Runs `wincode preflight` with [args] against a fake App Store Connect that [answer] drives and that knows
  /// [appleKey] (by default the key of the test), and checks that no secret reached the output. Returns the exit code,
  /// stdout and stderr.
  Future<(int, String, String)> preflight(
    List<String> args, {
    FakeAnswer Function(FakeRequest)? answer,
    ThrowawayKey? appleKey,
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    await apple?.close();
    final server = apple = await FakeAppStoreConnect.start(
      answer ?? _appStore(),
      key: appleKey ?? key,
      now: () => _now,
    );
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runWincode(
      ['preflight', '--config', config.path, ...args],
      out,
      err,
      environment: environment ?? {'WINCODE_ASC_KEY_DIR': keys.path},
      clock: () => _now,
      connect: (token, log) => HttpAscClient(
        api: server.uri,
        token: token,
        log: log,
        timeout: timeout,
        retryDelays: const [
          Duration(milliseconds: 1),
          Duration(milliseconds: 1),
        ],
      ),
    );
    final printed = '$out$err';
    final secrets = {
      'the Key ID': _keyId,
      'the Issuer ID': issuer,
      'the key folder': keys.path,
      'the key': key.pem().split('\r\n')[1],
      for (final (i, request) in server.requests.indexed)
        'token $i': request.authorization!.substring('Bearer '.length),
      'a token, redacted': '<token>',
    };
    for (final MapEntry(key: what, value: secret) in secrets.entries) {
      expect(printed, isNot(contains(secret)), reason: '$what was printed');
    }
    return (code, '$out', '$err');
  }

  test('the report, its messages and the dry run are test/goldens/preflight.txt (UPDATE_GOLDENS=1 rewrites it)', () async {
    final report = StringBuffer();
    Future<void> run(
      String setup,
      List<String> args, {
      Map<String, String>? environment,
    }) async {
      final (code, out, err) = await preflight(args, environment: environment);
      expect(err, '', reason: setup);
      report
        ..writeln('# $setup')
        ..writeln(['\$ wincode preflight', ...args].join(' '))
        ..writeln(out)
        ..writeln('exit $code')
        ..writeln();
    }

    await run(
      'App Store Connect has builds 11 and 12; the IPA is build 13',
      [],
    );
    ipa.writeAsBytesSync(_ipa(bundleId: 'com.example.app.beta', build: '12'));
    profile.writeAsBytesSync(
      profileOf(_profile(expires: _now.add(const Duration(days: 20)))),
    );
    await run(
      'the IPA is build 12 of com.example.app.beta; the profile expires in 20 days',
      ['--redact'],
    );
    await run('the requests, as asc_preflight.py --dry-run prints them', [
      '--dry-run',
      '--redact',
    ]);
    expect(apple!.requests, isEmpty);
    await run('without WINCODE_ASC_KEY_DIR', [
      '--dry-run',
    ], environment: const {});
    expect(apple!.requests, isEmpty);
    _expectGolden('preflight.txt', '$report');
  });

  test('--json prints one object on stdout, test/goldens/preflight.json, and the report on stderr', () async {
    profile.writeAsBytesSync(
      profileOf(_profile(expires: _now.add(const Duration(days: 20)))),
    );
    final (code, out, err) = await preflight([
      '--json',
    ], answer: _appStore(builds: ['13']));
    expect(code, 1);
    expect(out.split('\n'), [isNotEmpty, '']);
    _expectGolden(
      'preflight.json',
      '${const JsonEncoder.withIndent('  ').convert(jsonDecode(out))}\n',
    );
    expect(err, contains('FAIL  build 13 is not higher than 13'));
    expect(err, endsWith('wincode preflight: 1 check failed\n'));

    final (_, dry, _) = await preflight(['--json', '--dry-run']);
    expect(jsonDecode(dry), {
      'command': 'preflight',
      'ok': true,
      'exitCode': 0,
      'dryRun': true,
      'requests': hasLength(4),
    });
  });

  group('against a fake App Store Connect', () {
    test(
      'a build above every existing one passes, with GET requests only',
      () async {
        final (code, out, err) = await preflight([]);
        expect((code, err), (0, ''));
        expect(out, endsWith('\nwincode preflight: passed\n'));
        expect(
          [for (final r in apple!.requests) '${r.method} ${r.path}'],
          [
            'GET /v1/apps',
            'GET /v1/apps/1000000001/builds',
            'GET /v1/bundleIds',
            'GET /v1/bundleIds/BUNDLEID01/profiles',
          ],
        );
      },
    );

    test('the first build of an app passes', () async {
      final (code, out, _) = await preflight([], answer: _appStore(builds: []));
      expect(code, 0);
      expect(
        out,
        contains(
          'INFO  0 existing builds, highest build number none\n'
          'PASS  build 13 is the first build of this app\n',
        ),
      );
    });

    test('a build number equal to or below an existing one fails', () async {
      for (final builds in [
        ['13'],
        ['14', '2'],
      ]) {
        final (code, out, _) = await preflight(
          [],
          answer: _appStore(builds: builds),
        );
        expect(code, 1, reason: '$builds');
        expect(
          out,
          contains(
            'FAIL  build 13 is not higher than ${builds.first}, the highest build App Store Connect has for this '
            'app\n',
          ),
        );
      }
    });

    test(
      'a key that Apple refuses fails with 77, and nothing more is asked',
      () async {
        final (code, out, _) = await preflight([], appleKey: ThrowawayKey());
        expect(code, 77);
        expect(
          out,
          contains(
            'FAIL  App Store Connect refused the API key: HTTP 401 NOT_AUTHORIZED: A made-up detail for '
            'NOT_AUTHORIZED.\n',
          ),
        );
        expect(apple!.requests, hasLength(1));
        expect(out, contains('PASS  the IPA holds com.example.app'));
      },
    );

    test('a key whose role may not read App IDs fails with 77, after the checks it could make', () async {
      final (code, out, _) = await preflight(
        [],
        answer: (r) => r.path == '/v1/bundleIds'
            ? FakeAnswer.error(403, 'FORBIDDEN_ERROR')
            : _appStore()(r),
      );
      expect(code, 77);
      expect(out, contains('PASS  build 13 is higher than 12'));
      expect(
        out,
        contains(
          'FAIL  App Store Connect refused GET /v1/bundleIds to the API key: HTTP 403 FORBIDDEN_ERROR: A made-up '
          'detail for FORBIDDEN_ERROR.\n',
        ),
      );
    });

    test('an answer of HTTP 503 is asked again', () async {
      var first = true;
      final (code, _, _) = await preflight(
        [],
        answer: (r) {
          if (first) {
            first = false;
            return FakeAnswer.error(503, 'SERVICE_UNAVAILABLE');
          }
          return _appStore()(r);
        },
      );
      expect(code, 0);
      expect(
        [for (final r in apple!.requests.take(2)) r.path],
        ['/v1/apps', '/v1/apps'],
      );
    });

    test(
      'no answer within the timeout is offline (69), after two more tries',
      () async {
        final (code, out, _) = await preflight(
          [],
          answer: (_) => const FakeAnswer(null, delay: Duration(seconds: 2)),
          timeout: const Duration(milliseconds: 300),
        );
        expect(code, 69);
        expect(
          out,
          contains(
            'FAIL  cannot reach api.appstoreconnect.apple.com: no answer within 300 ms\n',
          ),
        );
        expect(apple!.requests, hasLength(3));
      },
    );
  });

  group('on this PC', () {
    test('an expired profile fails', () async {
      profile.writeAsBytesSync(
        profileOf(_profile(expires: _now.subtract(const Duration(days: 1)))),
      );
      final (code, out, _) = await preflight([]);
      expect(code, 1);
      expect(
        out,
        contains(
          'FAIL  the profile in wincode.yaml expired on 2026-11-08\n'
          '  why: Apple refuses a build signed with an expired profile.\n',
        ),
      );
    });

    test(
      'a profile that expires in 20 days is a warning, and the run passes',
      () async {
        profile.writeAsBytesSync(
          profileOf(_profile(expires: _now.add(const Duration(days: 20)))),
        );
        final (code, out, _) = await preflight([]);
        expect(code, 0);
        expect(
          out,
          contains(
            'WARN  the profile in wincode.yaml expires on 2026-11-29, in 20 days\n',
          ),
        );
        expect(out, endsWith('wincode preflight: passed, with 1 warning\n'));
      },
    );

    test(
      'a profile of another team, or not for the App Store, fails',
      () async {
        for (final (plist, id) in [
          (_profile(teamId: 'OTHER00000'), 'profile-team-mismatch'),
          (_profile(devices: true), 'profile-not-app-store'),
        ]) {
          profile.writeAsBytesSync(profileOf(plist));
          final (code, out, _) = await preflight(['--json']);
          expect(code, 1, reason: id);
          expect(
            (jsonDecode(out) as Map<String, Object?>)['error'],
            containsPair('id', id),
          );
        }
      },
    );

    test('an IPA of another bundle ID fails', () async {
      ipa.writeAsBytesSync(_ipa(bundleId: 'com.example.app.beta'));
      final (code, out, _) = await preflight([]);
      expect(code, 1);
      expect(
        out,
        contains(
          "FAIL  the IPA's bundle ID is com.example.app.beta, but wincode.yaml says com.example.app\n",
        ),
      );
    });

    test(
      'a file that is not an IPA fails, and its build number is not compared',
      () async {
        ipa.writeAsStringSync('not a zip archive');
        final (code, out, _) = await preflight([]);
        expect(code, 1);
        expect(
          out,
          contains(
            'FAIL  signed.ipa cannot be read as an IPA: not a zip archive\n',
          ),
        );
        expect(
          out,
          contains(
            'INFO  the build number was not compared: the IPA has none that can be read (ipa)\n',
          ),
        );
      },
    );

    test(
      'a build number that is not one fails, even before the first build',
      () async {
        ipa.writeAsBytesSync(_ipa(build: '13a'));
        final (code, out, _) = await preflight(
          [],
          answer: _appStore(builds: []),
        );
        expect(code, 1);
        expect(
          out,
          contains(
            "FAIL  the IPA's build number is 13a, which is not one to three numbers joined by dots\n",
          ),
        );
      },
    );

    test(
      'an IPA signed for another app fails, and an unsigned one is reported',
      () async {
        ipa.writeAsBytesSync(_ipa(signedAs: '$_teamId.com.example.other'));
        final (code, out, _) = await preflight([]);
        expect(code, 1);
        expect(
          out,
          contains(
            "FAIL  the IPA's executable is signed as TEAM000000.com.example.other, but wincode.yaml says "
            'TEAM000000.com.example.app\n',
          ),
        );

        ipa.writeAsBytesSync(_ipa(signed: false));
        final (unsigned, report, _) = await preflight([]);
        expect(unsigned, 0);
        expect(
          report,
          contains('INFO  the IPA holds no embedded.mobileprovision'),
        );
      },
    );

    test('another IPA can be named, and only one', () async {
      final other = File(inside(temp, 'other.ipa'))
        ..writeAsBytesSync(_ipa(build: '14'));
      final (code, out, _) = await preflight([other.path]);
      expect(code, 0);
      expect(out, contains('PASS  build 14 is higher than 12'));
      final (usage, _, err) = await preflight([other.path, ipa.path]);
      expect(usage, 64);
      expect(err, startsWith('Give at most one IPA.\n'));
    });

    test('a missing wincode.yaml is a setup error (78)', () async {
      config.deleteSync();
      final (code, _, err) = await preflight([]);
      expect(code, 78);
      expect(err, contains('wincode.yaml does not exist'));
      expect(apple!.requests, isEmpty);
    });
  });

  group('the key', () {
    Future<void> git(List<String> args) async {
      final result = await Process.run('git', ['-C', temp.path, ...args]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }

    test('in a git working tree, tracked or not ignored, is refused (78) before it is read, and nothing is sent', () async {
      await git(['init', '-q']);
      for (final tracked in [false, true]) {
        if (tracked) {
          await git(['add', 'asc']);
        }
        final (code, out, _) = await preflight([]);
        expect(code, 78, reason: 'tracked: $tracked');
        expect(
          out,
          startsWith(
            'FAIL  WINCODE_ASC_KEY_DIR points inside a git working tree, and git does not ignore the file\n',
          ),
        );
        expect(apple!.requests, isEmpty);
        expect(out, contains('PASS  the IPA holds com.example.app'));
      }
      File(inside(temp, '.gitignore')).writeAsStringSync('asc/\napp/\n');
      await git(['rm', '-r', '-q', '--cached', 'asc']);
      final (ignored, _, _) = await preflight([]);
      expect(ignored, 0);
    });

    test('is a setup error (78) when it is missing or not a key', () async {
      final (unset, out, _) = await preflight([], environment: const {});
      expect(unset, 78);
      expect(out, startsWith('FAIL  WINCODE_ASC_KEY_DIR is not set\n'));
      expect(out, contains('PASS  the IPA holds com.example.app'));

      File(inside(keys, 'AuthKey_$_keyId.p8'))
          .writeAsStringSync('not a key\r\n');
      final (broken, report, _) = await preflight([]);
      expect(broken, 78);
      expect(
        report,
        contains(
          'FAIL  the .p8 in WINCODE_ASC_KEY_DIR is not an App Store Connect API key\n',
        ),
      );
      expect(apple!.requests, isEmpty);
    });
  });

  test(
    '--redact and CI hide every ID in the report and the --verbose lines',
    () async {
      ipa.writeAsBytesSync(
        _ipa(
          bundleId: 'com.example.app.beta',
          signedAs: 'OTHER00000.com.example.app.beta',
        ),
      );
      for (final (args, environment) in [
        (['--redact', '--verbose'], {'WINCODE_ASC_KEY_DIR': keys.path}),
        (['--verbose'], {'WINCODE_ASC_KEY_DIR': keys.path, 'CI': 'true'}),
      ]) {
        final (code, out, err) = await preflight(
          args,
          environment: environment,
        );
        expect(code, 1);
        final printed = '$out$err';
        for (final id in [
          'com.example',
          _teamId,
          'OTHER00000',
          _appRecord,
          _appIdResource,
        ]) {
          expect(printed, isNot(contains(id)), reason: '$id in $args');
        }
        for (final placeholder in [
          '<bundle ID>',
          '<other bundle ID>',
          '<team ID>',
          '<other team ID>',
          '/v1/apps/{id of the app record}/builds',
          '/v1/bundleIds/{id of the App ID}/profiles',
        ]) {
          expect(printed, contains(placeholder), reason: '$args');
        }
        expect(err, isNot(contains('Bearer')));
      }
    },
  );

  test(
    'the build number is compared as the spike script compares it (PR #11)',
    () {
      List<AscResource> fake(List<String> versions) => [
        for (final (i, version) in versions.indexed)
          fakeResource('builds', '$i', {'version': version}),
      ];
      for (final (versions, mine, info, verdict) in [
        // The first upload.
        (
          <String>[],
          '1',
          '0 existing builds, highest build number none',
          'PASS',
        ),
        // All lower: 10 beats 9 as a number, not as text.
        (
          ['1', '9', '10'],
          '11',
          '3 existing builds, highest build number 10',
          'PASS',
        ),
        // Equal.
        (
          ['1', '13'],
          '13',
          '2 existing builds, highest build number 13',
          'FAIL',
        ),
        // An existing build is higher.
        (
          ['14', '2'],
          '13',
          '2 existing builds, highest build number 14',
          'FAIL',
        ),
        // Dotted.
        (
          ['1.2.3'],
          '1.2.4',
          '1 existing builds, highest build number 1.2.3',
          'PASS',
        ),
        // A longer number with the same start is higher, as Python compares tuples.
        (
          ['1.2'],
          '1.2.0',
          '1 existing builds, highest build number 1.2',
          'PASS',
        ),
        // An existing build whose number is not one is left out, but counted.
        (['3', 'x'], '4', '2 existing builds, highest build number 3', 'PASS'),
        // Nothing to compare: no IPA, or a number that is not one, which the ipa check fails.
        (['3'], null, '1 existing builds, highest build number 3', 'INFO'),
      ]) {
        final [count, compared] = buildNumberFindings(fake(versions), mine);
        expect(
          (count.what, compared.status),
          (info, verdict),
          reason: '$mine against $versions',
        );
      }
    },
  );
}
