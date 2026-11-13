import 'dart:io';

import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('wincode_digest_'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('the MD5 and SHA-256 of a file, as published for "abc"', () async {
    final file = File('${temp.path}/abc')..writeAsStringSync('abc');
    final digests = await digestsOfFile(file);
    expect(digests.md5, '900150983cd24fb0d6963f7d28e17f72');
    expect(
      digests.sha256,
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test('an empty file, and a file of several read chunks', () async {
    final empty = File('${temp.path}/empty')..writeAsBytesSync([]);
    expect(
      (await digestsOfFile(empty)).md5,
      'd41d8cd98f00b204e9800998ecf8427e',
    );
    // A million "a", as in the published test vectors: far more than one chunk.
    final big = File('${temp.path}/big')
      ..writeAsBytesSync(List.filled(1000000, 0x61));
    final digests = await digestsOfFile(big);
    expect(digests.md5, '7707d6ae4e027c70eea2a935c2296f21');
    expect(
      digests.sha256,
      'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
    );
  });
}
