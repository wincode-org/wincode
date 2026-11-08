import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wincode_cli/wincode_cli.dart';

// The synthetic SDK and Mach-O builders of wincode_core's tests: neutral, hand-written, nothing from an SDK.
import '../../wincode_core/test/fake_sdk.dart';
import '../../wincode_core/test/macho_builder.dart';

void main() {
  const symbols = [
    '_example_function',
    r'_$s7Example4ViewMp',
    movedSymbol,
    plainSymbol,
  ];
  // The facts we know: a Runner that links SwiftUICore strongly with a minimum of iOS 15, and the same Runner built with
  // the SwiftUICore autolink disabled.
  final linksCore = withLibraries(
    [(systemLibrary, 0xC), (swiftUI, 0xC), (swiftUICore, 0xC)],
    bindOrdinals: [1, 2, 3, 3],
    symbols: symbols,
    minOS: '15.0',
  );
  final noAutolink = withLibraries(
    [(systemLibrary, 0xC), (swiftUI, 0xC)],
    bindOrdinals: [1, 2, 2, 2],
    symbols: symbols,
    minOS: '15.0',
  );

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('doctor_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  String file(String name, Uint8List bytes) {
    final f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
    return f.path;
  }

  (int, String) doctor(List<String> args) {
    final out = StringBuffer();
    return (runWincode(['doctor', ...args], out), '$out');
  }

  test('fails on a Runner that links SwiftUICore strongly with a minimum of iOS 15', () {
    final binary = file('Runner', linksCore);
    final (code, out) = doctor(['--binary', binary, '--sdk', fakeSdk().path]);
    expect(code, 1);
    expect(out, contains('2 violation(s) of the minimum OS 15.0 in $binary'));
    expect(
      out,
      contains('  $swiftUICore: its stub restricts it to listed clients'),
    );
  });

  test(
    'passes the same Runner built with the SwiftUICore autolink disabled',
    () {
      final (code, out) = doctor([
        '--binary',
        file('Runner', noAutolink),
        '--sdk',
        fakeSdk().path,
      ]);
      expect(code, 0);
      expect(out, startsWith('0 violation(s)'));
    },
  );

  test('lists the differences from a reference without failing on them', () {
    final (code, out) = doctor([
      '--binary',
      file('Runner', linksCore),
      '--reference',
      file('Reference', noAutolink),
    ]);
    expect(code, 0);
    expect(out, contains('difference(s) from'));
    expect(
      out,
      contains('  library $swiftUICore: ours strong, reference not loaded'),
    );
  });

  test('a file that is not a Mach-O or a folder that is not an SDK is a failure that says so', () {
    final notMachO = file('notes.txt', Uint8List.fromList('text'.codeUnits));
    expect(doctor(['--binary', notMachO, '--reference', notMachO]), (
      1,
      'wincode doctor: $notMachO: not a 64-bit little-endian Mach-O file\n',
    ));
    final (code, out) = doctor([
      '--binary',
      file('Runner', noAutolink),
      '--sdk',
      dir.path,
    ]);
    expect(code, 1);
    expect(out, contains('not an SDK folder'));
  });

  test('a usage error prints the usage', () {
    for (final args in [
      <String>[],
      ['build'],
      ['doctor'],
      ['doctor', '--binary', 'Runner'],
      ['doctor', '--binary', 'Runner', '--sdk'],
      ['doctor', '--binary', 'Runner', '--color', 'red'],
      ['doctor', '--sdk', 'sdk', '--sdk', 'sdk'],
    ]) {
      final out = StringBuffer();
      expect(runWincode(args, out), 64, reason: '$args');
      expect('$out', usage);
    }
  });
}
