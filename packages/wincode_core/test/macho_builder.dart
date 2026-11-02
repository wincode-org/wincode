import 'dart:typed_data';

void _u32(BytesBuilder b, int v) =>
    b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());

void _u64(BytesBuilder b, int v) =>
    b.add((ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());

/// A 64-bit little-endian Mach-O header with an `LC_RPATH` for each of [paths], then an `LC_UUID`, then 8 bytes of
/// "code".
Uint8List withRpaths(List<String> paths) {
  final commands = BytesBuilder();
  for (final path in paths) {
    final size = (12 + path.length + 1 + 7) & ~7;
    _u32(commands, 0x8000001C);
    _u32(commands, size);
    _u32(commands, 12);
    commands
      ..add(path.codeUnits)
      ..add(Uint8List(size - 12 - path.length));
  }
  _u32(commands, 0x1B);
  _u32(commands, 24);
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
    _u32(out, v);
  }
  out
    ..add(body)
    ..add(List.generate(8, (i) => 0xB0 + i));
  return out.toBytes();
}

/// `major.minor[.patch]` packed in nibbles, as Mach-O stores versions.
int _packed(String version) {
  final parts = [...version.split('.').map(int.parse), 0, 0];
  return parts[0] << 16 | parts[1] << 8 | parts[2];
}

/// A 64-bit little-endian Mach-O header whose load commands are, in this order:
///
/// - an iOS `LC_BUILD_VERSION` with [minOS] and [sdk], when [minOS] is given;
/// - a dylib load command for each of [libraries]: an install name and its command, `0xC` for `LC_LOAD_DYLIB` or
///   `0x80000018` for a weak one;
/// - an `LC_RPATH` for each of [rpaths];
/// - when [bindOrdinals] is given, an `LC_DYLD_CHAINED_FIXUPS` whose import table, in [importFormat] 1, 2 or 3, holds one
///   symbol for each ordinal (the 1-based position of the library it binds to), named by [symbols] (empty names when
///   null) and weak at the positions in [weakImports].
Uint8List withLibraries(
  List<(String, int)> libraries, {
  List<int>? bindOrdinals,
  List<String>? symbols,
  Set<int> weakImports = const {},
  int importFormat = 1,
  String? minOS,
  String sdk = '26.5',
  List<String> rpaths = const [],
}) {
  final commands = BytesBuilder();
  var count = 0;
  if (minOS != null) {
    for (final v in [0x32, 24, 2, _packed(minOS), _packed(sdk), 0]) {
      _u32(commands, v);
    }
    count++;
  }
  for (final (name, command) in libraries) {
    final size = (24 + name.length + 1 + 7) & ~7;
    for (final v in [command, size, 24, 0, 0, 0]) {
      _u32(commands, v);
    }
    commands
      ..add(name.codeUnits)
      ..add(Uint8List(size - 24 - name.length));
    count++;
  }
  for (final path in rpaths) {
    final size = (12 + path.length + 1 + 7) & ~7;
    for (final v in [0x8000001C, size, 12]) {
      _u32(commands, v);
    }
    commands
      ..add(path.codeUnits)
      ..add(Uint8List(size - 12 - path.length));
    count++;
  }
  final blob = BytesBuilder();
  if (bindOrdinals != null) {
    final names = symbols ?? List.filled(bindOrdinals.length, '');
    final entry = const {1: 4, 2: 8, 3: 16}[importFormat]!;
    for (final v in [0, 0, 28, 28 + entry * bindOrdinals.length]) {
      _u32(blob, v); // version, starts_offset, imports_offset, symbols_offset
    }
    _u32(blob, bindOrdinals.length);
    _u32(blob, importFormat);
    _u32(blob, 0); // uncompressed names
    final strings = BytesBuilder();
    for (var i = 0; i < bindOrdinals.length; i++) {
      final weak = weakImports.contains(i) ? 1 : 0;
      final name = strings.length;
      strings
        ..add(names[i].codeUnits)
        ..addByte(0);
      switch (importFormat) {
        case 1:
          _u32(blob, bindOrdinals[i] & 0xFF | weak << 8 | name << 9);
        case 2:
          _u32(blob, bindOrdinals[i] & 0xFF | weak << 8 | name << 9);
          _u32(blob, 0);
        default:
          _u64(blob, bindOrdinals[i] & 0xFFFF | weak << 16 | name << 32);
          _u64(blob, 0);
      }
    }
    blob.add(strings.toBytes());
    // The blob follows the load commands, this one included.
    for (final v in [0x80000034, 16, 32 + commands.length + 16, blob.length]) {
      _u32(commands, v);
    }
    count++;
  }
  final body = commands.toBytes();
  final out = BytesBuilder();
  for (final v in [0xFEEDFACF, 0x0100000C, 0, 2, count, body.length, 0, 0]) {
    _u32(out, v);
  }
  out
    ..add(body)
    ..add(blob.toBytes());
  return out.toBytes();
}
