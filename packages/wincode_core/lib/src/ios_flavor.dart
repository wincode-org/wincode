import 'dart:io';

import 'build_settings.dart';
import 'entitlements.dart';
import 'info_plist.dart';
import 'openstep.dart';
import 'plist.dart';

/// The settings Flutter puts in `Generated.xcconfig`, which the project's xcconfig files include. Flutter writes the
/// real file on the Mac that builds; winCode gives the project the same names.
Map<String, String> flutterGeneratedSettings({
  required String buildName,
  required String buildNumber,
  String target = 'lib/main.dart',
}) => {
  'FLUTTER_TARGET': target,
  'FLUTTER_BUILD_DIR': 'build',
  'FLUTTER_BUILD_NAME': buildName,
  'FLUTTER_BUILD_NUMBER': buildNumber,
};

/// What a flavor's build of the iOS app is made of: its settings, and the `Info.plist` and entitlements winCode ships.
class IosFlavorInputs {
  const IosFlavorInputs({
    required this.configuration,
    required this.settings,
    required this.infoPlist,
    required this.entitlements,
  });

  /// The Xcode configuration that was read, for example `Release-demo`.
  final String configuration;
  final BuildSettings settings;
  final PlistMap infoPlist;
  final PlistMap entitlements;
}

/// Reads the iOS project in [iosDir] for [flavor] (null for none) in [mode] (`Debug`, `Profile` or `Release`), the
/// way `flutter build ios --flavor` picks the configuration: `<Mode>-<flavor>`.
///
/// [teamId] is the Apple team the app is signed for. It comes from the signing profile, not from the project.
IosFlavorInputs readIosFlavor({
  required Directory iosDir,
  required SdkKeys sdk,
  required String teamId,
  required String buildName,
  required String buildNumber,
  String? flavor,
  String mode = 'Release',
  String target = 'Runner',
  String dartTarget = 'lib/main.dart',
}) {
  final configuration = flavor == null ? mode : '$mode-$flavor';
  final settings = resolveBuildSettings(
    iosDir: iosDir,
    configuration: configuration,
    target: target,
    generated: flutterGeneratedSettings(
      buildName: buildName,
      buildNumber: buildNumber,
      target: dartTarget,
    ),
  );

  PlistMap read(String key, {required bool required}) {
    final relative = settings[key];
    if (relative == null || relative.isEmpty) {
      if (required) throw FormatException('the target has no $key');
      return {};
    }
    final file = File('${iosDir.path}/$relative');
    if (!file.existsSync()) {
      throw FormatException('$key names $relative, which does not exist');
    }
    return parsePlist(file.readAsStringSync()) as PlistMap;
  }

  return IosFlavorInputs(
    configuration: configuration,
    settings: settings,
    infoPlist: buildInfoPlist(
      template: read('INFOPLIST_FILE', required: true),
      settings: settings,
      sdk: sdk,
    ),
    entitlements: buildEntitlements(
      own: read('CODE_SIGN_ENTITLEMENTS', required: false),
      settings: settings,
      teamId: teamId,
    ),
  );
}

/// The names of the build configurations that the Xcode project lists, in the order of [pbxproj], the text of its
/// `project.pbxproj`. These are the names that `xcodebuild -list` prints under "Build Configurations", the list that
/// flutter_tools chooses from. Throws a [FormatException] when the file is not a project file with such a list.
List<String> buildConfigurationNames(String pbxproj) {
  try {
    final root = parseOpenStep(pbxproj) as Map<String, Object?>;
    final objects = root['objects']! as Map<String, Object?>;
    Map<String, Object?> object(Object? id) =>
        objects[id]! as Map<String, Object?>;
    final project = object(root['rootObject']);
    final list = object(project['buildConfigurationList']);
    return [
      for (final id in list['buildConfigurations']! as List<Object?>)
        object(id)['name']! as String,
    ];
  } on TypeError {
    throw const FormatException(
      'project file: it holds no list of build configurations',
    );
  }
}

