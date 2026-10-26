import 'dart:convert';
import 'dart:io';

import 'macho_edit.dart';
import 'process.dart';

/// The name of the framework for a bundled native library, by flutter_tools' rule (`frameworkUri`): a `.dylib` loses its
/// extension and a leading `lib`, characters other than letters, digits, dots, underscores and hyphens are dropped, and a
/// name already in [taken] gets a number. The name is added to [taken].
String nativeAssetFrameworkName(String fileName, Set<String> taken) {
  final parts = fileName.split('.');
  final isDylib = parts.length >= 2 && parts.last == 'dylib';
  var name = isDylib ? parts.sublist(0, parts.length - 1).join('.') : fileName;
  if (isDylib && name.startsWith('lib')) {
    name = name.replaceFirst('lib', '');
  }
  name = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
  if (taken.contains(name)) {
    final prefix = name;
    for (var i = 1; i < 1000 && taken.contains(name); i++) {
      name = '$prefix$i';
    }
    if (taken.contains(name)) {
      throw StateError('no free framework name for $fileName');
    }
  }
  taken.add(name);
  return name;
}

/// The `Info.plist` of a native-asset framework, written as flutter_tools writes it (`createInfoPlist`), byte for byte.
String nativeAssetFrameworkInfoPlist(String name, {String? minimumIosVersion}) {
  final id = 'io.flutter.flutter.native_assets.$name'.replaceAll('_', '-');
  return [
    '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleDevelopmentRegion</key>
\t<string>en</string>
\t<key>CFBundleExecutable</key>
\t<string>$name</string>
\t<key>CFBundleIdentifier</key>
\t<string>$id</string>
\t<key>CFBundleInfoDictionaryVersion</key>
\t<string>6.0</string>
\t<key>CFBundleName</key>
\t<string>$name</string>
\t<key>CFBundlePackageType</key>
\t<string>FMWK</string>
\t<key>CFBundleShortVersionString</key>
\t<string>1.0</string>
\t<key>CFBundleSignature</key>
\t<string>????</string>
\t<key>CFBundleVersion</key>
\t<string>1.0</string>
''',
    if (minimumIosVersion != null)
      '''
\t<key>MinimumOSVersion</key>
\t<string>$minimumIosVersion</string>
''',
    '''
</dict>
</plist>''',
  ].join();
}

/// `NativeAssetsManifest.json`, which tells the engine where each native library is: the asset ids of the hooks' code
/// assets and the framework each was put in, for one target such as `ios_arm64`. flutter_tools writes it compactly, and
/// Flutter 3.47 ships it in `flutter_assets` (ADR-0010).
String nativeAssetsManifest(
  Map<String, String> frameworkByAssetId, {
  String target = 'ios_arm64',
}) => jsonEncode({
  'format-version': [1, 0, 0],
  'native-assets': {
    target: {
      for (final entry in frameworkByAssetId.entries)
        entry.key: ['absolute', '${entry.value}.framework/${entry.value}'],
    },
  },
});

/// Makes `<name>.framework` in [outDirectory] from the dynamic library a build hook wrote, the way flutter_tools does for
/// iOS (`copyNativeCodeAssetsIOS`): the library is copied in as `<name>/<name>`, its local symbols are removed with
/// [objcopy] (`llvm-objcopy --discard-all --strip-debug`, which is `strip -x -S`), its install name becomes
/// `@rpath/<name>.framework/<name>`, and `Info.plist` is written next to it. Returns the framework folder.
///
/// There is no dSYM here: a dSYM is not part of the bundle. The code signature is made when the bundle is signed.
Future<Directory> buildNativeAssetFramework({
  required File dylib,
  required String name,
  required Directory outDirectory,
  required String objcopy,
  String minimumIosVersion = '15.0',
  RunProcess run = runProcess,
}) async {
  final framework = Directory('${outDirectory.path}/$name.framework')
    ..createSync(recursive: true);
  final binary = File('${framework.path}/$name');
  dylib.copySync(binary.path);
  final arguments = ['--discard-all', '--strip-debug', binary.path];
  final result = await run(objcopy, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      objcopy,
      arguments,
      '${result.stdout}\n${result.stderr}'.trim(),
      result.exitCode,
    );
  }
  binary.writeAsBytesSync(
    setInstallName(binary.readAsBytesSync(), '@rpath/$name.framework/$name'),
  );
  File('${framework.path}/Info.plist').writeAsStringSync(
    nativeAssetFrameworkInfoPlist(name, minimumIosVersion: minimumIosVersion),
  );
  return framework;
}
