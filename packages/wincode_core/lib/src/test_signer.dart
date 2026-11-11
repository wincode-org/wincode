import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'certificate.dart';
import 'der.dart';
import 'plist.dart';

// Test support only: throwaway RSA keys, self-made certificates and signatures laid out as zsign lays them out
// (docs/formats/code-signature-verification.md), so that the checks of the signature can be tested without zsign, WSL2
// or any file of Apple's. Nothing here is fit to sign a real app: the keys are small and nothing is kept secret.

/// A throwaway RSA key of [bits] bits, made at random for one test run.
class TestRsaKey {
  TestRsaKey._(this.n, this.e, this.d, this.p, this.q);

  factory TestRsaKey([int bits = 1024]) {
    final random = Random.secure();
    final e = BigInt.from(65537);
    while (true) {
      final p = _prime(bits ~/ 2, random);
      final q = _prime(bits - bits ~/ 2, random);
      final phi = (p - BigInt.one) * (q - BigInt.one);
      if (p != q && phi.gcd(e) == BigInt.one && (p * q).bitLength == bits) {
        return TestRsaKey._(p * q, e, e.modInverse(phi), p, q);
      }
    }
  }

  final BigInt n;
  final BigInt e;
  final BigInt d;
  final BigInt p;
  final BigInt q;

  RsaPublicKey get public => RsaPublicKey(n, e);

  /// The key as an unencrypted PEM file: PKCS #8 (`PRIVATE KEY`), or PKCS #1 (`RSA PRIVATE KEY`) when not [pkcs8].
  String pem({bool pkcs8 = true}) {
    final one = BigInt.one;
    final pkcs1 = _seq([
      _int(BigInt.zero),
      ...[
        n,
        e,
        d,
        p,
        q,
        d % (p - one),
        d % (q - one),
        q.modInverse(p),
      ].map(_int),
    ]);
    final der = pkcs8
        ? _seq([_int(BigInt.zero), _algorithm(_rsa), _der(0x04, pkcs1)])
        : pkcs1;
    return pemOf(pkcs8 ? 'PRIVATE KEY' : 'RSA PRIVATE KEY', der);
  }

  /// The RSASSA-PKCS1-v1_5 signature with SHA-256 (RFC 8017) of [message].
  Uint8List sign(List<int> message) {
    final k = (n.bitLength + 7) ~/ 8;
    final t = [..._sha256Info, ...sha256.convert(message).bytes];
    final em = [0, 1, ...List.filled(k - t.length - 3, 0xFF), 0, ...t];
    return bigIntBytes(unsignedBigInt(em).modPow(d, n), k);
  }
}

/// [der] as PEM with the label [label].
String pemOf(String label, List<int> der) {
  final text = base64.encode(der);
  return [
    '-----BEGIN $label-----',
    for (var i = 0; i < text.length; i += 64)
      text.substring(i, min(i + 64, text.length)),
    '-----END $label-----',
    '',
  ].join('\n');
}

/// A certificate of [key]'s public key, signed by [issuerKey] (by default [key] itself) in the name [issuer]: the
/// subject [commonName] and [organizationalUnit] (an Apple certificate's team ID), valid until [notAfter].
Uint8List testCertificate(
  TestRsaKey key, {
  String commonName = 'Apple Distribution: Example (TEAM000000)',
  String? organizationalUnit = 'TEAM000000',
  required DateTime notAfter,
  BigInt? serial,
  TestRsaKey? issuerKey,
  String issuer = 'Example Test CA',
}) {
  List<int> name(Map<String, String> parts) => _seq([
    for (final MapEntry(:key, :value) in parts.entries)
      _der(0x31, _seq([_oid(key), _der(0x0C, utf8.encode(value))])),
  ]);
  String utc(DateTime t) {
    final u = t.toUtc();
    String two(int v) => '$v'.padLeft(2, '0');
    return '${two(u.year % 100)}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
  }

  final tbs = _seq([
    _der(0xA0, _int(BigInt.two)),
    _int(serial ?? BigInt.parse('1234ABCD', radix: 16)),
    _algorithm(_sha256Rsa),
    name({'2.5.4.3': issuer}),
    _seq([
      _der(
        0x17,
        latin1.encode(utc(notAfter.subtract(const Duration(days: 365)))),
      ),
      _der(0x17, latin1.encode(utc(notAfter))),
    ]),
    name({
      '2.5.4.3': commonName,
      '2.5.4.11': ?organizationalUnit,
      '2.5.4.10': 'Example',
    }),
    _seq([
      _algorithm(_rsa),
      _der(0x03, [
        0,
        ..._seq([_int(key.n), _int(key.e)]),
      ]),
    ]),
  ]);
  return Uint8List.fromList(
    _seq([
      tbs,
      _algorithm(_sha256Rsa),
      _der(0x03, [0, ...(issuerKey ?? key).sign(tbs)]),
    ]),
  );
}

