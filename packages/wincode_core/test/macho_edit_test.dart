import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

import 'macho_builder.dart';

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

  group('removeRpaths', () {
    const keep = {'/usr/lib/swift', '@executable_path/Frameworks'};
    final paths = [
      '/usr/lib/swift',
      '@loader_path',
      '/home/me/toolchains/6.4.0/usr/lib/swift-6.2/iphoneos',
      '@executable_path/Frameworks',
    ];

    String rpathsOf(Uint8List macho) {
      final data = ByteData.sublistView(macho);
      final found = <String>[];
      var offset = 32;
      for (var i = data.getUint32(16, Endian.little); i > 0; i--) {
        final size = data.getUint32(offset + 4, Endian.little);
        if (data.getUint32(offset, Endian.little) == 0x8000001C) {
          final start = offset + data.getUint32(offset + 8, Endian.little);
          found.add(utf8.decode(macho.sublist(start, macho.indexOf(0, start))));
        }
        offset += size;
      }
      return found.join(' | ');
    }

    test(
      'removes the paths that are not kept, in order, and fixes the header',
      () {
        final before = withRpaths(paths);
        final result = removeRpaths(before, keep);
        expect(result.removed, [paths[1], paths[2]]);
        expect(
          rpathsOf(result.macho),
          '/usr/lib/swift | @executable_path/Frameworks',
        );
        final data = ByteData.sublistView(result.macho);
        expect(
          data.getUint32(16, Endian.little),
          3,
          reason: '2 rpaths and the UUID',
        );
        final size = data.getUint32(20, Endian.little);
        expect(
          result.macho.sublist(
            32 + size,
            32 + ByteData.sublistView(before).getUint32(20, Endian.little),
          ),
          everyElement(0),
          reason: 'the freed bytes are zeroed',
        );
        expect(result.macho.length, before.length);
        expect(
          result.macho.sublist(result.macho.length - 8),
          before.sublist(before.length - 8),
          reason: 'what follows the commands is not touched',
        );
      },
    );

    test('a file with nothing to remove comes back as it was', () {
      final before = withRpaths([...keep]);
      final result = removeRpaths(before, keep);
      expect(result.removed, isEmpty);
      expect(result.macho, before);
    });

    test('a file that is not a 64-bit Mach-O is refused', () {
      expect(() => removeRpaths(Uint8List(64), keep), throwsFormatException);
    });
  });
}
