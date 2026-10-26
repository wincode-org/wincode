import 'dart:convert';
import 'dart:io';

import 'build_settings.dart';
import 'plist.dart';

/// The five keys that name the SDK a bundle was built with. Xcode writes them; winCode reads the same values from the
/// user's own Darwin SDK (ADR-0011 rule 2). The keys that describe Xcode and the Mac, `DTXcode`, `DTXcodeBuild`,
/// `DTCompiler` and `BuildMachineOSBuild`, are never written.
class SdkKeys {
  const SdkKeys({
    required this.sdkName,
    required this.sdkBuild,
    required this.platformName,
    required this.platformVersion,
    required this.platformBuild,
  });

  /// Reads the keys from an `iPhoneOS.sdk` folder inside `iPhoneOS.platform/Developer/SDKs`.
  ///
  /// The platform build is the SDK's build: xtool's SDK keeps no platform version file of its own.
  factory SdkKeys.read(Directory sdk) {
    final settings = jsonDecode(
      File('${sdk.path}/SDKSettings.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final system = parsePlistBytes(
      File('${sdk.path}/System/Library/CoreServices/SystemVersion.plist')
          .readAsBytesSync(),
    ) as PlistMap;
    final platformInfo = File('${sdk.parent.parent.parent.path}/Info.plist');
    final platform =
        parsePlistBytes(platformInfo.readAsBytesSync()) as PlistMap;
    final build = system['ProductBuildVersion']! as String;
    return SdkKeys(
      sdkName: settings['CanonicalName']! as String,
      sdkBuild: build,
      platformName:
          (settings['DefaultProperties']!
                  as Map<String, Object?>)['PLATFORM_NAME']!
              as String,
      platformVersion:
          (platform['AdditionalInfo']! as PlistMap)['DTPlatformVersion']!
              as String,
      platformBuild: build,
    );
  }

  final String sdkName;
  final String sdkBuild;
  final String platformName;
  final String platformVersion;
  final String platformBuild;

  PlistMap toPlist() => {
    'DTSDKName': sdkName,
    'DTSDKBuild': sdkBuild,
    'DTPlatformName': platformName,
    'DTPlatformVersion': platformVersion,
    'DTPlatformBuild': platformBuild,
  };
}

/// The app's `Info.plist` as winCode ships it: the template with its `$(NAME)` variables replaced, the keys Xcode
/// derives from the build settings, and the five SDK keys.
///
/// - **Variables:** an unknown `$(NAME)` stops the build (`unknown variable $(NAME)`).
/// - **Derived keys** (the template's own value wins): `CFBundleExecutable`, `CFBundleSupportedPlatforms`,
///   `MinimumOSVersion` from `IPHONEOS_DEPLOYMENT_TARGET`, `UIDeviceFamily` from `TARGETED_DEVICE_FAMILY` and
///   `UIRequiredDeviceCapabilities` (`arm64`).
/// - **Dropped** (ADR-0011 rules 2 and 3): `UIMainStoryboardFile`, `UILaunchStoryboardName` and each scene's
///   `UISceneStoryboardFile`. The scene delegate's name stays, so the runner must provide that class.
/// - **Not written here:** `CFBundleIcons` and `CFBundleIcons~ipad`, which come from the asset compiler's partial
///   `Info.plist`, and Xcode's four keys.
PlistMap buildInfoPlist({
  required PlistMap template,
  required BuildSettings settings,
  required SdkKeys sdk,
}) {
  final own = _expand(template, settings) as PlistMap
    ..remove('UIMainStoryboardFile')
    ..remove('UILaunchStoryboardName');
  final scenes =
      ((own['UIApplicationSceneManifest']
                  as PlistMap?)?['UISceneConfigurations']
              as PlistMap?)
          ?.values;
  for (final role in scenes ?? const <Object?>[]) {
    for (final configuration in role! as List<Object?>) {
      (configuration! as PlistMap).remove('UISceneStoryboardFile');
    }
  }
  final family = settings['TARGETED_DEVICE_FAMILY'];
  final target = settings['IPHONEOS_DEPLOYMENT_TARGET'];
  final executable = settings['EXECUTABLE_NAME'];
  final derived = <String, Object?>{
    'CFBundleExecutable': ?executable,
    'CFBundleSupportedPlatforms': ['iPhoneOS'],
    'MinimumOSVersion': ?target,
    if (family != null)
      'UIDeviceFamily': [
        for (final f in family.split(',')) int.parse(f.trim()),
      ],
    'UIRequiredDeviceCapabilities': ['arm64'],
  };
  return {...derived, ...own, ...sdk.toPlist()};
}

Object? _expand(Object? value, BuildSettings settings) => switch (value) {
  final String s => settings.expand(s, strict: true),
  final List<Object?> l => [for (final v in l) _expand(v, settings)],
  final Map<Object?, Object?> m => {
    for (final e in m.entries) e.key! as String: _expand(e.value, settings),
  },
  _ => value,
};
