import 'dart:convert';
import 'dart:typed_data';

import 'plist.dart';

const _lcCodeSignature = 0x1D;

/// Where the code signature lies in a 64-bit little-endian Mach-O file, read from [head], the first bytes of the file:
/// its header and load commands. Null when the file has no `LC_CODE_SIGNATURE`. Throws a [FormatException] for another
/// kind of file, or when [head] ends inside the load commands.
({int offset, int size})? codeSignatureOf(Uint8List head) {
  final data = ByteData.sublistView(head);
  if (head.length < 32 || data.getUint32(0, Endian.little) != 0xFEEDFACF) {
    throw const FormatException('not a 64-bit little-endian Mach-O file');
  }
  try {
    var offset = 32;
    for (var i = data.getUint32(16, Endian.little); i > 0; i--) {
      final command = data.getUint32(offset, Endian.little);
      final size = data.getUint32(offset + 4, Endian.little);
      if (size < 8) {
        throw const FormatException('a load command is shorter than 8 bytes');
      }
      if (command == _lcCodeSignature) {
        return (
          offset: data.getUint32(offset + 8, Endian.little),
          size: data.getUint32(offset + 12, Endian.little),
        );
      }
      offset += size;
    }
    return null;
  } on RangeError {
    throw const FormatException('the Mach-O file is truncated');
  }
}

/// The entitlements in [signature], the bytes that `LC_CODE_SIGNATURE` points to (see [codeSignatureOf]): the property
/// list of its entitlements blob (`docs/formats/code-signature-entitlements.md`). Empty when the signature carries
/// none. The signature's hashes are not checked. Throws a [FormatException] for a signature that cannot be read.
PlistMap entitlementsOfSignature(Uint8List signature) {
  try {
    final blob = ByteData.sublistView(signature);
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
        Uint8List.sublistView(signature, at + 8, at + blob.getUint32(at + 4)),
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

/// The entitlements that the code signature of [macho], a whole 64-bit Mach-O file, claims. Null when the file is not
/// signed. Throws a [FormatException] for a file or signature that cannot be read.
PlistMap? readSignedEntitlements(Uint8List macho) {
  final signature = codeSignatureOf(macho);
  if (signature == null) {
    return null;
  }
  if (signature.offset + signature.size > macho.length) {
    throw const FormatException('the code signature is cut short');
  }
  return entitlementsOfSignature(
    Uint8List.sublistView(
      macho,
      signature.offset,
      signature.offset + signature.size,
    ),
  );
}
