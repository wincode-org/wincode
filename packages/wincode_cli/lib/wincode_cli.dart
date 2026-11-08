/// The `wincode` command.
library;

import 'dart:io';

import 'package:wincode_core/wincode_core.dart';

const usage = '''
Usage: wincode doctor --binary <Mach-O file> [--sdk <iPhoneOS.sdk folder>] [--reference <Mach-O file>]

  --sdk        Check the binary against the SDK's text stubs. Fails on a library or binding that its minimum OS lacks.
  --reference  List how the binary differs from a reference build, such as an Xcode-built copy. This does not fail.

Give --sdk, --reference or both.
''';

/// Runs `wincode` with [args] and writes its report to [out]. Returns the exit code: 0 when every check passes, 1 when
/// one fails or a file cannot be read, 64 for a usage error.
int runWincode(List<String> args, StringSink out) {
  final options = <String, String>{};
  for (var i = 1; i + 1 < args.length; i += 2) {
    options[args[i]] = args[i + 1];
  }
  final binary = options['--binary'];
  final sdk = options['--sdk'];
  final reference = options['--reference'];
  if (args.isEmpty ||
      args.first != 'doctor' ||
      args.length.isEven ||
      options.length * 2 != args.length - 1 ||
      !options.keys.every({'--binary', '--sdk', '--reference'}.contains) ||
      binary == null ||
      (sdk == null && reference == null)) {
    out.write(usage);
    return 64;
  }
  try {
    final file = _read(binary);
    var failed = false;
    if (sdk != null) {
      if (!File('$sdk/SDKSettings.json').existsSync()) {
        throw FormatException('$sdk: not an SDK folder (no SDKSettings.json)');
      }
      final violations = _about(
        binary,
        () => checkAgainstSdk(file, Directory(sdk)),
      );
      out.writeln(
        '${violations.length} violation(s) of the minimum OS ${file.buildVersion!.minOS} in $binary',
      );
      for (final v in violations) {
        out.writeln('  $v');
      }
      failed = violations.isNotEmpty;
    }
    if (reference != null) {
      final lines = diffMachO(file, _read(reference));
      out.writeln('${lines.length} difference(s) from $reference');
      for (final line in lines) {
        out.writeln('  $line');
      }
    }
    return failed ? 1 : 0;
  } on FormatException catch (e) {
    out.writeln('wincode doctor: ${e.message}');
    return 1;
  } on FileSystemException catch (e) {
    out.writeln('wincode doctor: ${e.path}: ${e.message}');
    return 1;
  }
}

MachO _read(String path) =>
    _about(path, () => readMachO(File(path).readAsBytesSync()));

/// Runs [work], naming [path] in the message of a [FormatException] it throws.
T _about<T>(String path, T Function() work) {
  try {
    return work();
  } on FormatException catch (e) {
    throw FormatException('$path: ${e.message}');
  }
}
