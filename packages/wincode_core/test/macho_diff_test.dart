import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

import 'macho_builder.dart';

void main() {
  const system = '/usr/lib/libSystem.B.dylib';
  const swiftUI = '/System/Library/Frameworks/SwiftUI.framework/SwiftUI';
  const swiftUICore =
      '/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore';
  const swiftExample = '/usr/lib/swift/libswiftExample.dylib';
  const services =
      '/System/Library/Frameworks/ExampleServices.framework/ExampleServices';
  const rpaths = ['/usr/lib/swift', '@executable_path/Frameworks'];
  const symbols = [
    '_example_function',
    r'_$s7Example4ViewMp',
    r'_$s7Example5PlainV',
    '_example_swift',
  ];

  group('diffMachO', () {
    test('finds no difference between a file and itself', () {
      final file = readMachO(
        withLibraries(
          [(system, 0xC)],
          bindOrdinals: [1],
          minOS: '15.0',
          rpaths: rpaths,
        ),
      );
      expect(diffMachO(file, file), isEmpty);
    });

    test('reports libraries, weak or strong, load commands and bindings that differ', () {
      // Ours links SwiftUICore and binds a symbol there; the reference binds it to SwiftUI, weak-links a Swift library and
      // links one more framework.
      final ours = readMachO(
        withLibraries(
          [
            (system, 0xC),
            (swiftUI, 0xC),
            (swiftExample, 0xC),
            (swiftUICore, 0xC),
          ],
          bindOrdinals: [1, 2, 4, 3],
          symbols: symbols,
          minOS: '15.0',
          rpaths: rpaths,
        ),
      );
      final reference = readMachO(
        withLibraries(
          [
            (system, 0xC),
            (swiftUI, 0xC),
            (swiftExample, 0x80000018),
            (services, 0xC),
          ],
          bindOrdinals: [1, 2, 2, 3],
          symbols: symbols,
          weakImports: {3},
          minOS: '15.0',
          rpaths: rpaths,
        ),
      );
      expect(diffMachO(ours, reference), [
        'library $swiftExample: ours strong, reference weak',
        'library $swiftUICore: ours strong, reference not loaded',
        'library $services: ours not loaded, reference strong',
        'load commands LC_LOAD_DYLIB: ours 4, reference 3',
        'load commands LC_LOAD_WEAK_DYLIB: ours 0, reference 1',
        'bindings to $swiftUI: ours 1, reference 2',
        'bindings to $swiftUI only in the reference: ${symbols[2]}',
        'bindings to $swiftUICore: ours 1, reference 0',
        'bindings to $swiftUICore only in ours: ${symbols[2]}',
        'binding _example_swift to $swiftExample: ours strong, reference weak',
      ]);
    });

    test('reports a missing build version, rpaths and chained fixups', () {
      final ours = readMachO(withLibraries([(system, 0xC)]));
      final reference = readMachO(
        withLibraries(
          [(system, 0xC)],
          bindOrdinals: [],
          minOS: '15.0',
          rpaths: rpaths,
        ),
      );
      expect(diffMachO(ours, reference), [
        'platform: ours none, reference 2',
        'minimum OS: ours none, reference 15.0',
        'SDK: ours none, reference 26.5',
        'rpaths: ours [], reference [/usr/lib/swift, @executable_path/Frameworks]',
        'load commands LC_BUILD_VERSION: ours 0, reference 1',
        'load commands LC_RPATH: ours 0, reference 2',
        'load commands LC_DYLD_CHAINED_FIXUPS: ours 0, reference 1',
        'chained fixups: ours none, reference present',
      ]);
    });
  });
}
