import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'certificate.dart';
import 'der.dart';
import 'plist.dart';
import 'zip.dart';

const _oidData = '1.2.840.113549.1.7.1';
const _oidSignedData = '1.2.840.113549.1.7.2';
const _oidContentType = '1.2.840.113549.1.9.3';
const _oidMessageDigest = '1.2.840.113549.1.9.4';
const _oidCdHashes = '1.2.840.113635.100.9.1';
const _oidSha256 = '2.16.840.1.101.3.4.2.1';
const _oidRsa = '1.2.840.113549.1.1.1';
const _oidSha256Rsa = '1.2.840.113549.1.1.11';

/// What [checkSignedIpa] found. The IPA is signed as it should be when [failures] is empty.
class SignatureCheck {
  SignatureCheck._();

  final failures = <String>[];
  final warnings = <String>[];

  /// The Mach-O files whose every slice was checked, and the bundles whose `CodeResources` were.
  int machOs = 0;
  int bundles = 0;

  void _fail(String what) => failures.add(what);
}

/// Checks the signatures of the IPA in [zip] as zsign writes them (`docs/formats/code-signature-verification.md`):
/// every Mach-O file carries a signature of [teamId] whose code directories hash its pages, its bundle's Info.plist,
/// its requirements, its bundle's `CodeResources` and its entitlements; the app's executable carries [entitlements],
/// as XML and DER, and every other file none; each CMS signature is [certificate]'s; each `CodeResources` seals exactly
/// the bundle's files; the embedded profile is [profile], byte for byte; the IPA holds only `Payload/`.
///
/// An app with extensions or a watch app is a failure: `wincode sign` does not sign them.
SignatureCheck checkSignedIpa(
  ZipArchive zip, {
  required String teamId,
  required PlistMap entitlements,
  required Certificate certificate,
  required Uint8List profile,
}) {
  final check = SignatureCheck._();
  final outside = zip.names.where((n) => !n.startsWith('Payload/')).length;
  if (outside > 0) {
    check._fail('the IPA holds $outside entries outside Payload/');
  }
  final apps = [
    for (final n in zip.names)
      if (RegExp(r'^Payload/[^/]+\.app/Info\.plist$').hasMatch(n))
        n.substring(0, n.length - 'Info.plist'.length),
  ];
  if (apps.length != 1) {
    check._fail(
      apps.isEmpty
          ? 'the IPA holds no Payload/<name>.app with an Info.plist'
          : 'the IPA holds ${apps.length} apps in Payload/',
    );
    return check;
  }
  final app = apps.single;
  final files = [
    for (final n in zip.names)
      if (n.startsWith(app) && !n.endsWith('/')) n,
  ];
  final unsupported = nestedCodeOf(files, app);
  if (unsupported.isNotEmpty) {
    check._fail(
      'the app holds ${unsupported.join(', ')}, which needs its own profile: not supported yet',
    );
    return check;
  }

  // The bundles: the app, and each .framework with an Info.plist naming its identifier and executable.
  final bundles = <String, ({String id, String executable})>{};
  final frameworks = {
    for (final f in files)
      for (final m in RegExp(r'[^/]+\.framework/').allMatches(f, app.length))
        f.substring(0, m.end),
  };
  for (final folder in [app, ...frameworks]) {
    final info = _plistOf(zip, '${folder}Info.plist');
    if (info case {
      'CFBundleIdentifier': final String id,
      'CFBundleExecutable': final String executable,
    }) {
      bundles[folder] = (id: id, executable: executable);
    }
  }
  final main = bundles[app];
  if (main == null) {
    check._fail(
      "the app's Info.plist names no CFBundleIdentifier and CFBundleExecutable",
    );
    return check;
  }

  final embedded = '${app}embedded.mobileprovision';
  if (!zip.names.contains(embedded)) {
    check._fail('the app holds no embedded.mobileprovision');
  } else if (!_sameBytes(zip.read(embedded), profile)) {
    check._fail('the embedded profile is not the configured profile');
  }

  final executables = {
    for (final MapEntry(key: folder, value: b) in bundles.entries)
      '$folder${b.executable}': folder,
  };
  if (!files.contains('$app${main.executable}')) {
    check._fail("the app's executable ${main.executable} is missing");
  }
  for (final file in files) {
    if (file.contains('.dSYM') || file.contains('_WatchKitStub')) {
      continue;
    }
    if (zip.sizeOf(file) < 4 || !_isMachO(zip.readRange(file, 0, 4))) {
      if (file == '$app${main.executable}') {
        check._fail(
          "the app's executable ${main.executable} is not a Mach-O file",
        );
      }
      continue;
    }
    final folder = executables[file];
    final name = file.substring('Payload/'.length);
    final isMain = file == '$app${main.executable}';
    _checkMachO(
      check,
      name,
      zip.read(file),
      expect: (
        identifier: folder != null
            ? bundles[folder]!.id
            : file.substring(file.lastIndexOf('/') + 1),
        teamId: teamId,
        infoPlist: folder != null ? zip.read('${folder}Info.plist') : null,
        resources: folder != null
            ? _readOrNull(zip, '${folder}_CodeSignature/CodeResources')
            : null,
        entitlements: isMain ? entitlements : const {},
        certificate: certificate,
      ),
    );
    check.machOs++;
  }
  for (final MapEntry(key: folder, value: b) in bundles.entries) {
    _checkResources(check, zip, folder, b.executable, files);
    check.bundles++;
  }
  return check;
}

