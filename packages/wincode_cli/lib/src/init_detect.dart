import 'dart:io';

import 'package:wincode_core/wincode_core.dart';

import 'config.dart';
import 'failure.dart';
import 'key_location.dart';

/// What `wincode init` found in a Flutter project's `ios` folder, without writing anything.
///
/// A value is set only when it is unambiguous. When a setting is a variable that cannot be resolved, or differs between
/// configurations, [bundleIdCandidates] lists what was found and [bundleId] stays null: `init` asks, and never guesses.
class ProjectFacts {
  const ProjectFacts({
    this.bundleId,
    this.bundleIdCandidates = const [],
    this.teamId,
    this.entitlements,
    this.entitlementsCandidates = const [],
    this.flavors = const [],
    this.configuration,
    this.configurations = const [],
    this.entitlementsNamedByProject = false,
    this.unresolved = const {},
    this.warnings = const [],
    this.notes = const [],
  });

  final String? bundleId;

  /// The distinct bundle IDs found, each with the configuration that has it, when [bundleId] could not be chosen.
  final List<({String configuration, String value})> bundleIdCandidates;

  /// `DEVELOPMENT_TEAM` of the release configuration, when it is a team ID.
  final String? teamId;

  /// The entitlements file of the release configuration, as an absolute path.
  final String? entitlements;

  /// The `.entitlements` files of `ios/Runner`, when there are several and none is named by the project.
  final List<String> entitlementsCandidates;

  /// The flavors of the project: the `Release-<flavor>` configurations.
  final List<String> flavors;

  /// The build configuration that the settings were read from (`Release`, `Release-<flavor>` or the one asked for).
  final String? configuration;

  /// Every build configuration of the `Runner` target; empty when the project could not be read.
  final List<String> configurations;

  /// Whether the project names the entitlements file in `CODE_SIGN_ENTITLEMENTS`, rather than `ios/Runner` having it.
  final bool entitlementsNamedByProject;

  /// The variables that stayed unresolved in the configuration that was read, by setting (`PRODUCT_BUNDLE_IDENTIFIER`,
  /// `DEVELOPMENT_TEAM`, `CODE_SIGN_ENTITLEMENTS`): no build setting or xcconfig file of it defines them.
  final Map<String, List<String>> unresolved;

  /// What the user should look at, such as build configurations that were not read.
  final List<String> warnings;

  /// What could not be read, and why, for the user.
  final List<String> notes;
}

/// The root of the Flutter project at or above [from]: the nearest folder with a `pubspec.yaml` and an `ios` folder.
/// Only the folders on the way up are looked at. Null when there is none.
Directory? findFlutterRoot(Directory from) {
  for (var dir = from.absolute; ; dir = dir.parent) {
    if (File('${dir.path}${Platform.pathSeparator}pubspec.yaml').existsSync() &&
        Directory('${dir.path}${Platform.pathSeparator}ios').existsSync()) {
      return dir;
    }
    if (dir.parent.path == dir.path) {
      return null;
    }
  }
}

