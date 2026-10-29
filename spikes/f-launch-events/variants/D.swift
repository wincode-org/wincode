//
//  Generated file. Do not edit.
//

import Flutter
import UIKit

class FlutterSceneDelegate: Flutter.FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    if window == nil, let windowScene = scene as? UIWindowScene {
      let window = UIWindow(windowScene: windowScene)
      window.rootViewController = FlutterViewController()
      forwardLaunchEvents()
      self.window = window
      window.makeKeyAndVisible()
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  /// The two events a storyboard's view controller sends the plugins once they are registered, sent by calling Flutter's
  /// own methods for them (they are not public, so this is by selector).
  private func forwardLaunchEvents() {
    let application = UIApplication.shared
    guard let lifeCycle = (application.delegate as? NSObject)?.value(forKey: "lifeCycleDelegate") as? NSObject else {
      return
    }
    lifeCycle.perform(NSSelectorFromString("sceneFallbackWillFinishLaunchingApplication:"), with: application)
    lifeCycle.perform(NSSelectorFromString("sceneFallbackDidFinishLaunchingApplication:"), with: application)
  }
}
