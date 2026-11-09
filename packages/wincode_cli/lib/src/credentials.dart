import 'dart:io';

import 'package:wincode_core/wincode_core.dart';

import 'config.dart';
import 'failure.dart';
import 'key_location.dart';
import 'redact.dart';

/// Where an app's keys are, and the rules for them (ADR-0013 section 2 for the two legacy variables, ADR-0014 section 2
/// for a credentials reference).
///
/// Nothing here starts `wsl.exe`: the App Store Connect key is read from a folder on the Windows side. Nothing here
/// prints a path or a key: a message names a variable, a reference or a placeholder, and the folders found are
/// registered with the [Redactor] as secrets.

/// The variable that names the keys root.
const keysRootVariable = 'WINCODE_KEYS_DIR';

const _legacyAsc = 'WINCODE_ASC_KEY_DIR';
const _legacyDist = 'WINCODE_DIST_KEY';

/// The name of a reference as it ends a variable: `team-one` gives `TEAM_ONE`.
String referenceSuffix(String reference) =>
    reference.toUpperCase().replaceAll('-', '_');

/// The variable that replaces the App Store Connect half of [reference]: a folder with the `.p8` and `issuer-id`.
String ascOverrideVariable(String reference) =>
    '${_legacyAsc}_${referenceSuffix(reference)}';

/// The variable that replaces the `dist.key` half of [reference]: a file.
String distOverrideVariable(String reference) =>
    '${_legacyDist}_${referenceSuffix(reference)}';

/// The keys root: the folder `WINCODE_KEYS_DIR` names, else `.wincode/keys` in the user's profile folder. Null when
/// neither is known.
({Directory directory, bool fromVariable})? keysRoot(
  Map<String, String> environment,
) {
  final variable = environment[keysRootVariable] ?? '';
  if (variable.isNotEmpty) {
    return (directory: Directory(variable).absolute, fromVariable: true);
  }
  final home = environment['USERPROFILE'] ?? environment['HOME'] ?? '';
  if (home.isEmpty) {
    return null;
  }
  final s = Platform.pathSeparator;
  return (
    directory: Directory('$home$s.wincode${s}keys').absolute,
    fromVariable: false,
  );
}

/// The files of an App Store Connect key folder, and how messages name where they came from: [source] is a variable, or
/// `the folder of the credentials <reference>`.
typedef AscKeyFiles = ({List<File> p8, File? issuer, String source});

/// Why `--dry-run` has no token: what is missing, in the words of the golden output.
String noTokenReason(WincodeConfig app) => app.credentials == null
    ? 'no token: $_legacyAsc is not set'
    : 'no token: the credentials ${app.credentials} were not found';

/// The key files of [app]'s App Store Connect key, each location checked before anything reads it.
///
/// - A flat file without `credentials`: the folder `WINCODE_ASC_KEY_DIR` names, with ADR-0013's single-file git rule on
///   each file, as before.
/// - An app with `credentials`: the folder `WINCODE_ASC_KEY_DIR_<REF>` names, else the folder of the reference under the
///   keys root. These are refused in any git working tree, ignored or not, and in OneDrive.
///
/// Null only for a [dryRun] whose keys are not there, which then sends no token.
Future<AscKeyFiles?> locateAscKeyFiles(
  WincodeConfig app, {
  required Map<String, String> environment,
  required Redactor redactor,
  RunProcess run = runProcess,
  bool dryRun = false,
}) async {
  final reference = app.credentials;
  if (reference == null) {
    return _legacyAscFiles(environment, redactor, run, dryRun);
  }
  final variable = ascOverrideVariable(reference);
  final override = environment[variable] ?? '';
  if (override.isNotEmpty) {
    final folder = Directory(override).absolute;
    redactor.secret(folder.path, '<keys folder>');
    _refuseOneDrive(folder.path, variable);
    await _refuseWorkTree(
      folder.path,
      variable: variable,
      run: run,
      whatOf: '$variable points inside a git working tree',
    );
    return _listKeyFolder(folder, variable);
  }
  final Directory? folder;
  try {
    folder = await _referenceFolder(
      app,
      reference,
      environment: environment,
      redactor: redactor,
      run: run,
    );
  } on WincodeException catch (e) {
    // A dry run goes on without a token when the keys are not there, as it does for WINCODE_ASC_KEY_DIR.
    if (dryRun && e.id == 'credentials-missing') {
      return null;
    }
    rethrow;
  }
  if (folder == null) {
    if (dryRun) {
      return null;
    }
    throw _missing(
      app,
      reference,
      environment,
      'the keys folder has no folder $reference',
    );
  }
  return _listKeyFolder(folder, 'the folder of the credentials $reference');
}

