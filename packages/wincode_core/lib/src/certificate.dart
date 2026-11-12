import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'der.dart';

const _rsaEncryption = '1.2.840.113549.1.1.1';
const _commonName = '2.5.4.3';
const _organizationalUnit = '2.5.4.11';

/// An RSA public key: the modulus and the public exponent.
class RsaPublicKey {
  const RsaPublicKey(this.modulus, this.exponent);

  final BigInt modulus;
  final BigInt exponent;

  @override
  bool operator ==(Object other) =>
      other is RsaPublicKey &&
      other.modulus == modulus &&
      other.exponent == exponent;

  @override
  int get hashCode => Object.hash(modulus, exponent);
}

/// What winCode reads in an X.509 certificate (RFC 5280).
class Certificate {
  const Certificate({
    required this.der,
    required this.serial,
    required this.issuer,
    required this.commonName,
    required this.organizationalUnit,
    required this.notAfter,
    required this.publicKeyAlgorithm,
    required this.rsa,
  });

  /// The whole certificate, as the profile's `DeveloperCertificates` holds it.
  final Uint8List der;

  final BigInt serial;

  /// The issuer's name, as DER: a CMS signer names its certificate by issuer and serial number.
  final Uint8List issuer;

  /// The subject's common name and organizational unit; an Apple certificate's unit is the team ID.
  final String? commonName;
  final String? organizationalUnit;

  /// The end of the validity, in UTC.
  final DateTime notAfter;

  /// The OID of the public key's algorithm.
  final String publicKeyAlgorithm;

  /// The public key when it is an RSA key, else null.
  final RsaPublicKey? rsa;

  /// The serial number as App Store Connect writes it: upper-case hexadecimal without leading zeros.
  String get serialHex => serial.toRadixString(16).toUpperCase();
}

/// Reads the DER certificate [der]. Throws a [FormatException] for anything else.
Certificate readCertificate(Uint8List der) {
  try {
    final tbs = Der.whole(der).items()[0].items();
    // The version is an explicit [0] that a version 1 certificate leaves out.
    final i = tbs[0].tag == 0xA0 ? 1 : 0;
    final validity = tbs[i + 3].items();
    final subject = _names(tbs[i + 4]);
    final spki = tbs[i + 5].items();
    final algorithm = spki[0].items()[0].oid;
    return Certificate(
      der: der,
      serial: tbs[i].integer,
      issuer: Uint8List.fromList(tbs[i + 2].encoded),
      commonName: subject[_commonName],
      organizationalUnit: subject[_organizationalUnit],
      notAfter: _time(validity[1]),
      publicKeyAlgorithm: algorithm,
      rsa: algorithm == _rsaEncryption ? _rsaPublic(_bitString(spki[1])) : null,
    );
  } on RangeError {
    throw const FormatException('the certificate is cut short');
  }
}

/// The attributes of a Name, by OID; the first of each.
Map<String, String> _names(Der name) {
  final found = <String, String>{};
  for (final rdn in name.items()) {
    for (final attribute in rdn.items(set: true)) {
      final pair = attribute.items();
      found.putIfAbsent(pair[0].oid, () => pair[1].text);
    }
  }
  return found;
}

DateTime _time(Der time) {
  final text = latin1.decode(time.value);
  final match = switch (time.tag) {
    0x17 => RegExp(r'^(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)Z$').firstMatch(text),
    0x18 => RegExp(
      r'^(\d\d\d\d)(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)Z$',
    ).firstMatch(text),
    _ => null,
  };
  if (match == null) {
    throw const FormatException('a certificate time that cannot be read');
  }
  final p = [for (var g = 1; g <= 6; g++) int.parse(match[g]!)];
  // RFC 5280, section 4.1.2.5.1: a two-digit year of 50 or more is 19xx.
  final year = time.tag == 0x17 ? (p[0] >= 50 ? 1900 : 2000) + p[0] : p[0];
  return DateTime.utc(year, p[1], p[2], p[3], p[4], p[5]);
}

Uint8List _bitString(Der bits) {
  bits.expect(0x03);
  final v = bits.value;
  if (v.isEmpty || v[0] != 0) {
    throw const FormatException('a BIT STRING that is not whole bytes');
  }
  return Uint8List.sublistView(v, 1);
}

RsaPublicKey _rsaPublic(Uint8List rsaPublicKey) {
  final numbers = Der.whole(rsaPublicKey).items();
  return RsaPublicKey(numbers[0].integer, numbers[1].integer);
}

/// Why a private key cannot be used.
enum PrivateKeyProblem {
  /// It is encrypted: an encrypted PEM key or a PKCS #12 file (`.p12`).
  encrypted,

  /// It is a key of another kind than RSA.
  notRsa,

  /// It is no private key that winCode reads.
  unreadable,
}

