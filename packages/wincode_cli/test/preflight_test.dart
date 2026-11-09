import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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

/// Made-up profile UUIDs: the App Store profile of the fixture, its development profile, and one that nobody has.
const _uuid = '00000000-0000-0000-0000-0000000000a1';
const _developmentUuid = '00000000-0000-0000-0000-0000000000b2';
const _otherUuid = '00000000-0000-0000-0000-0000000000c3';

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
          'uuid': _developmentUuid,
          'expirationDate': _appleDate(_now.add(const Duration(days: 400))),
        }),
        fakeResource('profiles', 'profile-2', {
          'profileType': 'IOS_APP_STORE',
          'profileState': 'ACTIVE',
          'uuid': _uuid,
          'expirationDate': _appleDate(expires ?? _expires),
        }),
      ]),
      _ => FakeAnswer.error(404, 'NOT_FOUND'),
    };

PlistMap _profile({
  String teamId = _teamId,
  DateTime? expires,
  bool devices = false,
  String uuid = _uuid,
}) => appStoreProfile(
  teamId: teamId,
  bundleId: _bundleId,
  expires: expires ?? _expires,
  devices: devices,
  uuid: uuid,
);

/// An IPA as zsign signs one: the app's Info.plist, a framework's, the embedded App Store profile, and the executable
/// signed as [signedAs]. Without [signed], it has neither the profile nor a signature.
List<int> _ipa({
  String bundleId = _bundleId,
  String build = '13',
  String signedAs = '$_teamId.$_bundleId',
  bool signed = true,
  String profileUuid = _uuid,
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
    'Payload/Runner.app/embedded.mobileprovision': profileOf(
      _profile(uuid: profileUuid),
    ),
});

/// Compares [actual] with test/goldens/[name]; UPDATE_GOLDENS=1 rewrites the file.
void _expectGolden(String name, String actual) {
  final golden = File('test/goldens/$name');
  if (Platform.environment['UPDATE_GOLDENS'] != null) {
    golden.writeAsStringSync(actual);
  }
  expect(actual, golden.readAsStringSync().replaceAll('\r\n', '\n'));
}

/// [zip] with the field [at] bytes into the central directory header of [name] set to [value].
List<int> _patched(
  List<int> zip,
  String name,
  int at,
  int value, {
  int bytes = 4,
}) {
  final out = List<int>.of(zip);
  final wanted = name.codeUnits;
  for (var i = 0; i + 46 + wanted.length <= out.length; i++) {
    final header =
        out[i] == 0x50 &&
        out[i + 1] == 0x4B &&
        out[i + 2] == 1 &&
        out[i + 3] == 2;
    if (header &&
        String.fromCharCodes(out.sublist(i + 46, i + 46 + wanted.length)) ==
            name) {
      for (var b = 0; b < bytes; b++) {
        out[i + at + b] = value >> (8 * b) & 0xFF;
      }
      return out;
    }
  }
  throw StateError('no entry $name');
}

