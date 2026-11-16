import 'redact.dart';

/// A line of zsign's output that says that something went wrong. zsign ends a failed run with `>>> Done.` as well as a
/// good one, so its last line says little: a failure message holds these lines and the last ones.
final zsignProblemLine = RegExp('error|failed|invalid', caseSensitive: false);

/// What a failure message holds of zsign's output at most: the lines, the characters of all lines together, and the
/// characters of one line. What passes them is replaced by `... (cut)`.
const _maxLines = 40;
const _maxCharacters = 4000;
const _maxLineLength = 300;

/// How many of the last lines of the output a failure message holds besides the lines with a problem.
const _tailLines = 10;

const _cut = '... (cut)';

/// Something that is, or looks like, a key, a password or a token. zsign is not known to print any, and a failure
/// message is pasted into issues and CI logs, so none is let through: a PEM line, a base64 line, a JWT, `Bearer <token>`,
/// a value after `password:`, `token=` and the like, and any long run of letters and digits (a hash).
final _looksSecret = RegExp(
  r'^.*-----(?:BEGIN|END) .*$|^[A-Za-z0-9+/]{32,}={0,2}$|'
  r'eyJ[\w-]+\.[\w-]+\.[\w-]*|'
  r'\bbearer\s+\S+|'
  r'\b(?:password|passwd|passphrase|secret|token|api[-_ ]?key|authorization)\s*[:=]\s*(?:bearer\s+)?\S+|'
  r'[A-Za-z0-9+_-]{40,}',
  caseSensitive: false,
);

/// The `why` of a failure of zsign: what it said, as [said] holds it (the lines of its output that matter, oldest
/// first), cut down to the lines with a problem and the last [_tailLines] lines, in the order zsign printed them, with no
/// line twice.
///
/// Every line goes through [redactor] (`forReport`, so that the IDs, names and paths of the configuration are hidden
/// whether or not `--redact` was given, as everywhere a message may be pasted into an issue) and is cleared of anything
/// that looks like a key, a password or a token. The text holds at most 40 lines and 4,000 characters, each line at
/// most 300; `... (cut)` says that something was left out. One line reads `zsign said: <line>`, several lines are
/// indented under `zsign said:`, and no line at all reads `zsign printed nothing.`.
String zsignWhy(List<String> said, Redactor redactor) {
  final lines = [
    for (final line in said)
      if (line.trim().isNotEmpty) line,
  ];
  final tail = lines.length - _tailLines;
  final chosen = <String>{};
  var dropped = false;
  var characters = 0;
  for (var i = 0; i < lines.length; i++) {
    if (i < tail && !zsignProblemLine.hasMatch(lines[i])) {
      continue;
    }
    var line = redactor
        .forReport(lines[i].trim())
        .replaceAll(_looksSecret, '<hidden>');
    if (line.length > _maxLineLength) {
      line = '${line.substring(0, _maxLineLength)} $_cut';
    }
    if (chosen.contains(line)) {
      continue;
    }
    if (chosen.length == _maxLines ||
        characters + line.length + 1 > _maxCharacters) {
      dropped = true;
      break;
    }
    chosen.add(line);
    characters += line.length + 1;
  }
  if (chosen.isEmpty) {
    return 'zsign printed nothing.';
  }
  if (dropped) {
    chosen.add(_cut);
  }
  return chosen.length == 1
      ? 'zsign said: ${chosen.single}'
      : 'zsign said:\n${chosen.map((l) => '    $l').join('\n')}';
}
