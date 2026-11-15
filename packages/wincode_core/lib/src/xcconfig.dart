import 'dart:io';

/// One `KEY[condition]... = value` line of an `.xcconfig` file.
class XcconfigEntry {
  const XcconfigEntry(this.key, this.conditions, this.value);

  final String key;

  /// The bracketed conditions, for example `sdk=iphoneos*`.
  final List<String> conditions;
  final String value;
}

/// Reads the text of the file at [path], a path from the Xcode project's folder with `/` between its parts, such as
/// `Flutter/Release.xcconfig`; null when there is no such file. [resolveBuildSettings] and [readXcconfigIn] read the
/// project through one, so that a commit's files can stand in for the disk (ADR-0015, section 2).
typedef ReadProjectFile = String? Function(String path);

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
    file.path,
    virtualFiles,
    depth,
    [...including, key],
    (target, depth, including) {
      final included = File('${file.parent.path}/$target');
      return included.existsSync()
          ? readXcconfig(
              included,
              virtualFiles: virtualFiles,
              depth: depth,
              including: including,
            )
          : null;
    },
  );
}

/// [readXcconfig] for the file at [path] of a project that [read] reads (see [ReadProjectFile]), not the disk. An
/// include is looked up from the including file's folder, with `.` and `..` resolved; a file that [read] does not know
/// is missing. The same limits apply, and so do the same messages, with the paths of the project in place of disk paths.
List<XcconfigEntry> readXcconfigIn(
  ReadProjectFile read,
  String path, {
  Map<String, String> virtualFiles = const {},
  int depth = 0,
  List<String> including = const [],
}) {
  final id = normalizeProjectPath(path);
  final text = read(id);
  if (text == null) {
    throw FormatException('$id does not exist');
  }
  return _readIn(read, id, text, virtualFiles, depth, including);
}

List<XcconfigEntry> _readIn(
  ReadProjectFile read,
  String id,
  String text,
  Map<String, String> virtualFiles,
  int depth,
  List<String> including,
) {
  if (depth > 16) {
    throw FormatException('$id: #include nests too deeply');
  }
  if (including.contains(id)) {
    throw FormatException(
      '${id.split('/').last}: #include is circular: it includes itself, directly or through other files',
    );
  }
  final folder = id.contains('/') ? id.substring(0, id.lastIndexOf('/')) : '';
  return _parse(text, id, virtualFiles, depth, [...including, id], (
    target,
    depth,
    including,
  ) {
    final included = normalizeProjectPath(
      folder.isEmpty ? target : '$folder/$target',
    );
    final includedText = read(included);
    return includedText == null
        ? null
        : _readIn(read, included, includedText, virtualFiles, depth, including);
  });
}

/// [path] with `\` read as `/`, empty and `.` parts dropped, and `..` resolved against the part before it. A `..`
/// that has nothing before it stays, so that a path out of the project is not found.
String normalizeProjectPath(String path) {
  final parts = <String>[];
  for (final part in path.replaceAll(r'\', '/').split('/')) {
    if (part.isEmpty || part == '.') {
      continue;
    }
    if (part == '..' && parts.isNotEmpty && parts.last != '..') {
      parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.join('/');
}

/// Reads [text], the contents of the file called [name]. [includeFile] gives the entries of the file that an `#include`
/// names, or null when there is none.
List<XcconfigEntry> _parse(
  String text,
  String name,
  Map<String, String> virtualFiles,
  int depth,
  List<String> including,
  List<XcconfigEntry>? Function(
    String target,
    int depth,
    List<String> including,
  )
  includeFile,
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
            base,
            virtualFiles,
            depth + 1,
            including,
            includeFile,
          ),
        );
      } else {
        final included = includeFile(target, depth + 1, including);
        if (included != null) {
          entries.addAll(included);
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