/// Reads `ios/Runner.xcodeproj` and `ios/Runner` of the project at [root] for the settings that `wincode.yaml` needs,
/// for [flavor] (null for an app without flavors), or for [configuration], one build configuration by name. With either,
/// only the one configuration is read (`Release-<flavor>`, or the named one), and Debug and Profile are not compared
/// with it. Without, Release is read and Debug and Profile must agree with it on the bundle ID. Never throws: what cannot be read becomes a note.
/// An unknown [configuration] is not a note: [ProjectFacts.configurations] lists the names, and the caller refuses it.
ProjectFacts detectProject(
  Directory root, {
  String? flavor,
  String? configuration,
}) {
  final notes = <String>[];
  final ios = Directory('${root.path}/ios');
  final pbxproj = File('${ios.path}/Runner.xcodeproj/project.pbxproj');
  if (!pbxproj.existsSync()) {
    return const ProjectFacts(
      notes: [
        'ios/Runner.xcodeproj/project.pbxproj was not found, so nothing was read from the Xcode project',
      ],
    );
  }
  List<String> names;
  try {
    names = _configurationNames(pbxproj);
  } on Object catch (e) {
    if (!_damaged(e)) {
      rethrow;
    }
    return const ProjectFacts(
      notes: [
        'ios/Runner.xcodeproj/project.pbxproj could not be read, so nothing was read from the Xcode project',
      ],
    );
  }
  final flavors = [
    for (final name in names)
      if (name.startsWith('Release-')) name.substring('Release-'.length),
  ];
  final suffix = flavor == null ? '' : '-$flavor';
  // The configuration whose settings are used, and the ones that must agree with it on the bundle ID.
  final primary = configuration ?? 'Release$suffix';
  // --flavor and --configuration read the one configuration of the App Store build. Without them, Debug and Profile
  // must agree with Release on the bundle ID.
  final read = configuration != null || flavor != null
      ? [primary]
      : ['Release', 'Debug', 'Profile'];
  if (!names.contains(primary)) {
    return ProjectFacts(
      flavors: flavors,
      configurations: names,
      notes: [
        if (configuration == null)
          'the Xcode project has no $primary configuration${flavors.isEmpty ? '' : ' (flavors: ${flavors.join(', ')})'}',
      ],
    );
  }
  // Without --flavor or --configuration, init reads the plain Release. Say what it did not read.
  final others = [
    for (final name in names)
      if (!const {'Debug', 'Profile', 'Release'}.contains(name)) name,
  ];
  final warnings = [
    if (flavor == null && configuration == null && others.isNotEmpty)
      'the project has build configurations other than Debug, Profile and Release: ${others.join(', ')}. init read '
          'Release. To read another, pass --configuration <name>',
  ];

  // The project folder is shortened to `ios` in what the readers say, so that no path of this PC is printed.
  String shortened(String message) => message.replaceAll(ios.path, 'ios');

  BuildSettings? settingsOf(String name) {
    try {
      return resolveBuildSettings(
        iosDir: ios,
        configuration: name,
        generated: flutterGeneratedSettings(
          buildName: '1.0.0',
          buildNumber: '1',
          target: 'lib/main.dart',
        ),
      );
    } on Object catch (e) {
      if (!_damaged(e)) {
        rethrow;
      }
      notes.add(
        e is FormatException
            ? 'the settings of $name could not be read: ${shortened(e.message)}'
            : 'the settings of $name could not be read',
      );
      return null;
    }
  }

  // The variables that stay unresolved in the settings of the configuration that is read, by setting.
  final unresolved = <String, List<String>>{};

  /// The value of the setting [key] in [settings], the settings of the build configuration [name]. Variables are
  /// replaced from the configuration's own settings, from the xcconfig files it references (with their includes) and
  /// from the values of those, nested. Nothing is executed. Null when the setting is not set or is empty, or when it
  /// needs a variable that nothing defines or refers to itself: a note says which, and [unresolved] keeps the names of
  /// the variables of the configuration that is read.
  String? valueOf(BuildSettings? settings, String name, String key) {
    if (settings == null || !settings.containsKey(key)) {
      return null;
    }
    final missing = settings.unresolved(key);
    if (missing.isNotEmpty) {
      // One note is enough when Release has the same problem.
      if (name == primary || !unresolved.containsKey(key)) {
        notes.add(
          '$key of $name needs ${missing.map((m) => '\$($m)').join(', ')}, which no build setting or xcconfig file of '
          '$name defines',
        );
      }
      if (name == primary) {
        unresolved[key] = [...missing];
      }
      return null;
    }
    try {
      final value = settings[key];
      return value == null || value.isEmpty ? null : value;
    } on FormatException catch (e) {
      notes.add('$key of $name cannot be resolved: ${e.message}');
      return null;
    }
  }

  final release = settingsOf(primary);
  final bundleIds = <String, String>{};
  for (final name in read) {
    final settings = !names.contains(name)
        ? null
        : name == primary
        ? release
        : settingsOf(name);
    final value = valueOf(settings, name, 'PRODUCT_BUNDLE_IDENTIFIER');
    if (value != null) {
      bundleIds[name] = value;
    }
  }
  String? bundleId;
  var candidates = <({String configuration, String value})>[];
  final releaseValue = bundleIds[primary];
  if (releaseValue != null &&
      isBundleId(releaseValue) &&
      bundleIds.values.every((v) => v == releaseValue)) {
    bundleId = releaseValue;
  } else {
    final seen = <String>{};
    candidates = [
      for (final MapEntry(:key, :value) in bundleIds.entries)
        if (isBundleId(value) && seen.add(value))
          (configuration: key, value: value),
    ];
    if (releaseValue != null && !isBundleId(releaseValue)) {
      notes.add('the bundle ID of $primary is not a bundle ID');
    } else if (releaseValue != null) {
      notes.add('the bundle ID differs between configurations');
    } else if (!unresolved.containsKey('PRODUCT_BUNDLE_IDENTIFIER')) {
      notes.add('the bundle ID of $primary is not set');
    }
  }

  final team = valueOf(release, primary, 'DEVELOPMENT_TEAM');
  String? entitlements;
  var entitlementsCandidates = <String>[];
  var entitlementsNamedByProject = false;
  final named = valueOf(release, primary, 'CODE_SIGN_ENTITLEMENTS');
  if (named != null) {
    final file = File('${ios.path}/$named');
    if (file.existsSync()) {
      entitlements = file.absolute.uri.normalizePath().toFilePath();
      entitlementsNamedByProject = true;
    } else {
      notes.add('the project names an entitlements file that does not exist');
    }
  }
  if (entitlements == null) {
    final found = [
      if (Directory('${ios.path}/Runner').existsSync())
        for (final f in Directory('${ios.path}/Runner').listSync())
          if (f is File && f.path.toLowerCase().endsWith('.entitlements'))
            f.absolute.path,
    ]..sort();
    if (found.length == 1) {
      entitlements = found.single;
    } else {
      entitlementsCandidates = found;
    }
  }
  return ProjectFacts(
    bundleId: bundleId,
    bundleIdCandidates: candidates,
    teamId: team != null && isTeamId(team) ? team : null,
    entitlements: entitlements,
    entitlementsCandidates: entitlementsCandidates,
    flavors: flavors,
    configuration: primary,
    configurations: names,
    entitlementsNamedByProject: entitlementsNamedByProject,
    unresolved: unresolved,
    warnings: warnings,
    notes: notes,
  );
}

