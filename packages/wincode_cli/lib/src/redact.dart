/// Hides values in what `wincode` prints (ADR-0013, section 7).
///
/// - Secrets registered with [secret] (the token, the Key ID, the Issuer ID, the key folder) are replaced in
///   everything printed, always.
/// - IDs registered with [hide] (the bundle ID, the team ID) are shown by default. They are replaced when `--redact` is
///   given or the `CI` environment variable is set, so that a log kept by a CI service does not carry them.
/// - Names registered with [hideName] (an app, a credentials reference, a flavor: ADR-0014, section 4) are IDs that are
///   replaced as whole words, ignoring case, so that a name never hides part of an ordinary word.
/// - Text meant for an issue report goes through [forReport], which replaces both kinds always.
///
/// Every registered value is replaced in one pass over the text, the longest first, so that a placeholder is never
/// replaced again.
class Redactor {
  Redactor({required this.active});

  /// Whether `--redact` was given or `CI` is set.
  factory Redactor.forRun({
    required bool flag,
    required Map<String, String> environment,
  }) => Redactor(active: flag || runsInCi(environment));

  final bool active;

  /// Key -> (value, placeholder, whether it is a secret, whether it is a name). A name is keyed by its lower-case form.
  final _hidden = <String, (String, String, bool, bool)>{};

  /// Registers [value] (a bundle ID, a team ID) to be replaced with [placeholder], such as `<bundle ID>`, when [active].
  /// A value that is registered already keeps its placeholder.
  void hide(String value, String placeholder) =>
      _add(value, placeholder, false, false);

  /// Registers [value], a name chosen by the user, to be replaced with [placeholder], such as `app-1`, when [active]:
  /// only where it stands as a whole word (a letter or digit does not touch it on either side), and whatever its case.
  void hideName(String value, String placeholder) =>
      _add(value, placeholder, false, true);

  /// Registers [value] (a token, a Key ID, a path) to be replaced with [placeholder] in everything printed.
  void secret(String value, String placeholder) =>
      _add(value, placeholder, true, false);

  void _add(String value, String placeholder, bool secret, bool name) {
    if (value.isNotEmpty) {
      final key = name ? 'n${value.toLowerCase()}' : 's$value';
      final (_, shown, wasSecret, _) =
          _hidden[key] ?? (value, placeholder, false, name);
      _hidden[key] = (value, shown, secret || wasSecret, name);
    }
  }

  /// [text] as it is printed: the secrets replaced, and the IDs too when [active].
  String apply(String text) => _replace(text, ids: active);

  /// [text] with every registered value replaced, whether or not [active]: for anything a person is asked to paste into
  /// an issue.
  String forReport(String text) => _replace(text, ids: true);

  String _replace(String text, {required bool ids}) {
    // The longest value first, so that one that contains another is replaced whole.
    final entries = _hidden.values.where((e) => ids || e.$3).toList()
      ..sort((a, b) {
        final byLength = b.$1.length.compareTo(a.$1.length);
        // Where two values are equally long, an exact string comes before a name, which matches in any case.
        return byLength != 0
            ? byLength
            : (a.$4 ? 1 : 0).compareTo(b.$4 ? 1 : 0);
      });
    if (entries.isEmpty) {
      return text;
    }
    // One alternation, one capture group per value: a placeholder is never scanned again.
    final pattern = entries
        .map((e) => '(${e.$4 ? _word(e.$1) : RegExp.escape(e.$1)})')
        .join('|');
    return text.replaceAllMapped(RegExp(pattern), (m) {
      for (var i = 0; i < entries.length; i++) {
        if (m.group(i + 1) != null) {
          return entries[i].$2;
        }
      }
      return m[0]!;
    });
  }

  /// A pattern for [name] as a whole word, ignoring case.
  static String _word(String name) {
    final letters = name.split('').map((c) {
      final lower = c.toLowerCase();
      final upper = c.toUpperCase();
      return lower == upper
          ? RegExp.escape(c)
          : '[${RegExp.escape(lower)}${RegExp.escape(upper)}]';
    }).join();
    return '(?<![A-Za-z0-9])$letters(?![A-Za-z0-9])';
  }

  /// [inner], with everything written to it passed through [apply]. A value written in two pieces is not found, so
  /// commands write whole lines.
  StringSink sink(StringSink inner) => _Sink(inner, this);
}

/// Whether the `CI` variable says that `wincode` runs in a CI service. GitHub Actions and most others set it to `true`;
/// empty, `0` and `false` mean that it does not.
bool runsInCi(Map<String, String> environment) {
  final value = environment['CI']?.toLowerCase();
  return value != null && value != '' && value != '0' && value != 'false';
}

class _Sink implements StringSink {
  _Sink(this._inner, this._redactor);

  final StringSink _inner;
  final Redactor _redactor;

  @override
  void write(Object? object) => _inner.write(_redactor.apply('$object'));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) =>
      _inner.writeln(_redactor.apply('$object'));
}
