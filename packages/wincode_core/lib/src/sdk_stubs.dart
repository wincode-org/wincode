import 'dart:io';

/// `$ld$previous$<installName>$<compat>$<platform>$<start>$<end>$<symbol>$`: for a minimum OS in [start, end) on the
/// platform, [symbol] is in the library named [installName], not in this one. An empty [symbol] means this library
/// itself had that name.
typedef Previous = ({
  String installName,
  int platform,
  String start,
  String end,
  String symbol,
});

/// `$ld$hide$os<os>$<symbol>`: at a minimum OS of exactly [os] the library does not export [symbol]. A null [os]
/// (`$ld$hide$<symbol>`) hides it at every OS.
typedef Hidden = ({String? os, String symbol});

/// What the SDK's text stub (`.tbd`) says about one library: the parts of it that tell which OS versions have the
/// library or one of its symbols. See `docs/formats/macho-conformance.md`.
class LibraryStub {
  const LibraryStub({
    required this.installName,
    required this.restricted,
    required this.previous,
    required this.installNames,
    required this.hidden,
  });

  final String installName;

  /// Whether the stub lists `allowable-clients`: only those may link the library, and everyone else reaches its symbols
  /// through the library that re-exports it.
  final bool restricted;

  /// The `$ld$previous$` directives.
  final Set<Previous> previous;

  /// The `$ld$install_name$os<version>$<name>` directives, as version to name: at a minimum OS of exactly that version
  /// the library has that name.
  final Map<String, String> installNames;

  /// The `$ld$hide$` directives.
  final Set<Hidden> hidden;
}

/// Reads the text stub of the library [installName] from the SDK folder [sdk] (`iPhoneOS.sdk`), or returns null when the
/// SDK has none. The stub of `/a/b/Name` or `/a/b/Name.dylib` is `a/b/Name.tbd` under the SDK or under its
/// `System/Cryptexes/OS`, and one file can hold the stubs of several libraries, one YAML document each.
///
/// Only TBD version 4 is read; another version is a [FormatException].
LibraryStub? readLibraryStub(Directory sdk, String installName) {
  final relative =
      '${installName.endsWith('.dylib') ? installName.substring(0, installName.length - 6) : installName}.tbd';
  for (final path in [
    '${sdk.path}$relative',
    '${sdk.path}/System/Cryptexes/OS$relative',
  ]) {
    final file = File(path);
    if (!file.existsSync()) {
      continue;
    }
    for (final document in file.readAsStringSync().split(
      RegExp(r'^--- !tapi-tbd', multiLine: true),
    )) {
      final name = RegExp(
        r"^install-name:\s*'?([^'\r\n]+)",
        multiLine: true,
      ).firstMatch(document)?.group(1)?.trim();
      if (name != installName) {
        continue;
      }
      final version = RegExp(
        r'^tbd-version:\s*(\d+)',
        multiLine: true,
      ).firstMatch(document)?.group(1);
      if (version != '4') {
        throw FormatException(
          'the stub of $installName in $path has TBD version $version; only version 4 is read',
        );
      }
      return _stub(name!, document);
    }
  }
  return null;
}

LibraryStub _stub(String installName, String document) {
  final previous = <Previous>{};
  final installNames = <String, String>{};
  final hidden = <Hidden>{};
  // Symbol names hold no quote, space, comma or bracket, whether the YAML quotes them or not.
  for (final m in RegExp(
    r"\$ld\$(previous|install_name|hide)\$([^'\s,\]]*)",
  ).allMatches(document)) {
    final body = m.group(2)!;
    switch (m.group(1)) {
      case 'previous':
        // <installName>$<compat>$<platform>$<start>$<end>$<symbol>$, and the symbol can itself hold a '$'.
        final f = body.split(r'$');
        if (f.length < 7) {
          throw FormatException('malformed directive in $installName: $body');
        }
        previous.add((
          installName: f[0],
          platform: int.parse(f[2]),
          start: f[3],
          end: f[4],
          symbol: f.sublist(5, f.length - 1).join(r'$'),
        ));
      case 'install_name':
        final v = RegExp(r'^os([\d.]+)\$(.+)$').firstMatch(body);
        if (v == null) {
          throw FormatException('malformed directive in $installName: $body');
        }
        installNames[v.group(1)!] = v.group(2)!;
      case 'hide':
        final v = RegExp(r'^os([\d.]+)\$(.+)$').firstMatch(body);
        hidden.add((os: v?.group(1), symbol: v?.group(2) ?? body));
    }
  }
  return LibraryStub(
    installName: installName,
    restricted: RegExp(
      r'^allowable-clients:',
      multiLine: true,
    ).hasMatch(document),
    previous: previous,
    installNames: installNames,
    hidden: hidden,
  );
}
