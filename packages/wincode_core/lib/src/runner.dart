import 'dart:convert';
import 'dart:io';

import 'macho_edit.dart';
import 'process.dart';
import 'swift_build.dart';
import 'wsl.dart';

/// A Flutter plugin with a SwiftPM package, as the generated plugin package and the registrant need it.
class SwiftPlugin {
  const SwiftPlugin({
    required this.name,
    required this.basename,
    required this.packagePath,
    required this.pluginClass,
  });

  /// The plugin's name in `pubspec.yaml`, such as `shared_preferences_foundation`. It names the plugin's package and
  /// Swift module.
  final String name;

  /// The plugin's folder name in the pub cache, `<name>-<version>`. Flutter links the plugin into `.packages` under this
  /// name, so SwiftPM sees the version in the package's identity (and Xcode's resource bundle IDs carry it).
  final String basename;

  /// The folder that holds the plugin's `Package.swift`, as the build host sees it (`darwin/<name>` or `ios/<name>`).
  final String packagePath;

  /// The plugin class from `pubspec.yaml`, which the registrant calls.
  final String pluginClass;

  /// The library product of the plugin's package. flutter_tools uses the plugin's name with hyphens.
  String get product => name.replaceAll('_', '-');
}

const _generatedPackage = 'FlutterGeneratedPluginSwiftPackage';
const _flutterFramework = 'FlutterFramework';

/// The `Package.swift` of `FlutterGeneratedPluginSwiftPackage`, as flutter_tools writes it on a Mac (3.47.5): a static
/// library whose target depends on the product of each plugin and, last, on the `FlutterFramework` package, for the
/// project's [deploymentTarget]. The plugins and `FlutterFramework` are the entries of `.packages` next to it. On Windows
/// `flutter pub get` writes only a version of it that has none of them.
String generatedPluginPackageManifest(
  List<SwiftPlugin> plugins, {
  required String deploymentTarget,
}) {
  final packages = [
    for (final p in plugins)
      '.package(name: "${p.name}", path: "../.packages/${p.basename}")',
    '.package(name: "$_flutterFramework", path: "../.packages/$_flutterFramework")',
  ].join(',\n        ');
  final products = [
    for (final p in plugins)
      '                .product(name: "${p.product}", package: "${p.name}")',
    '                .product(name: "$_flutterFramework", package: "$_flutterFramework")',
  ].join(',\n');
  final target =
      '.target(\n'
      '            name: "$_generatedPackage",\n'
      '            dependencies: [\n'
      '$products\n'
      '            ]\n'
      '        )';
  return '''
// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// Generated file. Do not edit.
//

import PackageDescription

let package = Package(
    name: "$_generatedPackage",
    platforms: [
        .iOS("$deploymentTarget")
    ],
    products: [
        .library(name: "$_generatedPackage", type: .static, targets: ["$_generatedPackage"])
    ],
    dependencies: [
        $packages
    ],
    targets: [
        $target
    ]
)
''';
}

/// The `Package.swift` of the `FlutterFramework` package in `.packages`, which some plugins depend on
/// (`.package(name: "FlutterFramework", path: "../FlutterFramework")`). flutter_tools writes it with one target that has no
/// code and one library product; the Flutter framework itself reaches the plugins through the framework search path, as
/// it does in an Xcode build.
String flutterFrameworkPackageManifest() =>
    '// swift-tools-version: 5.9\n'
    '// The swift-tools-version declares the minimum version of Swift required to build this package.\n'
    '//\n'
    '// Generated file. Do not edit.\n'
    '//\n'
    '\n'
    'import PackageDescription\n'
    '\n'
    'let package = Package(\n'
    '    name: "$_flutterFramework",\n'
    '    products: [\n'
    '        .library(name: "$_flutterFramework", targets: ["$_flutterFramework"])\n'
    '    ],\n'
    '    dependencies: [\n'
    '        \n'
    '    ],\n'
    '    targets: [\n'
    '        .target(\n'
    '            name: "$_flutterFramework"\n'
    '        )\n'
    '    ]\n'
    ')\n';

