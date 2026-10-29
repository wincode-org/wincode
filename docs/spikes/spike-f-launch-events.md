# Spike F: launch events with and without a storyboard

Status: run 2026-10-26 (workflow run 40414678072, `macos-26`, Xcode 26.6, Flutter 3.47.5, iPhone 17 Pro simulator). **Result: a window made with `FlutterViewController()` loses the two application launch events; making the view controller the way a storyboard does restores them, in the same order.** The fix is in `sceneDelegateBase` (`packages/wincode_core/lib/src/runner.dart`).

## Question

ADR-0011 rule 3 makes the runner create its window and `FlutterViewController` in code. What does a storyboard launch give a plugin that this does not: application launch options, the scene's connection options, `openURL` and `continueUserActivity` forwarding, and the order of these calls?

## What the engine sources say (Flutter 3.47.5, `shell/platform/darwin/ios/framework/Source`)

1. **Application launch events reach plugins late.** With scenes, UIKit sends `application:willFinishLaunching` and `application:didFinishLaunching` before the engine exists, so no plugin is registered to get them. Flutter makes up for it in `FlutterViewController sharedSetupWithProject:` (`FlutterViewController.mm`, lines 313 to 334): after the implicit-engine callback has registered the plugins, **only if `awokenFromNib` is set**, it calls `sceneFallbackWillFinishLaunchingApplication:` and `sceneFallbackDidFinishLaunchingApplication:` on the application's `lifeCycleDelegate` (`FlutterPluginAppLifeCycleDelegate.mm`, lines 121 to 145). Both send `@{}` as launch options, "since UIKit sends nil when UIScene is enabled", and each is skipped if the real event was already sent.
2. **`awokenFromNib` is set in `awakeFromNib`** (line 259), which a storyboard sends after decoding the view controller with `init(coder:)`. `init()` never sets it. So a view controller made with `init()` never sends the two events. This is the one thing a storyboard gives that the first runner did not.
3. **Scene events do not depend on how the view controller was made.** `FlutterSceneDelegate` (which the app's `SceneDelegate` subclasses) forwards `willConnect`, `openURLContexts`, `continueUserActivity`, the foreground and background events and shortcut items to every engine in its scene (`FlutterSceneLifeCycle.mm`). An engine joins the scene when its root `FlutterViewController` is the window's root at `willConnect` (line 198), or through the `UISceneWillConnectNotification` and `FlutterView willMoveToWindow:`. The runner sets the window before calling `super`, as a storyboard does.
4. **The scene connection options become launch options.** If no scene-aware plugin handled `willConnect`, `sceneWillConnectFallback:` converts the options (URL, source application, shortcut item) to a launch-options dictionary and calls `didFinishLaunching` on the plugins that are not scene-aware (lines 156 to 174). That code is in the scene delegate, not in the view controller.
5. **`openURL` and `continueUserActivity`** go to the plugins' scene methods first; if none handles it, to the application fallbacks (`sceneFallbackOpenURLContexts:`, `sceneFallbackContinueUserActivity:`, lines 498 and 671); if still unhandled, to Flutter's deep linking. All of it is in the scene delegate.

So by the source, the only difference is point 2.

## What the simulator showed

A generic sample app (the stock counter app and `launch_events_recorder`, a plugin that writes each event it gets to a file) was built four ways: **A** the template's storyboard; **B** the window in code with `FlutterViewController()` (what M3 shipped); **C** the view controller made with `init(coder:)` and `awakeFromNib()`; **D** B plus Flutter's two fallback methods called by selector. Events, in order, for a normal launch (details such as launch options left out):

| | Events |
| --- | --- |
| A, storyboard | register, app.willFinishLaunching, app.didFinishLaunching, scene.willConnect, scene.willEnterForeground, app.willEnterForeground, scene.didBecomeActive, app.didBecomeActive |
| B, `init()` | register, scene.willConnect, scene.willEnterForeground, app.willEnterForeground |
| C, `init(coder:)` + `awakeFromNib()` | register, app.willFinishLaunching, app.didFinishLaunching, scene.willConnect, scene.willEnterForeground, app.willEnterForeground |
| D, `init()` + selectors | the same as C |

- **B is missing `app.willFinishLaunching` and `app.didFinishLaunching`**, as the source predicts. Both launch-options dictionaries are empty (`keys=[]`) in A, as Flutter's comment says.
- **C and D match A, in the same order.** C uses only public API; D reaches Flutter's private methods by selector and a key-value lookup, so a Flutter release can break it silently. winCode generates **C**.
- **The "became active" pair is not a difference between variants.** It shows in A's first launch only, not in A's second run (the launch followed by a URL), and in none of B, C or D. The log was copied 15 seconds after the launch, so it more likely reflects the simulator's state than the code. It is not claimed either way.

## What the simulator did not show

- **The URL scenarios did not run.** The cold launch from a URL wrote no log in any variant, and the URL sent to a running app produced no `openURLContexts` in any variant, A included. The simulator most likely asked which app to open the URL with, and nothing answered. So `openURL`, `continueUserActivity` and the connection options of a URL launch were not compared. Point 3 and points 4 and 5 are the argument for them: they run in `FlutterSceneDelegate`, which is the same class in A, B and C.
- **Launch options are always empty** with scenes, in both paths. A real value (a URL, a shortcut item) arrives only through `sceneWillConnectFallback:`, point 4.

## Fix

`sceneDelegateBase` makes the view controller with `init(coder:)` on an empty keyed archive, then calls `awakeFromNib()`. A test keeps it equal to `spikes/f-launch-events/variants/C.swift`, the file the simulator ran.

## Reproduce

`gh workflow run launch-events.yml --ref <branch>`; it also runs when its file is pushed to `feat/launch-events`. The artifact has the logs of each variant and scenario, a screenshot of each launch, `summary.md` and the environment.