/// The extensions (`.appex`) and nested apps (a watch app) under the app at [app] among [files], by their paths in the
/// app.
List<String> nestedCodeOf(Iterable<String> files, String app) => {
  for (final f in files)
    if (f.startsWith(app))
      for (final m in RegExp(r'[^/]+\.(appex|app)/').allMatches(f, app.length))
        f.substring(app.length, m.end - 1),
}.toList()..sort();

typedef _Expected = ({
  String identifier,
  String teamId,
  Uint8List? infoPlist,
  Uint8List? resources,
  PlistMap entitlements,
  Certificate certificate,
});

bool _isMachO(Uint8List head) {
  final le = ByteData.sublistView(head).getUint32(0, Endian.little);
  final be = ByteData.sublistView(head).getUint32(0);
  return const {0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE}.contains(le) ||
      be == 0xCAFEBABE;
}

void _checkMachO(
  SignatureCheck check,
  String name,
  Uint8List file, {
  required _Expected expect,
}) {
  final data = ByteData.sublistView(file);
  if (data.getUint32(0) == 0xCAFEBABF) {
    check._fail('$name: a 64-bit fat file, which zsign does not write');
    return;
  }
  if (data.getUint32(0) != 0xCAFEBABE) {
    _checkSlice(check, name, file, expect);
    return;
  }
  final count = data.getUint32(4);
  if (8 + 20 * count > file.length) {
    check._fail('$name: the fat header is cut short');
    return;
  }
  for (var i = 0; i < count; i++) {
    final offset = data.getUint32(8 + 20 * i + 8);
    final size = data.getUint32(8 + 20 * i + 12);
    if (offset + size > file.length) {
      check._fail('$name: slice $i runs past the end of the file');
      continue;
    }
    _checkSlice(
      check,
      '$name (slice $i)',
      Uint8List.sublistView(file, offset, offset + size),
      expect,
    );
  }
}

void _checkSlice(
  SignatureCheck check,
  String name,
  Uint8List slice,
  _Expected expect,
) {
  void fail(String what) => check._fail('$name: $what');
  try {
    final data = ByteData.sublistView(slice);
    final magic = data.getUint32(0, Endian.little);
    if (magic != 0xFEEDFACF && magic != 0xFEEDFACE) {
      return fail('not a little-endian Mach-O file');
    }
    ({int offset, int size})? found;
    var at = magic == 0xFEEDFACF ? 32 : 28;
    for (var i = data.getUint32(16, Endian.little); i > 0; i--) {
      final size = data.getUint32(at + 4, Endian.little);
      if (size < 8) {
        return fail('a load command is shorter than 8 bytes');
      }
      if (data.getUint32(at, Endian.little) == 0x1D) {
        found = (
          offset: data.getUint32(at + 8, Endian.little),
          size: data.getUint32(at + 12, Endian.little),
        );
      }
      at += size;
    }
    if (found == null) {
      return fail('not signed');
    }
    final signature = Uint8List.sublistView(
      slice,
      found.offset,
      found.offset + found.size,
    );
    final sig = ByteData.sublistView(signature);
    if (sig.getUint32(0) != 0xFADE0CC0) {
      return fail('the signature is not an embedded signature');
    }
    final blobs = <int, Uint8List>{};
    for (var i = 0; i < sig.getUint32(8); i++) {
      final offset = sig.getUint32(16 + 8 * i);
      blobs[sig.getUint32(12 + 8 * i)] = Uint8List.sublistView(
        signature,
        offset,
        offset + sig.getUint32(offset + 4),
      );
    }
    final directories = [
      for (final slot in [0, 0x1000, 0x1001, 0x1002, 0x1003, 0x1004])
        ?blobs[slot],
    ];
    if (blobs[0] == null) {
      return fail('the signature has no code directory');
    }
    final xml = blobs[5];
    final der = blobs[7];
    final infoPlist = expect.infoPlist;
    final resources = expect.resources;
    final specials = <int, Uint8List?>{
      1: infoPlist,
      2: blobs[2],
      3: resources,
      5: xml,
      7: der,
    };
    for (final directory in directories) {
      _checkDirectory(
        fail,
        directory,
        slice,
        codeEnd: found.offset,
        expect: expect,
        specials: specials,
      );
    }
    _checkEntitlements(check, name, fail, xml, der, expect.entitlements);
    final cms = blobs[0x10000];
    if (cms == null ||
        cms.length <= 8 ||
        ByteData.sublistView(cms).getUint32(0) != 0xFADE0B01) {
      return fail('the signature has no CMS signature');
    }
    _checkCms(
      fail,
      Uint8List.sublistView(cms, 8),
      directories,
      expect.certificate,
    );
  } on RangeError {
    fail('the signature is cut short');
  } on FormatException catch (e) {
    fail('the signature cannot be read: ${e.message}');
  }
}

