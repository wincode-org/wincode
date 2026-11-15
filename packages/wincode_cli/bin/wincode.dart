import 'dart:io';

import 'package:wincode_cli/wincode_cli.dart';

Future<void> main(List<String> args) async {
  final code = await runWincode(args, stdout, stderr);
  try {
    await stdout.flush();
    await stderr.flush();
  } on IOException {
    // The reader of the output went away, as with `| head`; the exit code still says how the command ended.
  }
  // A build that was interrupted leaves a timer, or a read of standard input, behind: the process ends with the command.
  exit(code);
}
