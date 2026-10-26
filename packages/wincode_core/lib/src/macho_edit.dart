import 'dart:convert';
import 'dart:typed_data';

const _magic64 = 0xFEEDFACF;
const _lcIdDylib = 0xD;

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
