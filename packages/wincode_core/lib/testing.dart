/// Test support for winCode's packages: zip archives, signed Mach-O executables and provisioning profiles made in code,
/// with made-up IDs. Not for use outside tests.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'src/plist.dart';
import 'src/zip.dart';

/// A zip archive of [files], in order: deflated when [deflate], else stored. A name that ends in `/` is a folder.
Uint8List zipOf(Map<String, List<int>> files, {bool deflate = true}) {
  final out = BytesBuilder();
  final directory = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add([v & 0xFF, v >> 8 & 0xFF]);
  void u32(BytesBuilder b, int v) {
    u16(b, v & 0xFFFF);
    u16(b, v >> 16 & 0xFFFF);
  }

  for (final MapEntry(key: name, value: data) in files.entries) {
    final packed = deflate ? ZLibEncoder(raw: true).convert(data) : data;
    final nameBytes = utf8.encode(name);
    final offset = out.length;
    final fields = [
      deflate ? 8 : 0,
      0,
      0,
      crc32(data),
      packed.length,
      data.length,
      nameBytes.length,
      0,
    ];
    // The local header, then the same fields in the central directory.
    u32(out, 0x04034B50);
    u16(out, 20);
    u16(out, 0x800);
    for (final (i, v) in fields.indexed) {
      i == 3 || i == 4 || i == 5 ? u32(out, v) : u16(out, v);
    }
    out
      ..add(nameBytes)
      ..add(packed);
    u32(directory, 0x02014B50);
    u16(directory, 20);
    u16(directory, 20);
    u16(directory, 0x800);
    for (final (i, v) in fields.indexed) {
      i == 3 || i == 4 || i == 5 ? u32(directory, v) : u16(directory, v);
    }
    for (final v in [0, 0, 0]) {
      u16(directory, v);
    }
    u32(directory, 0);
    u32(directory, offset);
    directory.add(nameBytes);
  }
  final start = out.length;
  final size = directory.length;
  out.add(directory.takeBytes());
  u32(out, 0x06054B50);
  for (final v in [0, 0, files.length, files.length]) {
    u16(out, v);
  }
  u32(out, size);
  u32(out, start);
  u16(out, 0);
  return out.takeBytes();
}

/// A 64-bit arm64 Mach-O executable. When [signed], it has an `LC_CODE_SIGNATURE` whose SuperBlob holds a code
/// directory and, unless [entitlements] is null, an entitlements blob with them, as zsign writes one.
Uint8List executable({bool signed = true, PlistMap? entitlements}) {
  final b = BytesBuilder();
  void u32(int v, [Endian endian = Endian.little]) =>
      b.add((ByteData(4)..setUint32(0, v, endian)).buffer.asUint8List());
  const signatureAt = 64;
  final blobs = <(int, List<int>)>[
    (0, [0xFA, 0xDE, 0x0C, 0x02, 0, 0, 0, 8]),
    if (entitlements != null)
      (5, _blob(0xFADE7171, utf8.encode(writePlist(entitlements)))),
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
  // mach_header_64: magic, CPU arm64, subtype, MH_EXECUTE, one load command of 16 bytes, flags, reserved.
  for (final v in [
    0xFEEDFACF,
    0x0100000C,
    0,
    2,
    signed ? 1 : 0,
    signed ? 16 : 0,
    0,
    0,
  ]) {
    u32(v);
  }
  if (signed) {
    for (final v in [0x1D, 16, signatureAt, superBlob.length]) {
      u32(v);
    }
  }
  b.add(Uint8List(signatureAt - b.length));
  if (signed) {
    b.add(superBlob.takeBytes());
  }
  return b.takeBytes();
}

List<int> _blob(int magic, List<int> data) => [
  ...(ByteData(8)
        ..setUint32(0, magic)
        ..setUint32(4, 8 + data.length))
      .buffer
      .asUint8List(),
  ...data,
];

/// A provisioning profile as the developer portal delivers one: [plist] as XML inside a CMS SignedData in DER, with a
/// made-up signature after it.
Uint8List profileOf(PlistMap plist) {
  List<int> der(int tag, List<int> contents) => [
    tag,
    if (contents.length < 0x80)
      contents.length
    else ...[
      0x82,
      contents.length >> 8,
      contents.length & 0xFF,
    ],
    ...contents,
  ];
  const signedData = [
    0x06,
    0x09,
    0x2A,
    0x86,
    0x48,
    0x86,
    0xF7,
    0x0D,
    0x01,
    0x07,
    0x02,
  ];
  const data = [
    0x06,
    0x09,
    0x2A,
    0x86,
    0x48,
    0x86,
    0xF7,
    0x0D,
    0x01,
    0x07,
    0x01,
  ];
  final content = der(0x30, [
    ...data,
    ...der(0xA0, der(0x04, utf8.encode(writePlist(plist)))),
  ]);
  return Uint8List.fromList(
    der(0x30, [
      ...signedData,
      ...der(
        0xA0,
        der(0x30, [
          0x02,
          0x01,
          0x01,
          0x31,
          0x00,
          ...content,
          ...der(0x31, List.filled(300, 0x5A)),
        ]),
      ),
    ]),
  );
}

/// The property list of an App Store profile of team [teamId] for [bundleId] that expires at [expires]. [devices] makes
/// it an ad hoc one, [debuggable] a development one. [uuid] is made up, never a real profile's.
PlistMap appStoreProfile({
  required String teamId,
  required String bundleId,
  required DateTime expires,
  bool devices = false,
  bool debuggable = false,
  String uuid = '00000000-0000-0000-0000-000000000000',
}) => {
  'AppIDName': 'Example',
  'ApplicationIdentifierPrefix': [teamId],
  'CreationDate': expires.subtract(const Duration(days: 365)),
  'Platform': ['iOS'],
  'DeveloperCertificates': [
    Uint8List.fromList([0x30, 0x00]),
  ],
  'Entitlements': {
    'application-identifier': '$teamId.$bundleId',
    'keychain-access-groups': ['$teamId.*'],
    'get-task-allow': debuggable,
    'com.apple.developer.team-identifier': teamId,
  },
  'ExpirationDate': expires,
  'Name': 'Example App Store',
  if (devices) 'ProvisionedDevices': ['00000000-0000000000000000'],
  'TeamIdentifier': [teamId],
  'TeamName': 'Example',
  'TimeToLive': 365,
  'UUID': uuid,
  'Version': 1,
};