/// A private key that [readRsaPrivateKey] cannot use. Its message never quotes the key.
class PrivateKeyException implements Exception {
  const PrivateKeyException(this.problem, this.message);

  final PrivateKeyProblem problem;
  final String message;

  @override
  String toString() => message;
}

/// The public half of the unencrypted RSA private key in [bytes]: PEM, as PKCS #8 (`PRIVATE KEY`) or PKCS #1 (`RSA
/// PRIVATE KEY`). Throws a [PrivateKeyException] for an encrypted key, a `.p12`, a key of another kind or anything else.
RsaPublicKey readRsaPrivateKey(Uint8List bytes) {
  final text = latin1.decode(bytes);
  final begin = RegExp(r'-----BEGIN ([A-Z0-9 ]+)-----').firstMatch(text);
  if (begin == null) {
    // PFX (RFC 7292) is a SEQUENCE whose first item is the INTEGER 3.
    try {
      final items = Der.at(bytes).items();
      if (items.isNotEmpty &&
          items[0].tag == 0x02 &&
          items[0].integer == BigInt.from(3)) {
        throw const PrivateKeyException(
          PrivateKeyProblem.encrypted,
          'the distribution key is a PKCS #12 file (.p12)',
        );
      }
    } on FormatException {
      // Not DER either.
    }
    throw const PrivateKeyException(
      PrivateKeyProblem.unreadable,
      'the distribution key is not a PEM private key',
    );
  }
  final label = begin[1]!;
  final end = text.indexOf('-----END $label-----', begin.end);
  if (end < 0) {
    throw const PrivateKeyException(
      PrivateKeyProblem.unreadable,
      'the distribution key has no END line',
    );
  }
  final lines = text.substring(begin.end, end).split(RegExp(r'\r?\n'));
  if (label == 'ENCRYPTED PRIVATE KEY' ||
      lines.any((l) => l.startsWith('Proc-Type:') && l.contains('ENCRYPTED'))) {
    throw const PrivateKeyException(
      PrivateKeyProblem.encrypted,
      'the distribution key is encrypted',
    );
  }
  if (label != 'PRIVATE KEY' && label != 'RSA PRIVATE KEY') {
    throw PrivateKeyException(
      label.endsWith('PRIVATE KEY')
          ? PrivateKeyProblem.notRsa
          : PrivateKeyProblem.unreadable,
      label.endsWith('PRIVATE KEY')
          ? 'the distribution key is not an RSA key'
          : 'the distribution key is not a private key',
    );
  }
  final Uint8List der;
  try {
    der = base64.decode(
      lines.where((l) => l.isNotEmpty && !l.contains(':')).join().trim(),
    );
  } on FormatException {
    throw const PrivateKeyException(
      PrivateKeyProblem.unreadable,
      'the distribution key is damaged',
    );
  }
  try {
    var pkcs1 = der;
    if (label == 'PRIVATE KEY') {
      final info = Der.whole(der).items();
      if (info[1].items()[0].oid != _rsaEncryption) {
        throw const PrivateKeyException(
          PrivateKeyProblem.notRsa,
          'the distribution key is not an RSA key',
        );
      }
      info[2].expect(0x04);
      pkcs1 = info[2].value;
    }
    final numbers = Der.whole(pkcs1).items();
    return RsaPublicKey(numbers[1].integer, numbers[2].integer);
  } on FormatException {
    throw const PrivateKeyException(
      PrivateKeyProblem.unreadable,
      'the distribution key is damaged',
    );
  } on RangeError {
    throw const PrivateKeyException(
      PrivateKeyProblem.unreadable,
      'the distribution key is damaged',
    );
  }
}

/// The DER prefix of a SHA-256 DigestInfo (RFC 8017, section 9.2, note 1).
const _sha256DigestInfo = [
  0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, //
  0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
];

/// Whether [signature] is the RSASSA-PKCS1-v1_5 signature with SHA-256 (RFC 8017) of [message] by [key].
bool verifyRsaSha256(RsaPublicKey key, List<int> message, List<int> signature) {
  final k = (key.modulus.bitLength + 7) ~/ 8;
  final s = unsignedBigInt(signature);
  if (signature.length != k || s >= key.modulus) {
    return false;
  }
  final em = bigIntBytes(s.modPow(key.exponent, key.modulus), k);
  final t = [..._sha256DigestInfo, ...sha256.convert(message).bytes];
  if (k < t.length + 11 || em[0] != 0 || em[1] != 1) {
    return false;
  }
  final pad = k - t.length - 3;
  for (var i = 0; i < pad; i++) {
    if (em[2 + i] != 0xFF) {
      return false;
    }
  }
  if (em[2 + pad] != 0) {
    return false;
  }
  for (var i = 0; i < t.length; i++) {
    if (em[3 + pad + i] != t[i]) {
      return false;
    }
  }
  return true;
}
