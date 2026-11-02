import 'dart:io';

import 'package:test/test.dart';

// A fake iPhoneOS.sdk: SDKSettings.json and hand-written text stubs in the TBD version 4 layout, with invented symbols.
// Only the install names of public libraries are real, and the directives state the facts of
// docs/formats/macho-conformance.md, not contents of an SDK.

const systemLibrary = '/usr/lib/libSystem.B.dylib';
const swiftUI = '/System/Library/Frameworks/SwiftUI.framework/SwiftUI';
const swiftUICore =
    '/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore';

/// A symbol that the fake `SwiftUICore` stub places in `SwiftUI` before iOS 18.0.
const movedSymbol = r'_$s7Example5MovedV';

/// A symbol of the fake `SwiftUICore` stub with no directive, like the two that a `SwiftUICore` link bound.
const plainSymbol = r'_$s7Example5PlainV';

/// The stub of one library: [symbols] exported (directives among them), restricted to listed clients when
/// [restricted].
String stub(
  String installName, {
  List<String> symbols = const [],
  bool restricted = false,
}) =>
    '''
--- !tapi-tbd
tbd-version:     4
targets:         [ arm64-ios ]
install-name:    '$installName'
${restricted ? 'allowable-clients:\n  - targets:         [ arm64-ios ]\n    clients:         [ ExampleUmbrella ]\n' : ''}exports:
  - targets:         [ arm64-ios ]
    symbols:         [ ${symbols.map((s) => "'$s'").join(', ')} ]
...
''';

/// A fake SDK, version 26.5, in a temporary folder that is deleted after the test. It has stubs for `libSystem`,
/// `SwiftUI` and a restricted `SwiftUICore`, and [extra] stubs by install name.
Directory fakeSdk({Map<String, String> extra = const {}}) {
  final sdk = Directory.systemTemp.createTempSync('fake_sdk');
  addTearDown(() => sdk.deleteSync(recursive: true));
  File('${sdk.path}/SDKSettings.json').writeAsStringSync('{"Version": "26.5"}');
  final stubs = {
    systemLibrary: stub(systemLibrary, symbols: ['_example_function']),
    swiftUI: stub(swiftUI, symbols: [r'_$s7Example4ViewMp']),
    swiftUICore: stub(
      swiftUICore,
      restricted: true,
      symbols: [
        '\$ld\$previous\$$swiftUI\$\$2\$1.0\$18.0\$$movedSymbol\$',
        movedSymbol,
        plainSymbol,
      ],
    ),
    ...extra,
  };
  for (final MapEntry(key: name, value: text) in stubs.entries) {
    final base = name.endsWith('.dylib')
        ? name.substring(0, name.length - 6)
        : name;
    File('${sdk.path}$base.tbd')
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  }
  return sdk;
}
