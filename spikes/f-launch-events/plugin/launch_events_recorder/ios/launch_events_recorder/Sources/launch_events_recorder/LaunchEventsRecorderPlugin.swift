import Flutter
import UIKit

/// Writes one line per event to Documents/events.log: a number, the event, and what came with it. It only observes;
/// nothing it receives is ever "handled", so Flutter's own fallbacks and deep linking run as they would without it.
enum EventLog {
  private static var count = 0

  static func add(_ event: String, _ details: String = "") {
    count += 1
    let line = "\(count) \(event)" + (details.isEmpty ? "" : " \(details)") + "\n"
    NSLog("[launch-events] %@", line.trimmingCharacters(in: .newlines))
    let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("events.log")
    if let handle = try? FileHandle(forWritingTo: file) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    } else {
      try? Data(line.utf8).write(to: file)
    }
  }

  /// A URL as scheme://host: enough to tell the events apart, and nothing that varies.
  static func url(_ url: URL?) -> String {
    guard let url else { return "none" }
    return "\(url.scheme ?? "")://\(url.host ?? "")"
  }

  static func keys(_ dictionary: [AnyHashable: Any]?) -> String {
    let names = (dictionary ?? [:]).keys.map { "\($0.base)" }.sorted()
    return "keys=[\(names.joined(separator: ","))]"
  }
}

/// Receives the application lifecycle events (the plugin does not conform to the scene protocol, so it is the kind of
/// plugin that gets Flutter's scene fallbacks).
public final class LaunchEventsRecorderPlugin: NSObject, FlutterPlugin {
  private static var kept: [AnyObject] = []

  public static func register(with registrar: FlutterPluginRegistrar) {
    EventLog.add("plugin.register")
    let application = LaunchEventsRecorderPlugin()
    let scene = SceneRecorder()
    // Flutter holds its lifecycle delegates weakly.
    kept = [application, scene]
    registrar.addApplicationDelegate(application)
    registrar.addSceneDelegate(scene)
  }

  @objc(application:willFinishLaunchingWithOptions:)
  public func application(
    _ application: UIApplication,
    willFinishLaunchingWithOptions launchOptions: [AnyHashable: Any] = [:]
  ) -> Bool {
    EventLog.add("app.willFinishLaunching", EventLog.keys(launchOptions))
    return true
  }

  @objc(application:didFinishLaunchingWithOptions:)
  public func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [AnyHashable: Any] = [:]
  ) -> Bool {
    let url = launchOptions[UIApplication.LaunchOptionsKey.url] as? URL
    EventLog.add("app.didFinishLaunching", EventLog.keys(launchOptions) + " url=\(EventLog.url(url))")
    return true
  }

  @objc(application:openURL:options:)
  public func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    EventLog.add("app.openURL", "url=\(EventLog.url(url))")
    return false
  }

  @objc(application:continueUserActivity:restorationHandler:)
  public func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([Any]) -> Void
  ) -> Bool {
    EventLog.add("app.continueUserActivity", "type=\(userActivity.activityType)")
    return false
  }

  @objc(applicationWillEnterForeground:)
  public func applicationWillEnterForeground(_ application: UIApplication) {
    EventLog.add("app.willEnterForeground")
  }

  @objc(applicationDidBecomeActive:)
  public func applicationDidBecomeActive(_ application: UIApplication) {
    EventLog.add("app.didBecomeActive")
  }

  @objc(applicationWillResignActive:)
  public func applicationWillResignActive(_ application: UIApplication) {
    EventLog.add("app.willResignActive")
  }

  @objc(applicationDidEnterBackground:)
  public func applicationDidEnterBackground(_ application: UIApplication) {
    EventLog.add("app.didEnterBackground")
  }
}

/// Receives the scene lifecycle events. Every method answers "not handled", so Flutter's fallbacks to the application
/// events still happen for the plugin above.
final class SceneRecorder: NSObject, FlutterSceneLifeCycleDelegate {
  @objc(scene:willConnectToSession:options:)
  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    let options = connectionOptions
    EventLog.add(
      "scene.willConnect",
      "urlContexts=\(options?.urlContexts.count ?? 0) url=\(EventLog.url(options?.urlContexts.first?.url))"
        + " userActivities=\(options?.userActivities.count ?? 0) shortcut=\(options?.shortcutItem != nil)"
        + " source=\(options?.sourceApplication ?? "none")"
    )
    return false
  }

  @objc(sceneWillEnterForeground:)
  func sceneWillEnterForeground(_ scene: UIScene) { EventLog.add("scene.willEnterForeground") }

  @objc(sceneDidBecomeActive:)
  func sceneDidBecomeActive(_ scene: UIScene) { EventLog.add("scene.didBecomeActive") }

  @objc(sceneWillResignActive:)
  func sceneWillResignActive(_ scene: UIScene) { EventLog.add("scene.willResignActive") }

  @objc(sceneDidEnterBackground:)
  func sceneDidEnterBackground(_ scene: UIScene) { EventLog.add("scene.didEnterBackground") }

  @objc(sceneDidDisconnect:)
  func sceneDidDisconnect(_ scene: UIScene) { EventLog.add("scene.didDisconnect") }

  @objc(scene:openURLContexts:)
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    EventLog.add("scene.openURLContexts", "count=\(URLContexts.count) url=\(EventLog.url(URLContexts.first?.url))")
    return false
  }

  @objc(scene:continueUserActivity:)
  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) -> Bool {
    EventLog.add("scene.continueUserActivity", "type=\(userActivity.activityType)")
    return false
  }
}
