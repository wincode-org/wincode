import 'dart:convert';
import 'dart:typed_data';

const _magic64 = 0xFEEDFACF;
const _lcIdDylib = 0xD;
const _lcRpath = 0x8000001C;

/// Removes the `LC_RPATH` commands of a 64-bit little-endian Mach-O file whose path is not in [keep] (ADR-0011 rule 3:
/// a release runner carries exactly `/usr/lib/swift` and `@executable_path/Frameworks`, but Swift Build adds paths of
/// its own, one of them the build machine's toolchain folder). The commands after a removed one move up, the freed
/// bytes are zeroed and the header's count and size are updated. Run it before signing: it changes the file.
///
/// Returns the new file and the paths it removed, in order.
({Uint8List macho, List<String> removed}) removeRpaths(
  Uint8List macho,
  Set<String> keep,
) {
  final data = ByteData.sublistView(macho);
  if (macho.length < 32 || data.getUint32(0, Endian.little) != _magic64) {
    throw const FormatException('not a 64-bit little-endian Mach-O file');
  }
  final count = data.getUint32(16, Endian.little);
  final commandsSize = data.getUint32(20, Endian.little);
  final kept = <Uint8List>[];
  final removed = <String>[];
  var offset = 32;
  for (var i = 0; i < count; i++) {
    final size = data.getUint32(offset + 4, Endian.little);
    final command = Uint8List.sublistView(macho, offset, offset + size);
    if (data.getUint32(offset, Endian.little) == _lcRpath) {
      final start = data.getUint32(offset + 8, Endian.little);
      final end = command.indexOf(0, start);
      final path = utf8.decode(command.sublist(start, end < 0 ? size : end));
      if (!keep.contains(path)) {
        removed.add(path);
        offset += size;
        continue;
      }
    }
    kept.add(command);
    offset += size;
  }
  if (removed.isEmpty) {
    return (macho: macho, removed: removed);
  }
  final out = Uint8List.fromList(macho)..fillRange(32, 32 + commandsSize, 0);
  var at = 32;
  for (final command in kept) {
    out.setRange(at, at + command.length, command);
    at += command.length;
  }
  ByteData.sublistView(out)
    ..setUint32(16, kept.length, Endian.little)
    ..setUint32(20, at - 32, Endian.little);
  return (macho: out, removed: removed);
}

/// Sets the install name (`LC_ID_DYLIB`) of a 64-bit little-endian Mach-O dynamic library, which is what
/// `install_name_tool -id` does and Linux lacks (ADR-0010). The name is written in place, in the room the load command
/// already has, and the rest of the file is not touched. A name that does not fit is an error: `lld` names the library
/// by the path it was told to write it to, which is longer than the `@rpath/<name>.framework/<name>` it gets here.
Uint8List setInstallName(Uint8List macho, String name) {
  final data = ByteData.sublistView(macho);
  if (macho.length < 32 || data.getUint32(0, Endian.little) != _magic64) {
    throw const FormatException('not a 64-bit little-endian Mach-O file');
  }
  var offset = 32;
  for (var i = data.getUint32(16, Endian.little); i > 0; i--) {
    final command = data.getUint32(offset, Endian.little);
    final size = data.getUint32(offset + 4, Endian.little);
    if (command == _lcIdDylib) {
      final start = offset + data.getUint32(offset + 8, Endian.little);
      final room = offset + size - start;
      final bytes = utf8.encode(name);
      if (bytes.length + 1 > room) {
        throw FormatException(
          'the install name needs ${bytes.length + 1} bytes and the library has room for $room',
        );
      }
      return Uint8List.fromList(macho)
        ..fillRange(start, offset + size, 0)
        ..setRange(start, start + bytes.length, bytes);
    }
    offset += size;
  }
  throw const FormatException('no LC_ID_DYLIB: not a dynamic library');
}
