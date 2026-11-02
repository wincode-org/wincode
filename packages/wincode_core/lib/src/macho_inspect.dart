import 'dart:convert';
import 'dart:typed_data';

const _magic64 = 0xFEEDFACF;
const _lcRpath = 0x8000001C;
const _lcBuildVersion = 0x32;
const _lcDyldChainedFixups = 0x80000034;
const _dylibKinds = {
  0xC: DylibKind.strong, // LC_LOAD_DYLIB
  0x80000018: DylibKind.weak, // LC_LOAD_WEAK_DYLIB
  0x8000001F: DylibKind.reexport, // LC_REEXPORT_DYLIB
  0x80000023: DylibKind.upward, // LC_LOAD_UPWARD_DYLIB
  0x20: DylibKind.lazy, // LC_LAZY_LOAD_DYLIB
};

/// How a dylib load command loads its library.
enum DylibKind { strong, weak, reexport, upward, lazy }

/// A dylib load command: the library's install name and how it is loaded.
typedef Dylib = ({String installName, DylibKind kind});

/// An imported symbol of the chained-fixups import table: its name, the install name of the library it is bound to
/// (null for the special ordinals: the file itself, the main executable, a flat or a weak lookup) and its weak bit.
typedef Import = ({String symbol, String? library, bool weak});

/// `LC_BUILD_VERSION`: the platform number (2 is iOS), the minimum OS and the SDK, as `major.minor[.patch]`.
typedef BuildVersion = ({int platform, String minOS, String sdk});

/// What [readMachO] finds in a Mach-O file.
class MachO {
  const MachO({
    required this.commands,
    required this.dylibs,
    required this.rpaths,
    required this.buildVersion,
    required this.imports,
  });

  /// The kind (`cmd`) of each load command, in order.
  final List<int> commands;

  /// The dylib load commands, in order. A symbol's library ordinal is its 1-based position here.
  final List<Dylib> dylibs;

  /// The paths of the `LC_RPATH` commands, in order.
  final List<String> rpaths;

  /// The file's `LC_BUILD_VERSION`, or null when it has none.
  final BuildVersion? buildVersion;

  /// The chained-fixups import table, or null when the file has none (a file that binds with opcodes).
  final List<Import>? imports;
}

/// Reads the load commands of the 64-bit little-endian Mach-O file [macho] and the import table of its
/// `LC_DYLD_CHAINED_FIXUPS`, in all three of its formats.
///
/// Throws a [FormatException] for another kind of file, a truncated one, or symbol names that are compressed.
MachO readMachO(Uint8List macho) {
  final data = ByteData.sublistView(macho);
  if (macho.length < 32 || data.getUint32(0, Endian.little) != _magic64) {
    throw const FormatException('not a 64-bit little-endian Mach-O file');
  }
  String cString(int start, [int? end]) {
    final nul = macho.indexOf(0, start);
    return utf8.decode(
      macho.sublist(start, nul < 0 || (end != null && nul > end) ? end : nul),
    );
  }

  try {
    final commands = <int>[];
    final dylibs = <Dylib>[];
    final rpaths = <String>[];
    BuildVersion? buildVersion;
    int? fixups;
    var offset = 32;
    for (var i = data.getUint32(16, Endian.little); i > 0; i--) {
      final command = data.getUint32(offset, Endian.little);
      final size = data.getUint32(offset + 4, Endian.little);
      if (size < 8) {
        throw const FormatException('a load command is shorter than 8 bytes');
      }
      final kind = _dylibKinds[command];
      final end = offset + size;
      commands.add(command);
      if (kind != null) {
        dylibs.add((
          installName: cString(
            offset + data.getUint32(offset + 8, Endian.little),
            end,
          ),
          kind: kind,
        ));
      } else if (command == _lcRpath) {
        rpaths.add(
          cString(offset + data.getUint32(offset + 8, Endian.little), end),
        );
      } else if (command == _lcBuildVersion) {
        buildVersion = (
          platform: data.getUint32(offset + 8, Endian.little),
          minOS: _version(data.getUint32(offset + 12, Endian.little)),
          sdk: _version(data.getUint32(offset + 16, Endian.little)),
        );
      } else if (command == _lcDyldChainedFixups) {
        fixups = data.getUint32(offset + 8, Endian.little);
      }
      offset = end;
    }
    return MachO(
      commands: commands,
      dylibs: dylibs,
      rpaths: rpaths,
      buildVersion: buildVersion,
      imports: fixups == null ? null : _imports(data, fixups, dylibs, cString),
    );
  } on RangeError {
    throw const FormatException('the Mach-O file is truncated');
  }
}

