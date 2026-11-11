/// Shared logic of winCode: property lists, Xcode flavor settings and the pieces of the iOS bundle.
library;

export 'src/app_snapshot.dart'
    show
        buildAppBinary,
        buildKernel,
        finishAppBinary,
        genSnapshotArguments,
        wrapInFat;
export 'src/build_settings.dart' show BuildSettings, resolveBuildSettings;
export 'src/certificate.dart'
    show
        Certificate,
        PrivateKeyException,
        PrivateKeyProblem,
        RsaPublicKey,
        readCertificate,
        readRsaPrivateKey,
        verifyRsaSha256;
export 'src/code_signature.dart'
    show codeSignatureOf, entitlementsOfSignature, readSignedEntitlements;
export 'src/doctor.dart' show DoctorFinding, checkFlutterSdkLineEndings;
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
export 'src/macho_check.dart' show Violation, checkAgainstSdk;
export 'src/macho_diff.dart' show diffMachO;
export 'src/macho_edit.dart' show removeRpaths, setInstallName;
export 'src/macho_inspect.dart'
    show
        BuildVersion,
        Dylib,
        DylibKind,
        Import,
        LibraryUse,
        MachO,
        libraryUse,
        readMachO;
export 'src/native_assets.dart'
    show
        buildNativeAssetFramework,
        nativeAssetFrameworkInfoPlist,
        nativeAssetFrameworkName,
        nativeAssetsManifest;
export 'src/openstep.dart' show parseOpenStep;
export 'src/process.dart' show RunProcess, runProcess;
export 'src/provisioning_profile.dart'
    show ProvisioningProfile, readProvisioningProfile;
export 'src/plist.dart'
    show PlistMap, parsePlist, parsePlistBytes, writePlist, writePlistBinary;
export 'src/resource_bundle.dart'
    show
        declaredIosTarget,
        normalizeResourceBundle,
        resourceBundleIdentifier,
        resourceBundleInfo,
        swiftPackageIdentity;
export 'src/runner.dart'
    show
        SwiftPlugin,
        buildRunner,
        flutterFrameworkPackageManifest,
        generatedPluginPackageManifest,
        generatedPluginRegistrant,
        runnerPackageManifest,
        sceneDelegateBase,
        sdkVersion,
        writeRunnerPackage;
export 'src/sdk_stubs.dart' show Hidden, LibraryStub, Previous, readLibraryStub;
export 'src/signature_check.dart'
    show SignatureCheck, checkSignedIpa, nestedCodeOf, plistEquals;
export 'src/swift_build.dart'
    show SwiftBuild, buildSwiftPackage, swiftBuildCommand;
export 'src/wsl.dart' show toWslPath, wslRunner;
export 'src/xcconfig.dart' show XcconfigEntry, readXcconfig;
export 'src/zip.dart' show ZipArchive, ZipLimits;
