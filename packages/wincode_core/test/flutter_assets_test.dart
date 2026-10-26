import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

void main() {
  late Directory root;
  late Directory flutterRoot;
  late Directory project;
  late Directory output;

  void write(String path, String content) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('assets_test');
    flutterRoot = Directory('${root.path}/flutter');
    project = Directory('${root.path}/app');
    output = Directory('${root.path}/out');
    write(
      '${flutterRoot.path}/packages/flutter/lib/src/material/shaders/ink_sparkle.frag',
      'sdk material',
    );
    write(
      '${flutterRoot.path}/packages/flutter/lib/src/widgets/shaders/stretch_effect.frag',
      'sdk widgets',
    );
    write('${root.path}/pkgs/fancy/lib/shaders/glow.frag', 'package lib');
    write('${root.path}/pkgs/rooty/shaders/flat.frag', 'package root');
    write('${project.path}/shaders/mine.frag', 'app');
    write(
      '${project.path}/.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'fancy',
            'rootUri': '../../pkgs/fancy',
            'packageUri': 'lib/',
          },
          {
            'name': 'rooty',
            'rootUri': '../../pkgs/rooty/',
            'packageUri': 'lib/',
          },
        ],
      }),
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('shader sources', () {
    File find(String key) => shaderSource(
      key: key,
      flutterRoot: flutterRoot,
      projectDir: project,
      packages: PackageRoots.read(project),
    );

    test('the SDK\'s own shaders come from the Flutter SDK', () {
      expect(
        find('shaders/ink_sparkle.frag').readAsStringSync(),
        'sdk material',
      );
      expect(
        find('shaders/stretch_effect.frag').readAsStringSync(),
        'sdk widgets',
      );
    });

    test('a package\'s shader is in its lib folder, or else at its root', () {
      expect(
        find('packages/fancy/shaders/glow.frag').readAsStringSync(),
        'package lib',
      );
      expect(
        find('packages/rooty/shaders/flat.frag').readAsStringSync(),
        'package root',
      );
    });

    test('any other key is a path in the app', () {
      expect(find('shaders/mine.frag').readAsStringSync(), 'app');
    });

    test('a missing source or package is an error that names it', () {
      expect(() => find('shaders/none.frag'), throwsFormatException);
      expect(
        () => find('packages/unknown/x.frag'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('unknown'),
          ),
        ),
      );
    });
  });

  test('the impellerc arguments are flutter_tools\' iOS ones: Metal only', () {
    expect(
      impellercArguments(
        impellerc: '/sdk/impellerc',
        source: '/src/a/s.frag',
        output: '/out/s.frag',
      ),
      [
        '--runtime-stage-metal',
        '--iplr',
        '--sl=/out/s.frag',
        '--spirv=/out/s.frag.spirv',
        '--input=/src/a/s.frag',
        '--input-type=frag',
        '--include=/src/a',
        '--include=/sdk/shader_lib',
      ],
    );
  });

  group('buildFlutterAssets', () {
    final calls = <List<String>>[];

    RunProcess fake({int assembleExit = 0}) {
      calls.clear();
      return (exe, args, {workingDirectory}) async {
        calls.add([exe, ...args]);
        if (args.first == 'assemble') {
          final out = args
              .firstWhere((a) => a.startsWith('--output='))
              .substring('--output='.length);
          write('$out/shaders/ink_sparkle.frag', 'android variants');
          write('$out/packages/fancy/shaders/glow.frag', 'android variants');
          write('$out/AssetManifest.bin', 'manifest');
          write('$out/.last_build_id', 'id');
          return ProcessResult(
            1,
            assembleExit,
            'built',
            assembleExit == 0 ? '' : 'it failed',
          );
        }
        final sl = args
            .firstWhere((a) => a.startsWith('--sl='))
            .substring('--sl='.length);
        write(sl, 'metal');
        write('$sl.spirv', 'scratch');
        return ProcessResult(1, 0, '', '');
      };
    }

    test('assembles with the flavor and the defines, then compiles each shader again for iOS', () async {
      final compiled = await buildFlutterAssets(
        projectDir: project,
        flutterRoot: flutterRoot,
        outputDir: output,
        flavor: 'demo',
        target: 'lib/flavors/main_demo.dart',
        dartDefines: ['A=1', 'B=two'],
        run: fake(),
      );
      final assemble = calls.first;
      expect(
        assemble,
        containsAll([
          'assemble',
          '-dFlavor=demo',
          '-dBuildMode=release',
          '-dTargetFile=lib/flavors/main_demo.dart',
        ]),
      );
      expect(assemble.last, 'copy_flutter_bundle');
      expect(
        assemble.firstWhere((a) => a.startsWith('-dDartDefines=')),
        '-dDartDefines=${base64.encode(utf8.encode('A=1'))},${base64.encode(utf8.encode('B=two'))}',
      );
      expect(compiled..sort(), [
        'packages/fancy/shaders/glow.frag',
        'shaders/ink_sparkle.frag',
      ]);
      expect(
        File('${output.path}/shaders/ink_sparkle.frag').readAsStringSync(),
        'metal',
      );
      expect(
        File('${output.path}/packages/fancy/shaders/glow.frag')
            .readAsStringSync(),
        'metal',
      );
      expect(
        File('${output.path}/AssetManifest.bin').readAsStringSync(),
        'manifest',
      );
    });

    test('leaves no scratch SPIR-V file and no .last_build_id', () async {
      await buildFlutterAssets(
        projectDir: project,
        flutterRoot: flutterRoot,
        outputDir: output,
        run: fake(),
      );
      expect(
        output
            .listSync(recursive: true)
            .map((e) => e.path)
            .where((p) => p.endsWith('.spirv') || p.endsWith('.last_build_id')),
        isEmpty,
      );
      expect(calls.first, isNot(contains(startsWith('-dFlavor='))));
    });

    test('a failing assemble stops with its output', () async {
      await expectLater(
        buildFlutterAssets(
          projectDir: project,
          flutterRoot: flutterRoot,
          outputDir: output,
          run: fake(assembleExit: 1),
        ),
        throwsA(
          isA<ProcessException>().having(
            (e) => e.message,
            'message',
            contains('it failed'),
          ),
        ),
      );
      expect(calls.length, 1);
    });
  });
}
