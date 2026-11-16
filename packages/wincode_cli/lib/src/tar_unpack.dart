import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// An archive that [unpackTarGz] will not unpack: it is not a tar.gz that winCode reads, it is larger than the limits, or
/// an entry could write outside the folder (a path with `..`, an absolute path, a link).
class TarRefused implements Exception {
  TarRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Unpacks the `.tar.gz` file [archive] into the folder [into], which must exist and should be empty, and returns the
/// number of files written (ADR-0013, phase 3a.1: the pinned zsign source, after its SHA-256 was checked).
///
/// This is `tar -xzf` for a source archive and nothing else, so what a source archive never needs is refused instead of
/// handled: every entry must be a regular file or a folder whose path stays under [into] (no `..`, no absolute path or
/// drive letter, no backslash), and a link of any kind, a device, a FIFO or any other type is refused. Nothing is
/// written through a link, because none is ever made. Ownership and modes are not restored: the build runs no file of
/// the archive. The tar is read by hand (ustar, the `prefix` field, pax and GNU long names, which `git archive` and GNU
/// tar write), because the repository adds no archive package for one reader.
///
/// The unpacked size is held in memory, so [maxBytes] limits it (a gzip file can claim a thousand times its size), and
/// [maxEntries] the number of entries. Whatever fails throws [TarRefused], possibly after some files were written: the
/// caller deletes [into].
Future<int> unpackTarGz(
  File archive,
  Directory into, {
  int maxBytes = 256 << 20,
  int maxEntries = 20000,
}) async {
  final tar = await _gunzip(archive, maxBytes);
  final root = into.absolute.path;
  final s = Platform.pathSeparator;
  var pos = 0;
  var entries = 0;
  var files = 0;
  var ended = false;
  var pax = <String, String>{};
  String? longName;
  while (pos + 512 <= tar.length) {
    final header = Uint8List.sublistView(tar, pos, pos + 512);
    if (header.every((b) => b == 0)) {
      ended = true;
      break;
    }
    _checkSum(header);
    final size = _octal(header, 124, 12, 'size');
    final start = pos + 512;
    if (start + size > tar.length) {
      throw TarRefused('the archive ends inside an entry');
    }
    final body = Uint8List.sublistView(tar, start, start + size);
    pos = start + (size + 511) ~/ 512 * 512;
    final type = String.fromCharCode(header[156] == 0 ? 0x30 : header[156]);
    switch (type) {
      case 'g': // Global pax header: git archive writes the commit as a comment.
        continue;
      case 'x': // Pax header of the next entry: its path.
        pax = _pax(body);
        continue;
      case 'L': // GNU long name of the next entry.
        longName = _text(body, 0, body.length);
        continue;
    }
    if (++entries > maxEntries) {
      throw TarRefused('the archive has more than $maxEntries entries');
    }
    final prefix = _text(header, 345, 155);
    final named = _text(header, 0, 100);
    final raw =
        pax['path'] ??
        longName ??
        (prefix.isEmpty || !_isUstar(header) ? named : '$prefix/$named');
    pax = {};
    longName = null;
    final name = _cleanName(raw);
    if (type == '1' || type == '2') {
      throw TarRefused(
        'the archive holds a link, $raw, which winCode does not unpack',
      );
    }
    if (type != '0' && type != '7' && type != '5') {
      throw TarRefused(
        'the archive holds an entry of type "$type", $raw, which winCode '
        'does not unpack',
      );
    }
    if (name == null) {
      continue; // The folder itself, "./".
    }
    final path = '$root$s${name.replaceAll('/', s)}';
    // Belt and braces: _cleanName leaves no way out, and this checks the result.
    if (!path.startsWith('$root$s')) {
      throw TarRefused('$raw would be written outside the folder');
    }
    try {
      if (type == '5') {
        Directory(path).createSync(recursive: true);
      } else {
        File(path)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(body);
        files++;
      }
    } on FileSystemException catch (e) {
      throw TarRefused('cannot write $raw: ${e.osError?.message ?? e.message}');
    }
  }
  if (!ended) {
    throw TarRefused('the archive has no end: it is cut off');
  }
  return files;
}

/// The bytes of the gzip file [archive], at most [maxBytes] of them.
Future<Uint8List> _gunzip(File archive, int maxBytes) async {
  final bytes = BytesBuilder(copy: false);
  try {
    await for (final chunk in archive.openRead().transform(gzip.decoder)) {
      bytes.add(chunk);
      if (bytes.length > maxBytes) {
        throw TarRefused('the archive unpacks to more than $maxBytes bytes');
      }
    }
  } on TarRefused {
    rethrow;
  } on Object catch (e) {
    throw TarRefused(
      'the file is not a readable gzip archive (${e is FormatException ? e.message : e.runtimeType})',
    );
  }
  return bytes.takeBytes();
}

/// The path [raw] as a relative one with `/` between the names, or null for the archive's own folder. Refuses a path that
/// could leave the folder it is unpacked into.
String? _cleanName(String raw) {
  if (raw.contains('\u0000') || raw.contains(r'\')) {
    throw TarRefused(
      'the archive names a path with a backslash or a NUL: $raw',
    );
  }
  if (raw.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(raw)) {
    throw TarRefused('the archive names an absolute path: $raw');
  }
  final parts = raw.split('/').where((p) => p.isNotEmpty && p != '.').toList();
  if (parts.contains('..')) {
    throw TarRefused('the archive names a path that leaves the folder: $raw');
  }
  return parts.isEmpty ? null : parts.join('/');
}

bool _isUstar(Uint8List header) => _text(header, 257, 5) == 'ustar';

void _checkSum(Uint8List header) {
  var sum = 0;
  for (var i = 0; i < 512; i++) {
    sum += i >= 148 && i < 156 ? 0x20 : header[i];
  }
  if (sum != _octal(header, 148, 8, 'checksum')) {
    throw TarRefused('an entry header has a wrong checksum: this is not a tar');
  }
}

/// The text in the field at [start], up to its first NUL.
String _text(Uint8List bytes, int start, int length) {
  var end = start;
  while (end < start + length && bytes[end] != 0) {
    end++;
  }
  return utf8.decode(
    Uint8List.sublistView(bytes, start, end),
    allowMalformed: true,
  );
}

int _octal(Uint8List header, int start, int length, String what) {
  if (header[start] & 0x80 != 0) {
    throw TarRefused(
      'an entry has a $what in a form that winCode does not read',
    );
  }
  final text = _text(header, start, length).trim();
  final value = text.isEmpty ? 0 : int.tryParse(text, radix: 8);
  if (value == null) {
    throw TarRefused('an entry has a $what that is not a number: $text');
  }
  return value;
}

/// The records `<length> <key>=<value>\n` of a pax header.
Map<String, String> _pax(Uint8List body) {
  final records = <String, String>{};
  var i = 0;
  while (i < body.length) {
    final space = body.indexOf(0x20, i);
    final length = space < 0
        ? null
        : int.tryParse(
            ascii.decode(body.sublist(i, space), allowInvalid: true),
          );
    if (length == null || length < 1 || i + length > body.length) {
      throw TarRefused('a pax header of the archive is not well formed');
    }
    final record = utf8.decode(
      body.sublist(space + 1, i + length - 1),
      allowMalformed: true,
    );
    final eq = record.indexOf('=');
    if (eq > 0) {
      records[record.substring(0, eq)] = record.substring(eq + 1);
    }
    i += length;
  }
  return records;
}
