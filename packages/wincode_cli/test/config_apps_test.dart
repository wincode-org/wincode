import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_cli/wincode_cli.dart';

/// ADR-0014, section 1: files with `apps:` and `defaults:`, and the checks across apps.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('config_apps'));
  tearDown(() => dir.deleteSync(recursive: true));

  final sep = Platform.pathSeparator;
  final adr = File('../../docs/adr/0014-one-project-many-apps.md')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  /// The first YAML block of the ADR: its worked example.
  final example = RegExp(
    r'```yaml\n(.*?)```',
    dotAll: true,
  ).firstMatch(adr)![1]!;

  String write(String yaml) =>
      (File('${dir.path}${sep}wincode.yaml')..writeAsStringSync(yaml)).path;

  WincodeSettings load(String yaml, {Redactor? redactor}) =>
      loadSettings(write(yaml), redactor: redactor);

  /// The failure that loading [yaml] gives: a setup error (78) with what, why and next, and no [secret] in it.
  WincodeException failure(
    String yaml, {
    Redactor? redactor,
    List<String> never = const [],
  }) {
    try {
      load(yaml, redactor: redactor);
    } on WincodeException catch (e) {
      expect(e.exitCode, ExitCode.config, reason: e.what);
      expect([e.why, e.next], everyElement(isNotEmpty), reason: e.what);
      for (final word in never) {
        expect(e.toJson().values.join('\n'), isNot(contains(word)));
      }
      return e;
    }
    fail('no failure for:\n$yaml');
  }

  String clean(String text) => text.replaceAll('${dir.path}$sep', '');

  /// A file of apps with one app per name in [names], each with its own bundle ID, and shared defaults.
  String twoApps({
    String alpha = '',
    String beta = '',
    String defaults = '  team_id: TEAM000001\n  credentials: team-one\n',
  }) =>
      'defaults:\n$defaults'
      'apps:\n'
      '  alpha:\n    bundle_id: com.example.alpha\n$alpha'
      '  beta:\n    bundle_id: com.example.beta\n$beta';

  group('the worked example of the ADR', () {
    late WincodeSettings settings;
    setUp(() => settings = load(example));

    test('parses to three apps in file order', () {
      expect(settings.isFlat, isFalse);
      expect(settings.apps.map((a) => a.name), ['alpha', 'beta', 'gamma']);
      expect(settings.app('beta')!.bundleId, 'com.example.beta');
      expect(settings.app('nobody'), isNull);
    });

    test('gives each app its bundle ID, team, credentials, flavor and configuration', () {
      expect(
        settings.apps.map(
          (a) =>
              (a.bundleId, a.teamId, a.credentials, a.flavor, a.configuration),
        ),
        [
          (
            'com.example.alpha',
            'TEAM000001',
            'team-one',
            'alpha',
            'Release-alpha',
          ),
          (
            'com.example.beta',
            'TEAM000001',
            'team-one',
            'beta',
            'Release-beta',
          ),
          (
            'com.example.gamma',
            'TEAM000002',
            'team-two',
            'gamma',
            'Release-gamma',
          ),
        ],
      );
    });

    test('shares defaults, resolves paths against the file and defaults the output per app', () {
      for (final app in settings.apps) {
        expect(app.workflow, (
          repository: 'example-org/example-app',
          file: 'wincode-ios.yml',
          ref: 'main',
        ));
        expect(
          app.entitlements!.path,
          '${dir.path}${sep}ios/Runner/Runner.entitlements',
        );
        expect(app.output.path, '${dir.path}${sep}build/wincode/${app.name}');
        expect(
          app.profile!.path,
          '${dir.path}$sep../signing/${app.name}.mobileprovision',
        );
      }
    });

    test('keeps workflow_inputs for the app that writes them', () {
      expect(settings.app('alpha')!.workflowInputs, isEmpty);
      expect(settings.app('gamma')!.workflowInputs, {
        'environment': 'production',
      });
      expect(
        () => settings.app('gamma')!.workflowInputs['x'] = 'y',
        throwsUnsupportedError,
      );
    });

    test('loadConfig refuses several apps until --app exists (64)', () {
      try {
        loadConfig(write(example));
        fail('no failure');
      } on WincodeException catch (e) {
        expect(e.exitCode, ExitCode.usage);
        expect(e.id, 'not-implemented');
        expect(e.what, contains('3 apps'));
        expect(e.what, contains('ADR-0014'));
        expect([e.why, e.next], everyElement(isNotEmpty));
      }
    });
  });

  group('a file with one app', () {
    test('is what loadConfig returns for existing commands', () {
      final config = loadConfig(
        write(
          'apps:\n  alpha:\n    bundle_id: com.example.alpha\n'
          '    team_id: TEAM000001\n    credentials: team-one\n',
        ),
      );
      expect(config.name, 'alpha');
      expect(config.bundleId, 'com.example.alpha');
    });
  });

  group('defaults and overrides', () {
    test('an app replaces a default whole, workflow_inputs included', () {
      final settings = load(
        'defaults:\n'
        '  team_id: TEAM000001\n'
        '  credentials: team-one\n'
        '  entitlements: ios/Runner/Runner.entitlements\n'
        '  workflow_inputs:\n    environment: staging\n    region: eu\n'
        'apps:\n'
        '  alpha:\n    bundle_id: com.example.alpha\n'
        '  beta:\n    bundle_id: com.example.beta\n    team_id: TEAM000002\n'
        '    credentials: team-two\n    entitlements: Beta.entitlements\n'
        '    workflow_inputs:\n      environment: production\n',
      );
      final alpha = settings.app('alpha')!;
      final beta = settings.app('beta')!;
      expect(alpha.teamId, 'TEAM000001');
      expect(alpha.workflowInputs, {'environment': 'staging', 'region': 'eu'});
      expect(beta.teamId, 'TEAM000002');
      expect(beta.credentials, 'team-two');
      expect(beta.entitlements!.path, endsWith('Beta.entitlements'));
      expect(beta.workflowInputs, {'environment': 'production'});
    });

    test('a file of apps needs no defaults', () {
      final settings = load(
        'apps:\n  alpha:\n    bundle_id: com.example.alpha\n'
        '    team_id: TEAM000001\n    credentials: team-one\n',
      );
      expect(settings.apps.single.name, 'alpha');
    });
  });

  group('flavor, configuration and output', () {
    test('configuration defaults to Release-<flavor>, else Release, and the file may say another', () {
      final settings = load(
        twoApps(
          alpha: '    flavor: alpha\n',
          beta: '    flavor: beta\n    configuration: Release Beta.1\n',
        ),
      );
      expect(settings.app('alpha')!.configuration, 'Release-alpha');
      expect(settings.app('beta')!.configuration, 'Release Beta.1');
      expect(load(twoApps()).app('alpha')!.configuration, 'Release');
    });

    test('a flat file may name them too, and keeps build/wincode', () {
      final config = loadConfig(
        write(
          'bundle_id: com.example.alpha\nteam_id: TEAM000001\n'
          'flavor: alpha\ncredentials: team-one\n',
        ),
      );
      expect(config.name, isNull);
      expect(config.flavor, 'alpha');
      expect(config.configuration, 'Release-alpha');
      expect(config.credentials, 'team-one');
      expect(config.output.path, '${dir.path}${sep}build/wincode');
    });

    test('output is build/wincode/<app> unless the app names one', () {
      final settings = load(twoApps(beta: '    output: out/beta\n'));
      expect(
        settings.app('alpha')!.output.path,
        '${dir.path}${sep}build/wincode/alpha',
      );
      expect(settings.app('beta')!.output.path, '${dir.path}${sep}out/beta');
    });

    test('values outside their rule are refused without being repeated', () {
      for (final (extra, what) in [
        ('flavor: -x-sentinel\n', 'flavor is not a flavor name'),
        ('flavor: has space\n', 'flavor is not a flavor name'),
        (
          'configuration: "bad/sentinel"\n',
          'configuration is not a build configuration name',
        ),
        (
          "configuration: ' '\n",
          'configuration is not a build configuration name',
        ),
      ]) {
        final e = failure(
          twoApps(alpha: '    $extra'),
          never: ['sentinel', 'has space'],
        );
        expect(e.what, contains(what), reason: extra);
        expect(e.what, contains('app alpha: '), reason: extra);
      }
    });
  });

  group('the names of apps and of credentials', () {
    String app(String name) =>
        'apps:\n  $name:\n    bundle_id: com.example.one\n    team_id: TEAM000001\n    credentials: team-one\n';
    String reference(String name) =>
        'apps:\n  alpha:\n    bundle_id: com.example.one\n    team_id: TEAM000001\n    credentials: $name\n';

    test('3 to 32 lower-case letters, digits and hyphens are fine', () {
      for (final name in ['abc', 'alpha', 'team-one', 'a1b', 'a${'b' * 30}c']) {
        expect(load(app(name)).apps.single.name, name);
        expect(load(reference(name)).apps.single.credentials, name);
      }
    });

    test('anything else is refused, and the refused name is not printed', () {
      for (final (name, problem) in [
        ('ab', 'is shorter than 3 characters'),
        ('a${'b' * 32}c', 'is longer than 32 characters'),
        ('Sentinel', 'has characters other than'),
        ('sentinel_one', 'has characters other than'),
        ('sentinel-', 'has characters other than'),
        ('-sentinel', 'has characters other than'),
        ('1sentinel', 'has characters other than'),
        ("'sentinel one'", 'has characters other than'),
      ]) {
        final plain = name.replaceAll("'", '');
        for (final yaml in [app(name), reference(name)]) {
          final e = failure(yaml, never: plain.length > 3 ? [plain] : []);
          expect(e.what, contains(problem), reason: name);
          expect(e.id, 'config-invalid');
        }
      }
    });

    test('an app name that YAML does not read as text is refused', () {
      final e = failure(app('true'));
      expect(e.what, contains('the app name is not text'));
    });

    test(
      'the reserved words are refused, the ones the ADR names among them',
      () {
        expect(
          reservedNames,
          containsAll([
            'build',
            'key',
            'keys',
            'app',
            'apps',
            'test',
            'release',
            'debug', //
            'profile', 'sign', 'upload', 'config', 'default', 'all',
          ]),
        );
        for (final word in reservedNames) {
          expect(
            failure(app(word)).what,
            contains('is the common word "$word"'),
          );
          expect(
            failure(reference(word)).what,
            contains('the credentials name is the common word "$word"'),
          );
        }
      },
    );

    test(
      'Windows device names and the shapes of the placeholders are refused',
      () {
        for (final name in ['con', 'prn', 'aux', 'nul', 'com1', 'lpt9']) {
          expect(
            failure(app(name)).what,
            contains('Windows device'),
            reason: name,
          );
        }
        for (final name in [
          'app-1',
          'credentials-12',
          'flavor-3',
          'configuration-9',
        ]) {
          expect(
            failure(app(name)).what,
            contains('placeholder'),
            reason: name,
          );
          expect(
            failure(reference(name)).what,
            contains('placeholder'),
            reason: name,
          );
        }
        expect(nameProblem('app-x'), isNull);
      },
    );
  });

  group('the shape of the file', () {
    test(
      'a key of an app next to apps is refused, with its key and not its value',
      () {
        final e = failure(
          'bundle_id: com.example.sentinel\napps:\n  alpha:\n    bundle_id: com.example.alpha\n',
          never: ['sentinel'],
        );
        expect(
          e.what,
          endsWith('line 1: "bundle_id" is at the top level, next to apps'),
        );
      },
    );

    test('defaults without apps has nothing to apply to', () {
      final e = failure('defaults:\n  team_id: TEAM000001\n');
      expect(e.what, endsWith('line 1: defaults has no apps to apply to'));
    });

    test('apps must hold at least one app, each a map', () {
      for (final yaml in ['apps:\n', 'apps: {}\n', 'apps: [alpha]\n']) {
        expect(failure(yaml).what, endsWith('apps lists no app'), reason: yaml);
      }
      expect(
        failure('apps:\n  alpha:\n').what,
        endsWith('app alpha holds no settings'),
      );
    });

    test('defaults is a map', () {
      expect(
        failure(
          'defaults: [a]\napps:\n  alpha:\n    bundle_id: com.example.alpha\n',
        ).what,
        contains('defaults holds no settings'),
      );
    });

    test('a key that is per app cannot be shared in defaults', () {
      for (final key in [
        'bundle_id',
        'flavor',
        'configuration',
        'profile',
        'output',
      ]) {
        final e = failure(
          'defaults:\n  $key: sentinel-value\napps:\n  alpha:\n    bundle_id: com.example.alpha\n',
          never: ['sentinel-value'],
        );
        expect(
          e.what,
          contains('defaults: "$key" is per app and cannot be shared'),
        );
      }
    });

    test(
      'an unknown key is refused at every level, listing what is allowed',
      () {
        final top = failure(
          'apps:\n  alpha:\n    bundle_id: com.example.alpha\nextra: x\n',
        );
        expect(top.what, contains('line 4: unknown key "extra"'));
        expect(top.why, contains('apps, defaults'));
        final inApp = failure(twoApps(alpha: '    flavour: alpha\n'));
        expect(inApp.what, contains('app alpha: unknown key "flavour"'));
        expect(
          inApp.why,
          contains(
            'bundle_id, team_id, profile, entitlements, workflow, output, flavor, configuration, workflow_inputs, credentials',
          ),
        );
        final inDefaults = failure(
          twoApps(
            defaults:
                '  team_id: TEAM000001\n  credentials: team-one\n  tem_id: x\n',
          ),
        );
        expect(inDefaults.what, contains('defaults: unknown key "tem_id"'));
        expect(
          inDefaults.why,
          startsWith('defaults reads only team_id, entitlements'),
        );
      },
    );

    test(
      'a key that looks like a secret is refused everywhere, without its value',
      () {
        for (final (yaml, where) in [
          (
            'apps:\n  alpha:\n    bundle_id: com.example.alpha\napi_key: secret-sentinel\n',
            '',
          ),
          (twoApps(alpha: '    issuer_id: secret-sentinel\n'), 'app alpha: '),
          (
            twoApps(
              defaults: '  team_id: TEAM000001\n  credentials: team-one\n  token: secret-sentinel\n',
            ),
            'defaults: ',
          ),
        ]) {
          final e = failure(yaml, never: ['secret-sentinel']);
          expect(e.what, contains('$where"'));
          expect(
            e.what,
            endsWith('looks like a secret, and wincode.yaml holds none'),
          );
          expect(e.why, contains('credentials reference'));
          expect(e.next, contains('revoke'));
        }
      },
    );

    test(
      'credentials is a known key although its name looks like a secret',
      () {
        expect(load(twoApps()).apps.first.credentials, 'team-one');
      },
    );

    test(
      'a YAML merge key is an unknown key: defaults is the one way to share',
      () {
        final e = failure(
          'base: &b\n  team_id: TEAM000001\napps:\n  alpha:\n    <<: *b\n    bundle_id: com.example.alpha\n',
        );
        expect(e.what, contains('unknown key'));
      },
    );

    test('a value must be text, and a team ID of digits must be quoted', () {
      final e = failure(twoApps(alpha: '    team_id: 1234567890\n'));
      expect(e.what, endsWith('app alpha: team_id must be text'));
      expect(e.next, contains("team_id: '...'"));
    });

    test('values in the wrong shape name the app and the key only', () {
      for (final (extra, what) in [
        ('team_id: team0\n', 'team_id is not a team ID'),
        ('profile: dist.p12\n', 'profile must name a .mobileprovision file'),
        ('workflow: sentinel.yml\n', 'workflow must be'),
        ("output: ''\n", 'output must name a folder'),
      ]) {
        final e = failure(
          twoApps(alpha: '    $extra'),
          never: ['team0', 'dist.p12', 'sentinel'],
        );
        expect(e.what, contains('app alpha: $what'), reason: extra);
      }
      final bundle = failure(
        twoApps().replaceFirst('com.example.alpha', 'app'),
        never: ['bundle_id: app'],
      );
      expect(bundle.what, contains('app alpha: bundle_id is not a bundle ID'));
    });

    test('a bad value in defaults says so', () {
      final e = failure(
        twoApps(defaults: '  team_id: team0\n  credentials: team-one\n'),
      );
      expect(e.what, endsWith('defaults: team_id is not a team ID'));
    });
  });

  group('what every app needs', () {
    test('bundle_id', () {
      final e = failure(
        'apps:\n  alpha:\n    team_id: TEAM000001\n    credentials: team-one\n',
      );
      expect(e.what, endsWith('line 2: app alpha has no bundle_id'));
    });

    test('team_id, from the app or from defaults', () {
      final e = failure(twoApps(defaults: '  credentials: team-one\n'));
      expect(e.what, endsWith('app alpha has no team_id'));
      expect(e.next, contains('to the app or to defaults'));
    });

    test('credentials, from the app or from defaults', () {
      final e = failure(twoApps(defaults: '  team_id: TEAM000001\n'));
      expect(e.what, endsWith('app alpha has no credentials'));
      expect(e.why, contains('ADR-0014'));
      expect(e.next, contains('credentials: <reference>'));
    });
  });

  group('the checks across apps', () {
    test('a bundle ID used twice is the message of the ADR', () {
      final yaml = example.replaceFirst(
        'bundle_id: com.example.beta',
        'bundle_id: com.example.alpha',
      );
      final e = failure(yaml);
      expect(e.id, 'config-invalid');
      final message =
          RegExp(
                r'5\. \*\*Duplicate bundle ID\*\*.*?```\n(.*?)```',
                dotAll: true,
              )
              .firstMatch(adr)![1]!
              .split('\n')
              .map((l) => l.replaceFirst(RegExp('^   '), ''))
              .join('\n');
      expect(clean(e.describe('wincode preflight')), message.trim());
    });

    test('is found whatever the case, and in the line of the second app', () {
      final e = failure(
        twoApps(beta: '').replaceFirst('com.example.beta', 'com.example.ALPHA'),
      );
      expect(e.what, contains('apps beta and alpha have the same bundle_id'));
      expect(e.what, contains('line 8: '));
    });

    test(
      'a credentials reference used by apps of different teams is refused',
      () {
        final e = failure(twoApps(beta: '    team_id: TEAM000002\n'));
        expect(
          e.what,
          contains(
            'apps beta and alpha use the credentials team-one, but their team_id differs',
          ),
        );
        expect(e.why, contains('one team'));
        expect(e.next, contains('credentials reference of their own'));
      },
    );

    test('two references for one team are allowed', () {
      final settings = load(twoApps(beta: '    credentials: team-one-b\n'));
      expect(settings.app('beta')!.credentials, 'team-one-b');
    });

    test(
      'two apps may not share an output folder, whatever the case or separator',
      () {
        for (final other in ['out/x', 'OUT\\X', 'out/x/']) {
          final e = failure(
            twoApps(
              alpha: '    output: out/x\n',
              beta: "    output: '$other'\n",
            ),
          );
          expect(
            e.what,
            contains('apps beta and alpha have the same output folder'),
            reason: other,
          );
        }
        final e = failure(twoApps(beta: '    output: build/wincode/alpha\n'));
        expect(e.what, contains('same output folder'));
      },
    );
  });

  group('workflow_inputs', () {
    String inputs(String body) => twoApps(alpha: '    workflow_inputs:\n$body');

    test('names and values are plain', () {
      expect(
        load(
          inputs(
            '      environment: production\n      region_code: eu-west/1\n',
          ),
        ).app('alpha')!.workflowInputs,
        {'environment': 'production', 'region_code': 'eu-west/1'},
      );
    });

    test('the inputs that build sets itself, bad names and secret-looking names are refused', () {
      for (final name in [
        'request_id',
        'flavor',
        'build_number',
        'Env',
        '1x',
      ]) {
        expect(
          failure(inputs('      $name: x\n')).what,
          contains('is not allowed'),
          reason: name,
        );
      }
      for (final name in ['token', 'api_key', 'password']) {
        final e = failure(
          inputs('      $name: sentinel\n'),
          never: ['sentinel'],
        );
        expect(e.what, contains('looks like a secret'), reason: name);
        expect(e.next, contains('Actions secrets'));
      }
    });

    test('a value must be short plain text, and is not repeated', () {
      for (final value in [
        'has space sentinel',
        'x' * 65,
        '[a]',
        '1',
        'true',
      ]) {
        final e = failure(
          inputs(
            "      environment: ${value == 'has space sentinel' ? "'$value'" : value}\n",
          ),
          never: ['sentinel'],
        );
        expect(
          e.what,
          contains(
            'the value of the workflow input "environment" must be text',
          ),
          reason: value,
        );
      }
    });

    test('workflow_inputs must be a map', () {
      expect(
        failure(inputs('')).what,
        contains('workflow_inputs must be a map'),
      );
    });
  });

  group('redaction', () {
    Redactor active() => Redactor(active: true);

    test('the example hides names, IDs, credentials, flavors and paths with stable placeholders', () {
      final redactor = active();
      final settings = load(example, redactor: redactor);
      final gamma = settings.app('gamma')!;
      final text = [
        'app alpha, app Beta, gamma-app, alphabet',
        'Release-alpha and flavor beta',
        'com.example.alpha com.example.gamma TEAM000001 TEAM000002',
        'credentials team-one team-two',
        'WINCODE_ASC_KEY_DIR_TEAM_ONE WINCODE_DIST_KEY_TEAM_TWO',
        'build/wincode/alpha/signed.ipa',
        '${gamma.output.path}${sep}signed.ipa',
        settings.app('beta')!.profile!.path,
        gamma.entitlements!.path,
      ].join('\n');
      expect(
        redactor.apply(text),
        [
          'app app-1, app app-2, app-3-app, alphabet',
          'Release-app-1 and flavor app-2',
          '<bundle ID 1> <bundle ID 3> <team ID 1> <team ID 2>',
          'credentials credentials-1 credentials-2',
          'WINCODE_ASC_KEY_DIR_CREDENTIALS_1 WINCODE_DIST_KEY_CREDENTIALS_2',
          '<output of app-1>/signed.ipa',
          '<output of app-3>${sep}signed.ipa',
          '<profile of app-2>',
          '<entitlements of app-1>',
        ].join('\n'),
      );
    });

    test(
      'nothing is replaced while redaction is off, and a report always is',
      () {
        final redactor = Redactor(active: false);
        load(example, redactor: redactor);
        const text = 'alpha com.example.alpha TEAM000001 team-one';
        expect(redactor.apply(text), text);
        expect(
          redactor.forReport(text),
          'app-1 <bundle ID 1> <team ID 1> credentials-1',
        );
      },
    );

    test('a flat file keeps <bundle ID> and <team ID>, and names its paths without an app', () {
      final redactor = active();
      final config = loadConfig(
        write(
          'bundle_id: com.example.alpha\nteam_id: TEAM000001\n'
          'profile: ../signing/alpha.mobileprovision\n'
          'entitlements: ios/Runner/Runner.entitlements\n'
          'output: build/out\nflavor: alpha\n',
        ),
        redactor: redactor,
      );
      expect(
        redactor.apply(
          'com.example.alpha TEAM000001 ../signing/alpha.mobileprovision '
          'ios/Runner/Runner.entitlements build/out/signed.ipa ${config.output.path} alpha',
        ),
        '<bundle ID> <team ID> <profile> <entitlements> <output>/signed.ipa <output> flavor-1',
      );
    });

    test('a path is hidden with the file name that carries the brand, and a one-word folder is not a word to hide', () {
      final redactor = active();
      load(
        twoApps(
          alpha: '    profile: signing/Alpha-AppStore.mobileprovision\n    output: out\n',
        ),
        redactor: redactor,
      );
      expect(
        redactor.apply('signing/Alpha-AppStore.mobileprovision about out'),
        '<profile of app-1> about out',
      );
    });

    test('a flavor or configuration that is a common word or very short is not hidden on its own', () {
      final redactor = active();
      load(
        twoApps(
          alpha: '    flavor: release\n    configuration: Release Alpha\n',
          beta: '    flavor: eu\n',
        ),
        redactor: redactor,
      );
      expect(
        redactor.apply('release eu Release Alpha'),
        'release eu configuration-1',
      );
    });

    test('an error message prints the names it knows as placeholders', () {
      final redactor = active();
      final e = failure(
        example.replaceFirst(
          'bundle_id: com.example.beta',
          'bundle_id: com.example.alpha',
        ),
        redactor: redactor,
      );
      final text = clean(redactor.apply(e.describe('wincode preflight')));
      expect(
        text,
        contains('line 14: apps app-2 and app-1 have the same bundle_id'),
      );
      expect(
        text,
        contains(
          'correct the bundle_id of app-2 (line 14) or of app-1 (line 10)',
        ),
      );
      expect(text, isNot(contains('alpha')));
      expect(text, isNot(contains('beta')));
    });

    test(
      'an error about a reference or a team prints the placeholders too',
      () {
        final redactor = active();
        final e = failure(
          twoApps(beta: '    team_id: TEAM000002\n'),
          redactor: redactor,
        );
        expect(
          redactor.apply(e.what),
          contains(
            'apps app-2 and app-1 use the credentials credentials-1, but their team_id differs',
          ),
        );
      },
    );

    test('a refused name is never registered or printed', () {
      final redactor = active();
      final e = failure(
        'apps:\n  Acme-Corp:\n    bundle_id: com.example.one\n',
        redactor: redactor,
        never: ['Acme', 'acme'],
      );
      expect(redactor.apply(e.what), isNot(contains('Acme')));
    });
  });
}