List<int> _hash(int type, List<int> bytes) =>
    (type == 1 ? sha1 : sha256).convert(bytes).bytes;

void _checkDirectory(
  void Function(String) fail,
  Uint8List cd,
  Uint8List slice, {
  required int codeEnd,
  required _Expected expect,
  required Map<int, Uint8List?> specials,
}) {
  final d = ByteData.sublistView(cd);
  if (d.getUint32(0) != 0xFADE0C02) {
    return fail('a code directory has the wrong magic');
  }
  final version = d.getUint32(8);
  final hashOffset = d.getUint32(16);
  final nSpecial = d.getUint32(24);
  final nCode = d.getUint32(28);
  final hashSize = cd[36];
  final hashType = cd[37];
  final pageShift = cd[39];
  if (!(hashType == 1 && hashSize == 20 || hashType == 2 && hashSize == 32)) {
    return fail('a code directory of hash type $hashType');
  }
  if (version < 0x20200 || pageShift < 9 || pageShift > 16) {
    return fail(
      'a code directory of version 0x${version.toRadixString(16)} or page size 2^$pageShift',
    );
  }
  final kind = hashType == 1 ? 'SHA-1' : 'SHA-256';
  String cString(int offset) {
    final end = cd.indexOf(0, offset);
    return utf8.decode(
      Uint8List.sublistView(cd, offset, end < 0 ? cd.length : end),
    );
  }

  final identifier = cString(d.getUint32(20));
  if (identifier != expect.identifier) {
    fail('signed as $identifier, not ${expect.identifier}');
  }
  final teamOffset = d.getUint32(48);
  final team = teamOffset == 0 ? null : cString(teamOffset);
  if (team != expect.teamId) {
    fail('signed for team ${team ?? 'none'}, not ${expect.teamId}');
  }
  var codeLimit = d.getUint32(32);
  if (version >= 0x20300 && d.getUint64(56) != 0) {
    codeLimit = d.getUint64(56);
  }
  if (codeLimit != codeEnd) {
    return fail(
      'the $kind code directory hashes $codeLimit bytes, but the signature starts at $codeEnd',
    );
  }
  final page = 1 << pageShift;
  if (nCode != (codeLimit + page - 1) ~/ page) {
    return fail(
      'the $kind code directory has $nCode page hashes for $codeLimit bytes',
    );
  }
  for (var i = 0; i < nCode; i++) {
    final start = i * page;
    final end = start + page < codeLimit ? start + page : codeLimit;
    final want = _hash(hashType, Uint8List.sublistView(slice, start, end));
    final at = hashOffset + i * hashSize;
    if (!_sameBytes(Uint8List.sublistView(cd, at, at + hashSize), want)) {
      return fail('the $kind hash of page $i does not match the page');
    }
  }
  const names = {
    1: 'Info.plist',
    2: 'requirements',
    3: 'CodeResources',
    4: 'application slot',
    5: 'XML entitlements',
    6: 'slot -6',
    7: 'DER entitlements',
  };
  for (var slot = 1; slot <= 7; slot++) {
    final source = specials[slot];
    final at = hashOffset - slot * hashSize;
    final stored = slot <= nSpecial
        ? Uint8List.sublistView(cd, at, at + hashSize)
        : null;
    final empty = stored == null || stored.every((b) => b == 0);
    if (source == null) {
      if (!empty) {
        fail(
          'the $kind code directory has a hash for the ${names[slot]}, which the file does not have',
        );
      }
    } else if (empty) {
      fail('the $kind code directory has no hash for the ${names[slot]}');
    } else if (!_sameBytes(stored, _hash(hashType, source))) {
      fail('the $kind hash of the ${names[slot]} does not match it');
    }
  }
}