/// `GeneratedPluginRegistrant` in Swift, registering only [plugins]. flutter_tools writes it in Objective-C and for every
/// plugin of the app; a runner that links part of them needs one that names only those. The app's `AppDelegate` calls it
/// as it calls the Objective-C one, `GeneratedPluginRegistrant.register(with:)`.
String generatedPluginRegistrant(List<SwiftPlugin> plugins) =>
    '''
//
//  Generated file. Do not edit.
//

import Flutter
${[for (final p in plugins) 'import ${p.name}'].join('\n')}

enum GeneratedPluginRegistrant {
  static func register(with registry: FlutterPluginRegistry) {
${[for (final p in plugins) '    ${p.pluginClass}.register(with: registry.registrar(forPlugin: "${p.pluginClass}")!)'].join('\n')}
  }
}
''';

/// The window and the `FlutterViewController` in code, which a storyboard would make (ADR-0011 rule 3).
///
/// With no storyboard UIKit creates no window for a scene, and the scene delegate finds none. `FlutterSceneDelegate`
/// connects the engine of the window's root `FlutterViewController` to the scene when the scene connects, so the window
/// has to exist before `super.scene(_:willConnectTo:options:)` runs. The class has the name of Flutter's, so the app's
/// own `class SceneDelegate: FlutterSceneDelegate` inherits it unchanged, and the scene setup in `Info.plist` stays as
/// the app has it. A `FlutterViewController` made with `init()` has an implicit engine, and its creation calls the app
/// delegate's `didInitializeImplicitFlutterEngine`, as the storyboard's does.
const sceneDelegateBase = '''
//
//  Generated file. Do not edit.
//

import Flutter
import UIKit

class FlutterSceneDelegate: Flutter.FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    if window == nil, let windowScene = scene as? UIWindowScene {
      let window = UIWindow(windowScene: windowScene)
      window.rootViewController = FlutterViewController()
      self.window = window
      window.makeKeyAndVisible()
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }
}
''';

/// The `Package.swift` of the runner: one executable target, made of the app's Swift sources and the generated files,
/// that depends on the generated plugin package.
String runnerPackageManifest({
  required String deploymentTarget,
  String productName = 'Runner',
}) =>
    '''
// swift-tools-version: 5.9
//
// Generated file. Do not edit.
//

import PackageDescription

let package = Package(
    name: "$productName",
    platforms: [
        .iOS("$deploymentTarget")
    ],
    products: [
        .executable(name: "$productName", targets: ["$productName"])
    ],
    dependencies: [
        .package(name: "$_generatedPackage", path: "../Flutter/ephemeral/Packages/$_generatedPackage")
    ],
    targets: [
        .executableTarget(
            name: "$productName",
            dependencies: [
                .product(name: "$_generatedPackage", package: "$_generatedPackage")
            ],
            path: "Sources/$productName"
        )
    ]
)
''';

/// The version `-platform_version` records as the SDK (ADR-0011 rule 1): `Version` in the SDK's `SDKSettings.json`.
String sdkVersion(Directory sdk) {
  final settings = jsonDecode(
    File('${sdk.path}/SDKSettings.json').readAsStringSync(),
  ) as Map<String, Object?>;
  return settings['Version']! as String;
}

