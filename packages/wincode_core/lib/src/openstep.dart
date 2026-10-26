/// Reads an old-style (OpenStep) property list, the format of `project.pbxproj`: `{ key = value; }` dictionaries,
/// `( a, b, )` arrays, bare or quoted strings, and `/* */` and `//` comments. Everything is a `Map<String, Object?>`,
/// a `List<Object?>` or a `String`.
Object parseOpenStep(String text) {
  final parser = _Parser(text);
  final value = parser.value();
  parser.skip();
  if (!parser.atEnd) throw parser.error('unexpected text after the value');
  return value;
}

class _Parser {
  _Parser(this.text);

  final String text;
  int position = 0;

  bool get atEnd => position >= text.length;

  FormatException error(String message) {
    final line = '\n'.allMatches(text.substring(0, position)).length + 1;
    return FormatException('project file, line $line: $message');
  }

  /// Skips white space and comments.
  void skip() {
    while (!atEnd) {
      final c = text[position];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        position++;
      } else if (text.startsWith('//', position)) {
        final end = text.indexOf('\n', position);
        position = end < 0 ? text.length : end + 1;
      } else if (text.startsWith('/*', position)) {
        final end = text.indexOf('*/', position + 2);
        if (end < 0) throw error('a comment is not closed');
        position = end + 2;
      } else {
        return;
      }
    }
  }

  Object value() {
    skip();
    if (atEnd) throw error('a value is missing');
    final c = text[position];
    if (c == '{') return dictionary();
    if (c == '(') return array();
    if (c == '"') return quoted();
    return bare();
  }

  Map<String, Object?> dictionary() {
    position++;
    final map = <String, Object?>{};
    while (true) {
      skip();
      if (atEnd) throw error('a dictionary is not closed');
      if (text[position] == '}') {
        position++;
        return map;
      }
      final key = text[position] == '"' ? quoted() : bare();
      skip();
      if (atEnd || text[position] != '=') {
        throw error('expected = after the key $key');
      }
      position++;
      map[key] = value();
      skip();
      if (atEnd || text[position] != ';') {
        throw error('expected ; after the value of $key');
      }
      position++;
    }
  }

  List<Object?> array() {
    position++;
    final list = <Object?>[];
    while (true) {
      skip();
      if (atEnd) throw error('an array is not closed');
      if (text[position] == ')') {
        position++;
        return list;
      }
      list.add(value());
      skip();
      if (!atEnd && text[position] == ',') position++;
    }
  }

  String quoted() {
    position++;
    final out = StringBuffer();
    while (true) {
      if (atEnd) throw error('a string is not closed');
      final c = text[position++];
      if (c == '"') return out.toString();
      if (c != r'\') {
        out.write(c);
        continue;
      }
      final next = text[position++];
      out.write(switch (next) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        _ => next,
      });
    }
  }

  String bare() {
    final start = position;
    while (!atEnd && !' \t\r\n;,={}()"'.contains(text[position])) {
      position++;
    }
    if (start == position) {
      throw error('unexpected character ${text[position]}');
    }
    return text.substring(start, position);
  }
}