/// The distribution key of [app] (ADR-0014, section 2): the file `WINCODE_DIST_KEY_<REF>` names, else `dist.key` in the
/// folder of the reference, or for a flat file without `credentials` the file `WINCODE_DIST_KEY` names, which is null
/// when it is not set. Only the location is checked here, with the rules of [locateAscKeyFiles]: whether the file
/// exists and what is in it is for `wincode sign`.
Future<File?> resolveDistKey(
  WincodeConfig app, {
  required Map<String, String> environment,
  required Redactor redactor,
  RunProcess run = runProcess,
}) async {
  final reference = app.credentials;
  if (reference == null) {
    final variable = environment[_legacyDist] ?? '';
    if (variable.isEmpty) {
      return null;
    }
    final file = File(variable).absolute;
    redactor.secret(file.path, '<$_legacyDist>');
    _refuseOneDrive(file.path, _legacyDist);
    await requireOutsideGit(file.path, source: _legacyDist, run: run);
    return file;
  }
  final variable = distOverrideVariable(reference);
  final override = environment[variable] ?? '';
  if (override.isNotEmpty) {
    final file = File(override).absolute;
    redactor.secret(file.path, '<distribution key>');
    _refuseOneDrive(file.path, variable);
    await _refuseWorkTree(
      file.parent.path,
      variable: variable,
      run: run,
      whatOf: '$variable points inside a git working tree',
    );
    return file;
  }
  final folder = await _referenceFolder(
    app,
    reference,
    environment: environment,
    redactor: redactor,
    run: run,
  );
  if (folder == null) {
    throw _missing(
      app,
      reference,
      environment,
      'the keys folder has no folder $reference',
    );
  }
  return File('${folder.path}${Platform.pathSeparator}dist.key');
}

/// The folder of [reference] under the keys root, after the root and the folder passed the location rules. Null when
/// the root exists but has no such folder. Throws when the root itself is not there.
Future<Directory?> _referenceFolder(
  WincodeConfig app,
  String reference, {
  required Map<String, String> environment,
  required Redactor redactor,
  required RunProcess run,
}) async {
  final root = keysRoot(environment);
  if (root == null) {
    throw _missing(
      app,
      reference,
      environment,
      '$keysRootVariable is not set, and neither is the user profile folder that holds the default keys folder',
    );
  }
  final rootName = root.fromVariable
      ? keysRootVariable
      : 'the default keys folder';
  redactor.secret(root.directory.path, '<$keysRootVariable>');
  if (!root.directory.existsSync()) {
    throw _missing(
      app,
      reference,
      environment,
      root.fromVariable
          ? 'the folder that $keysRootVariable names does not exist'
          : 'the keys folder does not exist',
    );
  }
  _refuseOneDrive(root.directory.path, rootName, variable: root.fromVariable);
  await _refuseWorkTree(
    root.directory.path,
    variable: root.fromVariable ? keysRootVariable : null,
    run: run,
    whatOf: root.fromVariable
        ? '$keysRootVariable points inside a git working tree'
        : 'the default keys folder lies inside a git working tree',
    root: true,
  );
  final folder = Directory(
    '${root.directory.path}${Platform.pathSeparator}$reference',
  );
  if (!folder.existsSync()) {
    return null;
  }
  // A repository made inside the root (the root itself is outside every one).
  await _refuseWorkTree(
    folder.path,
    variable: null,
    run: run,
    whatOf:
        'the folder of the credentials $reference lies inside a git working tree',
    inner: true,
  );
  return folder;
}

// The App Store Connect key folder.

