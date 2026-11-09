import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_cli/wincode_cli.dart';

/// What `loadConfig` says about a flat `wincode.yaml` (ADR-0013, one app, no `apps:`), case by case. The golden was first
/// written from the loader as it was before ADR-0014's schema, so a diff in it shows a flat-file behaviour that changed.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('config_golden'));
  tearDown(() => dir.deleteSync(recursive: true));

  const minimal = 'bundle_id: org.example.app\nteam_id: TEAM000000\n';

  final cases = <String, String>{
    'the two required keys': minimal,
    'every key':
        '$minimal'
        'profile: ../signing/app.mobileprovision\n'
        'entitlements: ios/Runner/Runner.entitlements\n'
        'workflow: example-org/example-app/.github/workflows/wincode-ios.yml@release/1.0\n'
        'output: out\n',
    'a byte order mark': '﻿$minimal',
    'a YAML error':
        'bundle_id: org.example.app\nteam_id: TEAM000000: x\noutput: out\n',
    'an empty file': '',
    'a list': '- bundle_id\n',
    'a scalar': 'org.example.app\n',
    'an unknown key': '$minimal\nbundel_id: org.example.app\n',
    'a secret-looking key': "${minimal}issuer_id: 'not-a-real-secret'\n",
    'a secret-looking key, p8': "${minimal}p8: 'not-a-real-secret'\n",
    'no bundle_id': 'team_id: TEAM000000\n',
    'no team_id': 'bundle_id: org.example.app\n',
    'a team_id that YAML reads as a number':
        'bundle_id: org.example.app\nteam_id: 1234567890\n',
    'an output that is a list': '${minimal}output: [a, b]\n',
    'an empty profile': '${minimal}profile:\n',
    'a bundle_id that is not one': 'bundle_id: app\nteam_id: TEAM000000\n',
    'a team_id that is not one': 'bundle_id: org.example.app\nteam_id: team0\n',
    'a profile that is not a .mobileprovision': '${minimal}profile: dist.p12\n',
    'entitlements that are not a plist': '${minimal}entitlements: Runner.txt\n',
    'a workflow in the wrong shape': '${minimal}workflow: wincode-ios.yml\n',
    'an empty output': "${minimal}output: ''\n",
  };

  test('the messages and results for a flat file are test/goldens/config-flat.txt (UPDATE_GOLDENS=1 rewrites it)', () {
    final prefix = '${dir.path}${Platform.pathSeparator}';
    String clean(String text) => text.replaceAll(prefix, '');
    final report = StringBuffer();
    for (final MapEntry(:key, :value) in cases.entries) {
      report.writeln('# $key');
      final path = '$prefix${'wincode.yaml'}';
      File(path).writeAsStringSync(value);
      try {
        final c = loadConfig(path);
        report
          ..writeln('bundle_id: ${c.bundleId}')
          ..writeln('team_id: ${c.teamId}')
          ..writeln('output: ${clean(c.output.path)}')
          ..writeln('profile: ${clean(c.profile?.path ?? '-')}')
          ..writeln('entitlements: ${clean(c.entitlements?.path ?? '-')}')
          ..writeln('workflow: ${c.workflow}');
      } on WincodeException catch (e) {
        report
          ..writeln('exit ${e.exitCode.code} ${e.id}')
          ..writeln(clean(e.describe('wincode preflight')));
      }
      report.writeln();
    }
    final missing = '${prefix}nothing.yaml';
    report.writeln('# a file that does not exist');
    try {
      loadConfig(missing);
    } on WincodeException catch (e) {
      report
        ..writeln('exit ${e.exitCode.code} ${e.id}')
        ..writeln(clean(e.describe('wincode preflight')));
    }
    final golden = File('test/goldens/config-flat.txt');
    if (Platform.environment['UPDATE_GOLDENS'] != null) {
      golden.writeAsStringSync('$report');
    }
    expect('$report', golden.readAsStringSync().replaceAll('\r\n', '\n'));
  });
}
