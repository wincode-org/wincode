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
  int nameLength,
});

/// What a [ZipArchive] accepts. An archive over a limit is refused with a [FormatException], before anything that its
/// headers claim is allocated or inflated.
class ZipLimits {
  const ZipLimits({
    this.entries = 50000,
    this.directoryBytes = 32 << 20,
    this.totalSize = 8 << 30,
    this.readSize = 64 << 20,
  });

  /// The most entries in the central directory. An IPA of a large Flutter app holds a few thousand.
  final int entries;

  /// The most bytes in the central directory, which is read whole.
  final int directoryBytes;

  /// The most bytes that all the entries together claim to hold when inflated.
  final int totalSize;

  /// The most bytes of one entry, or of one range of it, that [ZipArchive.read] and [ZipArchive.readRange] keep in
  /// memory. An entry can be larger: [ZipArchive.readRange] streams it.
  final int readSize;
}

/// A zip archive, such as an IPA, opened to read entries by name. Only the central directory is read when it opens.
///
/// Entries may be stored or deflated. Zip64 archives (over 4 GB or 65,535 entries), encrypted entries and archives on
/// several disks are refused with a [FormatException]: an IPA made by zsign or by `zip` has none of them. So are an
/// archive over the [ZipLimits], with a name that is a duplicate or leaves its folder (`../`), or with entries whose
/// data overlap.
///
/// An entry is inflated in chunks and never beyond the size its header claims, so a lying header cannot make it grow
/// without bound; its size and CRC-32 are checked at the end.
class ZipArchive {
  ZipArchive._(this._file, this._entries, this.limits);

  /// Opens [file]. Throws a [FormatException] when it is not a zip archive that can be read here, and a
  /// [FileSystemException] when it cannot be opened.
  factory ZipArchive.open(File file, {ZipLimits limits = const ZipLimits()}) {
    final raf = file.openSync();
    try {
      return ZipArchive._(raf, _centralDirectory(raf, limits), limits);
    } on Object {
      raf.closeSync();
      rethrow;
    }
  }

  final RandomAccessFile _file;
  final Map<String, _Entry> _entries;
  final ZipLimits limits;

  /// The names of the entries, in the order of the central directory. A folder's name ends in `/`.
  Iterable<String> get names => _entries.keys;

  /// The contents of the entry [name], checked against its size and CRC-32. Throws an [ArgumentError] when there is no
  /// such entry and a [FormatException] when it cannot be read, or claims more than [ZipLimits.readSize].
  Uint8List read(String name) {
    final entry = _entry(name);
    _capped(name, entry.size);
    final out = BytesBuilder(copy: false);
    _stream(name, entry, out.add);
    return out.takeBytes();
  }

  /// [length] bytes of the entry [name] from [start]: the rest of the entry is inflated, checked and dropped, so
  /// memory holds the range only. For a header and a signature at the end of a large executable.
  Uint8List readRange(String name, int start, int length) {
    final entry = _entry(name);
    _capped(name, length);
    if (start < 0 || length < 0 || start + length > entry.size) {
      throw FormatException('$name is shorter than expected');
    }
    final out = BytesBuilder(copy: false);
    var at = 0;
    _stream(name, entry, (chunk) {
      final from = start - at;
      final to = start + length - at;
      if (to > 0 && from < chunk.length) {
        out.add(
          Uint8List.sublistView(
            chunk,
            from < 0 ? 0 : from,
            to < chunk.length ? to : chunk.length,
          ),
        );
      }
      at += chunk.length;
    });
    return out.takeBytes();
  }

  /// The size of the entry [name] as its header claims.
  int sizeOf(String name) => _entry(name).size;

  void close() => _file.closeSync();

  _Entry _entry(String name) =>
      _entries[name] ??
      (throw ArgumentError.value(name, 'name', 'no such entry'));

  void _capped(String name, int bytes) {
    if (bytes > limits.readSize) {
      throw FormatException(
        '$name asks for $bytes bytes, more than the ${limits.readSize} that are read',
      );
    }
  }

  /// Gives [onData] the inflated contents of [entry] chunk by chunk, then checks its size and CRC-32.
  void _stream(String name, _Entry entry, void Function(Uint8List) onData) {
    if (entry.flags & 1 != 0) {
      throw FormatException('$name is encrypted');
    }
    final local = _bytes(_file, entry.offset, 30);
    if (_u32(local, 0) != 0x04034B50) {
      throw FormatException('the local header of $name is missing');
    }
    final start = entry.offset + 30 + _u16(local, 26) + _u16(local, 28);
    if (start + entry.compressedSize > _file.lengthSync()) {
      throw const FormatException('the archive is cut short');
    }
    var size = 0;
    var crc = 0xFFFFFFFF;
    void produce(List<int> data) {
      final chunk = data is Uint8List ? data : Uint8List.fromList(data);
      size += chunk.length;
      if (size > entry.size) {
        throw _TooLarge();
      }
      crc = _crcUpdate(crc, chunk);
      onData(chunk);
    }

    try {
      switch (entry.method) {
        case 0:
          _chunks(start, entry.compressedSize, produce);
        case 8:
          final input = ZLibDecoder(raw: true)
              .startChunkedConversion(_Inflate(produce));
          _chunks(start, entry.compressedSize, input.add);
          input.close();
        default:
          throw FormatException(
            '$name uses compression method ${entry.method}',
          );
      }
    } on _TooLarge {
      throw FormatException('$name holds more than its header says');
    } on _CutShort {
      throw const FormatException('the archive is cut short');
    } on FormatException catch (e) {
      // A decoder's error means that the data are damaged; ours already say what is wrong.
      throw entry.method == 8 ? FormatException('$name is damaged') : e;
    }
    if (size != entry.size || (crc ^ 0xFFFFFFFF) != entry.crc) {
      throw FormatException('$name is damaged');
    }
  }