Future<AscKeyFiles?> _legacyAscFiles(
  Map<String, String> environment,
  Redactor redactor,
  RunProcess run,
  bool dryRun,
) async {
  final variable = environment[_legacyAsc] ?? '';
  if (variable.isEmpty) {
    return dryRun ? null : throw _legacyMissing;
  }
  // Only the absolute path is hidden: the value as set may be as short as `.`, and hiding it would hide every dot.
  // The files are listed from the absolute path, so their paths start with it.
  final folder = Directory(variable).absolute;
  redactor.secret(folder.path, '<$_legacyAsc>');
  if (_inOneDrive(folder.path)) {
    throw _legacyInOneDrive;
  }
  final key = _listKeyFolder(folder, _legacyAsc);
  for (final file in [...key.p8, ?key.issuer]) {
    await requireOutsideGit(file.path, source: _legacyAsc, run: run);
  }
  return key;
}

AscKeyFiles _listKeyFolder(Directory folder, String source) {
  final List<File> files;
  try {
    files = folder.listSync().whereType<File>().toList();
  } on FileSystemException {
    throw source == _legacyAsc
        ? ascKeyInvalid(
            '$source does not name a folder that can be read',
            why: 'it names the folder that holds AuthKey_<Key ID>.p8 and issuer-id.',
            next: 'set $source to that folder.',
          )
        : ascKeyInvalid(
            '$source cannot be read',
            why: 'preflight reads AuthKey_<Key ID>.p8 and issuer-id from it.',
            next: 'check that your user may read the folder and its files.',
          );
  }
  return (
    p8: [
      for (final f in files)
        if (_name(f).toLowerCase().endsWith('.p8')) f,
    ],
    issuer: files.where((f) => _name(f) == 'issuer-id').firstOrNull,
    source: source,
  );
}

/// The Key ID and the Issuer ID in [key], registered with [redactor] before anything can print them. Does not read the
/// key itself.
({String keyId, String issuer, File p8}) readAscKeyIds(
  AscKeyFiles key,
  Redactor redactor,
) {
  final source = key.source;
  if (key.p8.length != 1) {
    throw ascKeyInvalid(
      key.p8.isEmpty
          ? '$source holds no .p8 file'
          : '$source holds ${key.p8.length} .p8 files',
      why: 'preflight signs its requests with the one key in that folder.',
      next: 'keep exactly one key there: AuthKey_<Key ID>.p8, as App Store Connect delivered it.',
    );
  }
  final keyId = RegExp(r'^AuthKey_([A-Z0-9]{10})\.p8$')
      .firstMatch(_name(key.p8.single))?[1];
  if (keyId == null) {
    throw ascKeyInvalid(
      'the .p8 in $source is not named AuthKey_<Key ID>.p8',
      why: 'every token names the Key ID, which winCode takes from the name App Store Connect gives the file.',
      next: 'name the file AuthKey_ followed by the 10 characters of its Key ID (Users and Access, Integrations).',
    );
  }
  redactor.secret(keyId, '<Key ID>');
  final issuer = _text(key.issuer)?.trim() ?? '';
  if (!RegExp(
    r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$',
    caseSensitive: false,
  ).hasMatch(issuer)) {
    throw ascKeyInvalid(
      '$source has no file issuer-id with an Issuer ID in it',
      why: 'every token names the Issuer ID of the team.',
      next:
          'write the Issuer ID (Users and Access, Integrations) on one line in a file named issuer-id in that '
          'folder.',
    );
  }
  redactor.secret(issuer, '<Issuer ID>');
  return (keyId: keyId, issuer: issuer, p8: key.p8.single);
}

/// The text of [file] without a byte order mark, or null when it cannot be read.
String? readKeyText(File? file) => _text(file);

String? _text(File? file) {
  try {
    final text = file?.readAsStringSync();
    return text != null && text.startsWith('﻿') ? text.substring(1) : text;
  } on FileSystemException {
    return null;
  }
}

String _name(File file) => file.uri.pathSegments.last;

/// A key folder or key file that cannot be used (exit 78).
WincodeException ascKeyInvalid(
  String what, {
  required String why,
  required String next,
}) => WincodeException(
  ExitCode.config,
  'asc-key-invalid',
  what,
  why: why,
  next: next,
);

// Location rules.

bool _inOneDrive(String path) => path
    .split(RegExp(r'[\\/]'))
    .any((part) => part.toLowerCase().startsWith('onedrive'));

