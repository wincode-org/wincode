import 'dart:convert';
import 'dart:io';

import 'process.dart';

/// The path inside WSL2 of a Windows path: `C:\Users\me\app` becomes `/mnt/c/Users/me/app`. A path that is already a Linux
/// path (it starts with `/`) is returned as it is.
String toWslPath(String path) {
  if (path.startsWith('/')) {
    return path;
  }
  final match = RegExp(r'^([A-Za-z]):[\\/]*(.*)$').firstMatch(path);
  if (match == null) {
    throw FormatException('not an absolute Windows path: $path');
  }
  return '/mnt/${match.group(1)!.toLowerCase()}/${match.group(2)!.replaceAll(r'\', '/')}'
      .replaceFirst(RegExp(r'/$'), '');
}

/// A [RunProcess] that runs every command inside the WSL2 distribution [distro], with
/// `wsl.exe -d distro --cd folder -- command`. The arguments must already be Linux paths and plain words: `wsl.exe` passes
/// them on without a shell.
RunProcess wslRunner(String distro) =>
    (executable, arguments, {workingDirectory}) => Process.run(
      'wsl.exe',
      [
        '-d',
        distro,
        if (workingDirectory != null) ...['--cd', toWslPath(workingDirectory)],
        '--',
        executable,
        ...arguments,
      ],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
