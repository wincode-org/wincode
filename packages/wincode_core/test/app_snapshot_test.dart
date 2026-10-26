import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('snapshot_test'));
  tearDown(() => root.deleteSync(recursive: true));

  group('buildKernel', () {
    final calls = <List<String>>[];

    RunProcess fake({int exit = 0, bool reportKernel = true}) {
      calls.clear();
      return (exe, args, {workingDirectory}) async {
        calls.add([exe, ...args]);
        if (reportKernel) {
          File('${root.path}/.dart_tool/flutter_build/abc/app.dill')
            ..createSync(recursive: true)
            ..writeAsStringSync('kernel');
        }
        return ProcessResult(1, exit, 'out', exit == 0 ? '' : 'it failed');
      };
    }

    test('runs the iOS kernel target with the flavor and the defines and returns app.dill', () async {
      final dill = await buildKernel(
        projectDir: root,
        flutterRoot: Directory('${root.path}/sdk'),
        flavor: 'demo',
        target: 'lib/flavors/main_demo.dart',
        dartDefines: ['K=v'],
        run: fake(),
      );
      expect(dill.path, endsWith('app.dill'));
      final args = calls.single;
      expect(
        args,
        containsAll([
          'assemble',
          '-dTargetPlatform=ios',
          '-dBuildMode=release',
          '-dIosArchs=arm64',
          '-dFlavor=demo',
          '-dTargetFile=lib/flavors/main_demo.dart',
        ]),
      );
      expect(args.last, 'kernel_snapshot_program');
      expect(
        args.firstWhere((a) => a.startsWith('-dDartDefines=')),
        '-dDartDefines=${base64.encode(utf8.encode('K=v'))}',
      );
    });

    test('a failing assemble stops with its output', () async {
      await expectLater(
        buildKernel(projectDir: root, flutterRoot: root, run: fake(exit: 1)),
        throwsA(
          isA<ProcessException>().having(
            (e) => e.message,
            'message',
            contains('it failed'),
          ),
        ),
      );
    });

    test('an assemble that makes no kernel is an error', () async {
      await expectLater(
        buildKernel(
          projectDir: root,
          flutterRoot: root,
          run: fake(reportKernel: false),
        ),
        throwsFormatException,
      );
    });
  });

  test(
    'the gen_snapshot arguments are the ones flutter_tools uses for iOS',
    () {
      expect(
        genSnapshotArguments(
          kernel: 'app.dill',
          framework: 'arm64/App.framework/App',
          object: 'arm64/app.o',
        ),
        [
          '--deterministic',
          '--snapshot_kind=app-aot-macho-dylib',
          '--macho=arm64/App.framework/App',
          '--macho-object=arm64/app.o',
          '--macho-min-os-version=15.0',
          '--macho-rpath=@executable_path/Frameworks,@loader_path/Frameworks',
          '--macho-install-name=@rpath/App.framework/App',
          'app.dill',
        ],
      );
      expect(
        genSnapshotArguments(
          kernel: 'k',
          framework: 'f',
          object: 'o',
          minOsVersion: '16.0',
          obfuscate: true,
          saveDebuggingInfo: 'syms',
        ),
        containsAllInOrder([
          '--macho-min-os-version=16.0',
          '--dwarf-stack-traces',
          '--resolve-dwarf-paths',
          '--save-debugging-info=syms',
          '--obfuscate',
          'k',
        ]),
      );
    },
  );

  group('buildAppBinary', () {
    test('runs gen_snapshot inside the work folder with relative paths and returns App', () async {
      final kernel = File('${root.path}/in/app.dill')
        ..createSync(recursive: true)
        ..writeAsStringSync('kernel');
      final work = Directory('${root.path}/work');
      String? ranIn;
      List<String>? ranWith;
      final binary = await buildAppBinary(
        kernel: kernel,
        genSnapshot: File('${root.path}/gen_snapshot'),
        workDir: work,
        run: (exe, args, {workingDirectory}) async {
          ranIn = workingDirectory;
          ranWith = args;
          File('${work.path}/arm64/App.framework/App')
              .writeAsStringSync('dylib');
          return ProcessResult(1, 0, '', '');
        },
      );
      expect(ranIn, work.path);
      expect(ranWith!.last, 'app.dill');
      expect(ranWith, contains('--macho=arm64/App.framework/App'));
      expect(binary.readAsStringSync(), 'dylib');
      expect(File('${work.path}/app.dill').readAsStringSync(), 'kernel');
    });

    test('a failing gen_snapshot stops with its output', () async {
      final kernel = File('${root.path}/app.dill')..writeAsStringSync('k');
      await expectLater(
        buildAppBinary(
          kernel: kernel,
          genSnapshot: File('${root.path}/gen_snapshot'),
          workDir: Directory('${root.path}/work'),
          run: (exe, args, {workingDirectory}) async =>
              ProcessResult(1, 254, '', 'ApiError'),
        ),
        throwsA(
          isA<ProcessException>().having(
            (e) => e.message,
            'message',
            contains('ApiError'),
          ),
        ),
      );
    });
  });
}