void _checkEntitlements(
  SignatureCheck check,
  String name,
  void Function(String) fail,
  Uint8List? xml,
  Uint8List? der,
  PlistMap want,
) {
  PlistMap signed = const {};
  if (xml != null) {
    if (ByteData.sublistView(xml).getUint32(0) != 0xFADE7171) {
      return fail('the XML entitlements blob has the wrong magic');
    }
    final parsed = parsePlist(utf8.decode(Uint8List.sublistView(xml, 8)));
    if (parsed is! PlistMap) {
      return fail('the XML entitlements are not a dictionary');
    }
    signed = parsed;
  }
  if (!plistEquals(signed, want)) {
    fail(
      'signed with the entitlements ${(signed.keys.toList()..sort()).join(', ')}, '
      'not ${(want.keys.toList()..sort()).join(', ')}',
    );
  }
  if (der == null) {
    if (signed.isNotEmpty) {
      check.warnings.add('$name: the signature has no DER entitlements');
    }
    return;
  }
  if (ByteData.sublistView(der).getUint32(0) != 0xFADE7172) {
    return fail('the DER entitlements blob has the wrong magic');
  }
  final top = Der.whole(Uint8List.sublistView(der, 8));
  top.expect(0x70);
  final parts = top.children;
  if (parts.length != 2 || parts[0].integer != BigInt.one) {
    return fail('the DER entitlements are not version 1');
  }
  if (!plistEquals(_derValue(parts[1]), signed)) {
    fail('the DER entitlements are not the XML entitlements');
  }
}

Object? _derValue(Der d) => switch (d.tag) {
  0x01 when d.value.length == 1 => d.value[0] != 0,
  0x02 => d.integer.toInt(),
  0x0C => utf8.decode(d.value),
  0x30 => [for (final c in d.children) _derValue(c)],
  0xB0 => {
    for (final entry in d.children)
      if (entry.items() case [final key, final value])
        key.text: _derValue(value),
  },
  _ => throw FormatException(
    'a DER entitlement of tag 0x${d.tag.toRadixString(16)}',
  ),
};

void _checkCms(
  void Function(String) fail,
  Uint8List cms,
  List<Uint8List> directories,
  Certificate certificate,
) {
  final info = Der.whole(cms).items();
  if (info[0].oid != _oidSignedData || info[1].tag != 0xA0) {
    return fail('the CMS signature is not signed data');
  }
  final signed = info[1].children.single.items();
  final content = signed[2].items();
  if (content[0].oid != _oidData || content.length != 1) {
    return fail('the CMS signature is not detached');
  }
  final certificates = signed.where((e) => e.tag == 0xA0).firstOrNull;
  if (certificates == null ||
      !certificates.children.any(
        (c) => _sameBytes(c.encoded, certificate.der),
      )) {
    fail('the CMS signature does not carry the chosen certificate');
  }
  final signers = signed.last.items(set: true);
  if (signers.length != 1) {
    return fail('the CMS signature has ${signers.length} signers');
  }
  final signer = signers.single.items();
  final sid = signer[1];
  if (sid.tag != 0x30 ||
      !_sameBytes(sid.items()[0].encoded, certificate.issuer) ||
      sid.items()[1].integer != certificate.serial) {
    return fail('the CMS signer is not the chosen certificate');
  }
  if (signer[2].items()[0].oid != _oidSha256) {
    return fail('the CMS signature does not use SHA-256');
  }
  final attributes = signer[3];
  if (attributes.tag != 0xA0) {
    return fail('the CMS signature has no signed attributes');
  }
  final values = <String, Der>{
    for (final a in attributes.children)
      a.items()[0].oid: a.items()[1].items(set: true).first,
  };
  if (values[_oidContentType]?.oid != _oidData) {
    fail('the CMS content type is not data');
  }
  final digest = values[_oidMessageDigest];
  if (digest == null ||
      digest.tag != 0x04 ||
      !_sameBytes(digest.value, sha256.convert(directories.first).bytes)) {
    fail('the CMS message digest is not the hash of the code directory');
  }
  final hashes = values[_oidCdHashes];
  final listed = hashes == null || hashes.tag != 0x04
      ? null
      : parsePlist(utf8.decode(hashes.value));
  final want = [for (final cd in directories) _hash(cd[37], cd).sublist(0, 20)];
  if (listed is! PlistMap ||
      !plistEquals(listed['cdhashes'], [
        for (final w in want) Uint8List.fromList(w),
      ])) {
    fail('the CMS cdhashes are not the hashes of the code directories');
  }
  final algorithm = signer[4].items()[0].oid;
  final rsa = certificate.rsa;
  if ((algorithm != _oidRsa && algorithm != _oidSha256Rsa) || rsa == null) {
    return fail('the CMS signature is not an RSA signature');
  }
  final message = Uint8List.fromList(attributes.encoded)..[0] = 0x31;
  signer[5].expect(0x04);
  if (!verifyRsaSha256(rsa, message, signer[5].value)) {
    fail("the CMS signature does not verify with the chosen certificate's key");
  }
}

