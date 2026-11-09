import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_cli/src/init_detect.dart';
import 'package:wincode_cli/src/init.dart' show renderConfig;
import 'package:wincode_cli/wincode_cli.dart';
import 'package:wincode_core/testing.dart';

/// Made-up IDs, and the time of every run.
const _bundleId = 'com.example.app';
const _team = 'TEAM000000';
final _now = DateTime.utc(2026, 11, 9, 12);
final _later = DateTime.utc(2027, 9, 5, 12);

/// The `project.pbxproj` of a Runner target with the configurations of [bundleIds]. A null value leaves the setting
/// out. [team] and [entitlements] go into every configuration. [xcconfigOf] gives a configuration the base
/// configuration file `ios/Flutter/<name>`, and [extra] more settings of a configuration.
String _pbxproj(
  Map<String, String?> bundleIds, {
  String? team,
  String? entitlements,
  Map<String, String> xcconfigOf = const {},
  Map<String, Map<String, String>> extra = const {},
}) {
  final configs = StringBuffer();
  final ids = <String>[];
  final files = xcconfigOf.values.toSet().toList();
  for (final (i, MapEntry(key: name, value: bundleId))
      in bundleIds.entries.indexed) {
    final settings = [
      if (bundleId != null) 'PRODUCT_BUNDLE_IDENTIFIER = "$bundleId";',
      if (team != null) 'DEVELOPMENT_TEAM = $team;',
      if (entitlements != null) 'CODE_SIGN_ENTITLEMENTS = $entitlements;',
      for (final MapEntry(:key, :value)
          in (extra[name] ?? const <String, String>{}).entries)
        '$key = "$value";',
    ].join(' ');
    final base = xcconfigOf[name];
    final reference = base == null
        ? ''
        : 'baseConfigurationReference = X${files.indexOf(base)}; ';
    configs
      ..writeln(
        '\t\tT$i = {isa = XCBuildConfiguration; ${reference}buildSettings = {$settings}; name = "$name"; };',
      )
      ..writeln(
        '\t\tP$i = {isa = XCBuildConfiguration; buildSettings = {}; name = "$name"; };',
      );
    ids.add('$i');
  }
  for (final (i, file) in files.indexed) {
    configs.writeln(
      '\t\tX$i = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = "Flutter/$file"; sourceTree = "<group>"; };',
    );
  }
  final children = [for (var i = 0; i < files.length; i++) 'X$i,'].join(' ');
  String list(String prefix) => ids.map((i) => '$prefix$i,').join(' ');
  return '''
// !\$*UTF8*\$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 54;
	objects = {
$configs		G1 = {isa = PBXGroup; children = ($children); sourceTree = "<group>"; };
		C1 = {isa = PBXNativeTarget; buildConfigurationList = D2; name = Runner; productType = "com.apple.product-type.application"; };
		E1 = {isa = PBXProject; buildConfigurationList = D1; mainGroup = G1; targets = (C1,); };
		D1 = {isa = XCConfigurationList; buildConfigurations = (${list('P')}); };
		D2 = {isa = XCConfigurationList; buildConfigurations = (${list('T')}); };
	};
	rootObject = E1;
}
''';
}

Map<String, String?> _same([String id = _bundleId]) => {
  'Debug': id,
  'Profile': id,
  'Release': id,
};

/// A project with the three flavors alpha, beta and gamma, as Flutter lays them out: Debug, Profile and Release for each.
/// The Debug configuration of each flavor has another bundle ID than its Release.
Map<String, String?> _flavors() => {
  'Debug': _bundleId,
  'Profile': _bundleId,
  'Release': _bundleId,
  for (final f in ['alpha', 'beta', 'gamma']) ...{
    'Debug-$f': '$_bundleId.$f.debug',
    'Profile-$f': '$_bundleId.$f',
    'Release-$f': '$_bundleId.$f',
  },
};

