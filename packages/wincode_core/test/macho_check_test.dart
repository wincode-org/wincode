import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

import 'fake_sdk.dart';
import 'macho_builder.dart';

void main() {
  const weak = 0x80000018;

  group('checkAgainstSdk', () {
    test('a Runner that links SwiftUICore strongly with a minimum of iOS 15 fails', () {
      final runner = withLibraries(
        [(systemLibrary, 0xC), (swiftUI, 0xC), (swiftUICore, 0xC)],
        bindOrdinals: [1, 2, 3, 3],
        symbols: [
          '_example_function',
          r'_$s7Example4ViewMp',
          movedSymbol,
          plainSymbol,
        ],
        minOS: '15.0',
      );
      final violations = checkAgainstSdk(readMachO(runner), fakeSdk());
      expect(violations, hasLength(2));
      final library = violations.first;
      expect(library.library, swiftUICore);
      expect(library.symbol, isNull);
      expect(library.needs, '18.0');
      expect(library.minOS, '15.0');
      expect(library.reason, contains('restricts it to listed clients'));
      expect(library.reason, contains('2 bound here'));
      final symbol = violations.last;
      expect(
        (symbol.library, symbol.symbol, symbol.needs),
        (swiftUICore, movedSymbol, '18.0'),
      );
      expect(symbol.reason, contains(swiftUI));
      expect(
        '$symbol',
        '$movedSymbol (bound to $swiftUICore): before 18.0 it is in $swiftUI; it needs 18.0, the minimum is 15.0',
      );
    });

    test(
      'the same Runner built with the SwiftUICore autolink disabled passes',
      () {
        final runner = withLibraries(
          [(systemLibrary, 0xC), (swiftUI, 0xC)],
          bindOrdinals: [1, 2, 2, 2],
          symbols: [
            '_example_function',
            r'_$s7Example4ViewMp',
            movedSymbol,
            plainSymbol,
          ],
          minOS: '15.0',
        );
        expect(checkAgainstSdk(readMachO(runner), fakeSdk()), isEmpty);
      },
    );

    test('a weak load of a restricted library with nothing bound to it fails too, at any minimum', () {
      final violations = checkAgainstSdk(
        readMachO(
          withLibraries([(swiftUICore, weak)], bindOrdinals: [], minOS: '18.0'),
        ),
        fakeSdk(),
      );
      expect(violations.single.library, swiftUICore);
      expect(
        violations.single.needs,
        isNull,
        reason: 'no directive covers 18.0',
      );
    });

    test('a moved symbol bound to the library fails whether weak or not, only below the version it moved, on its platform', () {
      const library = '/usr/lib/libexample.dylib';
      final sdk = fakeSdk(
        extra: {
          library: stub(
            library,
            symbols: [
              r'$ld$previous$/usr/lib/libold.dylib$$2$1.0$16.0$_example_moved$',
              r'$ld$previous$/usr/lib/libold.dylib$$7$1.0$99.0$_example_kept$',
              '_example_moved',
              '_example_kept',
            ],
          ),
        },
      );
      List<Violation> check(String minOS) => checkAgainstSdk(
        readMachO(
          withLibraries(
            [(library, 0xC)],
            bindOrdinals: [1, 1],
            symbols: ['_example_moved', '_example_kept'],
            weakImports: {0},
            minOS: minOS,
          ),
        ),
        sdk,
      );
      final below = check('15.4');
      expect(below.single.symbol, '_example_moved');
      expect(below.single.needs, '16.0');
      expect(check('16.0'), isEmpty);
    });

    test('a library with another name before or at the minimum fails, and so does a symbol it hides there', () {
      const library = '/usr/lib/libexample.dylib';
      final sdk = fakeSdk(
        extra: {
          library: stub(
            library,
            symbols: [
              r'$ld$previous$@rpath/libexample.dylib$$2$7.0$13.0$$',
              r'$ld$install_name$os12.0$/usr/lib/libold.dylib',
              r'$ld$hide$os12.0$_example_hidden',
              '_example_hidden',
            ],
          ),
        },
      );
      List<Violation> check(String minOS) => checkAgainstSdk(
        readMachO(
          withLibraries(
            [(library, 0xC)],
            bindOrdinals: [1],
            symbols: ['_example_hidden'],
            minOS: minOS,
          ),
        ),
        sdk,
      );
      expect(
        [for (final v in check('12.0')) (v.symbol, v.needs, v.reason)],
        [
          (null, '13.0', 'before 13.0 it is @rpath/libexample.dylib'),
          (null, null, 'at 12.0 it is /usr/lib/libold.dylib'),
          ('_example_hidden', null, 'its stub hides it at 12.0'),
        ],
      );
      expect(check('13.0'), isEmpty);
    });

    test('a system library the SDK has no stub for fails, and a library that ships in the app is not checked', () {
      final violations = checkAgainstSdk(
        readMachO(
          withLibraries(
            [
              ('/usr/lib/libnone.dylib', 0xC),
              ('@rpath/Example.framework/Example', 0xC),
            ],
            bindOrdinals: [1, 2],
            minOS: '15.0',
          ),
        ),
        fakeSdk(),
      );
      expect(violations.single.library, '/usr/lib/libnone.dylib');
      expect(violations.single.reason, contains('no stub'));
    });

    test('a file without a build version or without chained fixups cannot be checked', () {
      expect(
        () => checkAgainstSdk(
          readMachO(withLibraries([(systemLibrary, 0xC)], bindOrdinals: [1])),
          fakeSdk(),
        ),
        throwsFormatException,
      );
      expect(
        () => checkAgainstSdk(
          readMachO(withLibraries([(systemLibrary, 0xC)], minOS: '15.0')),
          fakeSdk(),
        ),
        throwsFormatException,
      );
    });
  });
}
