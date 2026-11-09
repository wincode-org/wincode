/// Hides the app's IDs in what `wincode` prints (ADR-0013, section 7).
///
/// The bundle ID and the team ID are shown by default. The redactor replaces the IDs that a command has registered with
/// [hide] when `--redact` is given or the `CI` environment variable is set, so that a log kept by a CI service does not
/// carry them. Text meant for an issue report goes through [forReport], which hides them always.
class Redactor {
  Redactor({required this.active});

  /// Whether `--redact` was given or `CI` is set.
  factory Redactor.forRun({
    required bool flag,
    required Map<String, String> environment,
  }) => Redactor(active: flag || runsInCi(environment));

  final bool active;
  final _hidden = <String, String>{};

  /// Registers [value] (a bundle ID, a team ID) to be replaced with [placeholder], such as `<bundle ID>`.
  void hide(String value, String placeholder) {
    if (value.isNotEmpty) {
      _hidden[value] = placeholder;
    }
  }

  /// [text] as it is printed: unchanged unless [active].
  String apply(String text) => active ? forReport(text) : text;

  /// [text] with the registered values replaced, whether or not [active]: for anything a person is asked to paste into an
  /// issue.
  String forReport(String text) {
    // The longest value first, so that one that contains another is replaced whole.
    final values = _hidden.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return values.fold(text, (t, v) => t.replaceAll(v, _hidden[v]!));
  }

  /// [inner], with everything written to it passed through [apply]. A value written in two pieces is not found, so
  /// commands write whole lines.
  StringSink sink(StringSink inner) => active ? _Sink(inner, this) : inner;
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
