import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

/// A property-list dictionary. Keys keep the order they were added in.
typedef PlistMap = Map<String, Object?>;

/// Reads an XML property list. A dict becomes a [PlistMap], an array a `List<Object?>`, `integer` an `int`,
/// `real` a `double`, `date` a `DateTime` and `data` a [Uint8List]. Throws a [FormatException] when [source] is not one.
Object? parsePlist(String source) => _malformed(() {
  final root = XmlDocument.parse(source).rootElement;
  if (root.name.local != 'plist') {
    throw const FormatException(
      'not a property list: the root element is not <plist>',
    );
  }
  return _read(root.childElements.single);
});

/// Reads a property list in either form: XML, or the binary `bplist00` that Xcode and the Darwin SDK often use. Throws
/// a [FormatException] when [bytes] are not one.
Object? parsePlistBytes(Uint8List bytes) {
  const magic = [0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x30, 0x30];
  if (bytes.length > 8 &&
      [for (var i = 0; i < 8; i++) bytes[i]].toString() == magic.toString()) {
    return _malformed(_BinaryReader(bytes).read);
  }
  return parsePlist(utf8.decode(bytes));
}

/// [read], with the errors that damaged input causes (an offset past the end, a key that is not text, an element
/// with no or two values) turned into a [FormatException], as for any other property list that cannot be read.
Object? _malformed(Object? Function() read) {
  try {
    return read();
  } on RangeError {
    throw const FormatException('the property list is cut short or damaged');
  } on StateError {
    throw const FormatException('the property list is damaged');
  } on TypeError {
    throw const FormatException('the property list is damaged');
  }
}

/// A reader for binary property lists (Apple's `bplist00`): the trailer gives the object table, and each object
/// starts with a marker byte whose high nibble is the type and low nibble the size.
class _BinaryReader {
  _BinaryReader(this.bytes) : data = ByteData.sublistView(bytes) {
    if (bytes.length < 40) {
      throw const FormatException('binary property list: too short');
    }
    final trailer = bytes.length - 32;
    offsetSize = bytes[trailer + 6];
    refSize = bytes[trailer + 7];
    count = _uint(trailer + 8, 8);
    top = _uint(trailer + 16, 8);
    table = _uint(trailer + 24, 8);
  }

  final Uint8List bytes;
  final ByteData data;
  late final int offsetSize, refSize, count, top, table;

  int _uint(int at, int size) {
    var value = 0;
    for (var i = 0; i < size; i++) {
      value = (value << 8) | bytes[at + i];
    }
    return value;
  }

  Object? read() => _object(top);

  Object? _object(int index) {
    if (index >= count) {
      throw const FormatException(
        'binary property list: an object reference is out of range',
      );
    }
    final at = _uint(table + index * offsetSize, offsetSize);
    final marker = bytes[at];
    final type = marker >> 4;
    var size = marker & 0xf;
    var start = at + 1;
    // A size of 15 means the real size follows as an integer object.
    if (size == 0xf &&
        type != 0x0 &&
        type != 0x1 &&
        type != 0x2 &&
        type != 0x3 &&
        type != 0x8) {
      final width = 1 << (bytes[start] & 0xf);
      size = _uint(start + 1, width);
      start += 1 + width;
    }
    switch (type) {
      case 0x0:
        return switch (marker) {
          0x08 => false,
          0x09 => true,
          _ => null,
        };
      case 0x1:
        return _uint(start, 1 << size);
      case 0x2:
        return size == 2 ? data.getFloat32(start) : data.getFloat64(start);
      case 0x3:
        return DateTime.utc(
          2001,
        ).add(Duration(microseconds: (data.getFloat64(start) * 1e6).round()));
      case 0x4:
        return Uint8List.sublistView(bytes, start, start + size);
      case 0x5:
        return latin1
            .decode(bytes, allowInvalid: true)
            .substring(start, start + size);
      case 0x6:
        return String.fromCharCodes([
          for (var i = 0; i < size; i++) data.getUint16(start + 2 * i),
        ]);
      case 0xa:
        return <Object?>[
          for (var i = 0; i < size; i++)
            _object(_uint(start + i * refSize, refSize)),
        ];
      case 0xd:
        return <String, Object?>{
          for (var i = 0; i < size; i++)
            _object(_uint(start + i * refSize, refSize))! as String: _object(
              _uint(start + (size + i) * refSize, refSize),
            ),
        };
    }
    throw FormatException(
      'binary property list: unsupported object type 0x${type.toRadixString(16)}',
    );
  }
}