/// The files of an IPA, [files], with every Mach-O file under the app signed as zsign signs it: the frameworks' and
/// the app's executables with their bundle's identifier, Info.plist and `_CodeSignature/CodeResources`, other Mach-O
/// files with their file name; [entitlements] (XML, and DER unless not [derEntitlements]) on the app's executable and
/// none on the rest; each CMS signature by [key] with [certificate]; and [profile] as `embedded.mobileprovision`.
Map<String, List<int>> signTestIpa(
  Map<String, List<int>> files, {
  required String teamId,
  required PlistMap entitlements,
  required TestRsaKey key,
  required Uint8List certificate,
  required List<int> profile,
  bool derEntitlements = true,
  DateTime? signingTime,
}) {
  final out = {for (final MapEntry(:key, :value) in files.entries) key: value};
  final app = out.keys
      .firstWhere(
        (n) => RegExp(r'^Payload/[^/]+\.app/Info\.plist$').hasMatch(n),
      )
      .replaceFirst(RegExp(r'Info\.plist$'), '');
  out['${app}embedded.mobileprovision'] = profile;
  final cert = readCertificate(certificate);
  final time = signingTime ?? DateTime.utc(2026, 1, 1);

  ({String id, String executable})? bundleOf(String folder) {
    final info = out['${folder}Info.plist'];
    if (info == null) {
      return null;
    }
    if (parsePlistBytes(Uint8List.fromList(info)) case {
      'CFBundleIdentifier': final String id,
      'CFBundleExecutable': final String executable,
    }) {
      return (id: id, executable: executable);
    }
    return null;
  }

  final frameworks = {
    for (final f in out.keys)
      if (f.startsWith(app))
        for (final m in RegExp(r'[^/]+\.framework/').allMatches(f, app.length))
          f.substring(0, m.end),
  }.where((f) => bundleOf(f) != null).toList();
  final bundles = [...frameworks, app];
  final executables = {for (final b in bundles) '$b${bundleOf(b)!.executable}'};

  List<int> signed(String file, {String? identifier, String? folder}) =>
      _signMachO(
        out[file]!,
        identifier: identifier ?? file.substring(file.lastIndexOf('/') + 1),
        teamId: teamId,
        infoPlist: folder == null ? null : out['${folder}Info.plist'],
        resources: folder == null
            ? null
            : out['${folder}_CodeSignature/CodeResources'],
        entitlements: file == '$app${bundleOf(app)!.executable}'
            ? entitlements
            : const {},
        der: derEntitlements && file == '$app${bundleOf(app)!.executable}',
        key: key,
        certificate: cert,
        time: time,
      );

  // Loose Mach-O files first, then each framework, then the app: each seal covers the files in their final form.
  for (final file in out.keys.toList()) {
    if (file.startsWith(app) &&
        !executables.contains(file) &&
        _isMachO(out[file]!)) {
      out[file] = signed(file);
    }
  }
  for (final folder in bundles) {
    final b = bundleOf(folder)!;
    out['${folder}_CodeSignature/CodeResources'] = utf8.encode(
      _codeResources(out, folder, b.executable),
    );
    final executable = '$folder${b.executable}';
    out[executable] = signed(executable, identifier: b.id, folder: folder);
  }
  return out;
}

String _codeResources(
  Map<String, List<int>> files,
  String folder,
  String executable,
) {
  final inside =
      [
        for (final f in files.keys)
          if (f.startsWith(folder) && !f.endsWith('/'))
            f.substring(folder.length),
      ]..removeWhere(
        (f) =>
            f == executable ||
            f == '_CodeSignature/CodeResources' ||
            f.endsWith('.lproj/locversion.plist'),
      );
  Uint8List hash(Hash h, String f) =>
      Uint8List.fromList(h.convert(files['$folder$f']!).bytes);
  return writePlist({
    'files': {for (final f in inside) f: hash(sha1, f)},
    'files2': {
      for (final f in inside)
        if (f != 'Info.plist' && f != 'PkgInfo' && !f.endsWith('.DS_Store'))
          f: {'hash': hash(sha1, f), 'hash2': hash(sha256, f)},
    },
    'rules': <String, Object?>{},
    'rules2': <String, Object?>{},
  });
}

bool _isMachO(List<int> head) =>
    head.length >= 4 &&
    head[0] == 0xCF &&
    head[1] == 0xFA &&
    head[2] == 0xED &&
    head[3] == 0xFE;

