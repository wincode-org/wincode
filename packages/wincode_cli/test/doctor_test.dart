import 'dart:convert';
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

  /// (exit code, stdout, stderr) of `wincode doctor` with [args].
  Future<(int, String, String)> doctor(List<String> args) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runWincode(['doctor', ...args], out, err);
    return (code, '$out', '$err');
  }

  test('fails on a Runner that links SwiftUICore strongly with a minimum of iOS 15', () async {
    final binary = file('Runner', linksCore);
    final (code, out, err) = await doctor([
      '--binary',
      binary,
      '--sdk',
      fakeSdk().path,
    ]);
    expect(code, 1);
    expect(out, contains('2 violation(s) of the minimum OS 15.0 in $binary'));
    expect(
      out,
      contains('  $swiftUICore: its stub restricts it to listed clients'),
    );
    expect(err, isEmpty);
  });

  test(
    'passes the same Runner built with the SwiftUICore autolink disabled',
    () async {
      final (code, out, _) = await doctor([
        '--binary',
        file('Runner', noAutolink),
        '--sdk',
        fakeSdk().path,
      ]);
      expect(code, 0);
      expect(out, startsWith('0 violation(s)'));
    },
  );

  test(
    'lists the differences from a reference without failing on them',
    () async {
      final (code, out, _) = await doctor([
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
    },
  );

  test('--json prints one JSON object with the findings, before or after the command', () async {
    final binary = file('Runner', linksCore);
    for (final args in [
      ['doctor', '--json', '--binary', binary, '--sdk', fakeSdk().path],
      ['--json', 'doctor', '--binary', binary, '--sdk', fakeSdk().path],
    ]) {
      final out = StringBuffer();
      expect(await runWincode(args, out, StringBuffer()), 1, reason: '$args');
      final report = jsonDecode('$out') as Map<String, Object?>;
      expect(report, containsPair('command', 'doctor'));
      expect(report, containsPair('ok', false));
      expect(report, containsPair('exitCode', 1));
      expect(report['violations'], hasLength(2));
    }
  });

  test('a file that is not a Mach-O is a failure that says what, why and what next', () async {
    final notMachO = file('notes.txt', Uint8List.fromList('text'.codeUnits));
    final (code, out, err) = await doctor([
      '--binary',
      notMachO,
      '--reference',
      notMachO,
    ]);
    expect(code, 1);
    expect(out, isEmpty);
    expect(
      err,
      startsWith(
        'wincode doctor: $notMachO: not a 64-bit little-endian Mach-O file\n  why: ',
      ),
    );
    expect(err, contains('\n  next: give a binary from inside the app bundle'));
  });

  test('a folder that is not an SDK is "unavailable" (69) and says how to build the SDK', () async {
    final (code, _, err) = await doctor([
      '--binary',
      file('Runner', noAutolink),
      '--sdk',
      dir.path,
    ]);
    expect(code, 69);
    expect(
      err,
      contains(
        '${dir.path} is not an iPhoneOS SDK folder: it has no SDKSettings.json',
      ),
    );
    expect(
      err,
      contains('  why: --sdk names the iPhoneOS.sdk that `xtool sdk` builds'),
    );
    expect(err, contains('  next: build it with tools/setup-wsl-toolchain.sh'));
  });

  test('a usage error prints the message and the usage on stderr', () async {
    for (final (args, usage) in [
      (<String>[], 'Usage: wincode <command> [arguments]'),
      (['ship'], 'Usage: wincode <command> [arguments]'),
      (['doctor'], 'Usage: wincode doctor [arguments]'),
      (['doctor', '--binary', 'Runner'], 'Usage: wincode doctor [arguments]'),
      (
        ['doctor', '--binary', 'Runner', '--sdk'],
        'Usage: wincode doctor [arguments]',
      ),
      (
        ['doctor', '--binary', 'Runner', '--color', 'red'],
        'Usage: wincode doctor [arguments]',
      ),
      (['doctor', 'Runner'], 'Usage: wincode doctor [arguments]'),
    ]) {
      final out = StringBuffer();
      final err = StringBuffer();
      expect(await runWincode(args, out, err), 64, reason: '$args');
      expect('$out', isEmpty, reason: '$args');
      expect('$err', contains(usage), reason: '$args');
    }
  });
}
