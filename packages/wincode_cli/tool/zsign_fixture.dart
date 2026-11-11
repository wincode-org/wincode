/// Writes the inputs of the zsign integration job (.github/workflows/dart.yml): a minimal unsigned app of made-up IDs,
/// the property list of its App Store profile listing the certificate in the DER file given, the entitlements that
/// `wincode sign` would sign it with, and a wincode.yaml. Nothing here is Apple's: the app is a few hand-made Mach-O
/// files, and the job makes the certificate and signs the profile with a throwaway CA.
///
/// Usage: `dart run tool/zsign_fixture.dart <folder> <certificate.der>`
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wincode_cli/wincode_cli.dart' show signingEntitlements;
import 'package:wincode_core/testing.dart';
import 'package:wincode_core/wincode_core.dart'
    show readProvisioningProfile, writePlist;

const _team = 'TEAM000000';
const _bundleId = 'com.example.zsign';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
      'usage: dart run tool/zsign_fixture.dart <folder> <certificate.der>',
    );
    exit(64);
  }
  final folder = Directory(args[0])..createSync(recursive: true);
  final certificate = File(args[1]).readAsBytesSync();
  String inside(String name) => '${folder.path}${Platform.pathSeparator}$name';

  final profile = {
    ...appStoreProfile(
      teamId: _team,
      bundleId: _bundleId,
      expires: DateTime.now().toUtc().add(const Duration(days: 90)),
    ),
    'DeveloperCertificates': [certificate],
  };
  File(inside('profile.plist')).writeAsStringSync(writePlist(profile));
  final (:want, :problems) = signingEntitlements(
    readProvisioningProfile(profileOf(profile)),
    _bundleId,
  );
  if (problems.isNotEmpty) {
    throw StateError('the fixture profile does not allow its own entitlements');
  }
  File(inside('entitlements.plist')).writeAsStringSync(writePlist(want));

  const app = 'Payload/Example.app/';
  const framework = '${app}Frameworks/Lib.framework/';
  File(inside('unsigned.ipa')).writeAsBytesSync(
    zipOf({
      'Payload/': [],
      app: [],
      '${app}Info.plist': utf8.encode(
        writePlist({
          'CFBundleExecutable': 'Example',
          'CFBundleIdentifier': _bundleId,
          'CFBundleName': 'Example',
          'CFBundlePackageType': 'APPL',
          'CFBundleShortVersionString': '1.0',
          'CFBundleVersion': '1',
        }),
      ),
      '${app}Example': _machO(filetype: 2),
      '${app}assets/hello.txt': utf8.encode('hello'),
      '${framework}Info.plist': utf8.encode(
        writePlist({
          'CFBundleExecutable': 'Lib',
          'CFBundleIdentifier': 'com.example.zsign.lib',
          'CFBundlePackageType': 'FMWK',
        }),
      ),
      '${framework}Lib': _machO(filetype: 6),
    }),
  );
  File(inside('wincode.yaml')).writeAsStringSync(
    'bundle_id: $_bundleId\nteam_id: $_team\nprofile: profile.mobileprovision\noutput: build\n',
  );
}

/// A 64-bit arm64 Mach-O file of [filetype] (2: an executable, 6: a library) with what zsign needs to sign it: a
/// `__TEXT` segment whose `__text` section starts at 0x1000, leaving room for `LC_CODE_SIGNATURE` after the load
/// commands, and a `__LINKEDIT` segment at the end, which zsign grows to hold the signature.
Uint8List _machO({required int filetype}) {
  final file = ByteData(0x4010);
  var at = 0;
  void u32(int v) {
    file.setUint32(at, v, Endian.little);
    at += 4;
  }

  void u64(int v) {
    file.setUint64(at, v, Endian.little);
    at += 8;
  }

  void name(String text) {
    for (var i = 0; i < 16; i++) {
      file.setUint8(at + i, i < text.length ? text.codeUnitAt(i) : 0);
    }
    at += 16;
  }

  // mach_header_64: arm64, two load commands of 152 and 72 bytes.
  for (final v in [0xFEEDFACF, 0x0100000C, 0, filetype, 2, 224, 0, 0]) {
    u32(v);
  }
  // LC_SEGMENT_64 __TEXT with one section.
  u32(0x19);
  u32(152);
  name('__TEXT');
  for (final v in [0x100000000, 0x4000, 0, 0x4000]) {
    u64(v);
  }
  for (final v in [5, 5, 1, 0]) {
    u32(v);
  }
  name('__text');
  name('__TEXT');
  u64(0x100001000);
  u64(4);
  for (final v in [0x1000, 2, 0, 0, 0x80000400, 0, 0, 0]) {
    u32(v);
  }
  // LC_SEGMENT_64 __LINKEDIT.
  u32(0x19);
  u32(72);
  name('__LINKEDIT');
  for (final v in [0x100004000, 0x4000, 0x4000, 0x10]) {
    u64(v);
  }
  for (final v in [1, 1, 0, 0]) {
    u32(v);
  }
  // ret
  file.setUint32(0x1000, 0xD65F03C0, Endian.little);
  return file.buffer.asUint8List();
}
