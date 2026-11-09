/// The exit codes of `wincode` (ADR-0013). The values are those of sysexits.h, so 64 keeps the meaning `doctor` gave it.
enum ExitCode {
  /// The command did its work.
  ok(0),

  /// The work failed: a check found a problem, an input is wrong, or Apple or GitHub refused the work.
  failed(1),

  /// The command line is wrong, or the command is not implemented yet.
  usage(64),

  /// Something winCode needs is not there: a tool (zsign, gh), the SDK, or the network.
  unavailable(69),

  /// A bug in winCode.
  internal(70),

  /// Apple or GitHub refused the credentials.
  permission(77),

  /// The setup is wrong: `wincode.yaml`, or an environment variable that winCode reads.
  config(78);

  const ExitCode(this.code);

  final int code;
}

/// A failure that the user can act on (ADR-0013, "Error model"): [what] happened, [why], and the exact [next] step.
class WincodeException implements Exception {
  const WincodeException(
    this.exitCode,
    this.id,
    this.what, {
    this.why,
    this.next,
    this.details = const {},
  });

  final ExitCode exitCode;

  /// A stable name for the failure, such as `config-missing`, for scripts that read `--json`.
  final String id;

  final String what;
  final String? why;
  final String? next;

  /// More fields for the `error` object of `--json`, such as the names in `apps` (ADR-0014, section 7).
  final Map<String, Object?> details;

  /// The message for people, as [command] (such as `wincode sign`) prints it on stderr.
  String describe(String command) => [
    '$command: $what',
    if (why != null) '  why: $why',
    if (next != null) '  next: $next',
  ].join('\n');

  /// The `error` object of the `--json` output.
  Map<String, Object?> toJson() => {
    'id': id,
    'what': what,
    'why': ?why,
    'next': ?next,
    ...details,
  };

  @override
  String toString() => what;
}
