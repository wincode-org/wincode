import 'dart:io';

/// One `KEY[condition]... = value` line of an `.xcconfig` file.
class XcconfigEntry {
  const XcconfigEntry(this.key, this.conditions, this.value);

  final String key;

  /// The bracketed conditions, for example `sdk=iphoneos*`.
  final List<String> conditions;
  final String value;
}

final _assignment = RegExp(
  r'^([A-Za-z_][A-Za-z0-9_]*)((?:\[[^\]]*\])*)\s*=\s*(.*)$',
);
final _include = RegExp(r'^#include(\?)?\s+"([^"]+)"$');

/// Reads [file] and every file it includes, in order: an included file's entries stand where its `#include` stood.
///
/// [virtualFiles] holds files that don't exist on disk, by name. Flutter writes `Generated.xcconfig` on the Mac that
/// builds, so winCode supplies one. A missing file fails unless it was included with `#include?`.
///
/// Includes nest at most 16 deep, and a file that includes itself, directly or through others, fails at once with a
/// message that says so ([including] holds the files above [file] in the chain). Nothing in a file is executed.
List<XcconfigEntry> readXcconfig(
  File file, {
  Map<String, String> virtualFiles = const {},
  int depth = 0,
  List<String> including = const [],
}) {
  if (depth > 16) {
    throw FormatException('${file.path}: #include nests too deeply');
  }
  final id = file.resolveSymbolicLinksSync();
  final key = Platform.isWindows ? id.toLowerCase() : id;
  if (including.contains(key)) {
    throw FormatException(
      '${file.uri.pathSegments.last}: #include is circular: it includes itself, directly or through other files',
    );
  }
  return _parse(
    file.readAsStringSync(),
    file.parent,
    file.path,
    virtualFiles,
    depth,
    [...including, key],
  );
}

List<XcconfigEntry> _parse(
  String text,
  Directory folder,
  String name,
  Map<String, String> virtualFiles,
  int depth,
  List<String> including,
) {
  final entries = <XcconfigEntry>[];
  var number = 0;
  for (var line in text.split(RegExp(r'\r?\n'))) {
    number++;
    final comment = line.indexOf('//');
    if (comment >= 0) line = line.substring(0, comment);
    line = line.trim();
    if (line.isEmpty) continue;
    final include = _include.firstMatch(line);
    if (include != null) {
      final target = include.group(2)!;
      final base = target.split(RegExp(r'[\\/]')).last;
      if (virtualFiles.containsKey(base)) {
        entries.addAll(
          _parse(
            virtualFiles[base]!,
            folder,
            base,
            virtualFiles,
            depth + 1,
            including,
          ),
        );
      } else {
        final included = File('${folder.path}/$target');
        if (included.existsSync()) {
          entries.addAll(
            readXcconfig(
              included,
              virtualFiles: virtualFiles,
              depth: depth + 1,
              including: including,
            ),
          );
        } else if (include.group(1) == null) {
          throw FormatException(
            '$name:$number: the included file $target does not exist',
          );
        }
      }
      continue;
    }
    final match = _assignment.firstMatch(line);
    if (match == null) {
      throw FormatException('$name:$number: not a setting: $line');
    }
    final conditions = RegExp(r'\[([^\]]*)\]')
        .allMatches(match.group(2)!)
        .map((m) => m.group(1)!)
        .toList();
    entries.add(
      XcconfigEntry(match.group(1)!, conditions, match.group(3)!.trim()),
    );
  }
  return entries;
}
