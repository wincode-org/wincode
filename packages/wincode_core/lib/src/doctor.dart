import 'dart:io';

/// One problem that `wincode doctor` reports: an [id] to refer to it by and a [message] that says what is wrong, why
/// it matters and what to do.
class DoctorFinding {
  const DoctorFinding(this.id, this.message);

  final String id;
  final String message;

  @override
  String toString() => '$id: $message';
}

/// Warns when the Flutter SDK at [flutterRoot] has Windows line endings in its files.
///
/// The SDK's `LICENSE` file is stored with LF line endings, so a carriage return in it means git converted the
/// checkout: `core.autocrlf=true` does that, and so does `core.eol=crlf` (or Windows' default, `native`) when the
/// repository asks for text normalization. The licence list `NOTICES.Z` that goes into `flutter_assets` is built from
/// those files, so with CRLF it changes, and the app no longer matches the same app built on a Mac.
///
/// Returns null when the file has LF endings, or when there is no `LICENSE` (an SDK that is not a git checkout).
DoctorFinding? checkFlutterSdkLineEndings(Directory flutterRoot) {
  final license = File('${flutterRoot.path}/LICENSE');
  if (!license.existsSync()) {
    return null;
  }
  final bytes = license.readAsBytesSync();
  final hasCrLf = [
    for (var i = 0; i + 1 < bytes.length; i++)
      bytes[i] == 13 && bytes[i + 1] == 10,
  ].contains(true);
  if (!hasCrLf) {
    return null;
  }
  return DoctorFinding(
    'flutter-sdk-line-endings',
    'The Flutter SDK at ${flutterRoot.path} has Windows line endings (CRLF), which git adds when core.autocrlf is '
        'true, or when core.eol is crlf or native on Windows. They change the licence list NOTICES.Z, so flutter_assets '
        'will not match a build made on a Mac. Use an SDK with LF endings: clone it again with '
        '`git clone --config core.autocrlf=false --config core.eol=lf https://github.com/flutter/flutter.git`, or take '
        'the official zip.',
  );
}
