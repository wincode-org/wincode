import 'dart:math';

import 'package:wincode_core/wincode_core.dart' show sha256OfText;

/// Build numbers and the names of runs (ADR-0015, section 3). Pure functions, so that the rules are tested without a
/// network.

final _dottedNumber = RegExp(r'^\d+(\.\d+){0,2}$');

/// Whether [text] is a number that Apple takes as a version or a build number: one to three whole numbers joined by
/// dots.
bool isDottedNumber(String text) => _dottedNumber.hasMatch(text);

/// Compares build numbers part by part as numbers. A longer number with the same start is higher: 1.0.1 is above 1.0.
int compareBuildNumbers(String a, String b) {
  final x = a.split('.').map(BigInt.parse).toList();
  final y = b.split('.').map(BigInt.parse).toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    if (x[i] != y[i]) {
      return x[i].compareTo(y[i]);
    }
  }
  return x.length.compareTo(y.length);
}

/// Compares versions such as Xcode's, where a missing part is zero: 26 and 26.0.0 are the same.
int compareVersions(String a, String b) {
  final x = a.split('.').map(int.parse).toList();
  final y = b.split('.').map(int.parse).toList();
  for (var i = 0; i < max(x.length, y.length); i++) {
    final p = i < x.length ? x[i] : 0;
    final q = i < y.length ? y[i] : 0;
    if (p != q) {
      return p.compareTo(q);
    }
  }
  return 0;
}

/// The highest of [numbers] (build numbers), or null when there are none.
String? highestNumber(Iterable<String> numbers) => numbers.isEmpty
    ? null
    : numbers.reduce((a, b) => compareBuildNumbers(a, b) >= 0 ? a : b);

/// The mark that ties a run to an app: the first 12 hex digits of the SHA-256 of its bundle ID in lower case. It names
/// the app without its name or bundle ID appearing in the run list, and any machine finds the same one.
String appTag(String bundleId) =>
    sha256OfText(bundleId.toLowerCase()).substring(0, 12);

/// The request ID of a build: `<app tag>-<version>-<build number>-<random>` (ADR-0015, section 3). The run's name is
/// `wincode <request ID>`.
String requestIdOf({
  required String tag,
  required String version,
  required String number,
  required String random,
}) => '$tag-$version-$number-$random';

/// 8 random hex digits, for the last part of a request ID.
String randomHex([Random? random]) {
  final r = random ?? Random.secure();
  return [for (var i = 0; i < 8; i++) r.nextInt(16).toRadixString(16)].join();
}

final _requestId = RegExp(
  r'^([0-9a-f]{12})-(\d+(?:\.\d+){0,2})-(\d+(?:\.\d+){0,2})-([0-9a-f]{8})$',
);

/// What a run's name says: the app [tag], and the [version] and [number] of the build it makes.
typedef RunBuild = ({String tag, String version, String number});

/// The tag, version and number in the name of a run, `wincode <request ID>`, or null for a name of any other shape.
RunBuild? parseRunName(String name) {
  const prefix = 'wincode ';
  if (!name.startsWith(prefix)) {
    return null;
  }
  final m = _requestId.firstMatch(name.substring(prefix.length));
  return m == null ? null : (tag: m[1]!, version: m[2]!, number: m[3]!);
}

/// A run of the workflow that belongs to an app, as [analyseRuns] found it.
typedef AppRun = ({
  String id,
  String url,
  String version,
  String number,
  String status,
});

/// What the runs of the last day say about one app.
class RunsAnalysis {
  const RunsAnalysis({this.active = const [], this.highestSuccessful});

  /// The runs of the app that are queued or going: a second build of the app would compete with them.
  final List<AppRun> active;

  /// The highest build number of the app's runs that ended in success: its IPA exists, so the number is used.
  final String? highestSuccessful;
}

/// The statuses of a run that has not ended.
const activeStatuses = {
  'queued',
  'in_progress',
  'waiting',
  'requested',
  'pending',
};

/// Reads [runs], the workflow runs that GitHub lists (`id`, `name`, `display_title`, `status`, `conclusion`,
/// `html_url`), for those whose name carries [tag]. A run that ended any other way than success made no IPA, so its
/// number is free again.
RunsAnalysis analyseRuns(Iterable<Map<String, Object?>> runs, String tag) {
  final active = <AppRun>[];
  final numbers = <String>[];
  for (final run in runs) {
    final title = run['display_title'] ?? run['name'];
    final parsed = title is String ? parseRunName(title) : null;
    if (parsed == null || parsed.tag != tag) {
      continue;
    }
    final status = '${run['status']}';
    if (activeStatuses.contains(status)) {
      active.add((
        id: '${run['id']}',
        url: '${run['html_url']}',
        version: parsed.version,
        number: parsed.number,
        status: status,
      ));
    } else if (status == 'completed' && run['conclusion'] == 'success') {
      numbers.add(parsed.number);
    }
  }
  return RunsAnalysis(
    active: active,
    highestSuccessful: highestNumber(numbers),
  );
}