  /// Reads [count] bytes of the file from [offset] in chunks of 64 KiB.
  void _chunks(int offset, int count, void Function(Uint8List) onChunk) {
    _file.setPositionSync(offset);
    for (var left = count; left > 0;) {
      final chunk = _file.readSync(left < 65536 ? left : 65536);
      if (chunk.isEmpty) {
        throw _CutShort();
      }
      left -= chunk.length;
      onChunk(chunk);
    }
  }
}

/// Thrown from the decoder's callbacks, whose own errors are [FormatException]s too.
class _TooLarge implements Exception {}

class _CutShort implements Exception {}

class _Inflate implements Sink<List<int>> {
  _Inflate(this._onData);

  final void Function(List<int>) _onData;

  @override
  void add(List<int> data) => _onData(data);

  @override
  void close() {}
}

Map<String, _Entry> _centralDirectory(RandomAccessFile file, ZipLimits limits) {
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
  if (count > limits.entries) {
    throw FormatException(
      'it holds $count entries, more than the ${limits.entries} that are read',
    );
  }
  if (size > limits.directoryBytes) {
    throw FormatException(
      'its directory is $size bytes, more than the ${limits.directoryBytes} that are read',
    );
  }
  final directoryEnd = length - tailLength + end;
  if (offset + size > directoryEnd) {
    throw notZip;
  }
  final directory = _bytes(file, offset, size);
  final entries = <String, _Entry>{};
  var claimed = 0;
  var at = 0;
  for (var i = 0; i < count; i++) {
    if (at + 46 > directory.length || _u32(directory, at) != 0x02014B50) {
      throw notZip;
    }
    final nameLength = _u16(directory, at + 28);
    if (at + 46 + nameLength > directory.length) {
      throw notZip;
    }
    final name = utf8.decode(
      Uint8List.sublistView(directory, at + 46, at + 46 + nameLength),
      allowMalformed: true,
    );
    if (_unsafe(name)) {
      throw FormatException(
        'an entry is named "$name", which leaves its folder',
      );
    }
    final entry = (
      flags: _u16(directory, at + 8),
      method: _u16(directory, at + 10),
      crc: _u32(directory, at + 16),
      compressedSize: _u32(directory, at + 20),
      size: _u32(directory, at + 24),
      offset: _u32(directory, at + 42),
      nameLength: nameLength,
    );
    if (entry.compressedSize == 0xFFFFFFFF ||
        entry.size == 0xFFFFFFFF ||
        entry.offset == 0xFFFFFFFF) {
      throw const FormatException('a Zip64 archive, which is not read here');
    }
    if (entries.containsKey(name)) {
      throw FormatException('the entry "$name" occurs twice');
    }
    claimed += entry.size;
    if (claimed > limits.totalSize) {
      throw FormatException(
        'its entries claim more than the ${limits.totalSize} bytes that are read',
      );
    }
    entries[name] = entry;
    at += 46 + nameLength + _u16(directory, at + 30) + _u16(directory, at + 32);
  }
  // The data of an entry follow its local header, and no two entries may share bytes: that is how an archive is made
  // to inflate to far more than its size.
  final byOffset = entries.entries.toList()
    ..sort((a, b) => a.value.offset.compareTo(b.value.offset));
  for (var i = 0; i < byOffset.length; i++) {
    final e = byOffset[i].value;
    final dataEnd = e.offset + 30 + e.nameLength + e.compressedSize;
    final next = i + 1 < byOffset.length
        ? byOffset[i + 1].value.offset
        : offset;
    if (dataEnd > next) {
      throw FormatException(
        'the data of "${byOffset[i].key}" overlap the next entry or the directory',
      );
    }
  }
  return entries;
}

/// Whether [name] is absolute, has a `..` part, a backslash, a drive letter or a NUL.
bool _unsafe(String name) =>
    name.startsWith('/') ||
    name.contains('\\') ||
    name.contains('\u0000') ||
    RegExp(r'^[A-Za-z]:').hasMatch(name) ||
    name.split('/').contains('..');

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

int _crcUpdate(int crc, List<int> bytes) {
  var c = crc;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c;
}

/// The CRC-32 of [bytes], as zip archives store it.
int crc32(List<int> bytes) => _crcUpdate(0xFFFFFFFF, bytes) ^ 0xFFFFFFFF;