/// Whether [e] is what a damaged or unexpected Xcode project makes the readers throw.
bool _damaged(Object e) =>
    e is FormatException ||
    e is TypeError ||
    e is StateError ||
    e is RangeError ||
    e is FileSystemException;

/// The names of the build configurations of the `Runner` target.
List<String> _configurationNames(File pbxproj) {
  final root =
      parseOpenStep(pbxproj.readAsStringSync()) as Map<String, Object?>;
  final objects = root['objects']! as Map<String, Object?>;
  Map<String, Object?> object(Object? id) =>
      objects[id]! as Map<String, Object?>;
  final project = object(root['rootObject']);
  final target = (project['targets']! as List<Object?>)
      .map(object)
      .firstWhere((t) => t['name'] == 'Runner');
  final list = object(target['buildConfigurationList']);
  return [
    for (final id in list['buildConfigurations']! as List<Object?>)
      object(id)['name']! as String,
  ];
}

/// The profiles of a folder that `init` offers.
class ProfileScan {
  const ProfileScan({
    required this.usable,
    required this.skipped,
    this.refused,
  });

  /// App Store profiles for the bundle ID that have not expired, by file, with what they hold.
  final List<({File file, ProvisioningProfile profile})> usable;

  /// Why other `.mobileprovision` files were left out, one line each.
  final List<String> skipped;

