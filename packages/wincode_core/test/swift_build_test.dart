import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

void main() {
  group('swiftBuildCommand', () {
    final command = swiftBuildCommand(
      packagePath: '/work/plugin',
      product: 'my-plugin',
      scratchPath: '/work/scratch',
      darwinSdkBundle: '/sdk/darwin.artifactbundle',
      swift: '/opt/swift/bin/swift',
      flutterFrameworkFolder: '/work/fw',
    );

    test('sets the environment with env and starts swift build with the swiftbuild system', () {
      expect(command.take(6), [
        'env',
        '-u',
        'SDKROOT',
        'XCODE_EXTRA_PLATFORM_FOLDERS=/sdk/darwin.artifactbundle/Developer/Platforms',
        'PATH=/sdk/darwin.artifactbundle/toolset/bin:/usr/local/bin:/usr/bin:/bin',
        '/opt/swift/bin/swift',
      ]);
      expect(command.sublist(6, 10), [
        'build',
        '--configuration',
        'release',
        '--build-system',
      ]);
      expect(command[10], 'swiftbuild');
    });

    test('builds one product for iOS arm64 with the Darwin SDK\'s toolset', () {
      expect(
        command,
        containsAllInOrder([
          '--package-path',
          '/work/plugin',
          '--scratch-path',
          '/work/scratch',
        ]),
      );
      expect(
        command,
        containsAllInOrder([
          '--triple',
          'arm64-apple-ios',
          '--toolset',
          '/sdk/darwin.artifactbundle/toolset-swb.json',
        ]),
      );
      expect(command, containsAllInOrder(['--product', 'my-plugin']));
    });

    test('lets the plugin import Flutter from the framework folder, for Swift and for C', () {
      expect(command.sublist(command.length - 4), [
        '-Xswiftc',
        '-F/work/fw',
        '-Xcc',
        '-F/work/fw',
      ]);
      final linked = swiftBuildCommand(
        packagePath: '/p',
        product: 'x',
        scratchPath: '/s',
        darwinSdkBundle: '/b',
        linkerFlags: ['-rpath', '@executable_path/Frameworks'],
      );
      expect(linked.sublist(linked.length - 4), [
        '-Xlinker',
        '-rpath',
        '-Xlinker',
        '@executable_path/Frameworks',
      ]);
      final without = swiftBuildCommand(
        packagePath: '/p',
        product: 'x',
        scratchPath: '/s',
        darwinSdkBundle: '/b',
      );
      expect(without, isNot(contains('-Xswiftc')));
    });
  });

  group('buildSwiftPackage', () {
    ProcessResult ok(String out, [String err = '']) =>
        ProcessResult(1, 0, out, err);

    test(
      'finds the library and the bundles, and counts the warnings',
      () async {
        final calls = <List<String>>[];
        final build = await buildSwiftPackage(
          packagePath: '/p',
          product: 'my-plugin',
          scratchPath: '/s',
          darwinSdkBundle: '/b',
          run: (exe, args, {workingDirectory}) async {
            calls.add([exe, ...args]);
            if (exe == 'env') {
              return ok(
                'Build complete!',
                'a.swift:1: warning: x\nb.swift:2: warning: y\n',
              );
            }
            return ok(
              'libmy-plugin.a\nmy_plugin_my_plugin.bundle\nmy_plugin.swiftmodule\n',
            );
          },
        );
        expect(
          build.library,
          '/s/out/Products/Release-iphoneos/libmy-plugin.a',
        );
        expect(build.bundles, [
          '/s/out/Products/Release-iphoneos/my_plugin_my_plugin.bundle',
        ]);
        expect(build.warnings, 2);
        expect(calls[1], ['ls', '-1', '/s/out/Products/Release-iphoneos']);
      },
    );

    test('a failing build stops with its output', () async {
      await expectLater(
        buildSwiftPackage(
          packagePath: '/p',
          product: 'x',
          scratchPath: '/s',
          darwinSdkBundle: '/b',
          run: (exe, args, {workingDirectory}) async =>
              ProcessResult(1, 1, '', 'error: unable to find platform'),
        ),
        throwsA(
          isA<ProcessException>().having(
            (e) => e.message,
            'message',
            contains('unable to find platform'),
          ),
        ),
      );
    });

    test(
      'a build that wrote no library is an error that lists what it wrote',
      () async {
        await expectLater(
          buildSwiftPackage(
            packagePath: '/p',
            product: 'x',
            scratchPath: '/s',
            darwinSdkBundle: '/b',
            run: (exe, args, {workingDirectory}) async =>
                ok(exe == 'env' ? '' : 'other.a\n'),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('other.a'),
            ),
          ),
        );
      },
    );
  });

  group('toWslPath', () {
    test('turns a Windows path into the path WSL2 mounts it at', () {
      expect(toWslPath(r'C:\Users\me\app'), '/mnt/c/Users/me/app');
      expect(toWslPath('D:/work/x/'), '/mnt/d/work/x');
      expect(toWslPath('/home/me/x'), '/home/me/x');
      expect(() => toWslPath('relative/path'), throwsFormatException);
    });
  });
}
