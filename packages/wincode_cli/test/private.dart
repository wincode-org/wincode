import 'dart:io';

/// Closes [entity] to other users, as the keys of a real setup are on a shared machine (ADR-0013, section 11): a folder
/// to mode 0700, a file to 0600. Does nothing on Windows. Returns [entity], so a fixture can be written as
/// `private(File(path)..writeAsStringSync(text))`.
T private<T extends FileSystemEntity>(T entity) {
  if (!Platform.isWindows) {
    final mode = entity is Directory ? '700' : '600';
    final result = Process.runSync('chmod', [mode, entity.path]);
    if (result.exitCode != 0) {
      throw StateError('chmod $mode failed: ${result.stderr}');
    }
  }
  return entity;
}

/// [private] for [folder] and every folder above it, up to but not including [stop], for a keys folder that was made
/// with `recursive: true` below a test's temporary folder.
Directory privateFolders(Directory folder, Directory stop) {
  for (
    var d = folder.absolute;
    d.path != stop.absolute.path && d.path.startsWith(stop.absolute.path);
    d = d.parent
  ) {
    private(d);
  }
  return folder;
}
