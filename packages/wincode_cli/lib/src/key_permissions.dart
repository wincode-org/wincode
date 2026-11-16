import 'dart:io';

import 'failure.dart';

/// A key file, or a folder of keys, whose access [requirePrivate] checks.
///
/// [label] says what it is, such as `the distribution key of the credentials team-one`. [where] is how a shell names it,
/// such as `"$WINCODE_DIST_KEY"` or `~/.wincode/keys/team-one/dist.key`: the fix is printed with it, because a message
/// never prints the path of a key (ADR-0013, section 7), and the redactor would replace it anyway.
typedef KeyTarget = ({String path, bool folder, String label, String where});

/// Refuses a key, or a folder of keys, that another user could read or change, or that another user owns (ADR-0013,
/// section 11), as ssh refuses a private key that others can read. A key on a shared Linux server is only as private as
/// its mode. Skipped on Windows, where the user profile is the boundary. The first target that fails stops the check,
/// with `keys-permissions` (78); a target that does not exist is left to the caller, which reports it missing.
///
/// A file needs mode 0600 or tighter, a folder 0700 or tighter: no bit for the group or for others. The owner is the
/// user that runs `wincode`. When `id` or `stat` cannot tell who that is, the check fails closed (69, `stat-unavailable`)
/// rather than let a key through.
///
/// [tool] runs `id` and `stat` and returns the first line of their output, null when one fails (default: starts the
/// program). Tests give their own.
Future<void> requirePrivate(
  Iterable<KeyTarget> targets, {
  Future<String?> Function(String executable, List<String> arguments) tool =
      _output,
}) async {
  if (Platform.isWindows) {
    return;
  }
  String? me;
  for (final target in targets) {
    // stat follows a link, so a link to a key is checked as the key.
    final stat = FileStat.statSync(target.path);
    if (stat.type == FileSystemEntityType.notFound) {
      continue;
    }
    final mode = stat.mode & _everyone;
    final fix = target.folder ? '700' : '600';
    if (mode & _others != 0) {
      throw WincodeException(
        ExitCode.config,
        'keys-permissions',
        '${target.label} can be reached by other users (mode ${_octal(mode)})',
        why:
            'another user of this machine could read the keys, or replace them with their own. Like ssh with a private '
            'key, winCode refuses keys that only their owner should reach.',
        next: 'run: chmod $fix ${target.where}',
      );
    }
    me ??= await tool('id', ['-u']);
    final owner =
        await tool('stat', ['-c', '%u', '--', target.path]) ??
        await tool('stat', ['-f', '%u', target.path]); // BSD and macOS
    if (me == null || owner == null) {
      throw WincodeException(
        ExitCode.unavailable,
        'stat-unavailable',
        'cannot tell who owns ${target.label}',
        why: 'winCode refuses keys that another user owns, and it asks id and stat who owns them. Neither could be run.',
        next: 'install coreutils (id and stat), or run wincode as the user that owns the keys on a machine that has them.',
      );
    }
    if (me != owner) {
      throw WincodeException(
        ExitCode.config,
        'keys-permissions',
        '${target.label} is owned by another user (uid $owner, not $me)',
        why:
            'the owner can change who reads it at any time, and root-owned or shared keys are what a dedicated account '
            'is meant to avoid.',
        next:
            'run: sudo chown "\$(id -un)" ${target.where} && chmod $fix ${target.where}',
      );
    }
  }
}

/// The bits for the owner, the group and others.
const _everyone = 511; // 0777

/// The bits for the group and others.
const _others = 63; // 0077

String _octal(int mode) => mode.toRadixString(8).padLeft(4, '0');

/// The first line `<executable> <arguments>` prints, or null when it cannot be started, fails or prints nothing.
Future<String?> _output(String executable, List<String> arguments) async {
  try {
    final result = await Process.run(executable, arguments);
    if (result.exitCode != 0) {
      return null;
    }
    final line = '${result.stdout}'.trim().split('\n').first.trim();
    return line.isEmpty ? null : line;
  } on ProcessException {
    return null;
  }
}

/// Closes [folder], which winCode has just made, to everyone but its owner (mode 0700). `dart:io` makes a folder with
/// the process's umask, usually 0022, so a folder for a signing is chmod-ed before anything goes into it. Skipped on
/// Windows. Fails closed (69, `chmod-unavailable`) when `chmod` cannot be run, rather than sign in a folder that other
/// users could enter. [chmod] runs it and tells whether it succeeded (default: starts the program); tests give their own.
Future<void> makePrivate(
  Directory folder, {
  Future<bool> Function(List<String> arguments) chmod = _chmod,
}) async {
  if (Platform.isWindows || await chmod(['700', '--', folder.path])) {
    return;
  }
  throw const WincodeException(
    ExitCode.unavailable,
    'chmod-unavailable',
    'cannot make the temporary folder private',
    why:
        'wincode sign works in a folder that only you can enter, and dart:io makes folders with the umask. chmod could '
        'not be run.',
    next:
        'install coreutils (chmod), and check that you own the output folder.',
  );
}

/// The permission bits (0777) that the filesystem reports for [path].
int folderMode(String path) => FileStat.statSync(path).mode & _everyone;

/// Whether [folder], which [makePrivate] has just closed, really is closed (mode 0700): `chmod` succeeds on a filesystem
/// that ignores it, such as `/mnt/c` in WSL2 (a 9p mount without metadata), and the folder stays open. True on Windows,
/// where modes mean nothing. [modeOf] reads the mode (default: [folderMode]); tests give their own.
bool isPrivate(
  Directory folder, {
  int Function(String path) modeOf = folderMode,
}) => Platform.isWindows || modeOf(folder.path) == 448; // 0700

/// The warning for a folder that [makePrivate] closed and [isPrivate] says is open, with its [mode]. It never stops a
/// run: the folder holds no key.
WincodeException folderNotPrivate(int mode) => WincodeException(
  ExitCode.ok,
  'output-not-private',
  'the signing folder is not private: its mode is ${_octal(mode)}, not 0700, though chmod 700 succeeded; the signing goes on',
  why:
      'the filesystem under the output folder ignores chmod (a Windows drive that WSL2 mounts as /mnt/c does). The '
      "folder holds the certificate (public), the entitlements and zsign's work copy of the app, and never the key, so "
      'no secret is exposed; but other users of this machine could read or change those files while zsign works.',
  next: 'on a shared server, set output in wincode.yaml to a folder on the Linux disk.',
);

Future<bool> _chmod(List<String> arguments) async {
  try {
    return (await Process.run('chmod', arguments)).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
