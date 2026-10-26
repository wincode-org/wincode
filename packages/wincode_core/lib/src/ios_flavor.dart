import 'dart:io';

import 'build_settings.dart';
import 'entitlements.dart';
import 'info_plist.dart';
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
