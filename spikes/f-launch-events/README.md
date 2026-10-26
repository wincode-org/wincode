# Spike F: launch events with and without a storyboard

ADR-0011 rule 3 makes the runner create its window and `FlutterViewController` in code. A storyboard does more than make
the window: Flutter's view controller behaves differently when UIKit creates it from an archive. This spike records what
plugins receive in each case, on a generic sample app, in the simulator.

- `plugin/launch_events_recorder`: a plugin with no Dart code. It receives the application lifecycle events (as a plugin
  that does not know about scenes does) and the scene events (as one that does), and appends one line per event to
  `Documents/events.log`. It never answers "handled", so Flutter's fallbacks and deep linking run as they would without it.
- `variants/`: the scene delegate base for the three ways of making the window in code, as Swift. `C.swift` is the file
  winCode generates (`sceneDelegateBase` in `packages/wincode_core/lib/src/runner.dart`; a test keeps the two equal).
- `run.sh`: on a macOS runner, builds the sample app four times for the simulator (A: the template's storyboard; B, C, D: no
  storyboard), runs each three ways (a launch; a cold launch from a URL; a launch, then a URL) and calls `compare.py`.
- `compare.py`: lines the logs of B, C and D up against A.

The result is in `docs/spikes/spike-f-launch-events.md`. The workflow is `.github/workflows/launch-events.yml`; it runs
once when its file is pushed, or by hand.
