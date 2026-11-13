import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wincode_asc/testing.dart';
import 'package:wincode_asc/wincode_asc.dart';
import 'package:wincode_cli/wincode_cli.dart';
import 'package:wincode_core/testing.dart';
import 'package:wincode_core/wincode_core.dart'
    show
        ZipArchive,
        digestsOfFile,
        readCertificate,
        readProvisioningProfile,
        writePlistBinary;

/// The time of every run: tokens, expiry dates, and the timestamps of the steps.
final _now = DateTime.utc(2026, 11, 13, 12);
final _expires = _now.add(const Duration(days: 300));

const _team = 'TEAM000000';
const _bundleId = 'com.example.app';
const _keyId = 'ABCDE12345';
const _uuid = '00000000-0000-0000-0000-0000000000a1';

/// Made-up IDs that the fake App Store Connect hands out.
const _appRecord = '1000000001';
const _uploadId = 'UPLOAD0001';
const _fileId = 'FILE000001';

/// The key that signs the test IPAs. It is made once: generating a key is slow.
final _signKey = TestRsaKey();
final _certificate = testCertificate(_signKey, notAfter: _expires);

String _appleDate(DateTime time) =>
    '${time.toUtc().toIso8601String().substring(0, 23)}+0000';

/// The profile of the fixture: App Store, listing the certificate of [_signKey].
final _profileBytes = profileOf({
  ...appStoreProfile(
    teamId: _team,
    bundleId: _bundleId,
    expires: _expires,
    uuid: _uuid,
  ),
  'DeveloperCertificates': [_certificate],
});

/// The app as `wincode build` hands it to `wincode sign`.
Map<String, List<int>> _unsigned({String build = '15'}) => {
  'Payload/': [],
  'Payload/Runner.app/': [],
  'Payload/Runner.app/Info.plist': writePlistBinary({
    'CFBundleIdentifier': _bundleId,
    'CFBundleExecutable': 'Runner',
    'CFBundleShortVersionString': '1.0',
    'CFBundleVersion': build,
  }),
  'Payload/Runner.app/Runner': [
    ...executable(signed: false),
    ...List.filled(5000, 7),
  ],
  'Payload/Runner.app/Frameworks/App.framework/Info.plist': writePlistBinary({
    'CFBundleIdentifier': 'io.flutter.flutter.app',
    'CFBundleExecutable': 'App',
  }),
  'Payload/Runner.app/Frameworks/App.framework/App': executable(signed: false),
};

/// [files] signed as zsign signs them, with the entitlements that `wincode sign` builds.
Uint8List _signed(Map<String, List<int>> files) {
  final want = signingEntitlements(
    readProvisioningProfile(_profileBytes),
    _bundleId,
  ).want;
  return Uint8List.fromList(
    zipOf(
      signTestIpa(
        files,
        teamId: _team,
        entitlements: want,
        key: _signKey,
        certificate: _certificate,
        profile: _profileBytes,
      ),
    ),
  );
}

/// The answer of App Store Connect to GET /v1/buildUploads/{id}: the state of the upload, of its file and of its build.
Map<String, Object?> _state({
  String upload = 'PROCESSING',
  String file = 'COMPLETE',
  String? build,
  List<Map<String, Object?>> errors = const [],
  List<Map<String, Object?>> warnings = const [],
}) => {
  'data': {
    'type': 'buildUploads',
    'id': _uploadId,
    'attributes': {
      'state': {
        'state': upload,
        'errors': errors,
        'warnings': warnings,
        'infos': <Object?>[],
      },
    },
  },
  'included': [
    {
      'type': 'buildUploadFiles',
      'id': _fileId,
      'attributes': {
        'assetDeliveryState': {
          'state': file,
          'errors': <Object?>[],
          'warnings': <Object?>[],
        },
      },
    },
    if (build != null)
      {
        'type': 'builds',
        'id': 'BUILD00001',
        'attributes': {'processingState': build},
      },
  ],
};

/// What the fake App Store Connect and its upload store do, and what a test changes.
class _Scenario {
  _Scenario(this.ipa);

  /// The IPA that is uploaded, for the size of the parts.
  final Uint8List ipa;

  /// The builds that the app has.
  List<String> builds = ['13', '14'];

  /// How many parts Apple asks for.
  int parts = 3;

  /// The answers to the polls, in turn; the last one repeats.
  List<FakeAnswer> polls = [
    FakeAnswer(_state()),
    FakeAnswer(_state(upload: 'COMPLETE', build: 'VALID')),
  ];
  var _polled = 0;

  /// What the certificate list says, and what the writes answer instead of their normal answers.
  String certificateType = 'DISTRIBUTION';
  bool listCertificate = true;
  FakeAnswer? createUpload;
  FakeAnswer? createFile;
  FakeAnswer? commit;

