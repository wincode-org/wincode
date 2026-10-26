import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'process.dart';

/// Compiles the app's Dart code to a kernel file (`app.dill`) for an iOS release build, on a host that is not a Mac.
///
/// It runs `flutter assemble kernel_snapshot_program`, the target that Xcode's build script runs for iOS: Flutter's
/// own `frontend_server` with `--aot --tfa --target-os ios`, so the kernel is the one a Mac would make for the same
/// source, flavor and Dart defines. The kernel carries the hash of the Dart SDK that compiled it; `gen_snapshot` must
/// come from the same Dart revision.
///
/// The kernel is found in Flutter's build folder, `.dart_tool/flutter_build/<hash>/app.dill`. The hash includes the
/// output folder, and the output folder here is new every time, so the folder is new too and the kernel is never
/// one left by an earlier run. (`assemble --build-outputs` lists nothing for this target.)
///
/// Native assets (ADR-0010) are not part of this step yet.
Future<File> buildKernel({
  required Directory projectDir,
  required Directory flutterRoot,
  String? flavor,
  String target = 'lib/main.dart',
  List<String> dartDefines = const [],
  RunProcess run = runProcess,
}) async {
  final scratch = Directory.systemTemp.createTempSync('wincode_kernel');
  try {
    final started = DateTime.now().subtract(const Duration(seconds: 2));
    final flutter =
        '${flutterRoot.path}/bin/${Platform.isWindows ? 'flutter.bat' : 'flutter'}';
    final result = await run(flutter, [
      'assemble',
      '--no-version-check',
      '--output=${scratch.path}',
      '-dTargetPlatform=ios',
      '-dTargetFile=$target',
      '-dBuildMode=release',
      '-dIosArchs=arm64',
      '-dTreeShakeIcons=true',
      '-dTrackWidgetCreation=false',
      '-dDartObfuscation=false',
      if (flavor != null) '-dFlavor=$flavor',
      if (dartDefines.isNotEmpty)
        '-dDartDefines=${dartDefines.map((d) => base64.encode(utf8.encode(d))).join(',')}',
      'kernel_snapshot_program',
    ], workingDirectory: projectDir.path);
    if (result.exitCode != 0) {
      throw ProcessException(
        flutter,
        ['assemble', 'kernel_snapshot_program'],
        '${result.stdout}\n${result.stderr}'.trim(),
        result.exitCode,
      );
    }
    final buildRoot = Directory('${projectDir.path}/.dart_tool/flutter_build');
    final listed = buildRoot.existsSync()
        ? (buildRoot
              .listSync()
              .whereType<Directory>()
              .map((d) => File('${d.path}/app.dill'))
              .where(
                (f) => f.existsSync() && f.lastModifiedSync().isAfter(started),
              )
              .toList()
            ..sort(
              (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
            ))
        : <File>[];
    if (listed.isEmpty) {
      throw const FormatException('flutter assemble made no app.dill');
    }
    return listed.first;
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

/// The arguments flutter_tools gives `gen_snapshot` for an iOS release build (`AOTSnapshotter.build`, Flutter 3.47.5):
/// `gen_snapshot` itself writes the Mach-O dylib, so there is no assembly step and no C compiler (ADR-0004).
///
/// [framework] and [object] are the paths of `App.framework/App` and `app.o`; [minOsVersion] is the app's
/// deployment target. `--deterministic` comes first, as in flutter_tools.
List<String> genSnapshotArguments({
  required String kernel,
  required String framework,
  required String object,
  String minOsVersion = '15.0',
  bool obfuscate = false,
  String? saveDebuggingInfo,
}) => [
  '--deterministic',
  '--snapshot_kind=app-aot-macho-dylib',
  '--macho=$framework',
  '--macho-object=$object',
  '--macho-min-os-version=$minOsVersion',
  '--macho-rpath=@executable_path/Frameworks,@loader_path/Frameworks',
  '--macho-install-name=@rpath/App.framework/App',
  if (saveDebuggingInfo != null) ...[
    '--dwarf-stack-traces',
    '--resolve-dwarf-paths',
    '--save-debugging-info=$saveDebuggingInfo',
  ],
  if (obfuscate) '--obfuscate',
  kernel,
];

/// Runs [genSnapshot] on [kernel] and returns the `App.framework/App` it writes into [workDir].
///
/// gen_snapshot records the object file's path as it was given, so it runs inside [workDir] with relative paths, and
/// the debug-info step (`dsymutil`) must run there too. The binary still has its symbols; flutter_tools strips it
/// (`strip -x`) after the dSYM is made.
Future<File> buildAppBinary({
  required File kernel,
  required File genSnapshot,
  required Directory workDir,
  String minOsVersion = '15.0',
  bool obfuscate = false,
  RunProcess run = runProcess,
}) async {
  Directory('${workDir.path}/arm64/App.framework').createSync(recursive: true);
  final kernelCopy = File('${workDir.path}/app.dill');
  kernel.copySync(kernelCopy.path);
  final result = await run(
    genSnapshot.path,
    genSnapshotArguments(
      kernel: 'app.dill',
      framework: 'arm64/App.framework/App',
      object: 'arm64/app.o',
      minOsVersion: minOsVersion,
      obfuscate: obfuscate,
    ),
    workingDirectory: workDir.path,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      genSnapshot.path,
      ['app.dill'],
      '${result.stdout}\n${result.stderr}'.trim(),
      result.exitCode,
    );
  }
  final binary = File('${workDir.path}/arm64/App.framework/App');
  if (!binary.existsSync()) {
    throw const FormatException('gen_snapshot wrote no App.framework/App');
  }
  return binary;
}

/// Wraps a thin arm64 Mach-O file in the universal container that `lipo -create` makes for one architecture, as
/// flutter_tools does after `strip` (`lipo` is also run for a single architecture). The container is a big-endian header
/// (magic `0xcafebabe`, one entry with the file's CPU type and subtype, the slice's offset 16384 and size, and the
/// alignment 2^14), zeros up to the offset, and the slice.
Uint8List wrapInFat(Uint8List thin) {
  const offset = 16384;
  final thinHeader = ByteData.sublistView(thin);
  if (thin.length < 32 ||
      thinHeader.getUint32(0, Endian.little) != 0xfeedfacf) {
    throw const FormatException('not a 64-bit Mach-O file');
  }
  final fat = Uint8List(offset + thin.length);
  ByteData.sublistView(fat)
    ..setUint32(0, 0xcafebabe)
    ..setUint32(4, 1)
    ..setUint32(8, thinHeader.getUint32(4, Endian.little))
    ..setUint32(12, thinHeader.getUint32(8, Endian.little))
    ..setUint32(16, offset)
    ..setUint32(20, thin.length)
    ..setUint32(24, 14);
  fat.setRange(offset, fat.length, thin);
  return fat;
}

/// The steps flutter_tools runs after gen_snapshot for a release build (`AOTSnapshotter.build`): the debug symbols go to
/// a dSYM with [dsymutil], the local symbols are removed with [objcopy] (`llvm-objcopy --discard-all`, which is
/// `strip -x`), and the binary is wrapped as `lipo` would. Run it in the [workDir] that [buildAppBinary] used.
///
/// Returns `App.framework/App` in [workDir]; the dSYM is `arm64/App.framework.dSYM` there. The code signature is not
/// valid after stripping and is made again when the bundle is signed.
Future<File> finishAppBinary({
  required Directory workDir,
  required String dsymutil,
  required String objcopy,
  RunProcess run = runProcess,
}) async {
  Future<void> step(String tool, List<String> arguments) async {
    final result = await run(tool, arguments, workingDirectory: workDir.path);
    if (result.exitCode != 0) {
      throw ProcessException(
        tool,
        arguments,
        '${result.stdout}\n${result.stderr}'.trim(),
        result.exitCode,
      );
    }
  }

  await step(dsymutil, [
    '-o',
    'arm64/App.framework.dSYM',
    'arm64/App.framework/App',
  ]);
  await step(objcopy, [
    '--discard-all',
    'arm64/App.framework/App',
    'arm64/App.stripped',
  ]);
  final output = File('${workDir.path}/App.framework/App')
    ..parent.createSync(recursive: true);
  output.writeAsBytesSync(
    wrapInFat(File('${workDir.path}/arm64/App.stripped').readAsBytesSync()),
  );
  return output;
}
