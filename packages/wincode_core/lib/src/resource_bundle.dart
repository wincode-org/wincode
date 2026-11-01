import 'dart:convert';
import 'dart:io';

import 'info_plist.dart';
import 'plist.dart';

/// The keys that describe Xcode and the Mac it ran on. They are never written (ADR-0011 rule 2): winCode builds with no
/// Xcode, and the build tools that put placeholders in them describe no real Xcode either.
const _xcodeKeys = [
  'BuildMachineOSBuild',
  'DTCompiler',
  'DTXcode',
  'DTXcodeBuild',
];

/// The identity SwiftPM gives a package fetched from a git [location]: the last component of the URL, without a `.git`
/// suffix, in lower case. It is what `Package.resolved` lists as `identity`, so `https://example.com/org/Example-SDK.git`
/// is `example-sdk`.
String swiftPackageIdentity(String location) {
  final last = location.split(RegExp('[/:]')).where((s) => s.isNotEmpty).last;
  return (last.endsWith('.git') ? last.substring(0, last.length - 4) : last)
      .toLowerCase();
}

/// The bundle identifier Xcode gives the resource bundle of a SwiftPM package target: the package's name, a dot, the
/// target's name, and `.resources`. The package's name is its folder's name for a package on disk (for a Flutter plugin,
/// `<name>-<version>`, the name of its entry in `.packages`) and its identity, with no version, for a package fetched
/// from a git URL (see [swiftPackageIdentity]). Characters other than letters, digits, dots and hyphens become hyphens, so
/// `url_launcher_ios-6.4.2` and the target `url_launcher_ios` give `url-launcher-ios-6.4.2.url-launcher-ios.resources`,
/// and `example-sdk` and the target `ExampleCore` give `example-sdk.ExampleCore.resources`.
String resourceBundleIdentifier({
  required String packageDirectory,
  required String target,
}) =>
    '${_identifierPart(packageDirectory)}.${_identifierPart(target)}.resources';

String _identifierPart(String name) =>
    name.replaceAll(RegExp(r'[^A-Za-z0-9.-]'), '-');

/// The lowest iOS version Xcode 26.6 builds a target for. A package that declares an older one (a few widely used
/// packages still declare iOS 9 or 10) is built for this version instead, and its resource bundle says so.
const _lowestXcodeIosTarget = 12;

/// The iOS version Xcode builds a SwiftPM package's targets for, from the output of `swift package dump-package`, or
/// null if it declares none. It is the version the package declares, raised to [_lowestXcodeIosTarget] if lower, and it
/// is the `MinimumOSVersion` of the targets' resource bundles, whatever the app's own deployment target is.
String? declaredIosTarget(String dumpPackageJson) {
  final platforms =
      (jsonDecode(dumpPackageJson) as Map<String, Object?>)['platforms'];
  for (final platform in platforms as List<Object?>? ?? const []) {
    if (platform case {
      'platformName': 'ios',
      'version': final String version,
    }) {
      final major = int.tryParse(version.split('.').first);
      return major != null && major < _lowestXcodeIosTarget
          ? '$_lowestXcodeIosTarget.0'
          : version;
    }
  }
  return null;
}

/// The `Info.plist` of a package target's resource bundle as Xcode writes it, made from the one Swift Build writes on
/// Linux ([built]).
///
/// - **Taken out:** Xcode's four keys (`DTXcode`, `DTXcodeBuild`, `DTCompiler` and `BuildMachineOSBuild`). Swift Build
///   on Linux fills the first two with placeholders and copies the third.
/// - **Set:** the five SDK keys from the user's own SDK; `MinimumOSVersion`, the iOS version Xcode builds the package for
///   ([minimumOsVersion], see [declaredIosTarget]); `UIDeviceFamily`, from the app's `TARGETED_DEVICE_FAMILY` ([deviceFamily]); and the bundle
///   identifier with the package's version (see [resourceBundleIdentifier]), which Swift Build only writes when the
///   package folder it builds carries the version.
/// - **Kept:** everything else, as Swift Build wrote it.
PlistMap resourceBundleInfo({
  required PlistMap built,
  required String packageDirectory,
  required String target,
  required String minimumOsVersion,
  required List<int> deviceFamily,
  required SdkKeys sdk,
}) => {
  for (final entry in built.entries)
    if (!_xcodeKeys.contains(entry.key)) entry.key: entry.value,
  'CFBundleIdentifier': resourceBundleIdentifier(
    packageDirectory: packageDirectory,
    target: target,
  ),
  'MinimumOSVersion': minimumOsVersion,
  'UIDeviceFamily': deviceFamily,
  ...sdk.toPlist(),
};

/// Rewrites the `Info.plist` inside [bundle] (a `<package>_<target>.bundle` folder) with [resourceBundleInfo], as a
/// binary property list like Xcode's, and returns what it wrote.
PlistMap normalizeResourceBundle(
  Directory bundle, {
  required String packageDirectory,
  required String target,
  required String minimumOsVersion,
  required List<int> deviceFamily,
  required SdkKeys sdk,
}) {
  final file = File('${bundle.path}/Info.plist');
  final built = parsePlistBytes(file.readAsBytesSync()) as PlistMap;
  final info = resourceBundleInfo(
    built: built,
    packageDirectory: packageDirectory,
    target: target,
    minimumOsVersion: minimumOsVersion,
    deviceFamily: deviceFamily,
    sdk: sdk,
  );
  file.writeAsBytesSync(writePlistBinary(info));
  return info;
}
