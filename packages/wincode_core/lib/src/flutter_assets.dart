import 'dart:convert';
import 'dart:io';

/// Starts a process and waits for it. Tests pass a fake one.
typedef RunProcess = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
});

Future<ProcessResult> _run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) => Process.run(executable, arguments, workingDirectory: workingDirectory);

/// Builds the `flutter_assets` folder of an iOS release build, on a host that is not a Mac.
///
/// - **Assets, fonts, manifests and the licence list:** `flutter assemble copy_flutter_bundle`, the target that
///   `flutter build bundle` runs, called directly because `build bundle` has no `--flavor` and assets that name
///   flavors would be left out. `-dFlavor=` makes the flavor's assets part of the bundle.
/// - **Shaders:** flutter_tools copies assets for Android whatever the target (`CopyFlutterBundle` passes
///   `TargetPlatform.android`), so the compiled shaders hold SkSL, GLES and Vulkan instead of Metal. Each one is
///   compiled again for iOS from its source (ADR-0011 rule 5), with the arguments flutter_tools uses for iOS.
/// - **`.last_build_id`:** `assemble` leaves it in the output folder; an Xcode build doesn't ship it.
///
/// `NativeAssetsManifest.json` comes out empty: the native assets of the app's packages belong to the build hooks
/// (ADR-0010). Returns the asset keys of the shaders that were compiled again.
Future<List<String>> buildFlutterAssets({
  required Directory projectDir,
  required Directory flutterRoot,
  required Directory outputDir,
  String? flavor,
  String target = 'lib/main.dart',
  List<String> dartDefines = const [],
  RunProcess run = _run,
}) async {
  outputDir.createSync(recursive: true);
  final flutter =
      '${flutterRoot.path}/bin/${Platform.isWindows ? 'flutter.bat' : 'flutter'}';
  final result = await run(flutter, [
    'assemble',
    '--no-version-check',
    '--output=${outputDir.path}',
    // Android keeps the Dart build hooks of iOS-only packages from running here, and the assets don't depend on it.
    '-dTargetPlatform=android-arm64',
    '-dTargetFile=$target',
    '-dBuildMode=release',
    '-dTreeShakeIcons=true',
    '-dTrackWidgetCreation=false',
    '-dDartObfuscation=false',
    if (flavor != null) '-dFlavor=$flavor',
    if (dartDefines.isNotEmpty)
      '-dDartDefines=${dartDefines.map((d) => base64.encode(utf8.encode(d))).join(',')}',
    'copy_flutter_bundle',
  ], workingDirectory: projectDir.path);
  if (result.exitCode != 0) {
    throw ProcessException(
      flutter,
      ['assemble', 'copy_flutter_bundle'],
      '${result.stdout}\n${result.stderr}'.trim(),
      result.exitCode,
    );
  }
  final lastBuildId = File('${outputDir.path}/.last_build_id');
  if (lastBuildId.existsSync()) lastBuildId.deleteSync();

  final packages = PackageRoots.read(projectDir);
  final impellerc = impellercPath(flutterRoot);
  final compiled = <String>[];
  final shaders = outputDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.frag'))
      .toList();
  for (final shader in shaders) {
    final key = shader.path
        .substring(outputDir.path.length + 1)
        .replaceAll(r'\', '/');
    final source = shaderSource(
      key: key,
      flutterRoot: flutterRoot,
      projectDir: projectDir,
      packages: packages,
    );
    final compile = await run(
      impellerc,
      impellercArguments(
        impellerc: impellerc,
        source: source.path,
        output: shader.path,
      ),
    );
    final scratch = File('${shader.path}.spirv');
    if (scratch.existsSync()) scratch.deleteSync();
    if (compile.exitCode != 0) {
      throw ProcessException(
        impellerc,
        [key],
        '${compile.stderr}'.trim(),
        compile.exitCode,
      );
    }
    compiled.add(key);
  }
  return compiled;
}

/// The engine's `impellerc` for this host, from the Flutter SDK's artifact cache.
String impellercPath(Directory flutterRoot) {
  final host = Platform.isWindows
      ? 'windows-x64'
      : Platform.isMacOS
      ? 'darwin-x64'
      : 'linux-x64';
  return '${flutterRoot.path}/bin/cache/artifacts/engine/$host/impellerc${Platform.isWindows ? '.exe' : ''}';
}

/// flutter_tools' arguments for compiling a fragment shader for iOS (`ShaderCompiler.compileShader`): Metal only.
List<String> impellercArguments({
  required String impellerc,
  required String source,
  required String output,
}) {
  final sourceFolder = File(source).parent.path;
  final shaderLib = '${File(impellerc).parent.path}/shader_lib';
  return [
    '--runtime-stage-metal',
    '--iplr',
    '--sl=$output',
    '--spirv=$output.spirv',
    '--input=$source',
    '--input-type=frag',
    '--include=$sourceFolder',
    '--include=$shaderLib',
  ];
}

/// The folders of the app's packages, from `.dart_tool/package_config.json`.
class PackageRoots {
  PackageRoots(this.roots);

  factory PackageRoots.read(Directory projectDir) {
    final file = File('${projectDir.path}/.dart_tool/package_config.json');
    final config = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final base = file.uri;
    final roots = <String, Directory>{};
    for (final package
        in (config['packages']! as List<Object?>)
            .cast<Map<String, Object?>>()) {
      final root = base.resolve(
        '${package['rootUri']}'.endsWith('/')
            ? '${package['rootUri']}'
            : '${package['rootUri']}/',
      );
      roots[package['name']! as String] = Directory.fromUri(root);
    }
    return PackageRoots(roots);
  }

  final Map<String, Directory> roots;
}

/// Where the source of the shader with asset key [key] is, by the rules of flutter_tools' `asset.dart`:
///
/// - `shaders/ink_sparkle.frag` and `shaders/stretch_effect.frag` come from the Flutter SDK's own `material` and
///   `widgets` folders;
/// - `packages/<name>/<path>` belongs to the package `<name>`, in its `lib` folder or, failing that, at its root;
/// - any other key is a path in the app.
File shaderSource({
  required String key,
  required Directory flutterRoot,
  required Directory projectDir,
  required PackageRoots packages,
}) {
  final flutterLib = '${flutterRoot.path}/packages/flutter/lib/src';
  final File found;
  if (key == 'shaders/ink_sparkle.frag') {
    found = File('$flutterLib/material/shaders/ink_sparkle.frag');
  } else if (key == 'shaders/stretch_effect.frag') {
    found = File('$flutterLib/widgets/shaders/stretch_effect.frag');
  } else if (key.startsWith('packages/')) {
    final parts = key.split('/');
    final root = packages.roots[parts[1]];
    if (root == null) {
      throw FormatException(
        'shader $key: the package ${parts[1]} is not in package_config.json',
      );
    }
    final rest = parts.skip(2).join('/');
    final inLib = File('${root.path}/lib/$rest');
    found = inLib.existsSync() ? inLib : File('${root.path}/$rest');
  } else {
    found = File('${projectDir.path}/$key');
  }
  if (!found.existsSync()) {
    throw FormatException('the source of shader $key is not at ${found.path}');
  }
  return found;
}
