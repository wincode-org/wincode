import 'dart:convert';
import 'dart:typed_data';

const _magic64 = 0xFEEDFACF;
const _lcLoadDylib = 0xC;
const _lcLoadWeakDylib = 0x80000018;
const _lcReexportDylib = 0x8000001F;
const _lcLoadUpwardDylib = 0x80000023;
const _lcLazyLoadDylib = 0x20;
const _lcDyldChainedFixups = 0x80000034;

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
/// that name it and the imported symbols bound to it.
///
/// A symbol binds to a library by its ordinal, the 1-based position of the library's load command among the dylib load
/// commands. The ordinals of the chained-fixups import table are read in all three of its formats.
LibraryUse libraryUse(Uint8List macho, String framework) {
  final data = ByteData.sublistView(macho);
  if (macho.length < 32 || data.getUint32(0, Endian.little) != _magic64) {
    throw const FormatException('not a 64-bit little-endian Mach-O file');
  }
  final suffix = '/$framework.framework/$framework';
  final named = <bool>[]; // one entry per dylib load command, in order: does it name the framework
  int? fixups;
  var offset = 32;
  for (var i = data.getUint32(16, Endian.little); i > 0; i--) {
    final command = data.getUint32(offset, Endian.little);
    final size = data.getUint32(offset + 4, Endian.little);
    switch (command) {
      case _lcLoadDylib ||
          _lcLoadWeakDylib ||
          _lcReexportDylib ||
          _lcLoadUpwardDylib ||
          _lcLazyLoadDylib:
        final start = offset + data.getUint32(offset + 8, Endian.little);
        var end = start;
        while (end < offset + size && macho[end] != 0) {
          end++;
        }
        named.add(utf8.decode(macho.sublist(start, end)).endsWith(suffix));
      case _lcDyldChainedFixups:
        fixups = data.getUint32(offset + 8, Endian.little);
    }
    offset += size;
  }
  int? bindings;
  if (fixups != null) {
    final importsAt = fixups + data.getUint32(fixups + 8, Endian.little);
    final count = data.getUint32(fixups + 16, Endian.little);
    final format = data.getUint32(fixups + 20, Endian.little);
    // Format 1 is DYLD_CHAINED_IMPORT (4 bytes: 8-bit ordinal, 1 weak bit, 23-bit name offset), format 2 adds a 32-bit
    // addend, and format 3 is DYLD_CHAINED_IMPORT_ADDEND64 (16 bytes: 16-bit ordinal, 1 weak bit, 15 reserved bits, 32-bit
    // name offset, 64-bit addend).
    final entrySize = switch (format) {
      1 => 4,
      2 => 8,
      3 => 16,
      _ => throw FormatException(
        'unknown chained fixups import format $format',
      ),
    };
    var bound = 0;
    for (var i = 0; i < count; i++) {
      final at = importsAt + entrySize * i;
      final ordinal = format == 3
          ? data.getUint64(at, Endian.little) & 0xFFFF
          : data.getUint32(at, Endian.little) & 0xFF;
      if (ordinal >= 1 && ordinal <= named.length && named[ordinal - 1]) {
        bound++;
      }
    }
    bindings = bound;
  }
  return LibraryUse(
    loadCommands: named.where((n) => n).length,
    bindings: bindings,
  );
}