/// [original] wrapped in a 64-bit Mach-O whose only load command is an `LC_CODE_SIGNATURE`, signed.
Uint8List _signMachO(
  List<int> original, {
  required String identifier,
  required String teamId,
  required List<int>? infoPlist,
  required List<int>? resources,
  required PlistMap entitlements,
  required bool der,
  required TestRsaKey key,
  required Certificate certificate,
  required DateTime time,
}) {
  const reserve = 16384;
  final codeLimit = 32 + 16 + original.length;
  final head = ByteData(48)
    ..setUint32(0, 0xFEEDFACF, Endian.little)
    ..setUint32(4, 0x0100000C, Endian.little)
    ..setUint32(12, 2, Endian.little)
    ..setUint32(16, 1, Endian.little)
    ..setUint32(20, 16, Endian.little)
    ..setUint32(32, 0x1D, Endian.little)
    ..setUint32(36, 16, Endian.little)
    ..setUint32(40, codeLimit, Endian.little)
    ..setUint32(44, reserve, Endian.little);
  final code = [...head.buffer.asUint8List(), ...original];

  final requirements = [0xFA, 0xDE, 0x0C, 0x01, 0, 0, 0, 12, 0, 0, 0, 0];
  final xml = _blob(0xFADE7171, utf8.encode(writePlist(entitlements)));
  final derBlob = der
      ? _blob(0xFADE7172, _derEntitlements(entitlements))
      : null;
  final specials = <int, List<int>?>{
    1: infoPlist,
    2: requirements,
    3: resources,
    5: xml,
    7: derBlob,
  };
  final nSpecial = specials.entries
      .where((s) => s.value != null)
      .map((s) => s.key)
      .reduce(max);
  final ident = [...utf8.encode(identifier), 0];
  final team = [...utf8.encode(teamId), 0];
  const header = 88;
  final hashOffset = header + ident.length + team.length + 32 * nSpecial;
  final nCode = (codeLimit + 4095) ~/ 4096;
  final cd = ByteData(hashOffset + 32 * nCode)
    ..setUint32(0, 0xFADE0C02)
    ..setUint32(4, hashOffset + 32 * nCode)
    ..setUint32(8, 0x20400)
    ..setUint32(16, hashOffset)
    ..setUint32(20, header)
    ..setUint32(24, nSpecial)
    ..setUint32(28, nCode)
    ..setUint32(32, codeLimit)
    ..setUint8(36, 32)
    ..setUint8(37, 2)
    ..setUint8(39, 12)
    ..setUint32(48, header + ident.length);
  final bytes = cd.buffer.asUint8List()
    ..setAll(header, ident)
    ..setAll(header + ident.length, team);
  for (final MapEntry(key: slot, value: source) in specials.entries) {
    if (source != null) {
      bytes.setAll(hashOffset - 32 * slot, sha256.convert(source).bytes);
    }
  }
  for (var i = 0; i < nCode; i++) {
    bytes.setAll(
      hashOffset + 32 * i,
      sha256
          .convert(code.sublist(i * 4096, min((i + 1) * 4096, codeLimit)))
          .bytes,
    );
  }
  final cms = _blob(0xFADE0B01, _cms(bytes, key, certificate, time));
  final blobs = <(int, List<int>)>[
    (0, bytes),
    (2, requirements),
    (5, xml),
    if (derBlob != null) (7, derBlob),
    (0x10000, cms),
  ];
  final superBlob = BytesBuilder();
  var offset = 12 + 8 * blobs.length;
  final index = <int>[];
  for (final (type, blob) in blobs) {
    index.addAll([type, offset]);
    offset += blob.length;
  }
  for (final v in [0xFADE0CC0, offset, blobs.length, ...index]) {
    superBlob.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());
  }
  for (final (_, blob) in blobs) {
    superBlob.add(blob);
  }
  if (superBlob.length > reserve) {
    throw StateError('the test signature is larger than its space');
  }
  return Uint8List.fromList([
    ...code,
    ...superBlob.takeBytes(),
    ...List.filled(reserve - offset, 0),
  ]);
}

List<int> _blob(int magic, List<int> data) => [
  ...(ByteData(8)
        ..setUint32(0, magic)
        ..setUint32(4, 8 + data.length))
      .buffer
      .asUint8List(),
  ...data,
];

List<int> _derEntitlements(PlistMap entitlements) =>
    _der(0x70, [..._int(BigInt.one), ..._derDict(entitlements)]);

List<int> _derDict(Map<Object?, Object?> m) => _der(0xB0, [
  for (final k in m.keys.map((k) => '$k').toList()..sort())
    ..._seq([_der(0x0C, utf8.encode(k)), _derValue(m[k])]),
]);

List<int> _derValue(Object? v) => switch (v) {
  final bool b => _der(0x01, [if (b) 0xFF else 0]),
  final int i => _int(BigInt.from(i)),
  final String s => _der(0x0C, utf8.encode(s)),
  final List<Object?> l => _seq([for (final x in l) _derValue(x)]),
  final Map<Object?, Object?> m => _derDict(m),
  _ => throw ArgumentError('a test entitlement of type ${v.runtimeType}'),
};

