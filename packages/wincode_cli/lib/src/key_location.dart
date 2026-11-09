import 'dart:io';

import 'package:wincode_core/wincode_core.dart';

import 'failure.dart';

/// Refuses [path], a key or profile file, when it lies inside a git working tree that does not ignore it (ADR-0013,
/// section 2): a file there can be committed and pushed with the project.
///
/// [path] is the file as [run] sees it, so a Linux path for a runner made by `wslRunner`. [source] names where it came
/// from, such as `WINCODE_DIST_KEY` or `profile in wincode.yaml`: a message never prints the path. A file outside any
/// repository passes, and so does one that `git check-ignore` reports as ignored. A file that git tracks is not ignored.
///
/// Fails closed: when git cannot answer, the file is refused with a "git is missing" message rather than let through.
Future<void> requireOutsideGit(
  String path, {
  required String source,
  RunProcess run = runProcess,
}) async {
  final slash = path.lastIndexOf(RegExp(r'[\\/]'));
  final name = path.substring(slash + 1);
  if (name.isEmpty) {
    throw ArgumentError.value(path, 'path', 'must name a file');
  }
  // Keep the separator: the folder of C:\key.p8 is C:\, not C:.
  final folder = slash < 0 ? '.' : path.substring(0, slash + 1);

  Future<ProcessResult> git(List<String> arguments) async {
    try {
      return await run('git', ['-C', folder, ...arguments]);
    } on ProcessException {
      throw _gitFailed(source, 'git is not installed');
    }
  }

  final inside = await git(['rev-parse', '--is-inside-work-tree']);
  if (inside.exitCode != 0) {
    if ('${inside.stderr}'.contains('not a git repository')) {
      return;
    }
    throw _gitFailed(source, 'git could not read the folder');
  }
  if ('${inside.stdout}'.trim() != 'true') {
    return;
  }

  // Exit 0: ignored. Exit 1: not ignored, or tracked. Anything else: git failed.
  final ignored = await git(['check-ignore', '-q', '--', name]);
  switch (ignored.exitCode) {
    case 0:
      return;
    case 1:
      throw WincodeException(
        ExitCode.config,
        'key-in-git-tree',
        '$source points inside a git working tree, and git does not ignore the file',
        why:
            'a key or profile there can be committed and pushed with the project, and it stays in the history after it '
            'is deleted.',
        next:
            'move the file outside every project folder, such as %USERPROFILE%\\.wincode on Windows or ~/.wincode in '
            'WSL2, and point $source at the new place. A file that has to stay may be listed in the project\'s '
            '.gitignore, but git check-ignore must report it as ignored.',
      );
    default:
      throw _gitFailed(source, 'git could not check the file');
  }
}

/// Refuses [folder], a folder of keys, when it lies inside a git working tree at all: ignored or not (ADR-0014,
/// section 2). It throws [refusal] for that, and the fail-closed `git-unavailable` when git cannot answer. [source]
/// names the folder in that message, never its path.
Future<void> requireNoWorkTree(
  String folder, {
  required String source,
  required WincodeException refusal,
  RunProcess run = runProcess,
}) async {
  final ProcessResult inside;
  try {
    inside = await run('git', [
      '-C',
      folder,
      'rev-parse',
      '--is-inside-work-tree',
    ]);
  } on ProcessException {
    throw _gitFailed(source, 'git is not installed');
  }
  if (inside.exitCode != 0) {
    if ('${inside.stderr}'.contains('not a git repository')) {
      return;
    }
    throw _gitFailed(source, 'git could not read the folder');
  }
  if ('${inside.stdout}'.trim() == 'true') {
    throw refusal;
  }
}

WincodeException _gitFailed(String source, String what) => WincodeException(
  ExitCode.unavailable,
  'git-unavailable',
  '$what, so winCode cannot tell whether $source is safe from a commit',
  why: 'winCode refuses a key or profile in a git working tree that does not ignore it, and it cannot check without git.',
  next: 'install Git for Windows (or git in WSL2 for a file there), then run the command again.',
);
