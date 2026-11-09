import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// How long a token is valid. Apple refuses a token that expires more than 20 minutes after it was issued.
const tokenLifetime = Duration(minutes: 10);

const _label = 'PRIVATE KEY';
// The DER contents of the object identifiers id-ecPublicKey (1.2.840.10045.2.1) and prime256v1 (1.2.840.10045.3.1.7).
const _ecPublicKey = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01];
const _prime256v1 = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07];

/// An App Store Connect API key: the P-256 private key of `AuthKey_<Key ID>.p8`, its Key ID and the Issuer ID of the
/// team. [toString] shows none of them.
class AscKey {
  AscKey._(this.keyId, this.issuerId, this._d);

  /// Reads [pem], the `.p8` as App Store Connect delivers it: a PKCS #8 EC P-256 private key in PEM.
  ///
  /// Throws a [FormatException] whose message never repeats any of the key.
  factory AscKey.parse(
    String pem, {
    required String keyId,
    required String issuerId,
  }) {
    const notAKey = FormatException('not a PKCS #8 EC P-256 private key');
    final body = RegExp(
      '-----BEGIN $_label-----(.*?)-----END $_label-----',
      dotAll: true,
    ).firstMatch(pem)?[1];
    if (body == null) {
      throw notAKey;
    }
    try {
      // PrivateKeyInfo (RFC 5208): version 0, the algorithm, and the ECPrivateKey (RFC 5915) as an octet string.
      final info = _Der(base64.decode(body.replaceAll(RegExp(r'\s'), '')))
        ..enter(0x30)
        ..expect(0x02, [0]);
      _Der(info.read(0x30))
        ..expect(0x06, _ecPublicKey)
        ..expect(0x06, _prime256v1);
      final ecKey = _Der(info.read(0x04))
        ..enter(0x30)
        ..expect(0x02, [1]);
      final d = ecKey.read(0x04);
      final scalar = d.fold(BigInt.zero, (n, b) => n << 8 | BigInt.from(b));
      if (d.length != 32 ||
          scalar == BigInt.zero ||
          scalar >= ECCurve_secp256r1().n) {
        throw notAKey;
      }
      return AscKey._(keyId, issuerId, scalar);
    } catch (_) {
      // The FormatException of base64, or a RangeError, would carry the text it failed on.
      throw notAKey;
    }
  }

  /// The Key ID, from the name of the `.p8`. Never printed.
  final String keyId;

  /// The Issuer ID of the team. Never printed.
  final String issuerId;

  final BigInt _d;

  /// The token for one request, valid for [tokenLifetime] from [now]: a JWT signed with ES256, with the header and
  /// claims that Apple documents (`alg`, `kid`, `typ`; `iss`, `iat`, `exp`, `aud`).
  String token(DateTime now) {
    final issued = now.millisecondsSinceEpoch ~/ 1000;
    String part(Map<String, Object> json) =>
        _base64Url(utf8.encode(jsonEncode(json)));
    final header = part({'alg': 'ES256', 'kid': keyId, 'typ': 'JWT'});
    final claims = part({
      'iss': issuerId,
      'iat': issued,
      'exp': issued + tokenLifetime.inSeconds,
      'aud': 'appstoreconnect-v1',
    });
    return '$header.$claims.${_base64Url(sign(ascii.encode('$header.$claims')))}';
  }

  /// The ES256 signature of [message]: ECDSA on P-256 with SHA-256, as JWS writes it (R and S, 32 bytes each, not
  /// DER). k comes from the key and the message (RFC 6979), so the same message always gets the same signature.
  Uint8List sign(List<int> message) {
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(
        true,
        PrivateKeyParameter<ECPrivateKey>(
          ECPrivateKey(_d, ECCurve_secp256r1()),
        ),
      );
    final signature =
        signer.generateSignature(Uint8List.fromList(message)) as ECSignature;
    return Uint8List.fromList([
      ..._bytes32(signature.r),
      ..._bytes32(signature.s),
    ]);
  }

  @override
  String toString() => 'AscKey(not shown)';
}

String _base64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

List<int> _bytes32(BigInt value) => [
  for (var i = 31; i >= 0; i--) (value >> (8 * i)).toUnsigned(8).toInt(),
];

/// Reads DER elements one after another: a tag of one byte, then a length of at most two bytes.
class _Der {
  _Der(this._bytes);

  Uint8List _bytes;
  var _at = 0;

  /// The contents of the next element, which must have [tag].
  Uint8List read(int tag) {
    if (_bytes[_at] != tag) {
      throw const FormatException();
    }
    var length = _bytes[_at + 1];
    _at += 2;
    if (length > 0x7F) {
      final count = length & 0x7F;
      if (count == 0 || count > 2) {
        throw const FormatException();
      }
      length = 0;
      for (var i = 0; i < count; i++) {
        length = length << 8 | _bytes[_at++];
      }
    }
    final value = Uint8List.sublistView(_bytes, _at, _at + length);
    _at += length;
    return value;
  }

  /// Reads the next element, which must have [tag] and the contents [expected].
  void expect(int tag, List<int> expected) {
    final value = read(tag);
    if (value.length != expected.length) {
      throw const FormatException();
    }
    for (var i = 0; i < value.length; i++) {
      if (value[i] != expected[i]) {
        throw const FormatException();
      }
    }
  }

  /// Continues inside the next element, which must have [tag].
  void enter(int tag) {
    _bytes = read(tag);
    _at = 0;
  }
}
