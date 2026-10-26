import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

/// A property-list dictionary. Keys keep the order they were added in.
typedef PlistMap = Map<String, Object?>;

/// Reads an XML property list. A dict becomes a [PlistMap], an array a `List<Object?>`, `integer` an `int`,
/// `real` a `double`, `date` a `DateTime` and `data` a [Uint8List].
Object? parsePlist(String source) {
  final root = XmlDocument.parse(source).rootElement;
  if (root.name.local != 'plist') {
    throw const FormatException(
      'not a property list: the root element is not <plist>',
    );
  }
  return _read(root.childElements.single);
}

/// Reads a property list in either form: XML, or the binary `bplist00` that Xcode and the Darwin SDK often use.
Object? parsePlistBytes(Uint8List bytes) {
  const magic = [0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x30, 0x30];
  if (bytes.length > 8 &&
      [for (var i = 0; i < 8; i++) bytes[i]].toString() == magic.toString()) {
    return _BinaryReader(bytes).read();
  }
  return parsePlist(utf8.decode(bytes));
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
