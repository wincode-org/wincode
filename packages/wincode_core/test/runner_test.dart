import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

import 'macho_builder.dart';

const _plugins = [
  SwiftPlugin(
    name: 'flutter_secure_storage_darwin',
    basename: 'flutter_secure_storage_darwin-0.4.1',
    packagePath: '/pub/flutter_secure_storage_darwin-0.4.1/darwin/flutter_secure_storage_darwin',
    pluginClass: 'FlutterSecureStorageDarwinPlugin',
  ),
  SwiftPlugin(
    name: 'shared_preferences_foundation',
    basename: 'shared_preferences_foundation-2.5.7',
    packagePath: '/pub/shared_preferences_foundation-2.5.7/darwin/shared_preferences_foundation',
    pluginClass: 'SharedPreferencesPlugin',
  ),
];

void main() {
  group('generatedPluginPackageManifest', () {
    test('lists each plugin, linked as flutter_tools links it, in a static library', () {
      expect(
        generatedPluginPackageManifest(_plugins, deploymentTarget: '15.0'),
        '''
// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// Generated file. Do not edit.
//

import PackageDescription

let package = Package(
    name: "FlutterGeneratedPluginSwiftPackage",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "FlutterGeneratedPluginSwiftPackage", type: .static, targets: ["FlutterGeneratedPluginSwiftPackage"])
    ],
    dependencies: [
        .package(name: "flutter_secure_storage_darwin", path: "../.packages/flutter_secure_storage_darwin-0.4.1"),
        .package(name: "shared_preferences_foundation", path: "../.packages/shared_preferences_foundation-2.5.7"),
        .package(name: "FlutterFramework", path: "../.packages/FlutterFramework")
    ],
    targets: [
        .target(
            name: "FlutterGeneratedPluginSwiftPackage",
            dependencies: [
                .product(name: "flutter-secure-storage-darwin", package: "flutter_secure_storage_darwin"),
                .product(name: "shared-preferences-foundation", package: "shared_preferences_foundation"),
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
''',
      );
    });

    test('with no plugins it still depends on FlutterFramework', () {
      final text = generatedPluginPackageManifest(
        const [],
        deploymentTarget: '15.0',
      );
      expect(
        text,
        contains(
          '    dependencies: [\n'
          '        .package(name: "FlutterFramework", path: "../.packages/FlutterFramework")\n'
          '    ],',
        ),
      );
      expect(
        text,
        contains(
          '            dependencies: [\n'
          '                .product(name: "FlutterFramework", package: "FlutterFramework")\n'
          '            ]',
        ),
      );
    });
  });

  group('flutterFrameworkPackageManifest', () {
    test(
      'is the empty package flutter_tools writes: one target, one library',
      () {
        expect(
          flutterFrameworkPackageManifest(),
          '// swift-tools-version: 5.9\n'
          '// The swift-tools-version declares the minimum version of Swift required to build this package.\n'
          '//\n'
          '// Generated file. Do not edit.\n'
          '//\n'
          '\n'
          'import PackageDescription\n'
          '\n'
          'let package = Package(\n'
          '    name: "FlutterFramework",\n'
          '    products: [\n'
          '        .library(name: "FlutterFramework", targets: ["FlutterFramework"])\n'
          '    ],\n'
          '    dependencies: [\n'
          '        \n'
          '    ],\n'
          '    targets: [\n'
          '        .target(\n'
          '            name: "FlutterFramework"\n'
          '        )\n'
          '    ]\n'
          ')\n',
        );
      },
    );
  });

  group('generatedPluginRegistrant', () {
    test('imports and registers only the given plugins', () {
      expect(generatedPluginRegistrant(_plugins), '''
//
//  Generated file. Do not edit.
//

import Flutter
import flutter_secure_storage_darwin
import shared_preferences_foundation

enum GeneratedPluginRegistrant {
  static func register(with registry: FlutterPluginRegistry) {
    FlutterSecureStorageDarwinPlugin.register(with: registry.registrar(forPlugin: "FlutterSecureStorageDarwinPlugin")!)
    SharedPreferencesPlugin.register(with: registry.registrar(forPlugin: "SharedPreferencesPlugin")!)
  }
}
''');
    });
  });

  group('runnerPackageManifest', () {
    test('is one executable target that depends on the generated package', () {
      final text = runnerPackageManifest(deploymentTarget: '15.0');
      expect(
        text,
        contains('.executable(name: "Runner", targets: ["Runner"])'),
      );
      expect(
        text,
        contains(
          'path: "../Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage"',
        ),
      );
      expect(text, contains('path: "Sources/Runner"'));
      expect(text, contains('.iOS("15.0")'));
    });
  });

  group('sceneDelegateBase', () {
    test(
      'creates the window before the scene delegate connects the engine',
      () {
        final window = sceneDelegateBase.indexOf('window.makeKeyAndVisible()');
        final connect = sceneDelegateBase.indexOf(
          'super.scene(scene, willConnectTo',
        );
        expect(window, greaterThan(0));
        expect(connect, greaterThan(window));
        expect(
          sceneDelegateBase,
          contains('class FlutterSceneDelegate: Flutter.FlutterSceneDelegate'),
        );
      },
    );
  });

  group('writeRunnerPackage', () {
    test('writes both packages and links each plugin', () async {
      final root = Directory.systemTemp.createTempSync('runner_test');
      addTearDown(() => root.deleteSync(recursive: true));
      final src = Directory('${root.path}/app')..createSync();
      final appDelegate = File('${src.path}/AppDelegate.swift')
        ..writeAsStringSync('// app delegate');
      final sceneDelegate = File('${src.path}/SceneDelegate.swift')
        ..writeAsStringSync('// scene delegate');
      final links = <List<String>>[];
      final runner = await writeRunnerPackage(
        root: Directory('${root.path}/work'),
        appSources: [appDelegate, sceneDelegate],
        plugins: _plugins,
        deploymentTarget: '15.0',
        run: (exe, args, {workingDirectory}) async {
          links.add([exe, ...args]);
          return ProcessResult(1, 0, '', '');
        },
      );
      expect(runner.path, endsWith('work/ios/Runner'));
      final sources = Directory(
        '${runner.path}/Sources/Runner',
      ).listSync().map((f) => f.uri.pathSegments.last).toList()..sort();
      expect(sources, [
        'AppDelegate.swift',
        'FlutterSceneDelegate.swift',
        'GeneratedPluginRegistrant.swift',
        'SceneDelegate.swift',
      ]);
      expect(
        File('${runner.path}/Sources/Runner/AppDelegate.swift')
            .readAsStringSync(),
        '// app delegate',
      );
      final generated =
          '${root.path}/work/ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage';
      expect(
        File('$generated/Package.swift').readAsStringSync(),
        generatedPluginPackageManifest(_plugins, deploymentTarget: '15.0'),
      );
      expect(
        File(
          '$generated/Sources/FlutterGeneratedPluginSwiftPackage/FlutterGeneratedPluginSwiftPackage.swift',
        ).existsSync(),
        isTrue,
      );
      final framework =
          '${root.path}/work/ios/Flutter/ephemeral/Packages/.packages/FlutterFramework';
      expect(
        File('$framework/Package.swift').readAsStringSync(),
        flutterFrameworkPackageManifest(),
      );
      expect(
        File('$framework/Sources/FlutterFramework/FlutterFramework.swift')
            .existsSync(),
        isTrue,
      );
      expect(links.map((l) => l.take(3).toList()), [
        ['ln', '-sfn', _plugins[0].packagePath],
        ['ln', '-sfn', _plugins[1].packagePath],
      ]);
      expect(
        links[1].last,
        endsWith(
          '/ios/Flutter/ephemeral/Packages/.packages/shared_preferences_foundation-2.5.7',
        ),
      );
    });
  });

  group('buildRunner', () {
    test('links with the SDK stamp, then takes the build machine\'s rpaths out', () async {
      final dir = Directory.systemTemp.createTempSync('runner_build_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final output = File('${dir.path}/Runner');
      final calls = <List<String>>[];
      final result = await buildRunner(
        runnerPackage: Directory('${dir.path}/ios/Runner'),
        scratchPath: '/scratch',
        darwinSdkBundle: '/sdk',
        sdkVersion: '26.5',
        deploymentTarget: '15.0',
        flutterFrameworkFolder: '/fw',
        output: output,
        run: (exe, args, {workingDirectory}) async {
          calls.add([exe, ...args]);
          if (exe == 'ls') {
            return ProcessResult(1, 0, 'Runner\nFoo.bundle\n', '');
          }
          if (exe == 'cp') {
            output.writeAsBytesSync(
              withRpaths([
                '/usr/lib/swift',
                '@loader_path',
                '/home/me/.swiftly/toolchains/6.4.0/usr/lib/swift-6.2/iphoneos',
                '@executable_path/Frameworks',
              ]),
            );
          }
          return ProcessResult(1, 0, 'Build complete!', '');
        },
      );
      final swift = calls.first;
      expect(
        swift.sublist(swift.indexOf('--product')),
        containsAllInOrder([
          '--product',
          'Runner',
          '-Xlinker',
          '-F/fw',
          '-Xlinker',
          '-platform_version',
          '-Xlinker',
          'ios',
          '-Xlinker',
          '15.0',
          '-Xlinker',
          '26.5',
          '-Xlinker',
          '-rpath',
          '-Xlinker',
          '@executable_path/Frameworks',
        ]),
      );
      expect(
        result.build.library,
        '/scratch/out/Products/Release-iphoneos/Runner',
      );
      expect(result.removedRpaths, [
        '@loader_path',
        '/home/me/.swiftly/toolchains/6.4.0/usr/lib/swift-6.2/iphoneos',
      ]);
      final left = removeRpaths(output.readAsBytesSync(), const {});
      expect(left.removed, ['/usr/lib/swift', '@executable_path/Frameworks']);
    });
  });
}
