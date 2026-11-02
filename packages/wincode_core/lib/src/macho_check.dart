import 'dart:io';

import 'macho_inspect.dart';
import 'sdk_stubs.dart';

/// A library or symbol that a binary uses although its minimum OS does not have it there, as the SDK's text stubs say
/// (`docs/formats/macho-conformance.md`).
class Violation {
  const Violation({
    required this.library,
    this.symbol,
    required this.reason,
    this.needs,
    required this.minOS,
  });

  /// The install name of the library.
  final String library;

  /// The bound symbol, or null when the library itself is the problem.
  final String? symbol;

  /// What the SDK says, in words.
  final String reason;

  /// The OS version that has the library or symbol where the binary uses it, when the SDK names one.
  final String? needs;

  /// The binary's minimum OS.
  final String minOS;

  @override
  String toString() =>
      '${symbol == null ? library : '$symbol (bound to $library)'}: $reason; '
      '${needs == null ? '' : 'it needs $needs, '}the minimum is $minOS';
}

/// Checks the Mach-O file [file] against the text stubs of the SDK folder [sdk] (`iPhoneOS.sdk`), for its minimum OS and
/// platform (`LC_BUILD_VERSION`). Returns the violations; an empty list means the binary conforms.
///
/// - A system library with no stub, a library whose stub restricts it to listed clients, and a library that has another
///   name at the minimum (`$ld$previous$` without a symbol, `$ld$install_name$`) are violations, weak or strong.
/// - A symbol bound to a library whose stub places it in another library at the minimum (`$ld$previous$`), or hides it
///   there (`$ld$hide$`), is a violation, weak or strong: the weak bit allows a missing symbol, not a wrong library.
///
/// Libraries under `@rpath`, `@executable_path` or `@loader_path` ship in the app and are not checked. A file without
/// `LC_BUILD_VERSION` or without chained fixups cannot be checked, and is a [FormatException].
List<Violation> checkAgainstSdk(MachO file, Directory sdk) {
  final build = file.buildVersion;
  final imports = file.imports;
  if (build == null) {
    throw const FormatException(
      'no LC_BUILD_VERSION, so the minimum OS is unknown',
    );
  }
  if (imports == null) {
    throw const FormatException(
      'no chained fixups, so the bindings cannot be checked',
    );
  }
  final min = build.minOS;
  bool covers(Previous p) =>
      p.platform == build.platform &&
      _compare(p.start, min) <= 0 &&
      _compare(min, p.end) < 0;

  final violations = <Violation>[];
  final stubs = <String, LibraryStub?>{};
  for (final name in {
    for (final d in file.dylibs) d.installName,
  }.where((n) => !n.startsWith('@'))) {
    final stub = stubs[name] = readLibraryStub(sdk, name);
    Violation library(String reason, [String? needs]) =>
        Violation(library: name, reason: reason, needs: needs, minOS: min);
    if (stub == null) {
      violations.add(
        library(
          'the SDK has no stub for it, so nothing says the minimum has it',
        ),
      );
      continue;
    }
    if (stub.restricted) {
      final bound = imports.where((i) => i.library == name).length;
      final moved = stub.previous.where(
        (p) => p.symbol.isNotEmpty && covers(p),
      );
      violations.add(
        library(
          'its stub restricts it to listed clients, and this binary is not one; Xcode binds its symbols to the library '
          'that re-exports it ($bound bound here)',
          moved.isEmpty
              ? null
              : moved
                    .map((p) => p.end)
                    .reduce((a, b) => _compare(a, b) <= 0 ? a : b),
        ),
      );
    }
    for (final p in stub.previous.where((p) => p.symbol.isEmpty && covers(p))) {
      violations.add(library('before ${p.end} it is ${p.installName}', p.end));
    }
    for (final MapEntry(key: os, value: other) in stub.installNames.entries) {
      if (_compare(os, min) == 0) {
        violations.add(library('at $os it is $other'));
      }
    }
  }

  final moved = <String, Map<String, List<Previous>>>{};
  for (final i in imports) {
    final stub = stubs[i.library];
    if (stub == null) {
      continue;
    }
    final bySymbol = moved.putIfAbsent(stub.installName, () {
      final map = <String, List<Previous>>{};
      for (final p in stub.previous.where(
        (p) => p.symbol.isNotEmpty && covers(p),
      )) {
        (map[p.symbol] ??= []).add(p);
      }
      return map;
    });
    Violation symbol(String reason, [String? needs]) => Violation(
      library: stub.installName,
      symbol: i.symbol,
      reason: reason,
      needs: needs,
      minOS: min,
    );
    for (final p in bySymbol[i.symbol] ?? const <Previous>[]) {
      violations.add(
        symbol('before ${p.end} it is in ${p.installName}', p.end),
      );
    }
    if (stub.hidden.any(
      (h) =>
          h.symbol == i.symbol && (h.os == null || _compare(h.os!, min) == 0),
    )) {
      violations.add(symbol('its stub hides it at $min'));
    }
  }
  return violations;
}

/// Compares two dotted versions (`18`, `18.0` and `18.0.0` are equal).
int _compare(String a, String b) {
  final x = a.split('.').map(int.parse).toList();
  final y = b.split('.').map(int.parse).toList();
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) {
      return d;
    }
  }
  return 0;
}
