/// Hides values in what `wincode` prints (ADR-0013, section 7).
///
/// - Secrets registered with [secret] (the token, the Key ID, the Issuer ID, the key folder) are replaced in
///   everything printed, always.
/// - IDs registered with [hide] (the bundle ID, the team ID) are shown by default. They are replaced when `--redact` is
///   given or the `CI` environment variable is set, so that a log kept by a CI service does not carry them.
/// - Text meant for an issue report goes through [forReport], which replaces both kinds always.
class Redactor {
  Redactor({required this.active});

  /// Whether `--redact` was given or `CI` is set.
  factory Redactor.forRun({
    required bool flag,
    required Map<String, String> environment,
  }) => Redactor(active: flag || runsInCi(environment));

  final bool active;

  /// Value -> (placeholder, whether it is a secret).
  final _hidden = <String, (String, bool)>{};

  /// Registers [value] (a bundle ID, a team ID) to be replaced with [placeholder], such as `<bundle ID>`, when [active].
  /// A value that is registered already keeps its placeholder.
  void hide(String value, String placeholder) =>
      _add(value, placeholder, false);

  /// Registers [value] (a token, a Key ID, a path) to be replaced with [placeholder] in everything printed.
  void secret(String value, String placeholder) =>
      _add(value, placeholder, true);

  void _add(String value, String placeholder, bool secret) {
    if (value.isNotEmpty) {
      final (shown, wasSecret) = _hidden[value] ?? (placeholder, false);
      _hidden[value] = (shown, secret || wasSecret);
    }
  }

  /// [text] as it is printed: the secrets replaced, and the IDs too when [active].
  String apply(String text) => _replace(text, ids: active);

  /// [text] with every registered value replaced, whether or not [active]: for anything a person is asked to paste into
  /// an issue.
  String forReport(String text) => _replace(text, ids: true);

  String _replace(String text, {required bool ids}) {
    // The longest value first, so that one that contains another is replaced whole.
    final values = _hidden.keys.where((v) => ids || _hidden[v]!.$2).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return values.fold(text, (t, v) => t.replaceAll(v, _hidden[v]!.$1));
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
