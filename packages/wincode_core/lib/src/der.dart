import 'dart:convert';
import 'dart:typed_data';

/// One DER element (ITU-T X.690): its tag, and where its header and value lie in [bytes]. Only single-byte tags and
/// definite lengths are read, which is all that certificates, keys and CMS signatures use. Any other encoding, or an
/// element that runs past its container, throws a [FormatException].
class Der {
  Der._(this.bytes, this.tag, this.start, this.valueStart, this.end);

  /// Reads the element at [at] of [bytes], which must end by [limit] (default: the end of [bytes]).
  factory Der.at(Uint8List bytes, [int at = 0, int? limit]) {
    final stop = limit ?? bytes.length;
    if (at + 2 > stop) {
      throw const FormatException('a DER element is cut short');
    }
    final tag = bytes[at];
    if (tag & 0x1F == 0x1F) {
      throw const FormatException('a DER tag of more than one byte');
    }
    var length = bytes[at + 1];
    var value = at + 2;
    if (length & 0x80 != 0) {
      final count = length & 0x7F;
      if (count == 0 || count > 4 || value + count > stop) {
        throw const FormatException('a DER length that cannot be read');
      }
      length = 0;
      for (var i = 0; i < count; i++) {
        length = length << 8 | bytes[value + i];
      }
      value += count;
    }
    if (value + length > stop) {
      throw const FormatException('a DER element runs past its container');
    }
    return Der._(bytes, tag, at, value, value + length);
  }

  /// Reads [bytes] as one element that fills them.
  factory Der.whole(Uint8List bytes) {
    final element = Der.at(bytes);
    if (element.end != bytes.length) {
      throw const FormatException('bytes follow the DER element');
    }
    return element;
  }

  final Uint8List bytes;
  final int tag;

  /// Where the header starts, where the value starts, and where the element ends.
  final int start;
  final int valueStart;
  final int end;

  /// The value, without the header.
  Uint8List get value => Uint8List.sublistView(bytes, valueStart, end);

  /// The whole element, header included.
  Uint8List get encoded => Uint8List.sublistView(bytes, start, end);

  /// The elements inside a constructed element, in order.
  List<Der> get children {
    if (tag & 0x20 == 0) {
      throw const FormatException('a DER element that holds no others');
    }
    final found = <Der>[];
    for (var at = valueStart; at < end; at = found.last.end) {
      found.add(Der.at(bytes, at, end));
    }
    return found;
  }

  /// The children of a SEQUENCE (or SET when [set]), checked.
  List<Der> items({bool set = false}) {
    expect(set ? 0x31 : 0x30);
    return children;
  }

  /// Throws unless the tag is [wanted].
  void expect(int wanted) {
    if (tag != wanted) {
      throw FormatException(
        'expected DER tag 0x${wanted.toRadixString(16)}, found 0x${tag.toRadixString(16)}',
      );
    }
  }

  /// An INTEGER, as a signed big-endian number.
  BigInt get integer {
    expect(0x02);
    final v = value;
    if (v.isEmpty) {
      throw const FormatException('an empty DER INTEGER');
    }
    var n = BigInt.zero;
    for (final b in v) {
      n = n << 8 | BigInt.from(b);
    }
    return v[0] & 0x80 != 0 ? n - (BigInt.one << (8 * v.length)) : n;
  }

  /// An OBJECT IDENTIFIER, in dotted form.
  String get oid {
    expect(0x06);
    final v = value;
    if (v.isEmpty) {
      throw const FormatException('an empty DER OBJECT IDENTIFIER');
    }
    final parts = <int>[];
    var n = 0;
    for (final b in v) {
      n = n << 7 | (b & 0x7F);
      if (b & 0x80 == 0) {
        parts.add(n);
        n = 0;
      }
    }
    final first = parts.first;
    return [
      first < 80 ? first ~/ 40 : 2,
      first < 80 ? first % 40 : first - 80,
      ...parts.skip(1),
    ].join('.');
  }

  /// A string of one of the kinds that names use: UTF8String, PrintableString, IA5String, T61String.
  String get text => switch (tag) {
    0x0C => utf8.decode(value),
    0x13 || 0x16 || 0x14 => latin1.decode(value),
    _ => throw FormatException(
      'a DER string of tag 0x${tag.toRadixString(16)}',
    ),
  };
}

/// [n] as an unsigned big-endian number of [length] bytes.
Uint8List bigIntBytes(BigInt n, int length) {
  final out = Uint8List(length);
  var rest = n;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (rest & BigInt.from(0xFF)).toInt();
    rest >>= 8;
  }
  return out;
}

/// [bytes] as an unsigned big-endian number.
BigInt unsignedBigInt(List<int> bytes) {
  var n = BigInt.zero;
  for (final b in bytes) {
    n = n << 8 | BigInt.from(b);
  }
  return n;
}
