import 'macho_inspect.dart';

const _commandNames = {
  0x2: 'LC_SYMTAB',
  0xB: 'LC_DYSYMTAB',
  0xC: 'LC_LOAD_DYLIB',
  0xD: 'LC_ID_DYLIB',
  0xE: 'LC_LOAD_DYLINKER',
  0x19: 'LC_SEGMENT_64',
  0x1B: 'LC_UUID',
  0x1D: 'LC_CODE_SIGNATURE',
  0x20: 'LC_LAZY_LOAD_DYLIB',
  0x25: 'LC_VERSION_MIN_IPHONEOS',
  0x26: 'LC_FUNCTION_STARTS',
  0x29: 'LC_DATA_IN_CODE',
  0x2A: 'LC_SOURCE_VERSION',
  0x2B: 'LC_DYLIB_CODE_SIGN_DRS',
  0x2C: 'LC_ENCRYPTION_INFO_64',
  0x2D: 'LC_LINKER_OPTION',
  0x32: 'LC_BUILD_VERSION',
  0x80000018: 'LC_LOAD_WEAK_DYLIB',
  0x8000001C: 'LC_RPATH',
  0x8000001F: 'LC_REEXPORT_DYLIB',
  0x80000022: 'LC_DYLD_INFO_ONLY',
  0x80000023: 'LC_LOAD_UPWARD_DYLIB',
  0x80000028: 'LC_MAIN',
  0x80000033: 'LC_DYLD_EXPORTS_TRIE',
  0x80000034: 'LC_DYLD_CHAINED_FIXUPS',
};

/// The differences between two Mach-O files, [ours] and a [reference] (an Xcode-built copy), one line each: the build
/// version, the libraries and how they are loaded, the rpaths, the kinds of load commands, and the bindings to each
/// library (counts, the symbols found in one file only, and weak bits that differ). An empty list means none of these
/// differ. Some differences are expected, `lld` is not `ld` (ADR-0012), so it reports and does not judge.
List<String> diffMachO(MachO ours, MachO reference) {
  final out = <String>[];
  void differ(String what, Object? a, Object? b) {
    if ('$a' != '$b') {
      out.add('$what: ours $a, reference $b');
    }
  }

  final (a, b) = (ours.buildVersion, reference.buildVersion);
  differ('platform', a?.platform ?? 'none', b?.platform ?? 'none');
  differ('minimum OS', a?.minOS ?? 'none', b?.minOS ?? 'none');
  differ('SDK', a?.sdk ?? 'none', b?.sdk ?? 'none');

  Map<String, String> kinds(MachO m) => {
    for (final d in m.dylibs) d.installName: d.kind.name,
  };
  final (ka, kb) = (kinds(ours), kinds(reference));
  for (final name in {...ka.keys, ...kb.keys}) {
    differ('library $name', ka[name] ?? 'not loaded', kb[name] ?? 'not loaded');
  }

  differ('rpaths', ours.rpaths, reference.rpaths);

  Map<int, int> counts(MachO m) {
    final c = <int, int>{};
    for (final command in m.commands) {
      c[command] = (c[command] ?? 0) + 1;
    }
    return c;
  }

  final (ca, cb) = (counts(ours), counts(reference));
  for (final command in {...ca.keys, ...cb.keys}) {
    differ(
      'load commands ${_commandNames[command] ?? '0x${command.toRadixString(16)}'}',
      ca[command] ?? 0,
      cb[command] ?? 0,
    );
  }

  // Symbol -> weak bit, by library; the special ordinals (the file itself, flat or weak lookups) share one entry.
  Map<String, Map<String, bool>> bound(MachO m) {
    final byLibrary = <String, Map<String, bool>>{};
    for (final i in m.imports ?? const <Import>[]) {
      final library = i.library ?? '(no library: a special ordinal)';
      (byLibrary[library] ??= {})[i.symbol] = i.weak;
    }
    return byLibrary;
  }

  differ(
    'chained fixups',
    ours.imports == null ? 'none' : 'present',
    reference.imports == null ? 'none' : 'present',
  );
  final (ba, bb) = (bound(ours), bound(reference));
  for (final library in {...ba.keys, ...bb.keys}) {
    final (sa, sb) = (ba[library] ?? const {}, bb[library] ?? const {});
    differ('bindings to $library', sa.length, sb.length);
    final onlyOurs = [...sa.keys.where((s) => !sb.containsKey(s))]..sort();
    final onlyReference = [...sb.keys.where((s) => !sa.containsKey(s))]..sort();
    if (onlyOurs.isNotEmpty) {
      out.add('bindings to $library only in ours: ${onlyOurs.join(', ')}');
    }
    if (onlyReference.isNotEmpty) {
      out.add(
        'bindings to $library only in the reference: ${onlyReference.join(', ')}',
      );
    }
    for (final s in sa.keys.where((s) => sb.containsKey(s) && sa[s] != sb[s])) {
      differ(
        'binding $s to $library',
        sa[s]! ? 'weak' : 'strong',
        sb[s]! ? 'weak' : 'strong',
      );
    }
  }
  return out;
}
