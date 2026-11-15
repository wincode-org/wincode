import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:wincode_core/wincode_core.dart';

void main() {
  test('sha256OfText is the SHA-256 of the UTF-8 text, in lower case', () {
    expect(
      sha256OfText('abc'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      sha256OfText(''),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    // "é" is the two bytes C3 A9 in UTF-8.
    expect(sha256OfText('é'), sha256.convert([0xC3, 0xA9]).toString());
  });
}
