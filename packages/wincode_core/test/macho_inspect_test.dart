import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

import 'macho_builder.dart';

void main() {
  const system = '/usr/lib/libSystem.B.dylib';
  const swiftUI = '/System/Library/Frameworks/SwiftUI.framework/SwiftUI';
  const swiftUICore =
      '/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore';

  group('libraryUse', () {
    test('counts the load commands and the symbols bound to the framework', () {
      final macho = withLibraries(
        [(system, 0xC), (swiftUI, 0xC), (swiftUICore, 0xC)],
        bindOrdinals: [1, 2, 2, 3, 3, 1],
      );
      final core = libraryUse(macho, 'SwiftUICore');
      expect(core.loadCommands, 1);
      expect(core.bindings, 2);
      expect(core.isUsed, isTrue);
      final ui = libraryUse(macho, 'SwiftUI');
      expect(ui.loadCommands, 1);
      expect(ui.bindings, 2);
    });

    test('reads the three formats of the import table', () {
      for (final format in [1, 2, 3]) {
        final macho = withLibraries(
          [(system, 0xC), (swiftUICore, 0xC)],
          bindOrdinals: [2, 1, 2, 2],
          importFormat: format,
        );
        expect(
          libraryUse(macho, 'SwiftUICore').bindings,
          3,
          reason: 'format $format',
        );
      }
    });

    test('counts a weak load command, and leaves out another framework whose name starts the same and the special ordinals', () {
      final macho = withLibraries(
        [
          (swiftUICore, 0x80000018),
          (
            '/System/Library/Frameworks/SwiftUICoreExtras.framework/SwiftUICoreExtras',
            0xC,
          ),
        ],
        bindOrdinals: [1, 2, 2, 0xFE, 0],
      );
      final core = libraryUse(macho, 'SwiftUICore');
      expect(core.loadCommands, 1);
      expect(core.bindings, 1);
    });

    test('a file that links SwiftUI and not SwiftUICore uses none of it', () {
      final macho = withLibraries(
        [(system, 0xC), (swiftUI, 0xC)],
        bindOrdinals: [1, 2, 2],
      );
      final core = libraryUse(macho, 'SwiftUICore');
      expect(core.loadCommands, 0);
      expect(core.bindings, 0);
      expect(core.isUsed, isFalse);
    });

    test('without chained fixups the bindings are unknown', () {
      final linked = libraryUse(
        withLibraries([(swiftUICore, 0xC)]),
        'SwiftUICore',
      );
      expect(linked.bindings, isNull);
      expect(linked.isUsed, isTrue);
      final unlinked = libraryUse(
        withLibraries([(system, 0xC)]),
        'SwiftUICore',
      );
      expect(unlinked.bindings, isNull);
      expect(unlinked.isUsed, isFalse);
    });

    test('rejects what is not a 64-bit Mach-O file', () {
      expect(
        () => libraryUse(Uint8List(64), 'SwiftUICore'),
        throwsFormatException,
      );
    });
  });
}
