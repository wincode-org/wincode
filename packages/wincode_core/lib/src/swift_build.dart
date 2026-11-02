import 'dart:io';

import 'process.dart';

/// The result of building one SwiftPM package for iOS arm64. Paths are as the build host sees them (under WSL2, Linux
/// paths).
class SwiftBuild {
  const SwiftBuild({
    required this.library,
    required this.bundles,
    required this.warnings,
    required this.elapsed,
    required this.log,
  });

  /// What the build wrote for the product: the static library `lib<product>.a`, or the executable if the product is one.
  final String library;

  /// The resource bundles (`<package>_<target>.bundle`) the build wrote next to it.
  final List<String> bundles;

  /// The number of `warning:` lines in the build's output.
  final int warnings;
  final Duration elapsed;
  final String log;
}

/// The command that builds [product] of the SwiftPM package at [packagePath] for iOS arm64, the way xtool builds with
/// Swift 6.4: the `swiftbuild` build system, the Darwin SDK's toolset, and the SDK's platform folder in
/// `XCODE_EXTRA_PLATFORM_FOLDERS`. It starts with `env`, which sets the environment, so the same [RunProcess] can run it on
/// the host or inside WSL2 without a shell. `SDKROOT` is removed, because it would override the SDK configuration.
///
/// The compiler is told to load cross-import overlays. The SDK declares them (for example `PassKit.swiftcrossimport`), and
/// Xcode loads the overlay module when a file imports both modules. The `swiftbuild` system does not turn this on by
/// itself here, although xtool's native toolset does, so `PayWithApplePayButton` is not found after `import SwiftUI` and
/// `import PassKit`.
///
/// - [darwinSdkBundle]: the folder of `darwin.artifactbundle`.
/// - [swift]: the `swift` program, and [path] the rest of `PATH` (after the SDK's `toolset/bin`, which holds `dsymutil`).
/// - [flutterFrameworkFolder]: the folder that holds `Flutter.framework`. A plugin's `import Flutter` needs its headers
///   and module map; the engine binary is not used until the app is linked.
/// - [linkerFlags]: flags for the linker, each passed with `-Xlinker`. They only matter for a product that is linked,
///   an executable: a static library is not.
///
/// The compiler is told not to autolink `SwiftUICore`. SwiftUI's modules ask for it, and with that request `lld` links the
/// private framework directly and binds a few symbols to it, where Xcode's linker binds them to `SwiftUI`, which
/// re-exports it. `SwiftUICore` exists only from iOS 18, so such an app does not start on an older iOS, and Xcode's own
/// app never links it.
List<String> swiftBuildCommand({
  required String packagePath,
  required String product,
  required String scratchPath,
  required String darwinSdkBundle,
  String swift = 'swift',
  String path = '/usr/local/bin:/usr/bin:/bin',
  String? flutterFrameworkFolder,
  List<String> linkerFlags = const [],
  String triple = 'arm64-apple-ios',
  String configuration = 'release',
}) => [
  'env',
  '-u',
  'SDKROOT',
  'XCODE_EXTRA_PLATFORM_FOLDERS=$darwinSdkBundle/Developer/Platforms',
  'PATH=$darwinSdkBundle/toolset/bin:$path',
  swift,
  'build',
  '--configuration',
  configuration,
  '--build-system',
  'swiftbuild',
  '--package-path',
  packagePath,
  '--scratch-path',
  scratchPath,
  '--triple',
  triple,
  '--toolset',
  '$darwinSdkBundle/toolset-swb.json',
  '-Xswiftc',
  '-Xfrontend',
  '-Xswiftc',
  '-enable-cross-import-overlays',
  '--product',
  product,
  '-Xswiftc',
  '-Xfrontend',
  '-Xswiftc',
  '-disable-autolink-framework',
  '-Xswiftc',
  '-Xfrontend',
  '-Xswiftc',
  'SwiftUICore',
  if (flutterFrameworkFolder != null) ...[
    '-Xswiftc',
    '-F$flutterFrameworkFolder',
    '-Xcc',
    '-F$flutterFrameworkFolder',
  ],
  for (final flag in linkerFlags) ...['-Xlinker', flag],
];

/// Builds [product] of the SwiftPM package at [packagePath] (a path on the build host) into [scratchPath] and finds what
/// it wrote: `lib<product>.a` (or the file [artifact] names, for an executable product) and the resource bundles. A
/// static library is not linked into anything here.
Future<SwiftBuild> buildSwiftPackage({
  required String packagePath,
  required String product,
  required String scratchPath,
  required String darwinSdkBundle,
  String swift = 'swift',
  String path = '/usr/local/bin:/usr/bin:/bin',
  String? flutterFrameworkFolder,
  List<String> linkerFlags = const [],
  String? artifact,
  String triple = 'arm64-apple-ios',
  required RunProcess run,
}) async {
  final command = swiftBuildCommand(
    packagePath: packagePath,
    product: product,
    scratchPath: scratchPath,
    darwinSdkBundle: darwinSdkBundle,
    swift: swift,
    path: path,
    flutterFrameworkFolder: flutterFrameworkFolder,
    linkerFlags: linkerFlags,
    triple: triple,
  );
  final started = DateTime.now();
  final result = await run(command.first, command.skip(1).toList());
  final elapsed = DateTime.now().difference(started);
  final log = '${result.stdout}\n${result.stderr}'.trim();
  if (result.exitCode != 0) {
    throw ProcessException(swift, ['build', product], log, result.exitCode);
  }
  final products = '$scratchPath/out/Products/Release-iphoneos';
  final listing = await run('ls', ['-1', products]);
  final names = '${listing.stdout}'
      .split(RegExp(r'\r?\n'))
      .where((n) => n.isNotEmpty)
      .toList();
  final library = artifact ?? 'lib$product.a';
  if (!names.contains(library)) {
    throw FormatException(
      'the build wrote no $library in $products (found: ${names.join(', ')})',
    );
  }
  return SwiftBuild(
    library: '$products/$library',
    bundles: [
      for (final name in names)
        if (name.endsWith('.bundle')) '$products/$name',
    ],
    warnings: RegExp(r'warning:').allMatches(log).length,
    elapsed: elapsed,
    log: log,
  );
}