  /// The refusal of the first file that lies in an unignored git working tree, if any.
  final WincodeException? refused;
}

/// The `.mobileprovision` files directly in [folder] that are App Store profiles of [bundleId] and have not expired at
/// [now]. Each file passes [requireOutsideGit] before it is read; a file that fails it is not read.
Future<ProfileScan> scanProfiles(
  Directory folder, {
  required String? bundleId,
  required DateTime now,
  RunProcess run = runProcess,
}) async {
  final files = [
    for (final f in folder.listSync())
      if (f is File && f.path.toLowerCase().endsWith('.mobileprovision')) f,
  ]..sort((a, b) => a.path.compareTo(b.path));
  final usable = <({File file, ProvisioningProfile profile})>[];
  final skipped = <String>[];
  WincodeException? refused;
  for (final file in files) {
    final name = file.uri.pathSegments.last;
    try {
      await requireOutsideGit(file.path, source: 'the profile', run: run);
    } on WincodeException catch (e) {
      if (e.id != 'key-in-git-tree') {
        rethrow;
      }
      refused ??= e;
      skipped.add('$name lies in a git working tree that does not ignore it');
      continue;
    }
    final ProvisioningProfile profile;
    try {
      profile = readProvisioningProfile(file.readAsBytesSync());
    } on FormatException {
      skipped.add('$name is not a provisioning profile');
      continue;
    } on FileSystemException {
      skipped.add('$name cannot be read');
      continue;
    }
    if (!profile.isForAppStore) {
      skipped.add('$name is not an App Store profile');
    } else if (!profile.expirationDate.isAfter(now)) {
      skipped.add('$name has expired');
    } else if (bundleId != null &&
        !profile.applicationIdentifier.endsWith('.$bundleId')) {
      skipped.add('$name is for another app');
    } else {
      usable.add((file: file, profile: profile));
    }
  }
  return ProfileScan(usable: usable, skipped: skipped, refused: refused);
}

/// [target] relative to the folder [base], with forward slashes, or null when it is on another drive. Both are made
/// absolute first. On Windows, case does not matter.
String? relativePath(String base, String target) {
  List<String> segments(String path) {
    final uri = Uri.file(path, windows: Platform.isWindows).normalizePath();
    return [
      for (final s in uri.pathSegments)
        if (s.isNotEmpty) s,
    ];
  }

  String key(String s) => Platform.isWindows ? s.toLowerCase() : s;
  final from = segments(Directory(base).absolute.path);
  final to = segments(File(target).absolute.path);
  if (Platform.isWindows &&
      from.isNotEmpty &&
      to.isNotEmpty &&
      key(from.first) != key(to.first)) {
    return null;
  }
  var common = 0;
  while (common < from.length &&
      common < to.length - 1 &&
      key(from[common]) == key(to[common])) {
    common++;
  }
  return [
    for (var i = common; i < from.length; i++) '..',
    ...to.sublist(common),
  ].join('/');
}

/// The lines of a diff of [before] and [after]: `- ` for a line only in [before], `+ ` for one only in [after]. Lines
/// that both have are not listed.
List<String> diffLines(List<String> before, List<String> after) {
  // The longest common subsequence: the files are a few lines long.
  final lcs = List.generate(
    before.length + 1,
    (_) => List.filled(after.length + 1, 0),
  );
  for (var i = before.length - 1; i >= 0; i--) {
    for (var j = after.length - 1; j >= 0; j--) {
      lcs[i][j] = before[i] == after[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }
  final out = <String>[];
  var i = 0, j = 0;
  while (i < before.length || j < after.length) {
    if (i < before.length && j < after.length && before[i] == after[j]) {
      i++;
      j++;
    } else if (j >= after.length ||
        (i < before.length && lcs[i + 1][j] >= lcs[i][j + 1])) {
      out.add('- ${before[i++]}');
    } else {
      out.add('+ ${after[j++]}');
    }
  }
  return out;
}
