import 'config.dart';
import 'failure.dart';
import 'redact.dart';

/// Choosing the app or apps a command works on (ADR-0014, sections 3 and 7).

/// Refuses `--app` together with `--all`.
void checkAppOptions({String? app, required bool all}) {
  if (app != null && all) {
    throw const WincodeException(
      ExitCode.usage,
      'usage',
      '--app and --all cannot be given together',
      why: '--app works on the one app that it names, and --all on every app.',
      next: 'give one of them.',
    );
  }
}

/// Refuses `--all` for [command], one that writes (ADR-0014, section 3). [reason] says what it writes.
Never refuseAll(String command, String reason) => throw WincodeException(
  ExitCode.usage,
  'all-not-allowed',
  '--all is not allowed for $command',
  why:
      'wincode $command $reason. A loop over apps inside winCode would turn one wrong setting into several wrong '
      'results, and a stop halfway would leave some apps done and others not, with nothing that records which '
      '(ADR-0014, section 3).',
  next: 'run it once for each app: wincode $command --app <name>.',
);

/// What each command that writes does, for the message of [refuseAll].
const writesOf = {
  'sign': 'writes a signed IPA',
  'upload':
      'uploads to Apple, and an upload that was sent cannot be taken back',
  'build': 'starts a run on a paid macOS runner',
  'init': 'writes the settings of the apps',
};

/// The apps that [command] works on, in file order.
///
/// - With [all], every app (a flat file has one). Only commands that read and send nothing but GET requests allow it.
/// - With [app], the app of that name: another name is `app-unknown`, and a flat file has none (`app-flat-file`).
/// - With neither, the one app of the file, or `app-required` when there are several.
///
/// The messages are those of ADR-0014, section 10, and with an active [redactor] they do not print the name that the
/// user typed. [readOnly] says whether the `--all` clause belongs in the `app-required` message. [path] is the file as
/// `--config` named it.
List<WincodeConfig> selectApps(
  WincodeSettings settings, {
  required String path,
  required String? app,
  required bool all,
  required bool readOnly,
  required Redactor redactor,
}) {
  checkAppOptions(app: app, all: all);
  if (all) {
    return settings.apps;
  }
  if (settings.isFlat) {
    if (app != null) {
      throw WincodeException(
        ExitCode.usage,
        'app-flat-file',
        '$path describes one app without a name, and --app names an app',
        why: 'a wincode.yaml without an apps: map has no names to choose from.',
        next: 'leave --app out.',
      );
    }
    return settings.apps;
  }
  final names = [for (final a in settings.apps) a.name!];
  if (app != null) {
    final found = settings.app(app);
    if (found == null) {
      throw WincodeException(
        ExitCode.usage,
        'app-unknown',
        redactor.active
            ? '$path has no app by the name that --app gives'
            : '$path has no app named $app',
        why: '--app names one of the apps under apps: in wincode.yaml, spelled as there.',
        next: 'use one of ${names.join(', ')}.',
        details: {'apps': names},
      );
    }
    return [found];
  }
  if (settings.apps.length == 1) {
    return settings.apps;
  }
  throw appRequired(path, names, readOnly: readOnly);
}

/// The `app-required` error of a file with several [names].
WincodeException appRequired(
  String path,
  List<String> names, {
  required bool readOnly,
}) => WincodeException(
  ExitCode.usage,
  'app-required',
  '$path has ${names.length} apps, and the command does not say which one',
  why:
      'each app has its own bundle ID, team, profile and keys, and winCode works on the app that the command names, so '
      'that nothing reaches the wrong app record.',
  next:
      'add --app with one of ${names.join(', ')}${readOnly ? ', or --all to check every app' : ''}.',
  details: {'apps': names},
);

/// What one app gave in a run of `--all`: its exit [code], the id of its [firstFailure] (null when it passed), and its
/// own `--json` object without `command`.
typedef AppOutcome = ({
  WincodeConfig app,
  int code,
  String? firstFailure,
  Map<String, Object?> json,
});

/// The summary table of a run of `--all`, with the names as [redactor] would print them, so that the columns stay in
/// line when the names are replaced.
String summaryTable(List<AppOutcome> outcomes, Redactor redactor) {
  final rows = [
    ('app', 'result', 'first failure', 'exit'),
    for (final o in outcomes)
      (
        redactor.apply(o.app.name ?? '-'),
        o.code == 0 ? 'PASS' : 'FAIL',
        o.firstFailure ?? '',
        '${o.code}',
      ),
  ];
  final widths = [
    for (var i = 0; i < 3; i++)
      rows
          .map((r) => [r.$1, r.$2, r.$3][i].length)
          .reduce((a, b) => a > b ? a : b),
  ];
  String pad(String text, int i) => text.padRight(widths[i]);
  return [
    for (final r in rows)
      '${pad(r.$1, 0)}  ${pad(r.$2, 1)}  ${pad(r.$3, 2)}  ${r.$4}',
  ].join('\n');
}

/// The exit code of a run of `--all`: that of the first app, in file order, that failed; else 0.
int combinedCode(List<AppOutcome> outcomes) =>
    outcomes.where((o) => o.code != 0).firstOrNull?.code ?? 0;

/// The last line of a run of `--all`.
String summaryLine(String command, String path, List<AppOutcome> outcomes) {
  final failed = outcomes.where((o) => o.code != 0).toList();
  if (failed.isEmpty) {
    return 'wincode $command --all: ${outcomes.length} app${outcomes.length == 1 ? '' : 's'} passed.';
  }
  final name = failed.first.app.name;
  return 'wincode $command --all: ${failed.length} of ${outcomes.length} apps failed; exit ${failed.first.code}, the '
      'first failure in $path${name == null ? '' : ' ($name)'}.';
}

/// The one document of `--json` for a run of `--all` (ADR-0014, section 7): each app's object in file order, and the
/// first failing app's error with `app` added.
Map<String, Object?> allJson(String command, List<AppOutcome> outcomes) {
  final code = combinedCode(outcomes);
  final first = outcomes.where((o) => o.code != 0).firstOrNull;
  final error = first?.json['error'];
  return {
    'command': command,
    'all': true,
    'ok': code == 0,
    'exitCode': code,
    'apps': [for (final o in outcomes) o.json],
    'error': ?(error is Map<String, Object?>
        ? {'app': first!.app.name, ...error}
        : null),
  };
}