void _refuseOneDrive(String path, String name, {bool variable = true}) {
  if (!_inOneDrive(path)) {
    return;
  }
  throw WincodeException(
    ExitCode.config,
    'key-in-onedrive',
    variable ? '$name points into OneDrive' : '$name lies in OneDrive',
    why: 'OneDrive copies the folder, and the keys in it, to the cloud and to other PCs.',
    next: variable
        ? 'move it outside OneDrive, such as %USERPROFILE%\\.wincode\\keys, and point $name at the new place.'
        : 'move the user profile folder\'s .wincode out of OneDrive, or set $keysRootVariable to a folder outside it.',
  );
}

/// Refuses [folder] when it lies inside a git working tree, ignored or not (ADR-0014, section 2).
Future<void> _refuseWorkTree(
  String folder, {
  required String? variable,
  required RunProcess run,
  required String whatOf,
  bool root = false,
  bool inner = false,
}) => requireNoWorkTree(
  folder,
  source: variable ?? 'the keys folder',
  run: run,
  refusal: WincodeException(
    ExitCode.config,
    'keys-in-git-tree',
    whatOf,
    why: root
        ? 'the folder holds the keys of every team that wincode.yaml names. A key in a working tree can be committed and '
              'pushed with the project, and it stays in the history after it is deleted. A keys folder has no reason to '
              'be in a project, so winCode refuses it there even when git ignores it.'
        : 'a key in a working tree can be committed and pushed with the project, and it stays in the history after it '
              'is deleted. A folder of keys has no reason to be in a project, so winCode refuses it there even when git '
              'ignores it.',
    next: inner
        ? 'move the folder outside every git working tree, or remove the repository that holds it, then run the '
              'command again.'
        : variable == keysRootVariable
        ? 'move the folder outside every git working tree, such as %USERPROFILE%\\.wincode\\keys, and set '
              '$keysRootVariable to it (or unset $keysRootVariable to use that default).'
        : variable != null
        ? 'move it outside every git working tree, such as %USERPROFILE%\\.wincode\\keys, and point $variable at the new '
              'place.'
        : 'the default keys folder is in your user profile, which lies inside a git working tree: set '
              '$keysRootVariable to a folder outside every git working tree, or take the profile folder out of the '
              'repository.',
  ),
);

// Messages.

WincodeException _missing(
  WincodeConfig app,
  String reference,
  Map<String, String> environment,
  String reason,
) {
  final owner = app.name == null ? '' : ' of app ${app.name}';
  final subject = app.name == null ? "the app's" : "${app.name}'s";
  return WincodeException(
    ExitCode.config,
    'credentials-missing',
    'the credentials $reference$owner are missing: $reason',
    why:
        'wincode.yaml names a credentials reference for each app, never a key, and $subject App Store Connect key is '
        'read from that folder.',
    next:
        'create the folder $reference in %USERPROFILE%\\.wincode\\keys (or in the folder that $keysRootVariable '
        'names) with AuthKey_<Key ID>.p8, as App Store Connect delivered it, and issuer-id (and dist.key, for wincode '
        'sign), or set ${ascOverrideVariable(reference)} to a folder that holds the first two.'
        '${(environment[_legacyAsc] ?? '').isEmpty ? '' : ' $_legacyAsc is set, but it serves only a wincode.yaml without credentials.'}',
  );
}

const _legacyMissing = WincodeException(
  ExitCode.config,
  'asc-key-dir-missing',
  'WINCODE_ASC_KEY_DIR is not set',
  why: 'preflight reads the App Store Connect API key from that folder: AuthKey_<Key ID>.p8 and issuer-id.',
  next:
      'put AuthKey_<Key ID>.p8, as App Store Connect delivered it, and a file issuer-id with the Issuer ID (Users and '
      'Access, Integrations) in a folder outside every project and outside OneDrive, such as '
      r'%USERPROFILE%\.wincode\asc, and set WINCODE_ASC_KEY_DIR to it.',
);

const _legacyInOneDrive = WincodeException(
  ExitCode.config,
  'key-in-onedrive',
  'WINCODE_ASC_KEY_DIR points into OneDrive',
  why: 'OneDrive copies the folder, and the key in it, to the cloud and to other PCs.',
  next: r'move the folder outside OneDrive, such as %USERPROFILE%\.wincode\asc, and point WINCODE_ASC_KEY_DIR at it.',
);
