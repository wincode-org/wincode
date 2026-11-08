import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_cli/wincode_cli.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('config_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  final sep = Platform.pathSeparator;
  const minimal = 'bundle_id: org.example.app\nteam_id: TEAM000000\n';

  String write(String yaml) =>
      (File('${dir.path}${sep}wincode.yaml')..writeAsStringSync(yaml)).path;

  /// The failure that loading [yaml] gives. Every failure is a setup error (78) with what, why and next.
  WincodeException failure(String yaml) {
    try {
      loadConfig(write(yaml));
    } on WincodeException catch (e) {
      expect(e.exitCode, ExitCode.config);
      expect([e.why, e.next], everyElement(isNotEmpty), reason: e.what);
      return e;
    }
    fail('no failure for:\n$yaml');
  }

  test(
    'the two required keys are enough; output defaults to build/wincode',
    () {
      final config = loadConfig(write(minimal));
      expect(config.bundleId, 'org.example.app');
      expect(config.teamId, 'TEAM000000');
      expect(config.output.path, '${dir.path}${sep}build/wincode');
      expect([
        config.profile,
        config.entitlements,
        config.workflow,
      ], everyElement(isNull));
    },
  );

  test('every key: paths are relative to the file, the workflow is split as GitHub writes it', () {
    final absolute = '${dir.path}${sep}signing${sep}app.mobileprovision';
    final config = loadConfig(
      write(
        '$minimal'
        "profile: '$absolute'\n"
        'entitlements: ios/Runner/Runner.entitlements\n'
        'workflow: example-org/example-app/.github/workflows/wincode-ios.yml@release/1.0\n'
        'output: out\n',
      ),
    );
    expect(config.profile!.path, absolute);
    expect(
      config.entitlements!.path,
      '${dir.path}${sep}ios/Runner/Runner.entitlements',
    );
    expect(config.workflow, (
      repository: 'example-org/example-app',
      file: 'wincode-ios.yml',
      ref: 'release/1.0',
    ));
    expect(config.output.path, '${dir.path}${sep}out');
  });

  test('a byte order mark, as Notepad may write, is accepted', () {
    expect(loadConfig(write('﻿$minimal')).bundleId, 'org.example.app');
  });

  test('a missing file says how to make one', () {
    try {
      loadConfig('${dir.path}${sep}wincode.yaml');
      fail('no failure');
    } on WincodeException catch (e) {
      expect(e.exitCode, ExitCode.config);
      expect(e.id, 'config-missing');
      expect(e.what, endsWith('wincode.yaml does not exist'));
      expect(e.next, contains('wincode init'));
      expect(e.next, contains('--config'));
    }
  });

  test('a YAML error names its line', () {
    final e = failure(
      'bundle_id: org.example.app\nteam_id: TEAM000000: x\noutput: out\n',
    );
    expect(e.id, 'config-invalid');
    expect(e.what, contains('wincode.yaml line 2: '));
  });

  test('a file that is empty or not a map holds no settings', () {
    for (final yaml in ['', '- bundle_id\n', 'org.example.app\n']) {
      expect(failure(yaml).what, endsWith('holds no settings'), reason: yaml);
    }
  });

  test('an unknown key is refused, so that a typo is not ignored', () {
    final e = failure('$minimal\nbundel_id: org.example.app\n');
    expect(e.what, endsWith('wincode.yaml line 4: unknown key "bundel_id"'));
    expect(
      e.why,
      contains('bundle_id, team_id, profile, entitlements, workflow, output'),
    );
  });

  test('a key that looks like a secret is refused, and its value is never repeated', () {
    for (final key in [
      'issuer_id',
      'key_id',
      'api_key',
      'p8',
      'password',
      'private_key',
      'token',
    ]) {
      final e = failure("$minimal$key: 'not-a-real-secret'\n");
      expect(
        e.what,
        endsWith(
          'line 3: "$key" looks like a secret, and wincode.yaml holds none',
        ),
      );
      expect(e.why, contains('WINCODE_ASC_KEY_DIR'));
      expect(e.next, contains('revoke'));
      expect(e.toJson().values.join(), isNot(contains('not-a-real-secret')));
    }
  });

  test('a required key that is missing says where to find its value', () {
    expect(failure('team_id: TEAM000000\n').what, endsWith('has no bundle_id'));
    final e = failure('bundle_id: org.example.app\n');
    expect(e.what, endsWith('has no team_id'));
    expect(e.next, contains('Membership details'));
  });

  test('a value YAML reads as a number, a list or nothing must be quoted', () {
    for (final (yaml, key) in [
      ('bundle_id: org.example.app\nteam_id: 1234567890\n', 'team_id'),
      ('${minimal}output: [a, b]\n', 'output'),
      ('${minimal}profile:\n', 'profile'),
    ]) {
      final e = failure(yaml);
      expect(e.what, endsWith('$key must be text'), reason: yaml);
      expect(e.next, contains("$key: '...'"), reason: yaml);
    }
  });

  test('values in the wrong shape are refused without repeating them', () {
    for (final (yaml, what) in [
      (
        'bundle_id: app\nteam_id: TEAM000000\n',
        'line 1: bundle_id is not a bundle ID',
      ),
      (
        'bundle_id: org.example.app\nteam_id: team0\n',
        'line 2: team_id is not a team ID',
      ),
      (
        '${minimal}profile: dist.p12\n',
        'line 3: profile must name a .mobileprovision file',
      ),
      (
        '${minimal}entitlements: Runner.txt\n',
        'line 3: entitlements must name an .entitlements or .plist file',
      ),
      (
        '${minimal}workflow: wincode-ios.yml\n',
        'line 3: workflow must be <owner>/<repository>/.github/workflows/',
      ),
      ("${minimal}output: ''\n", 'line 3: output must name a folder'),
    ]) {
      final e = failure(yaml);
      expect(e.what, contains(what), reason: yaml);
      for (final value in ['dist.p12', 'Runner.txt', 'team0']) {
        expect(e.what, isNot(contains(value)), reason: yaml);
      }
    }
  });
}