Object? _read(XmlElement element) {
  switch (element.name.local) {
    case 'dict':
      final children = element.childElements.toList();
      if (children.length.isOdd) {
        throw const FormatException('a <dict> has a key without a value');
      }
      return <String, Object?>{
        for (var i = 0; i < children.length; i += 2)
          _key(children[i]): _read(children[i + 1]),
      };
    case 'array':
      return <Object?>[for (final child in element.childElements) _read(child)];
    case 'string':
      return element.innerText;
    case 'integer':
      return int.parse(element.innerText.trim());
    case 'real':
      return double.parse(element.innerText.trim());
    case 'true':
      return true;
    case 'false':
      return false;
    case 'date':
      return DateTime.parse(element.innerText.trim());
    case 'data':
      return base64.decode(element.innerText.replaceAll(RegExp(r'\s'), ''));
  }
  throw FormatException(
    'unknown property list element <${element.name.local}>',
  );
}

String _key(XmlElement element) {
  if (element.name.local != 'key') {
    throw FormatException('expected <key>, found <${element.name.local}>');
  }
  return element.innerText;
}

/// Writes [value] as an XML property list. Dictionary keys are sorted, so the same data always gives the same bytes.
String writePlist(Object? value) {
  final out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    )
    ..writeln('<plist version="1.0">');
  _write(out, value, 0);
  out.writeln('</plist>');
  return out.toString();
}

void _write(StringBuffer out, Object? value, int depth) {
  final pad = '\t' * depth;
  switch (value) {
    case final Map<Object?, Object?> map:
      if (map.isEmpty) {
        out.writeln('$pad<dict/>');
        return;
      }
      out.writeln('$pad<dict>');
      for (final key in (map.keys.cast<String>().toList()..sort())) {
        out.writeln('$pad\t<key>${_escape(key)}</key>');
        _write(out, map[key], depth + 1);
      }
      out.writeln('$pad</dict>');
    case final Uint8List bytes:
      out.writeln('$pad<data>${base64.encode(bytes)}</data>');
    case final List<Object?> list:
      if (list.isEmpty) {
        out.writeln('$pad<array/>');
        return;
      }
      out.writeln('$pad<array>');
      for (final item in list) {
        _write(out, item, depth + 1);
      }
      out.writeln('$pad</array>');
    case final String text:
      out.writeln('$pad<string>${_escape(text)}</string>');
    case final bool flag:
      out.writeln('$pad<${flag ? 'true' : 'false'}/>');
    case final int number:
      out.writeln('$pad<integer>$number</integer>');
    case final double number:
      out.writeln('$pad<real>$number</real>');
    case final DateTime date:
      out.writeln(
        '$pad<date>${date.toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z')}</date>',
      );
    default:
      throw ArgumentError(
        'cannot write ${value.runtimeType} to a property list',
      );
  }
}

String _escape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// Writes [value] as a binary property list (`bplist00`), laid out the way Core Foundation lays it out, so that the same
/// data gives the bytes Xcode writes: the root first, then all the keys of a dictionary in sorted order, then its values,
/// each container followed by its own contents; a string, number or other plain value that occurs again is written once
/// and referenced.
Uint8List writePlistBinary(Object? value) => _BinaryWriter().write(value);

/// An object of the binary table: a plain value, or a container that holds the table indexes of its contents.
class _Container {
  _Container(this.keys, this.values);
  final List<int>? keys;
  final List<int> values;
}

class _BinaryWriter {
  final _objects = <Object?>[];
  final _unique = <String, int>{};