void _checkResources(
  SignatureCheck check,
  ZipArchive zip,
  String folder,
  String executable,
  List<String> files,
) {
  final name = folder.substring('Payload/'.length, folder.length - 1);
  void fail(String what) => check._fail('$name: $what');
  final seal = '${folder}_CodeSignature/CodeResources';
  final plist = _plistOf(zip, seal);
  if (plist is! PlistMap) {
    return fail('_CodeSignature/CodeResources is missing or not a dictionary');
  }
  final inside =
      [
        for (final f in files)
          if (f.startsWith(folder)) f.substring(folder.length),
      ]..removeWhere(
        (f) =>
            f == executable ||
            f == '_CodeSignature/CodeResources' ||
            f.endsWith('.lproj/locversion.plist'),
      );
  final want1 = inside.toSet();
  final want2 = {
    for (final f in inside)
      if (f != 'Info.plist' && f != 'PkgInfo' && !f.endsWith('.DS_Store')) f,
  };
  final files1 = plist['files'];
  final files2 = plist['files2'];
  if (files1 is! PlistMap || files2 is! PlistMap) {
    return fail('CodeResources has no files and files2');
  }
  void compare(String key, Set<String> want, PlistMap got) {
    final missing = want.difference(got.keys.toSet()).toList()..sort();
    final extra = got.keys.toSet().difference(want).toList()..sort();
    for (final m in missing.take(3)) {
      fail('CodeResources $key does not seal $m');
    }
    for (final e in extra.take(3)) {
      fail('CodeResources $key seals $e, which the bundle does not hold');
    }
    if (missing.length + extra.length > 6) {
      fail(
        'CodeResources $key: ${missing.length} missing and ${extra.length} extra entries in all',
      );
    }
  }

  compare('files', want1, files1);
  compare('files2', want2, files2);
  var wrong = 0;
  for (final f in want1) {
    final bytes = zip.read('$folder$f');
    final one = sha1.convert(bytes).bytes;
    final entry1 = files1[f];
    final hash1 = entry1 is PlistMap ? entry1['hash'] : entry1;
    final entry2 = files2[f];
    final ok =
        (entry1 == null || hash1 is Uint8List && _sameBytes(hash1, one)) &&
        (entry2 == null ||
            entry2 is PlistMap &&
                entry2['hash'] is Uint8List &&
                _sameBytes(entry2['hash']! as Uint8List, one) &&
                entry2['hash2'] is Uint8List &&
                _sameBytes(
                  entry2['hash2']! as Uint8List,
                  sha256.convert(bytes).bytes,
                ));
    if (!ok && wrong++ < 3) {
      fail('the hash in CodeResources of $f does not match the file');
    }
  }
  if (wrong > 3) {
    fail('$wrong files in all do not match their hashes in CodeResources');
  }
}

Object? _plistOf(ZipArchive zip, String name) {
  if (!zip.names.contains(name)) {
    return null;
  }
  try {
    return parsePlistBytes(zip.read(name));
  } on FormatException {
    return null;
  }
}

Uint8List? _readOrNull(ZipArchive zip, String name) =>
    zip.names.contains(name) ? zip.read(name) : null;

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// Whether two property-list values are equal: dictionaries and arrays by content, data by bytes.
bool plistEquals(Object? a, Object? b) => switch ((a, b)) {
  (final Map<Object?, Object?> x, final Map<Object?, Object?> y) =>
    x.length == y.length &&
        x.keys.every((k) => y.containsKey(k) && plistEquals(x[k], y[k])),
  (final Uint8List x, final Uint8List y) => _sameBytes(x, y),
  (final List<Object?> x, final List<Object?> y) =>
    x.length == y.length &&
        [for (var i = 0; i < x.length; i++) i]
            .every((i) => plistEquals(x[i], y[i])),
  _ => a == b,
};