/// What `flutter build ipa` builds for a flavor: the Xcode scheme and the build configuration, chosen by the rules of
/// flutter_tools 3.47 (`XcodeProjectInfo.schemeFor` and `buildConfigurationFor`; ADR-0015, section 2). Flutter picks
/// the scheme and the configuration itself, and `--flavor` is all a caller gives it, so winCode applies the same rules
/// to see what a run would build before it spends a minute.
class FlutterBuildChoice {
  const FlutterBuildChoice({
    required this.expectedScheme,
    required this.scheme,
    required this.expectedConfiguration,
    required this.configuration,
    required this.fellBack,
    required this.ambiguous,
  });

  /// The scheme Flutter looks for: the flavor with its first letter in capitals, or `Runner` without a flavor.
  final String expectedScheme;

  /// The scheme Flutter builds: [expectedScheme] when a scheme has exactly that name, else the one scheme that has it
  /// ignoring case. Null when there is none, or several: Flutter then stops.
  final String? scheme;

  /// The configuration Flutter looks for: `Release-<scheme>` with a flavor, else `Release`.
  final String expectedConfiguration;

  /// The configuration Flutter builds. Null when [scheme] is null (nothing is chosen), or when [ambiguous].
  final String? configuration;

  /// Whether no configuration was found and Flutter builds plain `Release` without an error.
  final bool fellBack;

  /// Whether several configurations fit and Flutter stops.
  final bool ambiguous;
}

/// Applies the rules of flutter_tools 3.47 to a project with these [schemes] (the shared ones) and [configurations].
///
/// - The scheme is the flavor with its first letter in capitals (`store` gives `Store`), or `Runner`. Without an exact
///   match, the one scheme that equals it ignoring case.
/// - The configuration is `Release` without a flavor. With one, it is `Release-<scheme>` matched ignoring case; failing
///   that, the one configuration whose name holds both `Release` and the scheme, ignoring case. If several do, Flutter
///   stops, and if none does, it builds `Release`.
FlutterBuildChoice flutterBuildChoice({
  String? flavor,
  required List<String> schemes,
  required List<String> configurations,
}) {
  final expectedScheme = flavor == null
      ? 'Runner'
      : flavor[0].toUpperCase() + flavor.substring(1);
  String? only(Iterable<String> candidates) =>
      candidates.length == 1 ? candidates.single : null;
  final scheme = schemes.contains(expectedScheme)
      ? expectedScheme
      : only(
          schemes.where((s) => s.toLowerCase() == expectedScheme.toLowerCase()),
        );
  if (scheme == null || flavor == null) {
    return FlutterBuildChoice(
      expectedScheme: expectedScheme,
      scheme: scheme,
      expectedConfiguration: 'Release',
      configuration: scheme == null ? null : 'Release',
      fellBack: false,
      ambiguous: false,
    );
  }
  final expected = 'Release-$scheme';
  final exact = configurations.where(
    (c) => c.toLowerCase() == expected.toLowerCase(),
  );
  if (exact.isNotEmpty) {
    return FlutterBuildChoice(
      expectedScheme: expectedScheme,
      scheme: scheme,
      expectedConfiguration: expected,
      configuration: configurations.contains(expected) ? expected : exact.first,
      fellBack: false,
      ambiguous: false,
    );
  }
  final both = configurations.where(
    (c) =>
        c.toLowerCase().contains('release') &&
        c.toLowerCase().contains(scheme.toLowerCase()),
  );
  final one = only(both);
  return FlutterBuildChoice(
    expectedScheme: expectedScheme,
    scheme: scheme,
    expectedConfiguration: expected,
    configuration: one ?? (both.isEmpty ? 'Release' : null),
    fellBack: both.isEmpty,
    ambiguous: both.length > 1,
  );
}