/// Writes the runner package and the generated plugin package in the layout flutter_tools uses, under [root]:
///
/// - `ios/Runner/Package.swift`, with `Sources/<productName>/` holding the [appSources] unchanged, the registrant and
///   the window code;
/// - `ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/`, with a link in `.packages` for each of
///   [plugins] and the `FlutterFramework` package that some plugins depend on, next to them. The links are made with
///   [run], so under WSL2 they are made by Linux (`ln -sfn`).
///
/// Returns the runner package's folder.
Future<Directory> writeRunnerPackage({
  required Directory root,
  required List<File> appSources,
  required List<SwiftPlugin> plugins,
  required String deploymentTarget,
  String productName = 'Runner',
  required RunProcess run,
}) async {
  final runner = Directory('${root.path}/ios/Runner');
  final sources = Directory('${runner.path}/Sources/$productName')
    ..createSync(recursive: true);
  File('${runner.path}/Package.swift').writeAsStringSync(
    runnerPackageManifest(
      deploymentTarget: deploymentTarget,
      productName: productName,
    ),
  );
  for (final source in appSources) {
    source.copySync('${sources.path}/${source.uri.pathSegments.last}');
  }
  File('${sources.path}/GeneratedPluginRegistrant.swift')
      .writeAsStringSync(generatedPluginRegistrant(plugins));
  File('${sources.path}/FlutterSceneDelegate.swift')
      .writeAsStringSync(sceneDelegateBase);

  final packages = Directory('${root.path}/ios/Flutter/ephemeral/Packages');
  final generated = Directory('${packages.path}/$_generatedPackage');
  Directory('${generated.path}/Sources/$_generatedPackage')
      .createSync(recursive: true);
  File('${generated.path}/Package.swift').writeAsStringSync(
    generatedPluginPackageManifest(plugins, deploymentTarget: deploymentTarget),
  );
  File('${generated.path}/Sources/$_generatedPackage/$_generatedPackage.swift')
      .writeAsStringSync('//\n// Generated file. Do not edit.\n//\n');
  final framework = Directory('${packages.path}/.packages/$_flutterFramework');
  Directory('${framework.path}/Sources/$_flutterFramework')
      .createSync(recursive: true);
  File('${framework.path}/Package.swift')
      .writeAsStringSync(flutterFrameworkPackageManifest());
  File('${framework.path}/Sources/$_flutterFramework/$_flutterFramework.swift')
      .writeAsStringSync('//\n// Generated file. Do not edit.\n//\n');
  for (final plugin in plugins) {
    final link = toWslPath('${packages.path}/.packages/${plugin.basename}');
    final result = await run('ln', ['-sfn', plugin.packagePath, link]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'ln',
        ['-sfn', plugin.packagePath, link],
        '${result.stdout}\n${result.stderr}'.trim(),
        result.exitCode,
      );
    }
  }
  return runner;
}

/// Builds the runner package written by [writeRunnerPackage] into the executable [output]:
///
/// - It is linked with the SDK stamp of ADR-0011 rule 1 (`-platform_version ios <deployment target> <SDK version>`) and
///   the rpath `@executable_path/Frameworks`, against the `Flutter.framework` in [flutterFrameworkFolder] (headers, module
///   map and the engine binary).
/// - Then the rpaths other than `/usr/lib/swift` and `@executable_path/Frameworks` are removed (rule 3).
///
/// The result's [SwiftBuild.library] is the executable in the scratch folder; [output] is its copy with the rpaths removed.
Future<({SwiftBuild build, List<String> removedRpaths})> buildRunner({
  required Directory runnerPackage,
  required String scratchPath,
  required String darwinSdkBundle,
  required String sdkVersion,
  required String deploymentTarget,
  required String flutterFrameworkFolder,
  required File output,
  String productName = 'Runner',
  String swift = 'swift',
  String path = '/usr/local/bin:/usr/bin:/bin',
  required RunProcess run,
}) async {
  final build = await buildSwiftPackage(
    packagePath: toWslPath(runnerPackage.path),
    product: productName,
    artifact: productName,
    scratchPath: scratchPath,
    darwinSdkBundle: darwinSdkBundle,
    swift: swift,
    path: path,
    flutterFrameworkFolder: flutterFrameworkFolder,
    linkerFlags: [
      '-F$flutterFrameworkFolder',
      '-platform_version',
      'ios',
      deploymentTarget,
      sdkVersion,
      '-rpath',
      '@executable_path/Frameworks',
    ],
    run: run,
  );
  final copy = await run('cp', [build.library, toWslPath(output.path)]);
  if (copy.exitCode != 0) {
    throw ProcessException(
      'cp',
      [build.library, output.path],
      '${copy.stderr}'.trim(),
      copy.exitCode,
    );
  }
  final edited = removeRpaths(output.readAsBytesSync(), const {
    '/usr/lib/swift',
    '@executable_path/Frameworks',
  });
  output.writeAsBytesSync(edited.macho);
  return (build: build, removedRpaths: edited.removed);
}
