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