/// The import table of the chained fixups at [fixups]. Format 1 is DYLD_CHAINED_IMPORT (4 bytes: 8-bit ordinal, 1 weak
/// bit, 23-bit name offset), format 2 adds a 32-bit addend, and format 3 is DYLD_CHAINED_IMPORT_ADDEND64 (16 bytes:
/// 16-bit ordinal, 1 weak bit, 15 reserved bits, 32-bit name offset, 64-bit addend).
List<Import> _imports(
  ByteData data,
  int fixups,
  List<Dylib> dylibs,
  String Function(int start) cString,
) {
  final importsAt = fixups + data.getUint32(fixups + 8, Endian.little);
  final namesAt = fixups + data.getUint32(fixups + 12, Endian.little);
  final count = data.getUint32(fixups + 16, Endian.little);
  final format = data.getUint32(fixups + 20, Endian.little);
  if (data.getUint32(fixups + 24, Endian.little) != 0) {
    throw const FormatException(
      'the chained fixups have compressed symbol names',
    );
  }
  final entrySize = switch (format) {
    1 => 4,
    2 => 8,
    3 => 16,
    _ => throw FormatException('unknown chained fixups import format $format'),
  };
  final imports = <Import>[];
  for (
    var at = importsAt;
    at < importsAt + entrySize * count;
    at += entrySize
  ) {
    final word = data.getUint32(at, Endian.little);
    final (ordinal, weak, name) = format == 3
        ? (
            word & 0xFFFF,
            (word >> 16) & 1,
            data.getUint32(at + 4, Endian.little),
          )
        : (word & 0xFF, (word >> 8) & 1, word >> 9);
    imports.add((
      symbol: cString(namesAt + name),
      library: ordinal >= 1 && ordinal <= dylibs.length
          ? dylibs[ordinal - 1].installName
          : null,
      weak: weak == 1,
    ));
  }
  return imports;
}

/// A version packed as `xxxx.yy.zz` in nibbles, as `major.minor`, with `.patch` when it is not 0.
String _version(int v) {
  final patch = v & 0xFF;
  return '${v >> 16}.${(v >> 8) & 0xFF}${patch == 0 ? '' : '.$patch'}';
}

/// How a Mach-O file uses one framework: the dylib load commands that name it and the imported symbols that are bound to
/// it.
class LibraryUse {
  const LibraryUse({required this.loadCommands, required this.bindings});

  /// The dylib load commands (strong, weak, re-export, upward or lazy) whose install name is the framework's.
  final int loadCommands;

  /// The imported symbols that bind to the framework, counted in the chained-fixups import table, or `null` when the file
  /// has none. Bind opcodes, which older links use, are not read.
  final int? bindings;

  /// Whether the file refers to the framework at all.
  bool get isUsed => loadCommands > 0 || (bindings ?? 0) > 0;
}

/// Counts how the 64-bit little-endian Mach-O file [macho] uses `<framework>.framework/<framework>`: the load commands
/// that name it and the imported symbols bound to it ([readMachO]).
LibraryUse libraryUse(Uint8List macho, String framework) {
  final file = readMachO(macho);
  final suffix = '/$framework.framework/$framework';
  return LibraryUse(
    loadCommands: file.dylibs
        .where((d) => d.installName.endsWith(suffix))
        .length,
    bindings: file.imports
        ?.where((i) => i.library?.endsWith(suffix) ?? false)
        .length,
  );
}
