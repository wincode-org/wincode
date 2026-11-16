import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wincode_cli/wincode_cli.dart';

/// One entry of a tar that a test writes by hand: the archive of a source tree, or one that tries to leave its folder.
class TarEntry {
  const TarEntry(
    this.name, {
    this.body = const [],
    this.type = '0',
    this.link = '',
    this.prefix = '',
  });

  final String name;
  final List<int> body;
  final String type;
  final String link;
  final String prefix;
}

/// A ustar archive of [entries], with its end blocks unless [end] is false. [corrupt] flips a byte of the first header.
Uint8List tarOf(
  List<TarEntry> entries, {
  bool end = true,
  bool corrupt = false,
}) {
  final out = BytesBuilder();
  for (final e in entries) {
    final header = Uint8List(512);
    void put(int at, String text) =>
        header.setRange(at, at + utf8.encode(text).length, utf8.encode(text));
    put(0, e.name);
    put(100, '0000644\u0000');
    put(108, '0000000\u0000');
    put(116, '0000000\u0000');
    put(124, '${e.body.length.toRadixString(8).padLeft(11, '0')}\u0000');
    put(136, '00000000000\u0000');
    put(148, '        ');
    header[156] = e.type.codeUnitAt(0);
    put(157, e.link);
    put(257, 'ustar\u000000');
    put(345, e.prefix);
    final sum = header.fold<int>(0, (a, b) => a + b);
    put(148, '${sum.toRadixString(8).padLeft(6, '0')}\u0000 ');
    out
      ..add(header)
      ..add(e.body)
      ..add(Uint8List((512 - e.body.length % 512) % 512));
  }
  if (end) {
    out.add(Uint8List(1024));
  }
  final bytes = out.takeBytes();
  if (corrupt) {
    bytes[10] ^= 0x55;
  }
  return bytes;
}

/// The body of a pax header (type `x`) with [records], each as `<length> <key>=<value>\n`.
List<int> paxOf(Map<String, String> records) {
  final out = <int>[];
  records.forEach((key, value) {
    final text = ' $key=$value\n';
    var length = utf8.encode(text).length + 1;
    while ('$length$text'.length != length) {
      length = '$length$text'.length;
    }
    out.addAll(utf8.encode('$length$text'));
  });
  return out;
}

