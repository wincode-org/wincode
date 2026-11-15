import 'dart:collection';
import 'dart:convert';

import 'preflight.dart' show Finding;

/// The events of `--events` and the fields each may carry, besides `event`, `time` and `app` (ADR-0015, section 9).
///
/// This is the one place where the schema is written: `build`, `sign` and `upload` write their events through
/// [EventWriter], which refuses a field that is not listed here. A field or an event is not renamed, removed or given
/// another type without an amendment of the ADR; new ones may be added, and a reader ignores what it does not know.
const eventFields = <String, List<String>>{
  // One check, as `preflight` reports it: its name, PASS, WARN, FAIL or INFO, and its text.
  'check': ['id', 'status', 'text'],
  // What the command is about to do. `build` gives the first group, `upload` the second.
  'plan': [
    'repository',
    'private',
    'workflow',
    'ref',
    'commit',
    'runsOn',
    'timeoutMinutes',
    'inputs',
    'buildName',
    'buildNumber',
    'buildNumberSource',
    'file',
    'size',
    'version',
    'build',
  ],
  // `sign`: zsign starts (`started`) and ends (`ended`, with how: `ok`, `failed`, `timedOut` or `tooBig`).
  'signing': ['status', 'end'],
  // `upload`: the build upload is `created`; the file's `parts` are going, `sentBytes` of `totalBytes`; it is `committed`.
  'upload': ['stage', 'sentBytes', 'totalBytes'],
  // `upload`: Apple's states changed, or it said something new. `messages` holds each new error, warning and info as
  // Apple sent it, with its `source` (`upload` or `file`) and `kind`.
  'processing': ['upload', 'file', 'build', 'messages'],
};

/// Writes the lines of `--events` to stdout: one JSON object each, as things happen. Text for people goes to stderr.
///
/// Each event has `event`, `time` (UTC, ISO 8601, to the second) and `app`: the app's name, or null for a flat file.
/// The name passes through the redactor with everything else that is printed.
class EventWriter {
  EventWriter(this._out, this._clock, {required this.app});

  final StringSink _out;
  final DateTime Function() _clock;
  final String? app;

  /// Writes the event [name] with [fields], which the schema must list.
  void emit(String name, [Map<String, Object?> fields = const {}]) {
    final allowed =
        eventFields[name] ?? (throw StateError('unknown event "$name"'));
    for (final field in fields.keys) {
      if (!allowed.contains(field)) {
        throw StateError('the event "$name" has no field "$field"');
      }
    }
    _out.writeln(
      jsonEncode({
        'event': name,
        'time': _clock().toUtc().toIso8601String().replaceFirst(
          RegExp(r'\.\d+Z$'),
          'Z',
        ),
        'app': app,
        ...fields,
      }),
    );
  }

  /// The `check` event of [finding].
  void check(Finding finding) => emit('check', {
    'id': finding.check,
    'status': finding.status,
    'text': finding.what,
  });

  /// The last line: [json], the object that `--json` prints, with `event` added. It has no `time` of its own.
  void result(Map<String, Object?> json) =>
      _out.writeln(jsonEncode({'event': 'result', ...json}));
}

/// A list of findings that writes a `check` event for each one added, so that a command which collects its findings in
/// a list reports each as it comes.
class EventFindings extends ListBase<Finding> {
  EventFindings(this._events);

  final EventWriter _events;
  final _items = <Finding>[];

  @override
  int get length => _items.length;

  @override
  set length(int length) => _items.length = length;

  @override
  Finding operator [](int index) => _items[index];

  @override
  void operator []=(int index, Finding value) => _items[index] = value;

  @override
  void add(Finding element) {
    _items.add(element);
    _events.check(element);
  }

  @override
  void addAll(Iterable<Finding> iterable) => iterable.forEach(add);
}
