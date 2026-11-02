import 'dart:typed_data';

/// A 64-bit little-endian Mach-O header with an `LC_RPATH` for each of [paths], then an `LC_UUID`, then 8 bytes of
/// "code".
Uint8List withRpaths(List<String> paths) {
  void u32(BytesBuilder b, int v) =>
      b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  final commands = BytesBuilder();
  for (final path in paths) {
    final size = (12 + path.length + 1 + 7) & ~7;
    u32(commands, 0x8000001C);
    u32(commands, size);
    u32(commands, 12);
    commands
      ..add(path.codeUnits)
      ..add(Uint8List(size - 12 - path.length));
  }
  u32(commands, 0x1B);
  u32(commands, 24);
  commands.add(Uint8List(16));
  final body = commands.toBytes();
  final out = BytesBuilder();
  for (final v in [
    0xFEEDFACF,
    0x0100000C,
    0,
    2,
    paths.length + 1,
    body.length,
    0,
    0,
  ]) {
    u32(out, v);
  }
  out
    ..add(body)
    ..add(List.generate(8, (i) => 0xB0 + i));
  return out.toBytes();
}

/// A 64-bit little-endian Mach-O header with a dylib load command for each of [libraries], in that order. Each one is an
/// install name and its command: `0xC` for `LC_LOAD_DYLIB`, `0x80000018` for a weak one.
///
/// When [bindOrdinals] is given there is also an `LC_DYLD_CHAINED_FIXUPS` command whose import table, in [importFormat]
/// 1, 2 or 3, holds one symbol for each ordinal: the 1-based position of the library it binds to.
Uint8List withLibraries(
  List<(String, int)> libraries, {
  List<int>? bindOrdinals,
  int importFormat = 1,
}) {
  ByteData word(int bytes) => ByteData(bytes);
  void u32(BytesBuilder b, int v) =>
      b.add((word(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u64(BytesBuilder b, int v) =>
      b.add((word(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());
  final commands = BytesBuilder();
  for (final (name, command) in libraries) {
    final size = (24 + name.length + 1 + 7) & ~7;
    u32(commands, command);
    u32(commands, size);
    u32(commands, 24);
    for (var i = 0; i < 3; i++) {
      u32(commands, 0);
    }
    commands
      ..add(name.codeUnits)
      ..add(Uint8List(size - 24 - name.length));
  }
  final entry = const {1: 4, 2: 8, 3: 16}[importFormat]!;
  final blob = BytesBuilder();
  if (bindOrdinals != null) {
    for (final v in [0, 0, 28, 28 + entry * bindOrdinals.length]) {
      u32(blob, v); // version, starts_offset, imports_offset, symbols_offset
    }
    u32(blob, bindOrdinals.length);
    u32(blob, importFormat);
    u32(blob, 0);
    for (final ordinal in bindOrdinals) {
      switch (importFormat) {
        case 1:
          u32(blob, ordinal & 0xFF);
        case 2:
          u32(blob, ordinal & 0xFF);
          u32(blob, 0);
        default:
          u64(blob, ordinal & 0xFFFF);
          u64(blob, 0);
      }
    }
    blob.addByte(0); // the symbol names: one empty string
  }
  final fixupsCommand = BytesBuilder();
  if (bindOrdinals != null) {
    u32(fixupsCommand, 0x80000034);
    u32(fixupsCommand, 16);
    u32(
      fixupsCommand,
      32 + commands.length + 16,
    ); // the blob follows the load commands
    u32(fixupsCommand, blob.length);
  }
  final body = (BytesBuilder()
    ..add(commands.toBytes())
    ..add(fixupsCommand.toBytes()));
  final out = BytesBuilder();
  for (final v in [
    0xFEEDFACF,
    0x0100000C,
    0,
    2,
    libraries.length + (bindOrdinals == null ? 0 : 1),
    body.length,
    0,
    0,
  ]) {
    u32(out, v);
  }
  out
    ..add(body.toBytes())
    ..add(blob.toBytes());
  return out.toBytes();
}