Map<String, Object?> _error(String out) =>
    (jsonDecode(out) as Map<String, Object?>)['error']! as Map<String, Object?>;

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
    profile.writeAsBytesSync(profileOf(_profile(uuid: _otherUuid)));
    ipa.writeAsBytesSync(_ipa());
    await run(
      'the profile in wincode.yaml is not a profile that App Store Connect has',
      [],
    );
    profile.writeAsBytesSync(profileOf(_profile()));
    ipa.writeAsBytesSync(_ipa(profileUuid: _otherUuid));
    await run(
      'the IPA was signed with another profile than wincode.yaml names',
      [],
    );
    ipa.writeAsBytesSync(_ipa(signed: false));
    await run('the IPA is not signed', []);
    ipa.writeAsBytesSync(
      zipOf({
        'Payload/Runner.app/Info.plist': [1],
        'Payload/Runner.app/../../evil': [1],
      }),
    );
    await run('the IPA has an entry named with ../', []);
    ipa.writeAsBytesSync(
      _patched(_ipa(), 'Payload/Runner.app/Info.plist', 24, 100 << 20),
    );
    await run('the IPA claims an Info.plist larger than the cap', []);
    profile.writeAsBytesSync(profileOf(_profile()));
    ipa.writeAsBytesSync(_ipa());
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

  group('the profile in three places', () {
    test(
      'the same profile in App Store Connect, wincode.yaml and the IPA passes',
      () async {
        final (code, out, _) = await preflight([]);
        expect(code, 0);
        expect(
          out,
          contains(
            'PASS  the profile in wincode.yaml is an active App Store profile of com.example.app in App Store '
            'Connect (same UUID)\n'
            'PASS  the IPA is signed with the profile in wincode.yaml (same UUID)\n',
          ),
        );
      },
    );

    test(
      'a profile file that App Store Connect does not have fails (1)',
      () async {
        profile.writeAsBytesSync(profileOf(_profile(uuid: _otherUuid)));
        ipa.writeAsBytesSync(_ipa(profileUuid: _otherUuid));
        final (code, out, _) = await preflight(['--json']);
        expect(code, 1);
        expect(_error(out), {
          'id': 'profile-uuid-mismatch',
          'what': 'the profile in wincode.yaml is not a profile of com.example.app in App Store Connect',
          'why': contains('refused'),
          'next': startsWith('download the current App Store profile'),
        });
      },
    );

    test(
      'a profile file that App Store Connect has as another type fails (1)',
      () async {
        profile.writeAsBytesSync(profileOf(_profile(uuid: _developmentUuid)));
        ipa.writeAsBytesSync(_ipa(profileUuid: _developmentUuid));
        final (code, out, _) = await preflight(['--json']);
        expect(code, 1);
        expect(_error(out), containsPair('id', 'profile-not-active'));
        expect(
          _error(out)['what'],
          'the profile in wincode.yaml is in App Store Connect as IOS_APP_DEVELOPMENT, ACTIVE, not as an active App '
          'Store profile',
        );
      },
    );

    test(
      'a signed IPA with another profile than wincode.yaml fails (1)',
      () async {
        ipa.writeAsBytesSync(_ipa(profileUuid: _otherUuid));
        final (code, out, _) = await preflight(['--json']);
        expect(code, 1);
        expect(_error(out), containsPair('id', 'ipa-profile-mismatch'));
        expect(
          _error(out)['what'],
          'the profile inside the IPA is not the profile in wincode.yaml',
        );
      },
    );

    test(
      'an unsigned IPA is an INFO, and the other two are still compared',
      () async {
        ipa.writeAsBytesSync(_ipa(signed: false));
        final (code, out, _) = await preflight([]);
        expect(code, 0);
        expect(out, contains('(same UUID)\n'));
        expect(
          out,
          contains(
            'INFO  the IPA is not signed, so the profile inside it was not compared\n',
          ),
        );
      },
    );

    test('without a profile in wincode.yaml, the IPA is compared with App Store Connect', () async {
      config.writeAsStringSync(
        'bundle_id: $_bundleId\nteam_id: $_teamId\noutput: build\n',
      );
      final (ok, out, _) = await preflight([]);
      expect(ok, 0);
      expect(
        out,
        contains(
          'PASS  the IPA is signed with an active App Store profile of com.example.app in App Store Connect '
          '(same UUID)\n',
        ),
      );
      ipa.writeAsBytesSync(_ipa(profileUuid: _otherUuid));
      final (code, json, _) = await preflight(['--json']);
      expect(code, 1);
      expect(_error(json), containsPair('id', 'ipa-profile-unknown'));
    });

    test('with too little to compare, it says so', () async {
      config.writeAsStringSync(
        'bundle_id: $_bundleId\nteam_id: $_teamId\noutput: build\n',
      );
      ipa.writeAsBytesSync(_ipa(signed: false));
      final (code, out, _) = await preflight([], environment: const {});
      expect(code, 78);
      expect(
        out,
        contains(
          'INFO  the IPA is not signed, so the profile inside it was not compared',
        ),
      );
    });

    test('no UUID is printed', () async {
      profile.writeAsBytesSync(profileOf(_profile(uuid: _otherUuid)));
      ipa.writeAsBytesSync(_ipa(profileUuid: _developmentUuid));
      final (_, out, err) = await preflight(['--verbose']);
      for (final uuid in [_uuid, _developmentUuid, _otherUuid]) {
        expect('$out$err', isNot(contains(uuid)));
      }
    });
  });

  group('a damaged IPA is a failure (1) with the format error, never an internal error (70)', () {
    const info = 'Payload/Runner.app/Info.plist';
    final two = {
      info: writePlistBinary({
        'CFBundleIdentifier': _bundleId,
        'CFBundleVersion': '13',
      }),
      'Payload/Runner.app/a.txt': [1, 2, 3],
      'Payload/Runner.app/b.txt': [4, 5, 6],
    };
    final whole = _ipa();
    final cases = <String, (List<int>, String)>{
      'cut short': (whole.sublist(0, whole.length - 30), 'not a zip archive'),
      'a Zip64 marker': (
        List<int>.of(whole)
          ..[whole.length - 12] = 0xFF
          ..[whole.length - 11] = 0xFF,
        'a Zip64 archive, which is not read here',
      ),
      'a name with ../': (
        zipOf({
          ...two,
          'Payload/Runner.app/../../evil': [1],
        }),
        'an entry is named "Payload/Runner.app/../../evil", which leaves its folder',
      ),
      'a duplicate name': (
        _patched(
          zipOf(two),
          'Payload/Runner.app/b.txt',
          46 + 'Payload/Runner.app/'.length,
          0x61,
          bytes: 1,
        ),
        'the entry "Payload/Runner.app/a.txt" occurs twice',
      ),
      'overlapping entries': (
        _patched(zipOf(two), 'Payload/Runner.app/b.txt', 42, 0),
        'the data of "Payload/Runner.app/Info.plist" overlap the next entry or the directory',
      ),
      'a claimed size above the cap': (
        _patched(whole, info, 24, 100 << 20),
        '$info asks for ${100 << 20} bytes, more than the ${64 << 20} that are read',
      ),
      'more data than the header says': (
        _patched(whole, info, 24, 4),
        '$info holds more than its header says',
      ),
    };
    for (final MapEntry(key: what, value: (bytes, part)) in cases.entries) {
      test(what, () async {
        ipa.writeAsBytesSync(bytes);
        final (code, out, err) = await preflight(['--json']);
        expect(code, 1);
        expect(err, contains('FAIL  signed.ipa cannot be read as an IPA: '));
        expect(err, isNot(contains('internal error')));
        expect(_error(out), containsPair('id', 'ipa-unreadable'));
        expect(
          _error(out)['what'],
          'signed.ipa cannot be read as an IPA: $part',
        );
      });
    }

    test(
      'a large executable is read only at its header and its signature',
      () async {
        // 65 MiB of zeros between the header and the signature, more than ZipArchive.read keeps: a few kilobytes
        // deflated. Only readRange can get at the signature.
        final signed = executable(
          entitlements: {
            'application-identifier': '$_teamId.$_bundleId',
            'get-task-allow': false,
          },
        );
        const padding = 65 << 20;
        final big = BytesBuilder(copy: false)
          ..add(signed.sublist(0, 64))
          ..add(Uint8List(padding))
          ..add(signed.sublist(64));
        final bytes = big.takeBytes();
        // LC_CODE_SIGNATURE follows the 32-byte header: command, size, then the signature's offset.
        ByteData.sublistView(bytes).setUint32(40, 64 + padding, Endian.little);
        ipa.writeAsBytesSync(
          zipOf({
            'Payload/Runner.app/Info.plist': writePlistBinary({
              'CFBundleExecutable': 'Runner',
              'CFBundleIdentifier': _bundleId,
              'CFBundleShortVersionString': '1.0.0',
              'CFBundleVersion': '13',
            }),
            'Payload/Runner.app/Runner': bytes,
            'Payload/Runner.app/embedded.mobileprovision': profileOf(
              _profile(),
            ),
          }),
        );
        final (code, out, _) = await preflight([]);
        expect(code, 0);
        expect(
          out,
          contains('PASS  the IPA is signed as TEAM000000.com.example.app'),
        );
      },
    );
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
