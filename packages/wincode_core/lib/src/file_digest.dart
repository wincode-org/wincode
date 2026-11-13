import 'dart:io';

import 'package:crypto/crypto.dart';

/// The MD5 and the SHA-256 of [file], as lower-case hexadecimal, from one read in pieces: an IPA can be large, and is
/// not held in memory. MD5 is what App Store Connect asks for to check an upload (`sourceFileChecksums`); SHA-256 is
/// for the person who wants to compare or record the file.
Future<({String md5, String sha256})> digestsOfFile(File file) async {
  final md5Out = _Last();
  final shaOut = _Last();
  final md5Input = md5.startChunkedConversion(md5Out);
  final shaInput = sha256.startChunkedConversion(shaOut);
  try {
    await for (final chunk in file.openRead()) {
      md5Input.add(chunk);
      shaInput.add(chunk);
    }
  } finally {
    md5Input.close();
    shaInput.close();
  }
  return (md5: '${md5Out.digest}', sha256: '${shaOut.digest}');
}

class _Last implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
