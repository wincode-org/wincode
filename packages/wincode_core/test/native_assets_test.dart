import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

void main() {
  group('nativeAssetFrameworkName', () {
    test(
      'drops .dylib and a leading lib, and characters Apple does not allow',
      () {
        final taken = <String>{};
        expect(
          nativeAssetFrameworkName('objective_c.dylib', taken),
          'objective_c',
        );
        expect(nativeAssetFrameworkName('libsqlite3.dylib', taken), 'sqlite3');
        expect(nativeAssetFrameworkName('my lib+x.dylib', taken), 'mylibx');
        expect(nativeAssetFrameworkName('libfoo', taken), 'libfoo');
        expect(nativeAssetFrameworkName('a.b.dylib', taken), 'a.b');
      },
    );

    test('a name that is taken gets a number', () {
      final taken = <String>{};
      expect(nativeAssetFrameworkName('libfoo.dylib', taken), 'foo');
      expect(nativeAssetFrameworkName('foo.dylib', taken), 'foo1');
      expect(nativeAssetFrameworkName('foo.dylib', taken), 'foo2');
      expect(taken, {'foo', 'foo1', 'foo2'});
    });
  });

  group('nativeAssetFrameworkInfoPlist', () {
    test('is flutter_tools\' text, with the minimum iOS version last', () {
      const expected =
          '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
          '<plist version="1.0">\n'
          '<dict>\n'
          '\t<key>CFBundleDevelopmentRegion</key>\n\t<string>en</string>\n'
          '\t<key>CFBundleExecutable</key>\n\t<string>objective_c</string>\n'
          '\t<key>CFBundleIdentifier</key>\n\t<string>io.flutter.flutter.native-assets.objective-c</string>\n'
          '\t<key>CFBundleInfoDictionaryVersion</key>\n\t<string>6.0</string>\n'
          '\t<key>CFBundleName</key>\n\t<string>objective_c</string>\n'
          '\t<key>CFBundlePackageType</key>\n\t<string>FMWK</string>\n'
          '\t<key>CFBundleShortVersionString</key>\n\t<string>1.0</string>\n'
          '\t<key>CFBundleSignature</key>\n\t<string>????</string>\n'
          '\t<key>CFBundleVersion</key>\n\t<string>1.0</string>\n'
          '\t<key>MinimumOSVersion</key>\n\t<string>15.0</string>\n'
          '</dict>\n'
          '</plist>';
      expect(
        nativeAssetFrameworkInfoPlist('objective_c', minimumIosVersion: '15.0'),
        expected,
      );
      expect(
        nativeAssetFrameworkInfoPlist('objective_c'),
        isNot(contains('MinimumOSVersion')),
      );
    });

    test('is a property list that reads back', () {
      final plist = parsePlist(
        nativeAssetFrameworkInfoPlist('a_b', minimumIosVersion: '15.0'),
      ) as Map<String, Object?>;
      expect(
        plist['CFBundleIdentifier'],
        'io.flutter.flutter.native-assets.a-b',
      );
      expect(plist['CFBundleExecutable'], 'a_b');
    });
  });

  group('nativeAssetsManifest', () {
    test('is the compact JSON the engine reads', () {
      expect(
        nativeAssetsManifest({
          'package:objective_c/objective_c.dylib': 'objective_c',
        }),
        '{"format-version":[1,0,0],"native-assets":{"ios_arm64":'
        '{"package:objective_c/objective_c.dylib":["absolute","objective_c.framework/objective_c"]}}}',
      );
    });
  });

  group('buildNativeAssetFramework', () {
    test('makes the framework folder: binary stripped, install name set, Info.plist written', () async {
      final dir = Directory.systemTemp.createTempSync('native_assets_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final dylib = File('${dir.path}/objective_c.dylib')
        ..writeAsBytesSync(_dylib('/home/me/build/objective_c.dylib'));
      final calls = <List<String>>[];
      final framework = await buildNativeAssetFramework(
        dylib: dylib,
        name: 'objective_c',
        outDirectory: Directory('${dir.path}/out'),
        objcopy: '/tools/llvm-objcopy',
        run: (exe, args, {workingDirectory}) async {
          calls.add([exe, ...args]);
          return ProcessResult(1, 0, '', '');
        },
      );
      expect(framework.path, endsWith('out/objective_c.framework'));
      expect(calls.single.take(3), [
        '/tools/llvm-objcopy',
        '--discard-all',
        '--strip-debug',
      ]);
      expect(calls.single.last, '${framework.path}/objective_c');
      final binary = File('${framework.path}/objective_c').readAsBytesSync();
      final data = ByteData.sublistView(binary);
      final start = 32 + data.getUint32(32 + 8, Endian.little);
      expect(
        utf8.decode(binary.sublist(start, binary.indexOf(0, start))),
        '@rpath/objective_c.framework/objective_c',
      );
      expect(
        File('${framework.path}/Info.plist').readAsStringSync(),
        contains('<string>15.0</string>'),
      );
    });

    test('a failing strip stops with its output', () async {
      final dir = Directory.systemTemp.createTempSync('native_assets_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final dylib = File('${dir.path}/x.dylib')..writeAsBytesSync(_dylib('/a'));
      await expectLater(
        buildNativeAssetFramework(
          dylib: dylib,
          name: 'x',
          outDirectory: dir,
          objcopy: 'llvm-objcopy',
          run: (exe, args, {workingDirectory}) async =>
              ProcessResult(1, 1, '', 'error: cannot strip'),
        ),
        throwsA(
          isA<ProcessException>().having(
            (e) => e.message,
            'message',
            contains('cannot strip'),
          ),
        ),
      );
    });
  });
}

/// A 64-bit Mach-O header with one `LC_ID_DYLIB` that has room for 64 bytes of name.
Uint8List _dylib(String id) {
  final out = BytesBuilder();
  void u32(int v) => out.add(
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List(),
  );
  for (final v in [0xFEEDFACF, 0x0100000C, 0, 6, 1, 24 + 64, 0, 0]) {
    u32(v);
  }
  for (final v in [0xD, 24 + 64, 24, 2, 0x10000, 0x10000]) {
    u32(v);
  }
  out
    ..add(utf8.encode(id))
    ..add(Uint8List(64 - utf8.encode(id).length));
  return out.toBytes();
}
