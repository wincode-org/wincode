import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

final iosDir = Directory('test/fixtures/flavored_sample/ios');

const sdk = SdkKeys(
  sdkName: 'iphoneos99.0',
  sdkBuild: '99A1',
  platformName: 'iphoneos',
  platformVersion: '99.0',
  platformBuild: '99A1',
);

const xcodeOnly = [
  'DTXcode',
  'DTXcodeBuild',
  'DTCompiler',
  'BuildMachineOSBuild',
];

BuildSettings settingsOf(String configuration) => resolveBuildSettings(
  iosDir: iosDir,
  configuration: configuration,
  generated: flutterGeneratedSettings(buildName: '1.2.3', buildNumber: '45'),
);

void main() {
  group('build settings', () {
    test('a flavor configuration takes its values from its own xcconfig', () {
      final alpha = settingsOf('Release-alpha');
      expect(alpha['PRODUCT_BUNDLE_IDENTIFIER'], 'org.example.demo.alpha');
      expect(alpha['APP_DISPLAY_NAME'], 'Demo Alpha');
      expect(
        settingsOf('Release-beta')['PRODUCT_BUNDLE_IDENTIFIER'],
        'org.example.demo.beta',
      );
    });

    test('the target settings win over the xcconfig, and the project layer sits below both', () {
      expect(
        settingsOf('Release')['PRODUCT_BUNDLE_IDENTIFIER'],
        'org.example.demo',
      );
      expect(settingsOf('Release-alpha')['IPHONEOS_DEPLOYMENT_TARGET'], '15.0');
      expect(settingsOf('Release-beta')['IPHONEOS_DEPLOYMENT_TARGET'], '16.0');
    });

    test(
      r'Xcode defaults and $(inherited) and the generated Flutter settings',
      () {
        final alpha = settingsOf('Release-alpha');
        expect(alpha['EXECUTABLE_NAME'], 'Runner');
        expect(alpha['PRODUCT_MODULE_NAME'], 'Runner');
        expect(alpha['DEVELOPMENT_LANGUAGE'], 'en');
        expect(alpha['CONFIGURATION'], 'Release-alpha');
        expect(alpha['SRCROOT'], iosDir.absolute.path);
        expect(alpha['LD_RUNPATH_SEARCH_PATHS'], '@executable_path/Frameworks');
        expect(alpha['FLUTTER_BUILD_NAME'], '1.2.3');
        expect(alpha['FLUTTER_BUILD_NUMBER'], '45');
      },
    );

    test(
      'a setting for the device applies, one for the simulator does not',
      () {
        final alpha = settingsOf('Release-alpha');
        expect(alpha['CODE_SIGN_IDENTITY'], 'iPhone Developer');
      },
    );

    test('a missing configuration lists the ones the project has', () {
      expect(
        () => settingsOf('Release-gamma'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Release-alpha'),
          ),
        ),
      );
    });

    test('modifiers and loops', () {
      final settings = BuildSettings({
        'A': 'my app',
        'B': r'$(A:rfc1034identifier)',
        'C': r'$(C)',
      });
      expect(settings['B'], 'my-app');
      expect(() => settings['C'], throwsFormatException);
    });
  });

  group('xcconfig files', () {
    test('includes, comments and conditions are read in order', () {
      final dir = Directory.systemTemp.createTempSync('xcconfig');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/b.xcconfig').writeAsStringSync('B = 2 // a comment\n');
      final a = File('${dir.path}/a.xcconfig')
        ..writeAsStringSync(
          'A = 1\n#include "b.xcconfig"\n#include? "none.xcconfig"\nC[sdk=iphoneos*] = 3\n',
        );
      final entries = readXcconfig(a);
      expect(
        [for (final e in entries) '${e.key}=${e.value}${e.conditions}'],
        ['A=1[]', 'B=2[]', 'C=3[sdk=iphoneos*]'],
      );
    });

    test('a missing include fails', () {
      final dir = Directory.systemTemp.createTempSync('xcconfig');
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = File('${dir.path}/a.xcconfig')
        ..writeAsStringSync('#include "none.xcconfig"\n');
      expect(() => readXcconfig(a), throwsFormatException);
    });
  });

  group('the app Info.plist', () {
    final alpha = readIosFlavor(
      iosDir: iosDir,
      sdk: sdk,
      teamId: 'TEAM000000',
      buildName: '1.2.3',
      buildNumber: '45',
      flavor: 'alpha',
    );
    final plist = alpha.infoPlist;

    test('variables are replaced from the flavor', () {
      expect(plist['CFBundleIdentifier'], 'org.example.demo.alpha');
      expect(plist['CFBundleDisplayName'], 'Demo Alpha');
      expect(plist['CFBundleShortVersionString'], '1.2.3');
      expect(plist['CFBundleVersion'], '45');
      expect(plist['CFBundleDevelopmentRegion'], 'en');
      expect(plist['CFBundleExecutable'], 'Runner');
      expect(
        ((plist['CFBundleURLTypes']! as List<Object?>).single!
            as Map)['CFBundleURLSchemes'],
        ['demo-alpha'],
      );
    });

    test(
      'Xcode derives these keys from the build settings, and so does winCode',
      () {
        expect(plist['MinimumOSVersion'], '15.0');
        expect(plist['UIDeviceFamily'], [1, 2]);
        expect(plist['UIRequiredDeviceCapabilities'], ['arm64']);
        expect(plist['CFBundleSupportedPlatforms'], ['iPhoneOS']);
        final beta = readIosFlavor(
          iosDir: iosDir,
          sdk: sdk,
          teamId: 'TEAM000000',
          buildName: '1',
          buildNumber: '1',
          flavor: 'beta',
        );
        expect(beta.infoPlist['MinimumOSVersion'], '16.0');
        expect(beta.infoPlist['UIDeviceFamily'], [1]);
      },
    );

    test('the five SDK keys are written and Xcode\'s four never', () {
      expect(plist['DTSDKName'], 'iphoneos99.0');
      expect(plist['DTSDKBuild'], '99A1');
      expect(plist['DTPlatformName'], 'iphoneos');
      expect(plist['DTPlatformVersion'], '99.0');
      expect(plist['DTPlatformBuild'], '99A1');
      for (final key in xcodeOnly) {
        expect(plist.containsKey(key), isFalse, reason: key);
      }
    });

    test('storyboard keys are dropped and the scene delegate stays', () {
      expect(plist.containsKey('UIMainStoryboardFile'), isFalse);
      expect(plist.containsKey('UILaunchStoryboardName'), isFalse);
      final scene =
          ((((plist['UIApplicationSceneManifest']!
                                  as Map)['UISceneConfigurations']!
                              as Map)
                          .values
                          .single!
                      as List<Object?>)
                  .single!
              as Map);
      expect(scene.containsKey('UISceneStoryboardFile'), isFalse);
      expect(scene['UISceneDelegateClassName'], 'Runner.SceneDelegate');
    });

    test('an unknown variable stops the build', () {
      final settings = settingsOf('Release-alpha');
      expect(
        () => buildInfoPlist(
          template: {'K': r'$(NOT_SET)'},
          settings: settings,
          sdk: sdk,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains(r'$(NOT_SET)'),
          ),
        ),
      );
    });
  });

  group('the entitlements', () {
    test(
      'the app\'s own file is merged with the four the profile must allow',
      () {
        final alpha = readIosFlavor(
          iosDir: iosDir,
          sdk: sdk,
          teamId: 'TEAM000000',
          buildName: '1',
          buildNumber: '1',
          flavor: 'alpha',
        );
        expect(alpha.entitlements, {
          'application-identifier': 'TEAM000000.org.example.demo.alpha',
          'com.apple.developer.applesignin': ['Default'],
          'com.apple.developer.team-identifier': 'TEAM000000',
          'get-task-allow': false,
          'keychain-access-groups': [
            'TEAM000000.org.example.demo.alpha.shared',
            'TEAM000000.org.example.demo.alpha',
          ],
        });
      },
    );

    test('an app with no entitlements file gets just the four', () {
      final beta = readIosFlavor(
        iosDir: iosDir,
        sdk: sdk,
        teamId: 'TEAM000000',
        buildName: '1',
        buildNumber: '1',
        flavor: 'beta',
      );
      expect(beta.entitlements.keys.toSet(), {
        'application-identifier',
        'com.apple.developer.team-identifier',
        'get-task-allow',
        'keychain-access-groups',
      });
    });
  });

  group('the SDK keys', () {
    test('are read from the SDK folder, and the platform build is the SDK build', () {
      final root = Directory.systemTemp.createTempSync('sdk');
      addTearDown(() => root.deleteSync(recursive: true));
      final sdkDir = Directory(
        '${root.path}/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/CoreServices',
      )..createSync(recursive: true);
      final sdkRoot = sdkDir.parent.parent.parent;
      File('${sdkRoot.path}/SDKSettings.json').writeAsStringSync(
        jsonEncode({
          'CanonicalName': 'iphoneos99.0',
          'DefaultProperties': {'PLATFORM_NAME': 'iphoneos'},
        }),
      );
      File('${sdkDir.path}/SystemVersion.plist')
          .writeAsStringSync(writePlist({'ProductBuildVersion': '99A1'}));
      File('${root.path}/iPhoneOS.platform/Info.plist').writeAsStringSync(
        writePlist({
          'AdditionalInfo': {'DTPlatformVersion': '99.0'},
        }),
      );
      final keys = SdkKeys.read(sdkRoot).toPlist();
      expect(keys, {
        'DTSDKName': 'iphoneos99.0',
        'DTSDKBuild': '99A1',
        'DTPlatformName': 'iphoneos',
        'DTPlatformVersion': '99.0',
        'DTPlatformBuild': '99A1',
      });
    });
  });
}