List<int> _cms(
  Uint8List cd,
  TestRsaKey key,
  Certificate certificate,
  DateTime time,
) {
  List<int> attribute(String oid, List<int> value) =>
      _seq([_oid(oid), _der(0x31, value)]);
  final utc = time
      .toUtc()
      .toIso8601String()
      .replaceAll(RegExp(r'[-:T]'), '')
      .substring(2, 14);
  final cdhash = Uint8List.fromList(sha256.convert(cd).bytes.sublist(0, 20));
  final attributes = [
    ...attribute(_contentType, _oid(_data)),
    ...attribute('1.2.840.113549.1.9.5', _der(0x17, latin1.encode('${utc}Z'))),
    ...attribute(_messageDigest, _der(0x04, sha256.convert(cd).bytes)),
    ...attribute(
      '1.2.840.113635.100.9.1',
      _der(
        0x04,
        utf8.encode(
          writePlist({
            'cdhashes': [cdhash],
          }),
        ),
      ),
    ),
  ];
  final signer = _seq([
    _int(BigInt.one),
    _seq([certificate.issuer, _int(certificate.serial)]),
    _algorithm(_sha256),
    _der(0xA0, attributes),
    _algorithm(_rsa),
    _der(0x04, key.sign(_der(0x31, attributes))),
  ]);
  return _seq([
    _oid(_signedData),
    _der(
      0xA0,
      _seq([
        _int(BigInt.one),
        _der(0x31, _algorithm(_sha256)),
        _seq([_oid(_data)]),
        _der(0xA0, certificate.der),
        _der(0x31, signer),
      ]),
    ),
  ]);
}

const _rsa = '1.2.840.113549.1.1.1';
const _sha256Rsa = '1.2.840.113549.1.1.11';
const _sha256 = '2.16.840.1.101.3.4.2.1';
const _data = '1.2.840.113549.1.7.1';
const _signedData = '1.2.840.113549.1.7.2';
const _contentType = '1.2.840.113549.1.9.3';
const _messageDigest = '1.2.840.113549.1.9.4';

const _sha256Info = [
  0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, //
  0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
];

List<int> _der(int tag, List<int> content) {
  final n = content.length;
  final length = n < 0x80
      ? [n]
      : n < 0x100
      ? [0x81, n]
      : n < 0x10000
      ? [0x82, n >> 8, n & 0xFF]
      : [0x83, n >> 16, n >> 8 & 0xFF, n & 0xFF];
  return [tag, ...length, ...content];
}

List<int> _seq(List<List<int>> parts) =>
    _der(0x30, [for (final p in parts) ...p]);

List<int> _int(BigInt v) {
  var hex = v.toRadixString(16);
  if (hex.length.isOdd) {
    hex = '0$hex';
  }
  final bytes = [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
  return _der(0x02, [if (bytes.first & 0x80 != 0) 0, ...bytes]);
}

List<int> _oid(String dotted) {
  final parts = dotted.split('.').map(int.parse).toList();
  final out = <int>[40 * parts[0] + parts[1]];
  for (final p in parts.skip(2)) {
    final groups = <int>[p & 0x7F];
    for (var rest = p >> 7; rest > 0; rest >>= 7) {
      groups.insert(0, rest & 0x7F | 0x80);
    }
    out.addAll(groups);
  }
  return _der(0x06, out);
}

List<int> _algorithm(String oid) => _seq([
  _oid(oid),
  const [0x05, 0x00],
]);

BigInt _prime(int bits, Random random) {
  while (true) {
    var candidate = BigInt.zero;
    for (var i = 0; i < bits; i += 16) {
      candidate = candidate << 16 | BigInt.from(random.nextInt(1 << 16));
    }
    candidate =
        candidate.toUnsigned(bits) |
        BigInt.one |
        (BigInt.from(3) << (bits - 2));
    if (_probablyPrime(candidate, random)) {
      return candidate;
    }
  }
}

bool _probablyPrime(BigInt n, Random random) {
  for (final small in [3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47]) {
    if (n % BigInt.from(small) == BigInt.zero) {
      return false;
    }
  }
  final minusOne = n - BigInt.one;
  var d = minusOne;
  var s = 0;
  while (d.isEven) {
    d >>= 1;
    s++;
  }
  for (var round = 0; round < 24; round++) {
    final a = BigInt.from(2 + random.nextInt(1 << 30));
    var x = a.modPow(d, n);
    if (x == BigInt.one || x == minusOne) {
      continue;
    }
    var composite = true;
    for (var i = 1; i < s && composite; i++) {
      x = x.modPow(BigInt.two, n);
      composite = x != minusOne;
    }
    if (composite) {
      return false;
    }
  }
  return true;
}