  Uint8List write(Object? value) {
    _add(value);
    final out = BytesBuilder()..add(ascii.encode('bplist00'));
    final refSize = _width(_objects.length);
    final offsets = <int>[];
    for (final object in _objects) {
      offsets.add(out.length);
      _writeObject(out, object, refSize);
    }
    final table = out.length;
    final offsetSize = _width(table);
    for (final offset in offsets) {
      _writeUint(out, offset, offsetSize);
    }
    out
      ..add(Uint8List(6))
      ..addByte(offsetSize)
      ..addByte(refSize);
    _writeUint(out, _objects.length, 8);
    _writeUint(out, 0, 8);
    _writeUint(out, table, 8);
    return out.toBytes();
  }

  int _add(Object? value) {
    switch (value) {
      case final Map<Object?, Object?> map:
        final index = _reserve();
        final keys = map.keys.cast<String>().toList()..sort();
        final keyRefs = [for (final key in keys) _add(key)];
        final valueRefs = [for (final key in keys) _add(map[key])];
        _objects[index] = _Container(keyRefs, valueRefs);
        return index;
      case final Uint8List bytes:
        return _plain('data:${base64.encode(bytes)}', bytes);
      case final List<Object?> list:
        final index = _reserve();
        _objects[index] = _Container(null, [
          for (final item in list) _add(item),
        ]);
        return index;
      case final String _ || final int _ || final bool _ || final double _:
        return _plain('${value.runtimeType}:$value', value);
      case final DateTime date:
        return _plain('date:${date.toUtc()}', date);
      default:
        throw ArgumentError(
          'cannot write ${value.runtimeType} to a property list',
        );
    }
  }

  int _reserve() {
    _objects.add(null);
    return _objects.length - 1;
  }

  int _plain(String key, Object? value) => _unique.putIfAbsent(key, () {
    _objects.add(value);
    return _objects.length - 1;
  });

  void _writeObject(BytesBuilder out, Object? object, int refSize) {
    switch (object) {
      case final _Container c:
        final keys = c.keys;
        _writeMarker(out, keys == null ? 0xA0 : 0xD0, c.values.length);
        for (final ref in [...?keys, ...c.values]) {
          _writeUint(out, ref, refSize);
        }
      case final bool flag:
        out.addByte(flag ? 0x09 : 0x08);
      case final int number:
        _writeInt(out, number);
      case final double number:
        out.addByte(0x23);
        _writeFloat(out, number);
      case final DateTime date:
        out.addByte(0x33);
        _writeFloat(
          out,
          date.toUtc().millisecondsSinceEpoch / 1000 - 978307200,
        );
      case final Uint8List bytes:
        _writeMarker(out, 0x40, bytes.length);
        out.add(bytes);
      case final String text:
        if (text.codeUnits.every((unit) => unit < 0x80)) {
          _writeMarker(out, 0x50, text.length);
          out.add(ascii.encode(text));
        } else {
          _writeMarker(out, 0x60, text.length);
          for (final unit in text.codeUnits) {
            out
              ..addByte(unit >> 8)
              ..addByte(unit & 0xFF);
          }
        }
    }
  }

  /// The marker byte of an object that has a length: the length itself when it fits in 4 bits, else `0xF` and the length
  /// as an integer object.
  void _writeMarker(BytesBuilder out, int type, int length) {
    if (length < 15) {
      out.addByte(type | length);
    } else {
      out.addByte(type | 0xF);
      _writeInt(out, length);
    }
  }

  void _writeInt(BytesBuilder out, int number) {
    final size = number < 0 ? 8 : _width(number);
    out.addByte(
      0x10 |
          (size == 1
              ? 0
              : size == 2
              ? 1
              : size == 4
              ? 2
              : 3),
    );
    _writeUint(out, number, size);
  }

  void _writeFloat(BytesBuilder out, double number) {
    out.add(
      (ByteData(8)..setFloat64(0, number, Endian.big)).buffer.asUint8List(),
    );
  }

  /// The smallest of 1, 2, 4 and 8 bytes that holds [value]. It sizes integers, object references (by the number of
  /// objects) and offsets (by the offset table's position).
  int _width(int value) => value > 0xFFFFFFFF
      ? 8
      : value > 0xFFFF
      ? 4
      : value > 0xFF
      ? 2
      : 1;

  void _writeUint(BytesBuilder out, int number, int size) {
    for (var shift = (size - 1) * 8; shift >= 0; shift -= 8) {
      out.addByte((number >> shift) & 0xFF);
    }
  }
}