  /// What the upload store answers to the parts, in turn, by part number; then it says 200.
  final partAnswers = <int, List<FakeAnswer>>{};

  late Uri store;

  int get _partSize => (ipa.length / parts).ceil();

  String partUrl(int n) => '$store/part-$n?sig=SECRETSIG$n';

  FakeAnswer asc(FakeRequest r) => switch ('${r.method} ${r.path}') {
    'GET /v1/apps' => FakeAnswer.page([
      fakeResource('apps', _appRecord, {'bundleId': _bundleId}),
    ]),
    'GET /v1/apps/$_appRecord/builds' => FakeAnswer.page([
      for (final (i, version) in builds.indexed)
        fakeResource('builds', 'build-$i', {
          'version': version,
          'processingState': 'VALID',
        }),
    ]),
    'GET /v1/bundleIds' => FakeAnswer.page([
      fakeResource('bundleIds', 'BUNDLEID01', {
        'identifier': _bundleId,
        'platform': 'IOS',
      }),
    ]),
    'GET /v1/bundleIds/BUNDLEID01/profiles' => FakeAnswer.page([
      fakeResource('profiles', 'profile-1', {
        'profileType': 'IOS_APP_STORE',
        'profileState': 'ACTIVE',
        'uuid': _uuid,
        'expirationDate': _appleDate(_expires),
      }),
    ]),
    'GET /v1/certificates' => FakeAnswer.page([
      if (listCertificate)
        fakeResource('certificates', 'CERT000001', {
          'serialNumber': readCertificate(_certificate).serialHex,
          'certificateType': certificateType,
          'expirationDate': _appleDate(_expires),
        }),
    ]),
    'POST /v1/buildUploads' =>
      createUpload ??
          FakeAnswer({
            'data': {
              'type': 'buildUploads',
              'id': _uploadId,
              'attributes': {'cfBundleVersion': '15'},
            },
          }, status: 201),
    'POST /v1/buildUploadFiles' =>
      createFile ??
          FakeAnswer({
            'data': {
              'type': 'buildUploadFiles',
              'id': _fileId,
              'attributes': {
                'uploadOperations': [
                  for (var n = 1; n <= parts; n++)
                    {
                      'method': 'PUT',
                      'url': partUrl(n),
                      'partNumber': n,
                      'offset': (n - 1) * _partSize,
                      'length': min(
                        _partSize,
                        ipa.length - (n - 1) * _partSize,
                      ),
                      'requestHeaders': [
                        {
                          'name': 'Content-Type',
                          'value': 'application/octet-stream',
                        },
                        {
                          'name': 'x-store-grant',
                          'value': 'GRANTVALUE$n-abcdef',
                        },
                      ],
                    },
                ],
              },
            },
          }, status: 201),
    'PATCH /v1/buildUploadFiles/$_fileId' =>
      commit ??
          FakeAnswer({
            'data': {
              'type': 'buildUploadFiles',
              'id': _fileId,
              'attributes': {
                'assetDeliveryState': {
                  'state': 'COMPLETE',
                  'errors': <Object?>[],
                  'warnings': <Object?>[],
                },
              },
            },
          }),
    'GET /v1/buildUploads/$_uploadId' =>
      polls[min(_polled++, polls.length - 1)],
    _ => FakeAnswer.error(404, 'NOT_FOUND'),
  };

  FakeAnswer storeAnswer(FakeRequest r) {
    final n = int.tryParse(r.path.replaceFirst('/part-', '')) ?? 0;
    final queue = partAnswers[n];
    return queue != null && queue.isNotEmpty
        ? queue.removeAt(0)
        : const FakeAnswer.raw('');
  }
}

