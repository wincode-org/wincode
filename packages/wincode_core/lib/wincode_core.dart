/// Shared logic of winCode: property lists, Xcode flavor settings and the pieces of the iOS bundle.
library;

export 'src/build_settings.dart' show BuildSettings, resolveBuildSettings;
export 'src/doctor.dart' show DoctorFinding, checkFlutterSdkLineEndings;
export 'src/entitlements.dart' show buildEntitlements;
export 'src/flutter_assets.dart'
    show
        PackageRoots,
        RunProcess,
        buildFlutterAssets,
        impellercArguments,
        impellercPath,
        shaderSource;
export 'src/info_plist.dart' show SdkKeys, buildInfoPlist;
export 'src/ios_flavor.dart'
    show IosFlavorInputs, flutterGeneratedSettings, readIosFlavor;
export 'src/openstep.dart' show parseOpenStep;
export 'src/plist.dart' show PlistMap, parsePlist, parsePlistBytes, writePlist;
export 'src/xcconfig.dart' show XcconfigEntry, readXcconfig;
