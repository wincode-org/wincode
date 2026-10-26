import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

/// A 64-bit little-endian Mach-O header with an `LC_ID_DYLIB` command (name [id], [room] bytes for it) and an `LC_UUID`
/// after it, then 16 bytes of "code".
Uint8List _dylib(String id, {int room = 64}) {
  final out = BytesBuilder();
  void u32(int v) => out.add(
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List(),
  );
  final idSize = 24 + room;
  for (final v in [0xFEEDFACF, 0x0100000C, 0, 6, 2, idSize + 24, 0, 0]) {
    u32(v);
  }
  for (final v in [0xD, idSize, 24, 2, 0x10000, 0x10000]) {
    u32(v);
  }
  out
    ..add(utf8.encode(id))
    ..add(Uint8List(room - utf8.encode(id).length));
  for (final v in [0x1B, 24]) {
    u32(v);
  }
  out
    ..add(Uint8List(16))
    ..add(List.generate(16, (i) => 0xA0 + i));
  return out.toBytes();
}

String _idOf(Uint8List macho) {
  final data = ByteData.sublistView(macho);
  final start = 32 + data.getUint32(32 + 8, Endian.little);
  final end = macho.indexOf(0, start);
  return utf8.decode(macho.sublist(start, end));
}

void main() {
  group('setInstallName', () {
    test('rewrites the name in place and touches nothing else', () {
      final before = _dylib('/home/me/build/hooks/objective_c.dylib');
      final after = setInstallName(
        before,
        '@rpath/objective_c.framework/objective_c',
      );
      expect(_idOf(after), '@rpath/objective_c.framework/objective_c');
      expect(after.length, before.length);
      final nameStart = 32 + 24;
      expect(after.sublist(0, nameStart), before.sublist(0, nameStart));
      expect(
        after.sublist(nameStart + 64),
        before.sublist(nameStart + 64),
        reason: 'the other command and the code stay as they were',
      );
    });

    test('a name that does not fit is an error', () {
      expect(
        () => setInstallName(_dylib('/a', room: 16), 'x' * 20),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('needs 21 bytes'),
          ),
        ),
      );
    });

    test(
      'a file that is not a 64-bit Mach-O or has no install name is refused',
      () {
        expect(() => setInstallName(Uint8List(64), 'x'), throwsFormatException);
        final executable = _dylib('/a');
        ByteData.sublistView(executable).setUint32(32, 0x1B, Endian.little);
        expect(() => setInstallName(executable, 'x'), throwsFormatException);
      },
    );
  });
}
