import 'dart:convert';

import 'package:test/test.dart';
import 'package:wincode_asc/testing.dart';
import 'package:wincode_asc/wincode_asc.dart';

const _issuer = '12345678-90ab-cdef-1234-567890abcdef';

BigInt _hex(String hex) => BigInt.parse(hex, radix: 16);

List<int> _bytes32(BigInt value) => [
  for (var i = 31; i >= 0; i--) (value >> (8 * i)).toUnsigned(8).toInt(),
];

AscKey _parse(String pem) =>
    AscKey.parse(pem, keyId: 'ABCDE12345', issuerId: _issuer);

Object? _json(String part) =>
    jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(part))));

void main() {
  test('signs the known answers of RFC 6979 A.2.5: P-256 with SHA-256', () {
    // The RFC's key and signatures, so that the test does not rely on the library that signs.
    final key = _parse(
      ThrowawayKey.of(
        _hex(
          'C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721',
        ),
      ).pem(withPublicKey: false),
    );
    for (final (message, r, s) in [
      (
        'sample',
        'EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716',
        'F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8',
      ),
      (
        'test',
        'F1ABB023518351CD71D881567B1EA663ED3EFCF6C5132B354F28D3B0B7D38367',
        '019F4113742A2B14BD25926B49C649155F267E60D3814B4C0CC84250E46F0083',
      ),
    ]) {
      expect(key.sign(utf8.encode(message)), [
        ..._bytes32(_hex(r)),
        ..._bytes32(_hex(s)),
      ], reason: message);
    }
  });

  test(
    "the token has Apple's header and claims, lives 10 minutes and verifies",
    () {
      final throwaway = ThrowawayKey();
      final now = DateTime.utc(2026, 11, 9, 12);
      final token = _parse(throwaway.pem()).token(now);
      expect(token, isNot(contains('=')), reason: 'base64url without padding');
      final [header, claims, signature] = token.split('.');
      expect(_json(header), {
        'alg': 'ES256',
        'kid': 'ABCDE12345',
        'typ': 'JWT',
      });
      final iat = now.millisecondsSinceEpoch ~/ 1000;
      expect(_json(claims), {
        'iss': _issuer,
        'iat': iat,
        'exp': iat + 600,
        'aud': 'appstoreconnect-v1',
      });
      expect(tokenLifetime, lessThanOrEqualTo(const Duration(minutes: 20)));
      final raw = base64Url.decode(base64Url.normalize(signature));
      expect(raw, hasLength(64), reason: 'R and S, not DER');
      expect(throwaway.verifies(utf8.encode('$header.$claims'), raw), isTrue);
      expect(
        throwaway.verifies(utf8.encode('$header.${claims}A'), raw),
        isFalse,
        reason: 'the check can fail',
      );
      expect(throwaway.signed(token, now), isTrue);
      expect(throwaway.signed(token, now.add(tokenLifetime)), isFalse);
      expect(ThrowawayKey().signed(token, now), isFalse);
    },
  );

  test('reads the key with or without its public key, and with LF or CRLF', () {
    final throwaway = ThrowawayKey();
    for (final pem in [
      throwaway.pem(),
      throwaway.pem(withPublicKey: false),
      throwaway.pem().replaceAll('\r\n', '\n'),
    ]) {
      final signature = _parse(pem).sign([1, 2, 3]);
      expect(throwaway.verifies([1, 2, 3], signature), isTrue);
    }
  });

  test('refuses what is not a PKCS #8 EC P-256 key, without repeating it', () {
    final good = ThrowawayKey().der(withPublicKey: false);
    const label = 'PRIVATE KEY';
    String pem(List<int> der) =>
        '-----BEGIN $label-----\n${base64.encode(der)}\n-----END $label-----\n';
    expect(_parse(pem(good)), isA<AscKey>(), reason: 'the unchanged key');
    // The last byte of the prime256v1 identifier, at offset 25, changed: another curve.
    expect(good[25], 0x07);
    final otherCurve = [...good]..[25] ^= 0x01;
    for (final (what, text) in [
      ('no PEM', base64.encode(good)),
      ('a SEC1 key', ThrowawayKey().pem(label: 'EC $label')),
      ('broken base64', pem(good).replaceFirst('MEE', 'M*E')),
      ('cut short', pem(good.sublist(0, 40))),
      ('another curve', pem(otherCurve)),
      ('a key of zero', ThrowawayKey.of(BigInt.zero).pem(withPublicKey: false)),
    ]) {
      expect(
        () => _parse(text),
        throwsA(
          isA<FormatException>()
              .having(
                (e) => e.message,
                'message',
                'not a PKCS #8 EC P-256 private key',
              )
              .having((e) => e.source, 'source', isNull),
        ),
        reason: what,
      );
    }
  });

  test('toString shows nothing of the key', () {
    expect('${_parse(ThrowawayKey().pem())}', 'AscKey(not shown)');
  });
}
