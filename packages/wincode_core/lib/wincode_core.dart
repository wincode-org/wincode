/// Shared logic of winCode: property lists, Xcode flavor settings and the pieces of the iOS bundle.
library;

export 'src/app_snapshot.dart'
    show buildAppBinary, buildKernel, genSnapshotArguments;
export 'src/build_settings.dart' show BuildSettings, resolveBuildSettings;
export 'src/entitlements.dart' show buildEntitlements;
export 'src/flutter_assets.dart'
    show
        PackageRoots,
        buildFlutterAssets,
        impellercArguments,
        impellercPath,
        shaderSource;
export 'src/info_plist.dart' show SdkKeys, buildInfoPlist;
export 'src/ios_flavor.dart'
    show IosFlavorInputs, flutterGeneratedSettings, readIosFlavor;
export 'src/openstep.dart' show parseOpenStep;
export 'src/process.dart' show RunProcess, runProcess;
export 'src/plist.dart' show PlistMap, parsePlist, parsePlistBytes, writePlist;
export 'src/xcconfig.dart' show XcconfigEntry, readXcconfig;