void main() {
  late Directory temp;
  late Directory into;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('wincode_tar_');
    into = Directory('${temp.path}${Platform.pathSeparator}into')..createSync();
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<int> unpack(
    List<int> tar, {
    int maxBytes = 1 << 20,
    int maxEntries = 100,
  }) {
    final file = File('${temp.path}${Platform.pathSeparator}a.tar.gz')
      ..writeAsBytesSync(gzip.encode(tar));
    return unpackTarGz(file, into, maxBytes: maxBytes, maxEntries: maxEntries);
  }

  Future<String> refusal(List<int> tar, {int maxBytes = 1 << 20}) async {
    try {
      await unpack(tar, maxBytes: maxBytes);
    } on TarRefused catch (e) {
      return e.message;
    }
    fail('the archive was unpacked');
  }

  String read(String relative) => File(
    '${into.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
  ).readAsStringSync();

  /// Everything that was written anywhere under [temp], relative to it.
  List<String> written() => [
    for (final e in temp.listSync(recursive: true, followLinks: false))
      if (!e.path.endsWith('a.tar.gz'))
        e.path
            .substring(temp.path.length + 1)
            .replaceAll(Platform.pathSeparator, '/'),
  ]..sort();

  group('unpackTarGz unpacks a source archive', () {
    test(
      'files, folders, a "./" entry and parents that have no entry',
      () async {
        final files = await unpack(
          tarOf([
            const TarEntry('./', type: '5'),
            const TarEntry('src-1/', type: '5'),
            TarEntry('src-1/a.txt', body: utf8.encode('alpha')),
            TarEntry('src-1/deep/er/b.txt', body: utf8.encode('beta')),
            TarEntry('./src-1/c.txt', body: utf8.encode('gamma')),
            const TarEntry('src-1/empty'),
          ]),
        );
        expect(files, 4);
        expect(read('src-1/a.txt'), 'alpha');
        expect(read('src-1/deep/er/b.txt'), 'beta');
        expect(read('src-1/c.txt'), 'gamma');
        expect(read('src-1/empty'), '');
        expect(written(), [
          'into',
          'into/src-1',
          'into/src-1/a.txt',
          'into/src-1/c.txt',
          'into/src-1/deep',
          'into/src-1/deep/er',
          'into/src-1/deep/er/b.txt',
          'into/src-1/empty',
        ]);
      },
    );

    test(
      'the pax headers that git archive writes: global, and a path',
      () async {
        await unpack(
          tarOf([
            TarEntry(
              'pax_global_header',
              type: 'g',
              body: paxOf({
                'comment': 'f6158be9e62a5ce2a53d72b1a6d880880da956c8',
              }),
            ),
            TarEntry(
              'p',
              type: 'x',
              body: paxOf({'path': 'src-1/${'n' * 150}.txt'}),
            ),
            TarEntry('short', body: utf8.encode('long name')),
          ]),
        );
        expect(read('src-1/${'n' * 150}.txt'), 'long name');
        expect(written(), isNot(contains('into/short')));
      },
    );

    test('a GNU long name, and the prefix field of ustar', () async {
      await unpack(
        tarOf([
          TarEntry(
            'long',
            type: 'L',
            body: utf8.encode('src-1/${'m' * 120}\u0000'),
          ),
          TarEntry('x', body: utf8.encode('gnu')),
          TarEntry(
            'file.txt',
            prefix: 'src-1/folder',
            body: utf8.encode('prefix'),
          ),
        ]),
      );
      expect(read('src-1/${'m' * 120}'), 'gnu');
      expect(read('src-1/folder/file.txt'), 'prefix');
    });
  });

  group('unpackTarGz refuses, and writes nothing outside its folder', () {
    final escapes = {
      'a path with ..': const TarEntry('../outside.txt', body: [1]),
      'a path with .. in the middle': const TarEntry(
        'src-1/../../outside.txt',
        body: [1],
      ),
      'an absolute path': const TarEntry('/outside.txt', body: [1]),
      'a drive letter': const TarEntry('C:/outside.txt', body: [1]),
      'a backslash': const TarEntry(r'src-1\..\..\outside.txt', body: [1]),
      'a folder with ..': const TarEntry('../outside', type: '5'),
      'a prefix with ..': const TarEntry(
        'outside.txt',
        prefix: '../..',
        body: [1],
      ),
    };
    for (final MapEntry(:key, :value) in escapes.entries) {
      test(key, () async {
        final message = await refusal(tarOf([value]));
        expect(
          message,
          anyOf(
            contains('leaves the folder'),
            contains('absolute'),
            contains('backslash'),
          ),
        );
        expect(written(), ['into']);
      });
    }

    test('a pax path with ..', () async {
      final message = await refusal(
        tarOf([
          TarEntry('x', type: 'x', body: paxOf({'path': '../outside.txt'})),
          const TarEntry('inside.txt', body: [1]),
        ]),
      );
      expect(message, contains('leaves the folder'));
      expect(written(), ['into']);
    });

    test('a GNU long name with ..', () async {
      final message = await refusal(
        tarOf([
          TarEntry('l', type: 'L', body: utf8.encode('../outside.txt\u0000')),
          const TarEntry('inside.txt', body: [1]),
        ]),
      );
      expect(message, contains('leaves the folder'));
    });

    test('a symbolic link that leaves the folder, and the file that would be written through it', () async {
      final message = await refusal(
        tarOf([
          const TarEntry('src-1/link', type: '2', link: '../../'),
          const TarEntry('src-1/link/outside.txt', body: [1]),
        ]),
      );
      expect(message, contains('holds a link, src-1/link'));
      expect(written(), ['into']);
    });

    test(
      'a symbolic link to an absolute path, and one that stays inside',
      () async {
        for (final target in ['/etc', 'sibling']) {
          final message = await refusal(
            tarOf([TarEntry('src-1/link', type: '2', link: target)]),
          );
          expect(message, contains('holds a link'), reason: target);
        }
      },
    );

    test('a hard link', () async {
      final message = await refusal(
        tarOf([
          TarEntry('src-1/a', body: [1]),
          const TarEntry('src-1/b', type: '1', link: 'src-1/a'),
        ]),
      );
      expect(message, contains('holds a link, src-1/b'));
    });

    test('a device, a FIFO and an unknown type', () async {
      for (final type in ['3', '4', '6', 'S']) {
        final message = await refusal(tarOf([TarEntry('dev', type: type)]));
        expect(message, contains('an entry of type "$type"'), reason: type);
      }
    });
  });

  group('unpackTarGz refuses what is not a whole tar.gz', () {
    test('a file that is not gzip', () async {
      final file = File('${temp.path}${Platform.pathSeparator}b.tar.gz')
        ..writeAsStringSync('this is not an archive');
      await expectLater(
        unpackTarGz(file, into),
        throwsA(
          isA<TarRefused>().having(
            (e) => e.message,
            'message',
            contains('not a readable gzip'),
          ),
        ),
      );
    });

    test('a gzip file that is not a tar', () async {
      expect(
        await refusal(Uint8List.fromList(List.filled(1024, 7))),
        contains('checksum'),
      );
    });

    test('a tar with a wrong checksum', () async {
      expect(
        await refusal(
          tarOf([
            const TarEntry('a', body: [1]),
          ], corrupt: true),
        ),
        contains('checksum'),
      );
    });

    test(
      'a tar that is cut off inside an entry, and one that has no end',
      () async {
        final whole = tarOf([TarEntry('a', body: List.filled(2000, 1))]);
        expect(
          await refusal(whole.sublist(0, 700)),
          contains('inside an entry'),
        );
        expect(
          await refusal(
            tarOf([
              const TarEntry('a', body: [1]),
            ], end: false),
          ),
          contains('no end'),
        );
      },
    );

    test('more bytes than the limit, however small the gzip file is', () async {
      final bomb = tarOf([TarEntry('a', body: Uint8List(300000))]);
      expect(gzip.encode(bomb).length, lessThan(2000));
      expect(
        await refusal(bomb, maxBytes: 100000),
        contains('more than 100000 bytes'),
      );
    });

    test('more entries than the limit', () async {
      await expectLater(
        unpack(
          tarOf([for (var i = 0; i < 6; i++) TarEntry('f$i')]),
          maxEntries: 5,
        ),
        throwsA(isA<TarRefused>()),
      );
    });

    test('a file where a folder is', () async {
      final message = await refusal(
        tarOf([
          const TarEntry('src-1/a.txt', body: [1]),
          const TarEntry('src-1/a.txt/b.txt', body: [1]),
        ]),
      );
      expect(message, contains('cannot write src-1/a.txt/b.txt'));
    });
  });
}
