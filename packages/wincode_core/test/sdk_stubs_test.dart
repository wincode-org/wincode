import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

// Hand-written stubs in the TBD version 4 layout, with invented symbols. Only the install names of public frameworks are
// real, and the directives state facts from docs/formats/macho-conformance.md, not contents of an SDK.
const _swiftUI = '/System/Library/Frameworks/SwiftUI.framework/SwiftUI';
const _swiftUICore =
    '/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore';

const _coreStub = r'''
--- !tapi-tbd
tbd-version:     4
targets:         [ arm64-ios, arm64e-ios ]
install-name:    '/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore'
current-version: 1
allowable-clients:
  - targets:         [ arm64-ios, arm64e-ios ]
    clients:         [ ExampleUmbrella ]
exports:
  - targets:         [ arm64-ios ]
    symbols:         [ '$ld$previous$/System/Library/Frameworks/SwiftUI.framework/SwiftUI$$2$1.0$18.0$_$s7Example5MovedV$',
                       '$ld$previous$/System/Library/Frameworks/SwiftUI.framework/SwiftUI$$7$1.0$18.0$_$s7Example5MovedV$',
                       '_$s7Example5MovedV', '_$s7Example3NewV' ]
  - targets:         [ arm64e-ios ]
    symbols:         [ '$ld$previous$/System/Library/Frameworks/SwiftUI.framework/SwiftUI$$2$1.0$18.0$_$s7Example5MovedV$',
                       '_$s7Example5MovedV', '_$s7Example3NewV' ]
...
''';

// Two libraries in one file: the second is restricted, the first is not, and says what it was called before.
const _exampleStub = r'''
--- !tapi-tbd
tbd-version:     4
targets:         [ arm64-ios ]
install-name:    '/usr/lib/libexample.1.dylib'
exports:
  - targets:         [ arm64-ios ]
    symbols:         [ $ld$previous$@rpath/libexample.1.dylib$$2$7.0$12.2$$, $ld$install_name$os12.0$/usr/lib/libold.dylib,
                       '$ld$hide$os12.1$_example_new', '$ld$hide$_example_never', _example_new ]
...
--- !tapi-tbd
tbd-version:     4
targets:         [ arm64-ios ]
install-name:    '/usr/lib/system/libexample_inner.dylib'
allowable-clients:
  - targets:         [ arm64-ios ]
    clients:         [ example ]
exports:
  - targets:         [ arm64-ios ]
    symbols:         [ _example_inner ]
...
''';

void main() {
  late Directory sdk;

  setUp(() {
    sdk = Directory.systemTemp.createTempSync('sdk_stubs_test');
    void write(String path, String text) => File('${sdk.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
    write(
      'System/Library/Frameworks/SwiftUICore.framework/SwiftUICore.tbd',
      _coreStub,
    );
    write('usr/lib/libexample.1.tbd', _exampleStub);
    write(
      'System/Cryptexes/OS/System/Library/Frameworks/Example.framework/Example.tbd',
      _coreStub.replaceAll(
        _swiftUICore,
        '/System/Library/Frameworks/Example.framework/Example',
      ),
    );
    write(
      'usr/lib/libnext.tbd',
      "--- !tapi-tbd\ntbd-version: 5\ninstall-name: '/usr/lib/libnext.dylib'\n...\n",
    );
  });

  tearDown(() => sdk.deleteSync(recursive: true));

  group('readLibraryStub', () {
    test('reads a restricted library whose symbols were in another library before an OS version', () {
      final stub = readLibraryStub(sdk, _swiftUICore)!;
      expect(stub.installName, _swiftUICore);
      expect(stub.restricted, isTrue);
      // The directive appears once per target, and once more for the simulator (platform 7).
      expect(stub.previous, {
        (
          installName: _swiftUI,
          platform: 2,
          start: '1.0',
          end: '18.0',
          symbol: r'_$s7Example5MovedV',
        ),
        (
          installName: _swiftUI,
          platform: 7,
          start: '1.0',
          end: '18.0',
          symbol: r'_$s7Example5MovedV',
        ),
      });
      expect(stub.installNames, isEmpty);
      expect(stub.hidden, isEmpty);
    });

    test('reads the library-wide previous name, the install name and the hidden symbols, unquoted or quoted', () {
      final stub = readLibraryStub(sdk, '/usr/lib/libexample.1.dylib')!;
      expect(stub.restricted, isFalse, reason: 'only the next document is');
      expect(stub.previous, {
        (
          installName: '@rpath/libexample.1.dylib',
          platform: 2,
          start: '7.0',
          end: '12.2',
          symbol: '',
        ),
      });
      expect(stub.installNames, {'12.0': '/usr/lib/libold.dylib'});
      expect(stub.hidden, {
        (os: '12.1', symbol: '_example_new'),
        (os: null, symbol: '_example_never'),
      });
    });

    test('finds a stub under the cryptex, and not one that is only a document in another library\'s file', () {
      expect(
        readLibraryStub(sdk, '/usr/lib/system/libexample_inner.dylib'),
        isNull,
      );
      expect(
        readLibraryStub(
          sdk,
          '/System/Library/Frameworks/Example.framework/Example',
        )?.restricted,
        isTrue,
      );
    });

    test('returns null for a library the SDK has no stub for, and rejects another TBD version', () {
      expect(readLibraryStub(sdk, '/usr/lib/libnone.dylib'), isNull);
      expect(
        () => readLibraryStub(sdk, '/usr/lib/libnext.dylib'),
        throwsFormatException,
      );
    });
  });
}
