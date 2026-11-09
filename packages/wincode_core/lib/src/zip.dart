import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

typedef _Entry = ({
  int flags,
  int method,
  int crc,
  int compressedSize,
  int size,
  int offset,
});

/// A zip archive, such as an IPA, opened to read entries by name. Only the central directory is read when it opens.
///
/// Entries may be stored or deflated. Zip64 archives (over 4 GB or 65,535 entries), encrypted entries and archives on
/// several disks are refused with a [FormatException]: an IPA made by zsign or by `zip` has none of them.
class ZipArchive {
  ZipArchive._(this._file, this._entries);

  /// Opens [file]. Throws a [FormatException] when it is not a zip archive that can be read here, and a
  /// [FileSystemException] when it cannot be opened.
  factory ZipArchive.open(File file) {
    final raf = file.openSync();
    try {
      return ZipArchive._(raf, _centralDirectory(raf));
    } on Object {
      raf.closeSync();
      rethrow;
    }
  }

  final RandomAccessFile _file;
  final Map<String, _Entry> _entries;

  /// The names of the entries, in the order of the central directory. A folder's name ends in `/`.
  Iterable<String> get names => _entries.keys;

  /// The contents of the entry [name], checked against its size and CRC-32. Throws an [ArgumentError] when there is no
  /// such entry and a [FormatException] when it cannot be read.
  Uint8List read(String name) {
    final entry =
        _entries[name] ??
        (throw ArgumentError.value(name, 'name', 'no such entry'));
    if (entry.flags & 1 != 0) {
      throw FormatException('$name is encrypted');
    }
    final local = _bytes(_file, entry.offset, 30);
    if (_u32(local, 0) != 0x04034B50) {
      throw FormatException('the local header of $name is missing');
    }
    final start = entry.offset + 30 + _u16(local, 26) + _u16(local, 28);
    final stored = _bytes(_file, start, entry.compressedSize);
    final Uint8List data;
    switch (entry.method) {
      case 0:
        data = stored;
      case 8:
        try {
          data = Uint8List.fromList(ZLibDecoder(raw: true).convert(stored));
        } on FormatException {
          throw FormatException('$name is damaged');
        }
      default:
        throw FormatException('$name uses compression method ${entry.method}');
    }
    if (data.length != entry.size || crc32(data) != entry.crc) {
      throw FormatException('$name is damaged');
    }
    return data;
  }

  void close() => _file.closeSync();
}

Map<String, _Entry> _centralDirectory(RandomAccessFile file) {
  const notZip = FormatException('not a zip archive');
  final length = file.lengthSync();
  // The end record is 22 bytes, followed by a comment of at most 65,535 bytes.
  final tailLength = length < 22 + 0xFFFF ? length : 22 + 0xFFFF;
  final tail = _bytes(file, length - tailLength, tailLength);
  var end = -1;
  for (var i = tail.length - 22; i >= 0; i--) {
    if (_u32(tail, i) == 0x06054B50 &&
        i + 22 + _u16(tail, i + 20) == tail.length) {
      end = i;
      break;
    }
  }
  if (end < 0) {
    throw notZip;
  }
  final count = _u16(tail, end + 10);
  final size = _u32(tail, end + 12);
  final offset = _u32(tail, end + 16);
  if (count == 0xFFFF ||
      size == 0xFFFFFFFF ||
      offset == 0xFFFFFFFF ||
      (end >= 20 && _u32(tail, end - 20) == 0x07064B50)) {
    throw const FormatException('a Zip64 archive, which is not read here');
  }
  if (_u16(tail, end + 4) != 0 ||
      _u16(tail, end + 6) != 0 ||
      _u16(tail, end + 8) != count) {
    throw const FormatException(
      'an archive on several disks, which is not read here',
    );
  }
  if (offset + size > length - tailLength + end) {
    throw notZip;
  }
  final directory = _bytes(file, offset, size);
  final entries = <String, _Entry>{};
  var at = 0;
  for (var i = 0; i < count; i++) {
    if (at + 46 > directory.length || _u32(directory, at) != 0x02014B50) {
      throw notZip;
    }
    final nameLength = _u16(directory, at + 28);
    final name = utf8.decode(
      Uint8List.sublistView(directory, at + 46, at + 46 + nameLength),
      allowMalformed: true,
    );
    final entry = (
      flags: _u16(directory, at + 8),
      method: _u16(directory, at + 10),
      crc: _u32(directory, at + 16),
      compressedSize: _u32(directory, at + 20),
      size: _u32(directory, at + 24),
      offset: _u32(directory, at + 42),
    );
    if (entry.compressedSize == 0xFFFFFFFF ||
        entry.size == 0xFFFFFFFF ||
        entry.offset == 0xFFFFFFFF) {
      throw const FormatException('a Zip64 archive, which is not read here');
    }
    entries[name] = entry;
    at += 46 + nameLength + _u16(directory, at + 30) + _u16(directory, at + 32);
  }
  return entries;
}

/// [count] bytes of [file] from [offset]; a [FormatException] when the file ends before.
Uint8List _bytes(RandomAccessFile file, int offset, int count) {
  file.setPositionSync(offset);
  final bytes = file.readSync(count);
  if (bytes.length != count) {
    throw const FormatException('the archive is cut short');
  }
  return bytes;
}

int _u16(Uint8List b, int at) => b[at] | b[at + 1] << 8;

int _u32(Uint8List b, int at) => _u16(b, at) | _u16(b, at + 2) << 16;

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

/// The CRC-32 of [bytes], as zip archives store it.
int crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
