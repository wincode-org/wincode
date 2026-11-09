import 'dart:convert';
import 'dart:typed_data';

import 'macho_inspect.dart';
import 'plist.dart';

/// The entitlements that the code signature of [macho], a 64-bit Mach-O file ([readMachO]), claims: the property list of
/// its entitlements blob (`docs/formats/code-signature-entitlements.md`).
///
/// Null when the file is not signed, empty when its signature carries no entitlements. The signature's hashes are not
/// checked. Throws a [FormatException] for a file or signature that cannot be read.
PlistMap? readSignedEntitlements(Uint8List macho) {
  final signature = readMachO(macho).codeSignature;
  if (signature == null) {
    return null;
  }
  try {
    final blob = ByteData.sublistView(
      macho,
      signature.offset,
      signature.offset + signature.size,
    );
    if (blob.getUint32(0) != 0xFADE0CC0) {
      throw const FormatException(
        'the code signature is not an embedded signature',
      );
    }
    for (var i = 0; i < blob.getUint32(8); i++) {
      if (blob.getUint32(12 + 8 * i) != 5) {
        continue;
      }
      final at = blob.getUint32(16 + 8 * i);
      if (blob.getUint32(at) != 0xFADE7171) {
        throw const FormatException(
          'the entitlements blob has the wrong magic',
        );
      }
      final xml = utf8.decode(
        Uint8List.sublistView(
          macho,
          signature.offset + at + 8,
          signature.offset + at + blob.getUint32(at + 4),
        ),
      );
      return switch (parsePlist(xml)) {
        final PlistMap entitlements => entitlements,
        _ => throw const FormatException(
          'the entitlements are not a dictionary',
        ),
      };
    }
    return {};
  } on RangeError {
    throw const FormatException('the code signature is cut short');
  }
}