void main() {
  late Directory temp;
  late Directory root;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('wincode_init_');
    root = Directory('${temp.path}/app')..createSync();
  });
  tearDown(() => temp.deleteSync(recursive: true));

  /// A Flutter project in [root].
  void flutterProject(
    Map<String, String?> bundleIds, {
    String? team,
    String? entitlementsSetting,
    List<String> entitlementFiles = const ['Runner.entitlements'],
    Map<String, String> xcconfigFiles = const {},
    Map<String, String> xcconfigOf = const {},
    Map<String, Map<String, String>> extra = const {},
  }) {
    if (Directory('${root.path}/ios').existsSync()) {
      Directory('${root.path}/ios').deleteSync(recursive: true);
    }
    File('${root.path}/pubspec.yaml')
      ..createSync()
      ..writeAsStringSync('name: sample\n');
    Directory('${root.path}/ios/Runner.xcodeproj').createSync(recursive: true);
    File('${root.path}/ios/Runner.xcodeproj/project.pbxproj').writeAsStringSync(
      _pbxproj(
        bundleIds,
        team: team,
        entitlements: entitlementsSetting,
        xcconfigOf: xcconfigOf,
        extra: extra,
      ),
    );
    for (final MapEntry(:key, :value) in xcconfigFiles.entries) {
      File('${root.path}/ios/Flutter/$key')
        ..createSync(recursive: true)
        ..writeAsStringSync(value);
    }
    for (final name in entitlementFiles) {
      File('${root.path}/ios/Runner/$name')
        ..createSync(recursive: true)
        ..writeAsStringSync('<plist/>');
    }
  }

  /// The sample of three flavors whose bundle IDs come from per-flavor xcconfig files: alpha through a variable that
  /// its file defines, beta directly, gamma through nested variables and an include chain with an optional file that
  /// is not there. Debug-beta has a bundle ID of its own.
  void xcconfigFlavors() => flutterProject(
    {
      'Debug': _bundleId,
      'Release': _bundleId,
      'Debug-beta': '$_bundleId.beta.debug',
      'Release-alpha': r'$(APP_BUNDLE_ID)',
      'Release-beta': null,
      'Release-gamma': r'$(APP_BUNDLE_ID)',
    },
    xcconfigOf: {
      'Release-alpha': 'alpha.xcconfig',
      'Release-beta': 'beta.xcconfig',
      'Release-gamma': 'gamma.xcconfig',
    },
    xcconfigFiles: {
      'alpha.xcconfig': '#include "Generated.xcconfig"\nAPP_BUNDLE_ID = com.example.app.alpha\nDEVELOPMENT_TEAM = TEAM000000\n',
      'beta.xcconfig': 'PRODUCT_BUNDLE_IDENTIFIER = com.example.app.beta\n',
      'gamma.xcconfig':
          '#include "common.xcconfig"\n#include? "local.xcconfig"\n'
          r'APP_BUNDLE_ID = $(BASE_ID).$(FLAVOR_NAME)'
          '\nFLAVOR_NAME = gamma\n'
          r'CODE_SIGN_ENTITLEMENTS = Runner/$(ENTITLEMENTS_NAME).entitlements'
          '\n',
      'common.xcconfig':
          'BASE_ID = com.example.app\nENTITLEMENTS_NAME = Runner\n'
          r'DEVELOPMENT_TEAM = $(TEAM_FROM_COMMON)'
          '\nTEAM_FROM_COMMON = TEAM000000\n',
    },
  );

  File profile(
    String folder,
    String name, {
    String team = _team,
    String bundleId = _bundleId,
    DateTime? expires,
    bool devices = false,
  }) {
    final dir = Directory('${root.path}/$folder')..createSync(recursive: true);
    return File('${dir.path}/$name')..writeAsBytesSync(
      profileOf(
        appStoreProfile(
          teamId: team,
          bundleId: bundleId,
          expires: expires ?? _later,
          devices: devices,
        ),
      ),
    );
  }

  File config() => File('${root.path}/wincode.yaml');

  /// Runs `wincode init` in [root]. [input] is what the user types; with it, the run is at a terminal, and every typed
  /// line is echoed into stdout as a terminal would.
  Future<({int code, String out, String err, int asked})> init(
    List<String> args, {
    List<String>? input,
    bool terminal = false,
    Map<String, String> env = const {},
    Directory? cwd,
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final lines = [...?input];
    var asked = 0;
    final code = await runWincode(
      ['init', ...args],
      out,
      err,
      environment: env,
      clock: () => _now,
      workingDirectory: cwd ?? root,
      terminal: terminal || input != null,
      readLine: () {
        asked++;
        if (lines.isEmpty) {
          return null;
        }
        final line = lines.removeAt(0);
        out.writeln(line);
        return line;
      },
    );
    return (code: code, out: '$out', err: '$err', asked: asked);
  }

  Map<String, Object?> errorOf(String out) =>
      (jsonDecode(out) as Map<String, Object?>)['error']!
          as Map<String, Object?>;

  group('detection', () {
    test(
      'one bundle ID in every configuration, and the entitlements file',
      () async {
        flutterProject(
          _same(),
          team: _team,
          entitlementsSetting: 'Runner/Runner.entitlements',
        );
        final facts = detectProject(root);
        expect(facts.bundleId, _bundleId);
        expect(facts.teamId, _team);
        expect(facts.entitlements, endsWith('Runner.entitlements'));
        expect(facts.notes, isEmpty);
      },
    );

    test('a bundle ID that is a variable is asked, not guessed', () {
      flutterProject({
        'Debug': r'$(APP_ID)',
        'Profile': r'$(APP_ID)',
        'Release': r'$(APP_ID)',
      });
      final facts = detectProject(root);
      expect(facts.bundleId, isNull);
      expect(facts.bundleIdCandidates, isEmpty);
      expect(facts.notes, [
        r'PRODUCT_BUNDLE_IDENTIFIER of Release needs $(APP_ID), which no build setting or xcconfig file of Release '
            'defines',
      ]);
      expect(facts.unresolved, {
        'PRODUCT_BUNDLE_IDENTIFIER': ['APP_ID'],
      });
    });

    test('a bundle ID that differs between configurations is asked, with each choice', () {
      flutterProject({
        'Debug': '$_bundleId.debug',
        'Profile': _bundleId,
        'Release': _bundleId,
      });
      final facts = detectProject(root);
      expect(facts.bundleId, isNull);
      expect(
        [for (final c in facts.bundleIdCandidates) (c.configuration, c.value)],
        [('Release', _bundleId), ('Debug', '$_bundleId.debug')],
      );
      expect(facts.notes, ['the bundle ID differs between configurations']);
    });

    test(
      'a flavor reads its own Release configuration, and the others are noted',
      () {
        final all = {
          'Release': _bundleId,
          'Release-demo': '$_bundleId.demo',
          'Debug-demo': '$_bundleId.demo',
          'Profile-demo': '$_bundleId.demo',
        };
        flutterProject(all);
        expect(detectProject(root, flavor: 'demo').bundleId, '$_bundleId.demo');
        final plain = detectProject(root);
        expect(plain.bundleId, _bundleId);
        expect(plain.flavors, ['demo']);
        expect(plain.notes, isEmpty);
        expect(
          plain.warnings.single,
          'the project has build configurations other than Debug, Profile and Release: Release-demo, Debug-demo, '
          'Profile-demo. init read Release. To read another, pass --configuration <name>',
        );
        expect(detectProject(root, flavor: 'demo').warnings, isEmpty);
        expect(
          detectProject(root, flavor: 'nope').notes.single,
          contains('no Release-nope configuration'),
        );
      },
    );

    test('without an entitlements file, or with several, none is chosen', () {
      flutterProject(_same(), entitlementFiles: const []);
      expect(detectProject(root).entitlements, isNull);
      flutterProject(
        _same(),
        entitlementFiles: const ['A.entitlements', 'B.entitlements'],
      );
      final facts = detectProject(root);
      expect(facts.entitlements, isNull);
      expect(facts.entitlementsCandidates, hasLength(2));
      flutterProject(
        _same(),
        entitlementsSetting: 'Runner/Gone.entitlements',
        entitlementFiles: const [],
      );
      expect(detectProject(root).notes, [
        'the project names an entitlements file that does not exist',
      ]);
    });

    test('an unreadable project is a note, not a failure', () {
      flutterProject(_same());
      File('${root.path}/ios/Runner.xcodeproj/project.pbxproj')
          .writeAsStringSync('not a project');
      expect(detectProject(root).notes.single, contains('could not be read'));
      File('${root.path}/ios/Runner.xcodeproj/project.pbxproj').deleteSync();
      expect(detectProject(root).notes.single, contains('was not found'));
    });

    test(
      'the project root is the nearest folder above with pubspec.yaml and ios',
      () {
        flutterProject(_same());
        final deep = Directory('${root.path}/lib/src')
          ..createSync(recursive: true);
        expect(findFlutterRoot(deep)!.path, root.absolute.path);
        expect(findFlutterRoot(temp), isNull);
      },
    );
  });

  group('the flavored sample of wincode_core', () {
    // The sample has an app flavor (alpha, beta) in xcconfig files, and org.example.demo in Release.
    void copySample() {
      void copy(Directory from, Directory to) {
        to.createSync(recursive: true);
        for (final entity in from.listSync()) {
          final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (entity is Directory) {
            copy(entity, Directory('${to.path}/$name'));
          } else if (entity is File) {
            entity.copySync('${to.path}/$name');
          }
        }
      }

      copy(
        Directory('../wincode_core/test/fixtures/flavored_sample/ios'),
        Directory('${root.path}/ios'),
      );
      File('${root.path}/pubspec.yaml').writeAsStringSync('name: sample\n');
    }

    test('init reads the bundle ID of the flavor that is asked for, and the entitlements', () async {
      copySample();
      final alpha = await init([
        '--yes',
        '--flavor',
        'alpha',
        '--team-id',
        _team,
      ]);
      expect(alpha.code, 0, reason: alpha.err);
      final config = loadConfig('${root.path}/wincode.yaml');
      expect(
        (config.bundleId, config.teamId),
        ('org.example.demo.alpha', _team),
      );
      expect(
        File('${root.path}/wincode.yaml').readAsStringSync(),
        contains('entitlements: ios/Runner/Runner.entitlements\n'),
      );
    });

    test('without a flavor, init says the project has flavors, and reads the plain Release', () async {
      copySample();
      final plain = await init(['--yes', '--team-id', _team]);
      expect(plain.code, 0, reason: plain.err);
      expect(
        plain.out,
        contains(
          'WARN  the project has build configurations other than Debug, Profile and Release: Release-alpha, '
          'Release-beta. init read Release. To read another, pass --configuration <name>.\n',
        ),
      );
      expect(
        loadConfig('${root.path}/wincode.yaml').bundleId,
        'org.example.demo',
      );
    });

    test('it refuses to overwrite the file that it wrote', () async {
      copySample();
      expect(
        (await init(['--yes', '--flavor', 'beta', '--team-id', _team])).code,
        0,
      );
      final again = await init([
        '--yes',
        '--flavor',
        'alpha',
        '--team-id',
        _team,
      ]);
      expect(again.code, 1);
      expect(
        again.out,
        contains(
          '- bundle_id: org.example.demo.beta\n+ bundle_id: org.example.demo.alpha\n',
        ),
      );
    });
  });

  group('the profile folder', () {
    test('lists the App Store profiles of this app that have not expired, and says why it skips the others', () async {
      flutterProject(_same());
      final good = profile('signing', 'Good.mobileprovision');
      profile('signing', 'Dev.mobileprovision', devices: true);
      profile(
        'signing',
        'Old.mobileprovision',
        expires: _now.subtract(const Duration(days: 1)),
      );
      profile(
        'signing',
        'Other.mobileprovision',
        bundleId: 'com.example.other',
      );
      File('${root.path}/signing/Broken.mobileprovision')
          .writeAsStringSync('nothing');
      File('${root.path}/signing/notes.txt').writeAsStringSync('ignored');
      final scan = await scanProfiles(
        Directory('${root.path}/signing'),
        bundleId: _bundleId,
        now: _now,
      );
      expect(
        [for (final u in scan.usable) u.file.uri.pathSegments.last],
        [good.uri.pathSegments.last],
      );
      expect(scan.skipped, [
        'Broken.mobileprovision is not a provisioning profile',
        'Dev.mobileprovision is not an App Store profile',
        'Old.mobileprovision has expired',
        'Other.mobileprovision is for another app',
      ]);
    });
  });

  group('non-interactive', () {
    test(
      '--yes accepts what was found, writes wincode.yaml, and never asks',
      () async {
        flutterProject(
          _same(),
          entitlementsSetting: 'Runner/Runner.entitlements',
        );
        profile('signing', 'App.mobileprovision');
        final run = await init(['--yes', '--profile-dir', 'signing']);
        expect((run.code, run.err, run.asked), (0, '', 0));
        expect(config().readAsStringSync(), '''
# wincode.yaml: one app, no secrets. Paths are relative to this file.
# Written by wincode init. The App Store Connect key is not stored here: it comes from the folder that
# WINCODE_ASC_KEY_DIR names. Keep the profile out of git working trees, or let .gitignore list it.

# The app that wincode ships (the PRODUCT_BUNDLE_IDENTIFIER of its build), and the team that signs it.
bundle_id: com.example.app
team_id: TEAM000000

# The App Store profile, as the developer portal delivers it. wincode sign signs with it.
profile: signing/App.mobileprovision

# The app's own entitlements file, if it has one. wincode sign signs the app with the keys in it.
entitlements: ios/Runner/Runner.entitlements

# The workflow that wincode build starts (<owner>/<repository>/.github/workflows/<file>@<branch or tag>).
# workflow: example-org/example-app/.github/workflows/wincode-ios.yml@main

# Where wincode build and wincode sign write their IPAs.
output: build/wincode
''');
        final loaded = loadConfig(config().path);
        expect((loaded.bundleId, loaded.teamId), (_bundleId, _team));
        expect(run.out, contains('list signing/ in .gitignore'));
        expect(run.out, contains('wincode preflight --dry-run\n'));
      },
    );

    test('every field from flags, with a team ID of digits that stays text', () async {
      flutterProject(_same());
      final file = profile('signing', 'A.mobileprovision', team: '0123456789');
      final run = await init([
        '--yes',
        '--json',
        '--bundle-id',
        'org.example.other',
        '--team-id',
        '0123456789',
        '--profile',
        file.path,
        '--entitlements',
        'ios/Runner/Runner.entitlements',
        '--workflow-ref',
        'example-org/example-app/.github/workflows/wincode-ios.yml@main',
        '--output',
        'out dir',
      ]);
      expect(run.code, 0, reason: run.err);
      expect(jsonDecode(run.out), {
        'command': 'init',
        'ok': true,
        'exitCode': 0,
        'dryRun': false,
        'written': true,
        'config': {
          'bundle_id': 'org.example.other',
          'team_id': '0123456789',
          'profile': 'A.mobileprovision',
          'entitlements': 'Runner.entitlements',
          'workflow':
              'example-org/example-app/.github/workflows/wincode-ios.yml@main',
          'output': 'out dir',
        },
      });
      final loaded = loadConfig(config().path);
      expect(
        (loaded.bundleId, loaded.teamId),
        ('org.example.other', '0123456789'),
      );
      expect(loaded.output.path, endsWith('out dir'));
      expect(loaded.workflow!.ref, 'main');
      expect(config().readAsStringSync(), contains("team_id: '0123456789'"));
    });

    test(
      'a value of the wrong shape is a usage error that names the option',
      () async {
        flutterProject(_same());
        final run = await init(['--yes', '--json', '--team-id', 'abc']);
        expect(run.code, 64);
        expect(errorOf(run.out), containsPair('id', 'init-value-invalid'));
        expect(
          errorOf(run.out)['what'],
          '--team-id: it is not a team ID: 10 capital letters and digits',
        );
        expect(config().existsSync(), isFalse);
      },
    );

    test('what is missing is listed with the options that give it, and nothing is written', () async {
      flutterProject({
        'Debug': '$_bundleId.debug',
        'Profile': _bundleId,
        'Release': _bundleId,
      });
      final run = await init(['--yes', '--json']);
      expect(run.code, 64);
      final error = errorOf(run.out);
      expect(error['id'], 'init-input-missing');
      expect(
        error['what'],
        'init cannot ask here, and 2 values are not settled. bundle_id: detected several (com.example.app in '
        'ios/Runner.xcodeproj (Release), com.example.app.debug in ios/Runner.xcodeproj (Debug)); pass --bundle-id. '
        'team_id: not detected; pass --team-id.',
      );
      expect(error['next'], contains('add --yes to accept what init found'));
      expect(config().existsSync(), isFalse);
    });

    test('without --yes, a run in CI or without a terminal asks nothing, even when init found everything', () async {
      flutterProject(_same(), team: _team);
      for (final (env, terminal) in [
        (const {'CI': 'true'}, true),
        (const <String, String>{}, false),
      ]) {
        final run = await init([], env: env, terminal: terminal);
        expect(run.code, 64, reason: '$env $terminal');
        expect(run.asked, 0);
        expect(
          run.err
              .replaceAll('<bundle ID>', 'com.example.app')
              .replaceAll('<team ID>', _team),
          contains(
            'bundle_id: detected com.example.app in ios/Runner.xcodeproj (Release); confirm with --yes or pass '
            '--bundle-id. team_id: detected TEAM000000 in ios/Runner.xcodeproj (Release); confirm with --yes or pass '
            '--team-id. entitlements: detected ios/Runner/Runner.entitlements in ios/Runner; confirm with --yes or '
            'pass --entitlements.',
          ),
          reason: '$env $terminal',
        );
      }
      expect(config().existsSync(), isFalse);
    });

    test('--json never asks either', () async {
      flutterProject(_same(), team: _team);
      final run = await init(['--json'], input: ['x'], terminal: true);
      expect((run.code, run.asked), (64, 0));
    });
  });

  group('interactive', () {
    test(
      'shows what it found, asks to confirm each value, and writes the file',
      () async {
        flutterProject(
          _same(),
          entitlementsSetting: 'Runner/Runner.entitlements',
        );
        profile('signing', 'App.mobileprovision');
        final run = await init(
          ['--redact'],
          input: ['', 'signing', '', '', '', ''],
        );
        expect((run.code, run.err), (0, ''));
        // The terminal shows a trailing space after each prompt; the comparison ignores the ends of lines.
        expect(run.out.split('\n').map((l) => l.trimRight()).join('\n'), '''
Bundle ID [<bundle ID>]:
Folder with the App Store profile (Enter to skip): signing
Profile [App.mobileprovision, valid until 2027-09-05] (- for none):
Team ID [<team ID> (the profile)]:
Entitlements file [ios/Runner/Runner.entitlements] (- for none):
--- wincode.yaml
# wincode.yaml: one app, no secrets. Paths are relative to this file.
# Written by wincode init. The App Store Connect key is not stored here: it comes from the folder that
# WINCODE_ASC_KEY_DIR names. Keep the profile out of git working trees, or let .gitignore list it.

# The app that wincode ships (the PRODUCT_BUNDLE_IDENTIFIER of its build), and the team that signs it.
bundle_id: <bundle ID>
team_id: <team ID>

# The App Store profile, as the developer portal delivers it. wincode sign signs with it.
profile: signing/App.mobileprovision

# The app's own entitlements file, if it has one. wincode sign signs the app with the keys in it.
entitlements: ios/Runner/Runner.entitlements

# The workflow that wincode build starts (<owner>/<repository>/.github/workflows/<file>@<branch or tag>).
# workflow: example-org/example-app/.github/workflows/wincode-ios.yml@main

# Where wincode build and wincode sign write their IPAs.
output: build/wincode
---
Write wincode.yaml? [Y/n]
Wrote wincode.yaml.
The profile is inside the project: list signing/ in .gitignore, so that it is never committed (init does not edit .gitignore).

Next:
  1. Put AuthKey_<Key ID>.p8, as App Store Connect delivered it, and a file issuer-id with the Issuer ID in a folder outside the project and outside OneDrive, and set WINCODE_ASC_KEY_DIR to it. init never stores them.
  2. wincode preflight --dry-run
  3. wincode preflight    (checks signed.ipa in the output folder; name another IPA as the last argument)
''');
        final text = config().readAsStringSync();
        expect(text, contains('bundle_id: com.example.app'));
        expect(text, contains('team_id: TEAM000000'));
      },
    );

    test('several bundle IDs are listed and chosen by number; a typed value is checked and asked again', () async {
      flutterProject({
        'Debug': '$_bundleId.debug',
        'Profile': _bundleId,
        'Release': _bundleId,
      });
      final run = await init(
        [],
        input: ['nonsense', '2', '', 'TEAM000000', '-', 'y'],
      );
      expect(run.code, 0, reason: run.err);
      expect(
        run.out,
        contains(
          'Bundle ID: init found several.\n  1) com.example.app (Release)\n  2) com.example.app.debug (Debug)\n',
        ),
      );
      expect(run.out, contains('nonsense: it is not a bundle ID'));
      expect(loadConfig(config().path).bundleId, '$_bundleId.debug');
    });

    test('with --redact, a list of choices stays readable', () async {
      flutterProject({
        'Debug': '$_bundleId.debug',
        'Profile': _bundleId,
        'Release': _bundleId,
      });
      final run = await init(
        ['--redact'],
        input: ['1', '', 'TEAM000000', '', 'n'],
      );
      expect(
        run.out,
        contains('  1) <bundle ID 1> (Release)\n  2) <bundle ID 2> (Debug)\n'),
      );
      expect(run.out, endsWith('Nothing was written.\n'));
      expect(config().existsSync(), isFalse);
    });

    test('input that ends is an error, and nothing is written', () async {
      flutterProject(_same());
      final run = await init(['--json'], input: [], terminal: true);
      // --json asks nothing: the missing team ID is reported instead.
      expect(run.code, 64);
      final plain = await init([], input: ['']);
      expect(plain.code, 64);
      expect(
        plain.err,
        contains('the input ended before init had all it needs'),
      );
      expect(config().existsSync(), isFalse);
    });
  });

  group('safety', () {
    test(
      'an existing wincode.yaml is not replaced, and the changes are shown',
      () async {
        flutterProject(_same());
        config().writeAsStringSync(
          'bundle_id: org.example.old\r\nteam_id: TEAM000000\r\noutput: build/wincode\r\n',
        );
        final run = await init(['--yes', '--team-id', _team]);
        expect(run.code, 1);
        expect(run.out, contains('Changes init would make to wincode.yaml'));
        expect(run.out, contains('- bundle_id: org.example.old\n'));
        expect(run.out, contains('+ bundle_id: com.example.app\n'));
        expect(
          run.err,
          startsWith('wincode init: wincode.yaml already exists\n'),
        );
        expect(run.err, contains('wincode init --force'));
        expect(
          config().readAsStringSync(),
          startsWith('bundle_id: org.example.old'),
        );
        expect(run.asked, 0);
      },
    );

    test('--force replaces it', () async {
      flutterProject(_same());
      config().writeAsStringSync(
        'bundle_id: org.example.old\nteam_id: TEAM000000\n',
      );
      final run = await init(['--yes', '--force', '--team-id', _team]);
      expect(run.code, 0, reason: run.err);
      expect(loadConfig(config().path).bundleId, _bundleId);
    });

    test('--dry-run prints the file and writes nothing, not even the workflow; it still refuses an existing file', () async {
      flutterProject(_same());
      final run = await init([
        '--yes',
        '--dry-run',
        '--workflow',
        '--team-id',
        _team,
      ]);
      expect(run.code, 0, reason: run.err);
      expect(run.out, contains('bundle_id: com.example.app'));
      expect(run.out, contains('Dry run: nothing was written.'));
      expect(
        run.out,
        contains(
          'It would copy the reference workflow to .github/workflows/wincode-ios.yml.',
        ),
      );
      expect(config().existsSync(), isFalse);
      expect(Directory('${root.path}/.github').existsSync(), isFalse);
      config().writeAsStringSync(
        'bundle_id: org.example.old\nteam_id: TEAM000000\n',
      );
      expect((await init(['--yes', '--dry-run', '--team-id', _team])).code, 1);
    });

    test('--redact and CI hide the IDs in everything printed, and the file keeps them', () async {
      flutterProject(_same());
      for (final (args, env) in [
        (['--yes', '--redact', '--team-id', _team], const <String, String>{}),
        (['--yes', '--force', '--team-id', _team], const {'CI': 'true'}),
      ]) {
        final run = await init(args, env: env);
        expect(run.code, 0, reason: run.err);
        expect(
          '${run.out}${run.err}',
          isNot(contains('com.example')),
          reason: '$args $env',
        );
        expect('${run.out}${run.err}', isNot(contains(_team)));
        expect(run.out, contains('bundle_id: <bundle ID>'));
        expect(
          config().readAsStringSync(),
          contains('bundle_id: com.example.app'),
        );
        expect(config().readAsStringSync(), contains('team_id: TEAM000000'));
      }
    });

    test('a profile in a git working tree that git does not ignore is refused, and nothing is written', () async {
      flutterProject(_same());
      expect(
        (await Process.run('git', ['-C', root.path, 'init', '-q'])).exitCode,
        0,
      );
      final file = profile('signing', 'App.mobileprovision');
      for (final args in [
        ['--yes', '--profile-dir', 'signing'],
        ['--yes', '--profile', file.path, '--team-id', _team],
      ]) {
        final run = await init([...args, '--json']);
        expect(run.code, 78, reason: '$args');
        expect(errorOf(run.out), containsPair('id', 'key-in-git-tree'));
        expect(
          errorOf(run.out)['what'],
          'the profile points inside a git working tree, and git does not ignore the file',
        );
        expect(
          errorOf(run.out)['next'],
          contains('move the file outside every project folder'),
        );
        expect('${run.out}${run.err}', isNot(contains(temp.path)));
        expect(config().existsSync(), isFalse);
      }
      File('${root.path}/.gitignore').writeAsStringSync('signing/\n');
      final ok = await init(['--yes', '--profile-dir', 'signing']);
      expect(ok.code, 0, reason: ok.err);
      expect(
        loadConfig(config().path).profile!.path,
        endsWith('App.mobileprovision'),
      );
      expect(File('${root.path}/.gitignore').readAsStringSync(), 'signing/\n');
    });

    test('the file never holds a key or the key folder, and init does not edit .gitignore', () async {
      flutterProject(_same());
      final keys = Directory('${temp.path}/asc')..createSync();
      File('${keys.path}/AuthKey_ABCDE12345.p8')
          .writeAsStringSync('not a real key');
      File('${root.path}/.gitignore').writeAsStringSync('build/\n');
      final run = await init(
        ['--yes', '--team-id', _team],
        env: {'WINCODE_ASC_KEY_DIR': keys.path},
      );
      expect(run.code, 0, reason: run.err);
      final text = config().readAsStringSync();
      expect(text, isNot(contains(keys.path)));
      expect(text, isNot(contains('ABCDE12345')));
      expect(
        RegExp(r'^[a-z_]+:', multiLine: true).allMatches(text).map((m) => m[0]),
        ['bundle_id:', 'team_id:', 'entitlements:', 'output:'],
      );
      expect(File('${root.path}/.gitignore').readAsStringSync(), 'build/\n');
    });

    test('a folder without a Flutter project is refused', () async {
      final run = await init(['--yes'], cwd: temp);
      expect(run.code, 1);
      expect(
        run.err,
        startsWith(
          'wincode init: there is no Flutter project in this folder or above it\n',
        ),
      );
    });
  });

  group('the reference workflow', () {
    test('--workflow copies the template byte for byte, and never replaces a file', () async {
      flutterProject(_same());
      final run = await init(['--yes', '--workflow', '--team-id', _team]);
      expect(run.code, 0, reason: run.err);
      final copy = File('${root.path}/.github/workflows/wincode-ios.yml');
      expect(
        copy.readAsBytesSync(),
        File('templates/wincode-ios.yml').readAsBytesSync(),
      );
      expect(
        run.out,
        contains(
          'Copied the reference workflow to .github/workflows/wincode-ios.yml.',
        ),
      );

      copy.writeAsStringSync('mine');
      final again = await init([
        '--yes',
        '--force',
        '--workflow',
        '--team-id',
        _team,
        '--json',
      ]);
      expect(again.code, 1);
      expect(errorOf(again.out), containsPair('id', 'workflow-exists'));
      expect(copy.readAsStringSync(), 'mine');
    });

    test('without --workflow nothing is copied', () async {
      flutterProject(_same());
      await init(['--yes', '--team-id', _team]);
      expect(Directory('${root.path}/.github').existsSync(), isFalse);
    });
  });

  group('paths', () {
    test('relativePath gives forward slashes, steps up, and works across mixed separators', () {
      final base = Directory('${temp.path}/a/b')..createSync(recursive: true);
      expect(
        relativePath(base.path, '${temp.path}/a/c/x.mobileprovision'),
        '../c/x.mobileprovision',
      );
      expect(
        relativePath(base.path, '${base.path}/ios/Runner.entitlements'),
        'ios/Runner.entitlements',
      );
      expect(relativePath(base.path, '${base.path}/../b/./x'), 'x');
      if (Platform.isWindows) {
        expect(
          relativePath(
            r'C:\Users\me\app',
            r'C:\Users\me\signing\A.mobileprovision',
          ),
          '../signing/A.mobileprovision',
        );
        expect(
          relativePath(
            r'C:\Users\me\app',
            r'c:\users\ME\app\ios\Runner.entitlements',
          ),
          'ios/Runner.entitlements',
        );
        expect(
          relativePath(r'C:\Users\me\app', r'D:\signing\A.mobileprovision'),
          isNull,
        );
      }
    });

    test('a profile outside the project is written as a path relative to wincode.yaml', () async {
      flutterProject(_same());
      final file = File('${temp.path}/signing/A.mobileprovision')
        ..createSync(recursive: true)
        ..writeAsBytesSync(
          profileOf(
            appStoreProfile(
              teamId: _team,
              bundleId: _bundleId,
              expires: _later,
            ),
          ),
        );
      final run = await init(['--yes', '--profile', file.path]);
      expect(run.code, 0, reason: run.err);
      expect(
        config().readAsStringSync(),
        contains('profile: ../signing/A.mobileprovision\n'),
      );
      expect(run.out, isNot(contains('is inside the project')));
      expect(
        File(loadConfig(config().path).profile!.path).existsSync(),
        isTrue,
      );
    });

    test('--config names the file, and the next steps name it', () async {
      flutterProject(_same());
      final run = await init([
        '--yes',
        '--team-id',
        _team,
        '--config',
        'wincode.beta.yaml',
      ]);
      expect(run.code, 0, reason: run.err);
      expect(File('${root.path}/wincode.beta.yaml').existsSync(), isTrue);
      expect(
        run.out,
        contains('wincode preflight --config "wincode.beta.yaml" --dry-run'),
      );
    });
  });

  group('--flavor reads only Release-<flavor>', () {
    test('Debug-X with another bundle ID does not matter, and the output says which configuration was read', () async {
      flutterProject(_flavors(), team: _team);
      final run = await init(['--yes', '--json', '--flavor', 'beta']);
      expect(run.code, 0, reason: run.err);
      expect(loadConfig(config().path).bundleId, '$_bundleId.beta');
      expect(
        run.err,
        startsWith(
          'Read the build configuration Release-beta of ios/Runner.xcodeproj.\n',
        ),
      );
      expect(run.err, isNot(contains('WARN')));
      expect(
        (jsonDecode(run.out) as Map<String, Object?>)['configuration'],
        'Release-beta',
      );
    });

    test('three flavors with literal values', () async {
      flutterProject(_flavors(), team: _team);
      for (final flavor in ['alpha', 'beta', 'gamma']) {
        final run = await init(['--yes', '--force', '--flavor', flavor]);
        expect(run.code, 0, reason: '$flavor: ${run.err}');
        expect(loadConfig(config().path).bundleId, '$_bundleId.$flavor');
        expect(
          run.out,
          contains(
            'Read the build configuration Release-$flavor of ios/Runner.xcodeproj.\n',
          ),
        );
      }
    });

    test(
      'without --flavor, Debug and Profile are still compared with Release',
      () async {
        flutterProject({
          'Debug': '$_bundleId.debug',
          'Profile': _bundleId,
          'Release': _bundleId,
        }, team: _team);
        final run = await init(['--yes']);
        expect(run.code, 64);
        expect(run.err, contains('bundle_id: detected several'));
        expect(run.out, isNot(contains('Read the build configuration')));
      },
    );

    test('bundle IDs, the team and the entitlements come from per-flavor xcconfig files', () async {
      xcconfigFlavors();
      final alpha = await init(['--yes', '--flavor', 'alpha']);
      expect(alpha.code, 0, reason: alpha.err);
      expect(alpha.out, isNot(contains('note:')));
      final loaded = loadConfig(config().path);
      expect((loaded.bundleId, loaded.teamId), ('$_bundleId.alpha', _team));

      final beta = await init([
        '--yes',
        '--force',
        '--flavor',
        'beta',
        '--team-id',
        _team,
      ]);
      expect(beta.code, 0, reason: beta.err);
      expect(loadConfig(config().path).bundleId, '$_bundleId.beta');
    });

    test('nested variables follow an include chain, and an optional include that is missing is skipped', () async {
      xcconfigFlavors();
      final run = await init(['--yes', '--flavor', 'gamma']);
      expect(run.code, 0, reason: run.err);
      final loaded = loadConfig(config().path);
      expect((loaded.bundleId, loaded.teamId), ('$_bundleId.gamma', _team));
      expect(
        config().readAsStringSync(),
        contains('entitlements: ios/Runner/Runner.entitlements\n'),
      );
      expect(run.out, isNot(contains('note:')));
    });

    test('a variable that nothing defines is listed, and a run that cannot ask fails with it', () async {
      flutterProject({'Release-gamma': r'$(GAMMA_ID)'}, team: _team);
      final run = await init(['--yes', '--json', '--flavor', 'gamma']);
      expect(run.code, 64);
      expect(
        run.err,
        contains(
          r'note: PRODUCT_BUNDLE_IDENTIFIER of Release-gamma needs $(GAMMA_ID), which no build setting or xcconfig '
          'file of Release-gamma defines.',
        ),
      );
      expect(
        errorOf(run.out)['what'],
        contains(
          r'bundle_id: not detected ($(GAMMA_ID) is not defined in Release-gamma or its xcconfig files); pass --bundle-id',
        ),
      );
      expect(config().existsSync(), isFalse);

      final given = await init([
        '--yes',
        '--flavor',
        'gamma',
        '--bundle-id',
        '$_bundleId.gamma',
      ]);
      expect(given.code, 0, reason: given.err);
    });

    test('at a terminal, a variable that nothing defines is asked', () async {
      flutterProject({'Release-gamma': r'$(GAMMA_ID)'}, team: _team);
      final run = await init(
        ['--flavor', 'gamma'],
        input: ['$_bundleId.gamma', '', '', '', ''],
      );
      expect(run.code, 0, reason: run.err);
      expect(
        run.out,
        contains(
          r'note: PRODUCT_BUNDLE_IDENTIFIER of Release-gamma needs $(GAMMA_ID)',
        ),
      );
      expect(run.out, contains('Bundle ID: com.example.app.gamma\n'));
      expect(loadConfig(config().path).bundleId, '$_bundleId.gamma');
    });

    test(
      'an unresolved team ID or entitlements file is listed too, never guessed',
      () async {
        flutterProject(
          {'Release-gamma': '$_bundleId.gamma'},
          entitlementFiles: const [],
          extra: {
            'Release-gamma': {
              'DEVELOPMENT_TEAM': r'$(TEAM_VAR)',
              'CODE_SIGN_ENTITLEMENTS': r'Runner/$(ENT).entitlements',
            },
          },
        );
        final run = await init(['--yes', '--json', '--flavor', 'gamma']);
        expect(run.code, 64);
        final what = errorOf(run.out)['what']! as String;
        expect(
          what,
          contains(
            r'team_id: not detected ($(TEAM_VAR) is not defined in Release-gamma or its xcconfig files); pass --team-id',
          ),
        );
        expect(
          what,
          contains(
            r'entitlements: not detected ($(ENT) is not defined in Release-gamma or its xcconfig files); pass --entitlements',
          ),
        );
      },
    );

    test(
      'variables that refer to each other are reported, not followed forever',
      () async {
        flutterProject(
          {'Release-x': r'$(A)'},
          extra: {
            'Release-x': {'A': r'$(B)', 'B': r'$(A)'},
          },
        );
        final run = await init(['--yes', '--flavor', 'x', '--team-id', _team]);
        expect(run.code, 64);
        expect(
          run.out,
          contains(
            'note: PRODUCT_BUNDLE_IDENTIFIER of Release-x cannot be resolved: build settings refer to each other in a loop',
          ),
        );
      },
    );

    test('an include cycle is reported without a path of this PC, and nothing is guessed', () async {
      flutterProject(
        {'Release-alpha': r'$(APP_BUNDLE_ID)'},
        xcconfigOf: {'Release-alpha': 'alpha.xcconfig'},
        xcconfigFiles: {
          'alpha.xcconfig': '#include "beta.xcconfig"\nAPP_BUNDLE_ID = com.example.app.alpha\n',
          'beta.xcconfig': '#include "alpha.xcconfig"\n',
        },
      );
      final run = await init([
        '--yes',
        '--flavor',
        'alpha',
        '--team-id',
        _team,
      ]);
      expect(run.code, 64);
      expect(
        run.out,
        contains(
          'note: the settings of Release-alpha could not be read: alpha.xcconfig: #include is circular',
        ),
      );
      expect('${run.out}${run.err}', isNot(contains(temp.path)));
      expect(run.err, contains('bundle_id: not detected; pass --bundle-id'));
    });
  });

  group('--configuration', () {
    test('without it, init reads Release and warns about the other configurations', () async {
      flutterProject(_flavors());
      final run = await init(['--yes', '--json', '--team-id', _team]);
      expect(run.code, 0, reason: run.err);
      expect(loadConfig(config().path).bundleId, _bundleId);
      const others =
          'Debug-alpha, Profile-alpha, Release-alpha, Debug-beta, Profile-beta, Release-beta, Debug-gamma, '
          'Profile-gamma, Release-gamma';
      expect(
        run.err,
        contains(
          'WARN  the project has build configurations other than Debug, Profile and Release: $others. init read '
          'Release. To read another, pass --configuration <name>.\n',
        ),
      );
      expect((jsonDecode(run.out) as Map<String, Object?>)['warnings'], [
        'the project has build configurations other than Debug, Profile and Release: $others. init read Release. '
            'To read another, pass --configuration <name>',
      ]);
    });

    test('with it, init reads that configuration only, and does not compare Debug and Profile with it', () async {
      flutterProject(_flavors(), team: _team);
      final run = await init(['--yes', '--configuration', 'Release-beta']);
      expect(run.code, 0, reason: run.err);
      expect(loadConfig(config().path).bundleId, '$_bundleId.beta');
      expect(run.out, isNot(contains('WARN')));
      expect(run.out, isNot(contains('note:')));
    });

    test(
      'a configuration that does not exist fails and lists the ones that do',
      () async {
        flutterProject(_flavors());
        final run = await init([
          '--yes',
          '--json',
          '--configuration',
          'Release-delta',
        ]);
        expect(run.code, 1);
        expect(errorOf(run.out), containsPair('id', 'configuration-not-found'));
        expect(
          errorOf(run.out)['what'],
          'the Xcode project has no build configuration named Release-delta; it has Debug, Profile, Release, '
          'Debug-alpha, Profile-alpha, Release-alpha, Debug-beta, Profile-beta, Release-beta, Debug-gamma, Profile-gamma, '
          'Release-gamma',
        );
        expect(
          errorOf(run.out)['next'],
          startsWith('pass one of those names to --configuration'),
        );
        expect(config().existsSync(), isFalse);
      },
    );

    test(
      'a variable bundle ID in that configuration is asked, not guessed',
      () async {
        flutterProject({'Release': _bundleId, 'Release-x': r'$(APP_ID)'});
        final run = await init([
          '--yes',
          '--configuration',
          'Release-x',
          '--team-id',
          _team,
        ]);
        expect(run.code, 64);
        expect(
          run.out,
          contains(
            r'note: PRODUCT_BUNDLE_IDENTIFIER of Release-x needs $(APP_ID), which no build setting or xcconfig file of '
            'Release-x defines.',
          ),
        );
        expect(
          run.err,
          contains(
            r'bundle_id: not detected ($(APP_ID) is not defined in Release-x or its xcconfig files); pass --bundle-id',
          ),
        );
      },
    );

    test('--flavor and --configuration together are a usage error', () async {
      flutterProject(_flavors());
      final run = await init([
        '--yes',
        '--json',
        '--flavor',
        'beta',
        '--configuration',
        'Release-beta',
      ]);
      expect(run.code, 64);
      expect(
        errorOf(run.out)['what'],
        '--flavor and --configuration both name the build configuration to read',
      );
    });
  });

  test('the messages of a run that cannot ask are test/goldens/init-messages.txt (UPDATE_GOLDENS=1 rewrites it)', () async {
    final report = StringBuffer();
    Future<void> run(
      String setup,
      List<String> args, {
      Map<String, String> env = const {},
    }) async {
      final result = await init(args, env: env);
      report
        ..writeln('# $setup')
        ..writeln([r'$ wincode init', ...args].join(' '))
        ..write(result.out)
        ..write(
          result.err.isEmpty
              ? ''
              : result.err
                    .trimRight()
                    .split('\n')
                    .map((l) => 'stderr: $l\n')
                    .join(),
        )
        ..writeln('exit ${result.code}')
        ..writeln();
    }

    flutterProject(_same(), team: _team);
    await run(
      'everything was detected, and nothing can be confirmed (no terminal)',
      ['--redact'],
    );
    await run('the same in CI, with --json', ['--json'], env: {'CI': 'true'});
    flutterProject({
      'Debug': '$_bundleId.debug',
      'Profile': _bundleId,
      'Release': _bundleId,
    });
    await run('several bundle IDs, and no team ID anywhere', ['--redact']);
    flutterProject(_flavors());
    await run('the project has flavors, and the plain Release is read', [
      '--redact',
      '--dry-run',
      '--yes',
      '--team-id',
      _team,
    ]);
    await run('a configuration that does not exist', [
      '--redact',
      '--configuration',
      'Release-delta',
    ]);
    xcconfigFlavors();
    await run(
      '--flavor alpha: the bundle ID and the team ID come from the flavor\'s xcconfig file',
      ['--redact', '--dry-run', '--yes', '--flavor', 'alpha'],
    );
    await run('--flavor gamma: nested variables through an include chain', [
      '--redact',
      '--dry-run',
      '--yes',
      '--flavor',
      'gamma',
    ]);
    flutterProject({'Release-delta': r'$(DELTA_ID)'}, team: _team);
    await run('--flavor delta: a variable that nothing defines', [
      '--redact',
      '--yes',
      '--flavor',
      'delta',
    ]);
    await run('--flavor together with --configuration', [
      '--redact',
      '--flavor',
      'beta',
      '--configuration',
      'Release-beta',
    ]);
    final golden = File('test/goldens/init-messages.txt');
    if (Platform.environment['UPDATE_GOLDENS'] != null) {
      golden.writeAsStringSync('$report');
    }
    expect('$report', golden.readAsStringSync().replaceAll('\r\n', '\n'));
  });

  test('renderConfig quotes what YAML would misread, and comments out what is not known', () {
    final text = renderConfig(teamId: '1E12345678', output: "it's");
    expect(text, contains("team_id: '1E12345678'"));
    expect(text, contains("output: 'it''s'"));
    expect(text, contains('# bundle_id: com.example.app'));
    expect(text, contains('# profile: ../signing/App_Store.mobileprovision'));
  });

  test('diffLines lists the lines only one side has, in order', () {
    expect(diffLines(['a', 'b', 'c'], ['a', 'x', 'c', 'd']), [
      '- b',
      '+ x',
      '+ d',
    ]);
    expect(diffLines(['a'], ['a']), isEmpty);
  });
}
