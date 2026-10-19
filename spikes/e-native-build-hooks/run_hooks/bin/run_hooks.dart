// Spike E: run an app's Dart build hooks for iOS arm64 on Linux, with the build input
// flutter_tools 3.47.7 uses on macOS (targets.dart, IOSAssetTarget): dynamic linking,
// iPhoneOS SDK, iOS 15. Writes the code assets the hooks produced as JSON.
//
// Usage: dart run bin/run_hooks.dart <app-dir> <out.json> <clang> <linker> <archiver> <xcrun-shim-dir>
import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:file/local.dart';
import 'package:hooks_runner/hooks_runner.dart';
import 'package:logging/logging.dart';
import 'package:package_config/package_config.dart';

Future<void> main(List<String> args) async {
  if (args.length != 6) {
    stderr.writeln('usage: run_hooks <app-dir> <out.json> <clang> <linker> <archiver> <xcrun-shim-dir>');
    exit(64);
  }
  final [appDir, outJson, clang, linker, archiver, shimDir] = args;
  final app = Directory(appDir).absolute.uri;
  final packageConfigUri = app.resolve('.dart_tool/package_config.json');
  final appName = RegExp(r'^name:\s*(\S+)', multiLine: true)
      .firstMatch(File.fromUri(app.resolve('pubspec.yaml')).readAsStringSync())![1]!;

  final logger = Logger.detached('hooks')
    ..level = Level.INFO
    ..onRecord.listen((r) => stderr.writeln('${r.level.name}: ${r.message}'));
  const fileSystem = LocalFileSystem();

  final runner = NativeAssetsBuildRunner(
    logger: logger,
    dartExecutable: Uri.file(Platform.resolvedExecutable),
    fileSystem: fileSystem,
    packageLayout: PackageLayout.fromPackageConfig(
      fileSystem,
      await loadPackageConfigUri(packageConfigUri),
      packageConfigUri,
      appName,
      includeDevDependencies: false,
    ),
    // The variables hooks_runner passes on by default, with the xcrun shim first on PATH.
    hookEnvironment: {
      for (final e in Platform.environment.entries)
        if (NativeAssetsBuildRunner.includeHookEnvironmentVariable(e.key)) e.key: e.value,
      'PATH': '$shimDir:${Platform.environment['PATH']}',
    },
    userDefines: UserDefines(workspacePubspec: app.resolve('pubspec.yaml')),
  );

  final result = await runner.build(
    linkingEnabled: false,
    extensions: [
      CodeAssetExtension(
        targetArchitecture: Architecture.arm64,
        targetOS: OS.iOS,
        linkModePreference: LinkModePreference.dynamic,
        cCompiler: CCompilerConfig(
          compiler: Uri.file(clang),
          linker: Uri.file(linker),
          archiver: Uri.file(archiver),
        ),
        iOS: IOSCodeConfig(targetSdk: IOSSdk.iPhoneOS, targetVersion: 15),
      ),
    ],
  );
  if (!result.isSuccess) {
    stderr.writeln('hooks failed: ${result.failure}');
    exit(1);
  }

  final assets = [
    for (final encoded in result.success.encodedAssets)
      if (encoded.isCodeAsset) CodeAsset.fromEncoded(encoded),
  ];
  File(outJson).writeAsStringSync(const JsonEncoder.withIndent('  ').convert([
    for (final asset in assets)
      {'id': asset.id, 'file': asset.file?.toFilePath(), 'linkMode': '${asset.linkMode}'},
  ]));
  stdout.writeln('${assets.length} code asset(s) -> $outJson');
}
