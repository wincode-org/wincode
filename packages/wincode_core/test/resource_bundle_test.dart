import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

const _sdk = SdkKeys(
  sdkName: 'iphoneos26.5',
  sdkBuild: '23F81a',
  platformName: 'iphoneos',
  platformVersion: '26.5',
  platformBuild: '23F81a',
);

/// The `Info.plist` Swift Build writes on Linux for the resource bundle of `url_launcher_ios`, built from a folder that
/// has no version in its name.
final _built = <String, Object?>{
  'CFBundleDevelopmentRegion': 'en',
  'CFBundleIdentifier': 'url-launcher-ios.url-launcher-ios.resources',
  'CFBundleInfoDictionaryVersion': '6.0',
  'CFBundleName': 'url_launcher_ios_url_launcher_ios',
  'CFBundlePackageType': 'BNDL',
  'CFBundleSupportedPlatforms': ['iPhoneOS'],
  'DTCompiler': 'com.apple.compilers.llvm.clang.1_0',
  'DTPlatformBuild': '',
  'DTPlatformName': 'iphoneos',
  'DTPlatformVersion': '26.5',
  'DTSDKBuild': '23F81a',
  'DTSDKName': 'iphoneos26.5',
  'DTXcode': '10989',
  'DTXcodeBuild': '99T999',
  'MinimumOSVersion': '15.0',
  'UIRequiredDeviceCapabilities': ['arm64'],
};

/// What Xcode 26.6 wrote for the same bundle, less its four keys.
final _expected = <String, Object?>{
  'CFBundleDevelopmentRegion': 'en',
  'CFBundleIdentifier': 'url-launcher-ios-6.4.2.url-launcher-ios.resources',
  'CFBundleInfoDictionaryVersion': '6.0',
  'CFBundleName': 'url_launcher_ios_url_launcher_ios',
  'CFBundlePackageType': 'BNDL',
  'CFBundleSupportedPlatforms': ['iPhoneOS'],
  'DTPlatformBuild': '23F81a',
  'DTPlatformName': 'iphoneos',
  'DTPlatformVersion': '26.5',
  'DTSDKBuild': '23F81a',
  'DTSDKName': 'iphoneos26.5',
  'MinimumOSVersion': '13.0',
  'UIDeviceFamily': [1, 2],
  'UIRequiredDeviceCapabilities': ['arm64'],
};

void main() {
  group('resourceBundleIdentifier', () {
    test('is the package folder, the target and .resources, with hyphens', () {
      expect(
        resourceBundleIdentifier(
          packageDirectory: 'url_launcher_ios-6.4.2',
          target: 'url_launcher_ios',
        ),
        'url-launcher-ios-6.4.2.url-launcher-ios.resources',
      );
      expect(
        resourceBundleIdentifier(
          packageDirectory: 'flutter_secure_storage_darwin-0.4.1',
          target: 'flutter_secure_storage_darwin',
        ),
        'flutter-secure-storage-darwin-0.4.1.flutter-secure-storage-darwin.resources',
      );
    });
  });

  group('declaredIosTarget', () {
    test('reads the iOS entry of dump-package', () {
      const dump =
          '{"name":"p","platforms":[{"platformName":"macos","version":"10.15","options":[]},'
          '{"platformName":"ios","version":"13.0","options":[]}]}';
      expect(declaredIosTarget(dump), '13.0');
    });

    test('is null when the package declares no iOS version', () {
      expect(declaredIosTarget('{"name":"p","platforms":[]}'), isNull);
      expect(declaredIosTarget('{"name":"p"}'), isNull);
    });
  });

  group('resourceBundleInfo', () {
    PlistMap normalized() => resourceBundleInfo(
      built: _built,
      packageDirectory: 'url_launcher_ios-6.4.2',
      target: 'url_launcher_ios',
      minimumOsVersion: '13.0',
      deviceFamily: [1, 2],
      sdk: _sdk,
    );

    test('is what Xcode wrote, less its four keys', () {
      expect(normalized(), _expected);
    });

    test('never writes Xcode\'s four keys, whatever it was given', () {
      final info = normalized();
      for (final key in [
        'DTXcode',
        'DTXcodeBuild',
        'DTCompiler',
        'BuildMachineOSBuild',
      ]) {
        expect(info, isNot(contains(key)));
      }
    });

    test('keeps a key it knows nothing about', () {
      final info = resourceBundleInfo(
        built: {..._built, 'CFBundleVersion': '1'},
        packageDirectory: 'p-1.0',
        target: 't',
        minimumOsVersion: '13.0',
        deviceFamily: [1],
        sdk: _sdk,
      );
      expect(info['CFBundleVersion'], '1');
      expect(info['UIDeviceFamily'], [1]);
    });
  });

  group('normalizeResourceBundle', () {
    test('rewrites the bundle\'s Info.plist as a binary property list', () {
      final dir = Directory.systemTemp.createTempSync('bundle_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/Info.plist').writeAsBytesSync(writePlistBinary(_built));
      final info = normalizeResourceBundle(
        dir,
        packageDirectory: 'url_launcher_ios-6.4.2',
        target: 'url_launcher_ios',
        minimumOsVersion: '13.0',
        deviceFamily: [1, 2],
        sdk: _sdk,
      );
      expect(info, _expected);
      final bytes = File('${dir.path}/Info.plist').readAsBytesSync();
      expect(String.fromCharCodes(bytes.take(8)), 'bplist00');
      expect(parsePlistBytes(bytes), _expected);
    });
  });
}