void main() {
  late Directory temp;
  late Directory keys;
  late ThrowawayKey ascKey;
  late String issuer;
  late File config;
  late File ipa;
  late _Scenario scenario;
  late FakeAppStoreConnect apple;
  late FakeAppStoreConnect store;
  late Uint8List signedBytes;
  late ({String md5, String sha256}) digests;

  String inside(Directory folder, String name) =>
      '${folder.path}${Platform.pathSeparator}$name';

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('wincode_upload_');
    ascKey = ThrowawayKey();
    final random = Random.secure();
    String hex(int length) =>
        [for (var i = 0; i < length; i++) random.nextInt(16).toRadixString(16)]
            .join();
    issuer = [hex(8), hex(4), hex(4), hex(4), hex(12)].join('-');
    keys = Directory(inside(temp, 'asc'))..createSync();
    File(inside(keys, 'AuthKey_$_keyId.p8')).writeAsStringSync(ascKey.pem());
    File(inside(keys, 'issuer-id')).writeAsStringSync('$issuer\n');
    final app = Directory(inside(temp, 'app'))..createSync();
    config = File(inside(app, 'wincode.yaml'))
      ..writeAsStringSync(
        'bundle_id: $_bundleId\nteam_id: $_team\nprofile: App_Store.mobileprovision\noutput: build\n',
      );
    File(inside(app, 'App_Store.mobileprovision'))
        .writeAsBytesSync(_profileBytes);
    final output = Directory(inside(app, 'build'))..createSync();
    signedBytes = _signed(_unsigned());
    ipa = File(inside(output, 'signed.ipa'))..writeAsBytesSync(signedBytes);
    digests = await digestsOfFile(ipa);
    scenario = _Scenario(signedBytes);
    apple = await FakeAppStoreConnect.start(
      (r) => scenario.asc(r),
      key: ascKey,
      now: () => _now,
    );
    store = await FakeAppStoreConnect.start((r) => scenario.storeAnswer(r));
    scenario.store = store.uri;
  });

  tearDown(() async {
    await apple.close();
    await store.close();
    temp.deleteSync(recursive: true);
  });

  /// Everything that must never be printed: the API key and its IDs, every token, and what makes a part's link and
  /// headers work.
  Map<String, String> secrets() => {
    'the Key ID': _keyId,
    'the Issuer ID': issuer,
    'the key folder': keys.path,
    'the key': ascKey.pem().split('\r\n')[1],
    for (final (i, r) in apple.requests.indexed)
      'token $i': r.authorization!.substring('Bearer '.length),
    'a token, redacted': '<token>',
    for (var n = 1; n <= scenario.parts; n++) ...{
      'the link of part $n': scenario.partUrl(n),
      'the signature of part $n': 'SECRETSIG$n',
      'a header of part $n': 'GRANTVALUE$n-abcdef',
    },
  };

  /// Runs `wincode upload` with [args] against the fakes, and checks that no secret reached the output. Returns the exit
  /// code, stdout and stderr.
  Future<(int, String, String)> upload(
    List<String> args, {
    bool yes = true,
    bool terminal = false,
    String? Function()? readLine,
    Map<String, String>? environment,
    File? configFile,
    Duration pollInterval = const Duration(milliseconds: 10),
    Duration writeTimeout = const Duration(seconds: 5),
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runWincode(
      [
        'upload',
        '--config',
        (configFile ?? config).path,
        if (yes) '--yes',
        ...args,
      ],
      out,
      err,
      environment: environment ?? {'WINCODE_ASC_KEY_DIR': keys.path},
      clock: () => _now,
      terminal: terminal,
      readLine: readLine,
      pollInterval: pollInterval,
      connect: (token, log) => HttpAscClient(
        api: apple.uri,
        token: token,
        log: log,
        timeout: const Duration(seconds: 5),
        writeTimeout: writeTimeout,
        partTimeout: const Duration(seconds: 5),
        retryDelays: const [
          Duration(milliseconds: 1),
          Duration(milliseconds: 1),
        ],
        partRetryDelays: const [
          Duration(milliseconds: 1),
          Duration(milliseconds: 1),
          Duration(milliseconds: 1),
          Duration(milliseconds: 1),
        ],
      ),
    );
    final printed = '$out$err';
    for (final MapEntry(key: what, value: secret) in secrets().entries) {
      expect(printed, isNot(contains(secret)), reason: '$what was printed');
    }
    return (code, '$out', '$err');
  }

  Map<String, Object?> errorOf(String out) =>
      (jsonDecode(out) as Map<String, Object?>)['error']!
          as Map<String, Object?>;

  /// The requests that wrote: everything but GET.
  List<String> writes() => [
    for (final r in [...apple.requests, ...store.requests])
      if (r.method != 'GET') '${r.method} ${r.path}',
  ];

  List<String> uploadRequests() => [
    for (final r in apple.requests)
      if (r.path.startsWith('/v1/buildUpload')) '${r.method} ${r.path}',
  ];

  group('a real upload', () {
    test('creates the upload, sends the parts, commits with the MD5, and waits for VALID', () async {
      final (code, out, err) = await upload(['--verbose']);
      expect(code, 0, reason: '$out$err');
      expect(out, contains('app record found'));
      expect(out, contains('build upload created: version 1.0, build 15'));
      expect(out, contains('file reserved: 3 part(s) to send'));
      expect(
        out,
        contains('upload PROCESSING, file COMPLETE, build not created yet'),
      );
      expect(out, contains('upload COMPLETE, file COMPLETE, build VALID'));
      expect(
        out,
        contains(
          'PASS  App Store Connect processed version 1.0 (build 15) as valid',
        ),
      );
      expect(out, endsWith('wincode upload: passed\n'));
      // The steps are those of the spike's script, in its order.
      expect(uploadRequests(), [
        'POST /v1/buildUploads',
        'POST /v1/buildUploadFiles',
        'PATCH /v1/buildUploadFiles/$_fileId',
        'GET /v1/buildUploads/$_uploadId',
        'GET /v1/buildUploads/$_uploadId',
      ]);
      final bodies = [
        for (final r in apple.requests)
          if (r.method != 'GET') r.json,
      ];
      expect(bodies[0], {
        'data': {
          'type': 'buildUploads',
          'attributes': {
            'cfBundleShortVersionString': '1.0',
            'cfBundleVersion': '15',
            'platform': 'IOS',
          },
          'relationships': {
            'app': {
              'data': {'type': 'apps', 'id': _appRecord},
            },
          },
        },
      });
      expect(bodies[1], {
        'data': {
          'type': 'buildUploadFiles',
          'attributes': {
            'assetType': 'ASSET',
            'fileName': 'signed.ipa',
            'fileSize': signedBytes.length,
            'uti': 'com.apple.ipa',
          },
          'relationships': {
            'buildUpload': {
              'data': {'type': 'buildUploads', 'id': _uploadId},
            },
          },
        },
      });
      expect(bodies[2], {
        'data': {
          'type': 'buildUploadFiles',
          'id': _fileId,
          'attributes': {
            'uploaded': true,
            'sourceFileChecksums': {
              'file': {'hash': digests.md5, 'algorithm': 'MD5'},
            },
          },
        },
      });
      // The parts rebuild the IPA byte for byte, and went to the store with Apple's headers and no token.
      expect(store.requests, hasLength(3));
      final rebuilt = <int>[
        for (final r in [
          ...store.requests,
        ]..sort((a, b) => a.path.compareTo(b.path)))
          ...r.body,
      ];
      expect(rebuilt, signedBytes);
      for (final r in store.requests) {
        expect(r.method, 'PUT');
        expect(r.authorization, isNull);
        expect(r.headers['content-type'], 'application/octet-stream');
        expect(r.headers['x-store-grant'], startsWith('GRANTVALUE'));
        expect(r.query['sig'], startsWith('SECRETSIG'));
      }
      // Every request to App Store Connect had a token of the API key.
      for (final r in apple.requests) {
        expect(r.authorization, startsWith('Bearer '));
        expect(ascKey.signed(r.authorization!.substring(7), _now), isTrue);
      }
    });

    test('the output of a run under --redact is test/goldens/upload.txt (UPDATE_GOLDENS=1 rewrites it)', () async {
      final report = StringBuffer();
      Future<void> run(
        String setup,
        List<String> args, {
        bool yes = true,
      }) async {
        final (code, out, err) = await upload(
          ['--redact', ...args],
          yes: yes,
          // A dry run waits for nothing: it shows the interval of a real run.
          pollInterval: args.contains('--dry-run')
              ? const Duration(seconds: 30)
              : const Duration(milliseconds: 10),
        );
        expect(err, '', reason: setup);
        report
          ..writeln('# $setup')
          ..writeln(['\$ wincode upload', '--redact', ...args].join(' '))
          ..writeln(out)
          ..writeln('exit $code')
          ..writeln();
      }

      await run('a valid build', []);
      scenario
        ..polls = [
          FakeAnswer(
            _state(
              upload: 'FAILED',
              errors: [
                {
                  'code': 'STATE_ERROR.DUPLICATE',
                  'description': 'This bundle is invalid. Café.',
                },
              ],
            ),
          ),
        ]
        ..parts = 2;
      await run('Apple fails the processing', []);
      await run('--dry-run', ['--dry-run']);
      final normal = _normalised('$report');
      final golden = File('test/goldens/upload.txt');
      if (Platform.environment['UPDATE_GOLDENS'] != null) {
        golden.writeAsStringSync(normal);
      }
      expect(normal, golden.readAsStringSync().replaceAll('\r\n', '\n'));
    });

    test(
      'a part that fails and then succeeds is sent again, and nothing else is',
      () async {
        scenario.partAnswers[2] = [FakeAnswer.error(503, 'UNAVAILABLE')];
        final (code, out, err) = await upload(['--verbose']);
        expect(code, 0, reason: '$out$err');
        expect(
          [for (final r in store.requests) r.path],
          ['/part-1', '/part-2', '/part-2', '/part-3'],
        );
        // Once each: the writes to App Store Connect are never repeated.
        expect(uploadRequests().where((r) => r.startsWith('POST')), [
          'POST /v1/buildUploads',
          'POST /v1/buildUploadFiles',
        ]);
        expect(err, contains('trying again'));
        expect(out, contains('part 2 sent'));
      },
    );

    test('a part that never succeeds stops after its retries, with the commit not sent', () async {
      scenario.partAnswers[1] = [
        for (var i = 0; i < 9; i++) const FakeAnswer.raw('', status: 503),
      ];
      final (code, out, _) = await upload(['--json']);
      expect(code, 69);
      expect(errorOf(out)['id'], 'upload-part-unavailable');
      // The first try and four more, within the bounded backoff.
      expect(store.requests.where((r) => r.path == '/part-1'), hasLength(5));
      expect(uploadRequests(), [
        'POST /v1/buildUploads',
        'POST /v1/buildUploadFiles',
      ]);
      expect(errorOf(out)['next'], contains('build 15 now counts as used'));
    });

    test('a part that the store refuses is not repeated, and what it echoes is not printed', () async {
      scenario.partAnswers[2] = [
        FakeAnswer.raw(
          '<Error><Code>AccessDenied</Code><Message>Request has expired for ${scenario.partUrl(2)}</Message>'
          '<SignatureProvided>SECRETSIG2</SignatureProvided><StringToSign>GRANTVALUE2-abcdef</StringToSign></Error>',
          status: 403,
        ),
      ];
      final (code, out, err) = await upload(['--json']);
      expect(code, 1, reason: err);
      final error = errorOf(out);
      expect(error['id'], 'upload-part-refused');
      expect(error['what'], contains('AccessDenied'));
      expect(error['what'], contains('<URL>'));
      expect(store.requests.where((r) => r.path == '/part-2'), hasLength(1));
      expect(writes(), isNot(contains('PATCH /v1/buildUploadFiles/$_fileId')));
    });
  });

  group('how it ends', () {
    test(
      'Apple fails the processing: exit 65, with its messages as sent',
      () async {
        scenario.polls = [
          FakeAnswer(_state()),
          FakeAnswer(
            _state(
              upload: 'FAILED',
              errors: [
                {'code': 'STATE_ERROR', 'description': 'Invalid bundle: Café'},
              ],
            ),
          ),
        ];
        final (code, out, err) = await upload(['--json']);
        expect(code, 65, reason: err);
        expect(errorOf(out)['id'], 'processing-failed');
        expect(
          err,
          contains(
            'upload error: {"code": "STATE_ERROR", "description": "Invalid bundle: Café"}',
          ),
        );
        expect(
          errorOf(out)['next'],
          contains('raise the build number above 15'),
        );
      },
    );

    test('a build that is INVALID fails too, and a processing result VALID is not reached', () async {
      scenario.polls = [
        FakeAnswer(_state(upload: 'COMPLETE', build: 'INVALID')),
      ];
      final (code, out, _) = await upload(['--json']);
      expect(code, 65);
      expect(errorOf(out)['what'], contains('build INVALID'));
    });

    test('no result within --timeout: exit 75, which is not the code of a failed processing', () async {
      scenario.polls = [FakeAnswer(_state(build: 'PROCESSING'))];
      final (code, out, err) = await upload([
        '--timeout',
        '1s',
        '--json',
      ], pollInterval: const Duration(milliseconds: 100));
      expect(code, 75, reason: err);
      expect(ExitCode.pending.code, isNot(ExitCode.rejected.code));
      final error = errorOf(out);
      expect(error['id'], 'processing-timeout');
      expect(error['what'], contains('after 1 second;'));
      expect(error['next'], contains('do not upload build 15 again'));
      // The upload was committed before it waited.
      expect(writes(), contains('PATCH /v1/buildUploadFiles/$_fileId'));
    });

    test('a read of the state that fails once is asked again', () async {
      scenario.polls = [
        for (var i = 0; i < 3; i++) FakeAnswer.error(503, 'UNAVAILABLE'),
        FakeAnswer(_state(upload: 'COMPLETE', build: 'VALID')),
      ];
      final (code, out, err) = await upload([]);
      expect(code, 0, reason: '$out$err');
      expect(out, contains('could not read the state'));
    });

    test('reads of the state that keep failing end the wait with the upload described', () async {
      scenario.polls = [FakeAnswer.error(503, 'UNAVAILABLE')];
      final (code, out, _) = await upload(['--json']);
      expect(code, 69);
      expect(errorOf(out)['id'], 'asc-unavailable');
      expect(errorOf(out)['next'], contains('now counts as used'));
    });
  });

  group('writes are not repeated', () {
    test('a 4xx on creating the upload: refused with Apple\'s words, one request, no file', () async {
      scenario.createUpload = FakeAnswer.error(
        409,
        'ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE',
      );
      final (code, out, _) = await upload(['--json']);
      expect(code, 1);
      final error = errorOf(out);
      expect(error['id'], 'upload-refused');
      expect(
        error['what'],
        contains('ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE'),
      );
      expect(error['why'], contains('version 1.0 build 15'));
      expect(uploadRequests(), ['POST /v1/buildUploads']);
      expect(store.requests, isEmpty);
    });

    test(
      'a 5xx on creating the upload is not tried again, and may have been done',
      () async {
        scenario.createUpload = const FakeAnswer(null, status: 503);
        final (code, out, _) = await upload(['--json']);
        expect(code, 69);
        expect(uploadRequests(), ['POST /v1/buildUploads']);
        expect(
          errorOf(out)['next'],
          contains('may or may not have reached Apple'),
        );
      },
    );

    test(
      'no answer to the commit is not tried again, and may have been done',
      () async {
        scenario.commit = const FakeAnswer(null, delay: Duration(seconds: 2));
        final (code, out, _) = await upload([
          '--json',
        ], writeTimeout: const Duration(milliseconds: 300));
        expect(code, 69);
        expect(errorOf(out)['id'], 'offline');
        expect(
          errorOf(out)['next'],
          contains('may or may not have reached Apple'),
        );
        expect(
          uploadRequests().where((r) => r.startsWith('PATCH')),
          hasLength(1),
        );
      },
    );

    test('Apple refusing the key on the first write is 77', () async {
      scenario.createUpload = FakeAnswer.error(403, 'FORBIDDEN_ERROR');
      final (code, out, _) = await upload(['--json']);
      expect(code, 77);
      expect(errorOf(out)['id'], 'asc-forbidden');
      expect(errorOf(out)['next'], contains('may upload builds'));
    });
  });

  group('nothing is uploaded when a check fails', () {
    void noUpload() {
      expect(writes(), isEmpty, reason: 'a write was sent');
      expect(store.requests, isEmpty);
    }

    test('an IPA that is not signed', () async {
      ipa.writeAsBytesSync(zipOf(_unsigned()));
      final (code, out, _) = await upload(['--json']);
      expect(code, 1);
      expect(errorOf(out)['id'], 'ipa-unsigned');
      expect(errorOf(out)['next'], contains('wincode sign'));
      noUpload();
    });

    test(
      'a build number that is not higher than every existing build',
      () async {
        scenario.builds = ['13', '15'];
        final (code, out, _) = await upload(['--json']);
        expect(code, 1);
        expect(errorOf(out)['id'], 'build-number-not-higher');
        noUpload();
      },
    );

    test('a signature that does not verify', () async {
      final files = _unzip(ipa)
        ..['Payload/Runner.app/Frameworks/App.framework/App'] = executable(
          signed: false,
        );
      ipa.writeAsBytesSync(zipOf(files));
      final (code, out, _) = await upload(['--json']);
      expect(code, 1);
      expect(errorOf(out)['id'], 'signature-invalid');
      noUpload();
    });

    test('a certificate that App Store Connect does not list as a distribution certificate', () async {
      scenario.certificateType = 'IOS_DEVELOPMENT';
      final (code, out, _) = await upload(['--json']);
      expect(code, 1);
      expect(errorOf(out)['id'], 'certificate-not-distribution');
      noUpload();
      scenario
        ..certificateType = 'DISTRIBUTION'
        ..listCertificate = false;
      final (code2, out2, _) = await upload(['--json']);
      expect(code2, 1);
      expect(errorOf(out2)['id'], 'certificate-not-in-asc');
      noUpload();
    });

    test(
      'an IPA signed with a profile that is not the one in wincode.yaml',
      () async {
        File(inside(config.parent, 'App_Store.mobileprovision'))
            .writeAsBytesSync(
              profileOf({
                ...appStoreProfile(
                  teamId: _team,
                  bundleId: _bundleId,
                  expires: _expires,
                  uuid: '00000000-0000-0000-0000-0000000000c3',
                ),
                'DeveloperCertificates': [_certificate],
              }),
            );
        final (code, out, _) = await upload(['--json']);
        expect(code, 1);
        noUpload();
        expect(
          errorOf(out)['id'],
          anyOf('ipa-profile-mismatch', 'profile-uuid-mismatch'),
        );
      },
    );

    test('no IPA at all', () async {
      ipa.deleteSync();
      final (code, out, _) = await upload(['--json']);
      expect(code, 1);
      expect(errorOf(out)['id'], 'ipa-missing');
      expect(errorOf(out)['next'], contains('wincode upload --ipa'));
      noUpload();
    });

    test('the report says that nothing was uploaded', () async {
      scenario.builds = ['15'];
      final (code, out, _) = await upload([]);
      expect(code, 1);
      expect(out, contains('INFO  nothing was uploaded: a check above failed'));
      expect(out, contains('FAIL  build 15 is not higher than 15'));
      noUpload();
    });
  });

  group('--dry-run', () {
    test('makes no request at all, and prints the plan and the requests of the spike\'s dry run', () async {
      final (code, out, err) = await upload([
        '--dry-run',
      ], pollInterval: const Duration(seconds: 30));
      expect(code, 0, reason: '$out$err');
      expect(apple.requests, isEmpty);
      expect(store.requests, isEmpty);
      expect(out, contains('Upload plan (nothing is sent):'));
      expect(out, contains('  app:      $_bundleId'));
      expect(out, contains('  version:  1.0, build 15'));
      expect(
        out,
        contains('  file:     signed.ipa, ${signedBytes.length} bytes'),
      );
      expect(out, contains('  MD5:      ${digests.md5}'));
      expect(out, contains('  SHA-256:  ${digests.sha256}'));
      // The lines of asc_upload.py --dry-run, with the values of this IPA.
      expect(
        out,
        contains(
          'GET https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]=$_bundleId&fields[apps]=bundleId&limit=200\n'
          '    Authorization: Bearer <token signed locally, not shown>\n'
          'POST https://api.appstoreconnect.apple.com/v1/buildUploads\n'
          '    {"data": {"type": "buildUploads", "attributes": {"cfBundleShortVersionString": "1.0", "cfBundleVersion": "15", "platform": "IOS"}, "relationships": {"app": {"data": {"type": "apps", "id": "{id of the app record}"}}}}}\n'
          'POST https://api.appstoreconnect.apple.com/v1/buildUploadFiles\n'
          '    {"data": {"type": "buildUploadFiles", "attributes": {"assetType": "ASSET", "fileName": "signed.ipa", "fileSize": ${signedBytes.length}, "uti": "com.apple.ipa"}, "relationships": {"buildUpload": {"data": {"type": "buildUploads", "id": "{id of the build upload}"}}}}}\n'
          '<each uploadOperations entry of the answer>: its method and URL, its byte range of the ${signedBytes.length}-byte IPA and its requestHeaders; no token\n'
          'PATCH https://api.appstoreconnect.apple.com/v1/buildUploadFiles/{id of the upload file}\n'
          '    {"data": {"type": "buildUploadFiles", "id": "{id of the upload file}", "attributes": {"uploaded": true, "sourceFileChecksums": {"file": {"hash": "${digests.md5}", "algorithm": "MD5"}}}}}\n'
          'GET https://api.appstoreconnect.apple.com/v1/buildUploads/{id of the build upload}?include=build,assetFile&fields[builds]=processingState&fields[buildUploadFiles]=assetDeliveryState\n'
          '    every 30 s, for up to 20 minutes after the commit',
        ),
      );
    });

    test('still refuses an IPA that is not signed, with no request', () async {
      ipa.writeAsBytesSync(zipOf(_unsigned()));
      final (code, out, _) = await upload(['--dry-run', '--json']);
      expect(code, 1);
      expect(errorOf(out)['id'], 'ipa-unsigned');
      expect(apple.requests, isEmpty);
    });

    test('with --json, the plan and the requests are in the object', () async {
      final (code, out, _) = await upload(['--dry-run', '--json']);
      expect(code, 0);
      final json = jsonDecode(out) as Map<String, Object?>;
      expect(json['dryRun'], isTrue);
      expect((json['plan']! as Map)['build'], '15');
      expect((json['plan']! as Map)['md5'], digests.md5);
      expect(json['requests'], isNotEmpty);
    });
  });

  group('the confirmation', () {
    test('without --yes and without a terminal, upload refuses (64) before any request', () async {
      final (code, out, err) = await upload(['--json'], yes: false);
      expect(code, 64, reason: err);
      expect(errorOf(out)['id'], 'confirmation-required');
      expect(apple.requests, isEmpty);
    });

    test(
      '--json and CI are not terminals either, even when stdin is one',
      () async {
        for (final (args, environment) in [
          (['--json'], <String, String>{'WINCODE_ASC_KEY_DIR': keys.path}),
          (<String>[], {'WINCODE_ASC_KEY_DIR': keys.path, 'CI': 'true'}),
        ]) {
          final (code, _, err) = await upload(
            args,
            yes: false,
            terminal: true,
            environment: environment,
            readLine: () => _bundleId,
          );
          expect(code, 64, reason: err);
        }
        expect(apple.requests, isEmpty);
      },
    );

    test('at a terminal, the name of the app starts the upload; for a file without names, the bundle ID', () async {
      final answers = [_bundleId];
      final (code, out, err) = await upload(
        [],
        yes: false,
        terminal: true,
        readLine: answers.removeLast,
      );
      expect(code, 0, reason: '$out$err');
      expect(
        out,
        contains(
          'To upload this build, type the name of the app ($_bundleId): ',
        ),
      );
      expect(out, contains('Upload plan:'));
    });

    test('anything else cancels, with nothing uploaded', () async {
      final (code, out, _) = await upload(
        [],
        yes: false,
        terminal: true,
        readLine: () => 'yes',
      );
      expect(code, 1);
      expect(
        out,
        contains(
          'FAIL  the upload was not confirmed: what you typed is not the name of the app',
        ),
      );
      expect(out, contains('Nothing was uploaded.'));
      expect(writes(), isEmpty);
      // The end of the input is no confirmation either.
      expect(
        (await upload([], yes: false, terminal: true, readLine: () => null)).$1,
        1,
      );
      expect(writes(), isEmpty);
    });

    test('a file of apps asks for the app\'s name, and --app chooses the app', () async {
      final root = Directory(inside(temp, 'keys-root'))..createSync();
      final folder = Directory(inside(root, 'test-one'))..createSync();
      for (final name in ['AuthKey_$_keyId.p8', 'issuer-id']) {
        File(inside(keys, name)).copySync(inside(folder, name));
      }
      final apps = File(inside(config.parent, 'apps.yaml'))
        ..writeAsStringSync(
          'apps:\n'
          '  alpha:\n    bundle_id: $_bundleId\n    team_id: $_team\n    credentials: test-one\n'
          '    profile: App_Store.mobileprovision\n    output: build\n'
          '  beta:\n    bundle_id: com.example.beta\n    team_id: $_team\n    credentials: test-one\n'
          '    profile: App_Store.mobileprovision\n    output: build-beta\n',
        );
      final environment = {'WINCODE_KEYS_DIR': root.path};
      final (code, out, _) = await upload(
        ['--app', 'alpha'],
        yes: false,
        terminal: true,
        readLine: () => 'alpha',
        environment: environment,
        configFile: apps,
      );
      expect(code, 0, reason: out);
      expect(out, contains('type the name of the app (alpha)'));
      expect(out, contains('  app:      alpha'));
      // Without --app, a file of apps does not choose.
      final (none, _, _) = await upload(
        [],
        configFile: apps,
        environment: environment,
      );
      expect(none, 64);
    });
  });

  group('the command line', () {
    test('--all is refused: upload writes', () async {
      final (code, _, err) = await upload(['--all']);
      expect(code, 64);
      expect(err, contains('--all is not allowed for upload'));
    });

    test('the IPA is named once, with --ipa or alone', () async {
      final copy = File(inside(config.parent, 'other.ipa'))
        ..writeAsBytesSync(signedBytes);
      expect((await upload(['--ipa', copy.path, '--dry-run'])).$1, 0);
      expect((await upload([copy.path, '--dry-run'])).$1, 0);
      expect(
        (await upload(['--ipa', copy.path, copy.path, '--dry-run'])).$1,
        64,
      );
      expect((await upload(['a.ipa', 'b.ipa', '--dry-run'])).$1, 64);
    });

    test('--timeout is minutes, or seconds with an s', () async {
      for (final bad in ['abc', '0', '-1', '1.5', '']) {
        expect(
          (await upload(['--timeout', bad, '--dry-run'])).$1,
          64,
          reason: bad,
        );
      }
      expect((await upload(['--timeout', '90s', '--dry-run'])).$1, 0);
      expect((await upload(['--timeout', '20', '--dry-run'])).$1, 0);
    });
  });

  group('redaction', () {
    test(
      '--redact and CI hide the IDs, and the secrets are hidden always',
      () async {
        for (final (args, environment) in [
          (['--redact'], <String, String>{'WINCODE_ASC_KEY_DIR': keys.path}),
          (<String>[], {'WINCODE_ASC_KEY_DIR': keys.path, 'CI': 'true'}),
        ]) {
          scenario = _Scenario(signedBytes)..store = store.uri;
          final (code, out, err) = await upload([
            ...args,
            '--verbose',
          ], environment: environment);
          expect(code, 0, reason: '$out$err');
          for (final id in [_bundleId, _team, _appRecord, _uploadId, _fileId]) {
            expect('$out$err', isNot(contains(id)), reason: id);
          }
          expect(out, contains('<bundle ID>'));
        }
      },
    );

    test('with --verbose, the requests are logged without a token, a body or a link', () async {
      final (code, out, err) = await upload(['--verbose']);
      expect(code, 0, reason: '$out$err');
      expect(err, contains('PUT part 1 ('));
      expect(err, contains('POST 127.0.0.1/v1/buildUploads'));
      expect(err, isNot(contains('SECRETSIG')));
      expect(err, isNot(contains('GRANTVALUE')));
    });
  });
}

/// The contents of [file], a zip archive, by name.
Map<String, List<int>> _unzip(File file) {
  final zip = ZipArchive.open(file);
  try {
    return {
      for (final n in zip.names) n: n.endsWith('/') ? <int>[] : zip.read(n),
    };
  } finally {
    zip.close();
  }
}

/// [text] with what differs from run to run made the same: the checksums and sizes of an IPA that a random key signed.
String _normalised(String text) => text
    .replaceAll('\r\n', '\n')
    .replaceAll(RegExp(r'\b[0-9a-f]{64}\b'), '<sha256>')
    .replaceAll(RegExp(r'\b[0-9a-f]{32}\b'), '<md5>')
    .replaceAllMapped(RegExp(r'\b\d+(-byte| bytes)'), (m) => '<n>${m[1]}')
    .replaceAllMapped(RegExp(r'"fileSize": \d+'), (m) => '"fileSize": <n>');
