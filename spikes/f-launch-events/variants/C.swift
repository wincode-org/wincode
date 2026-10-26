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
      window.rootViewController = makeFlutterViewController()
      self.window = window
      window.makeKeyAndVisible()
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  /// A storyboard makes its view controller by decoding it (`init(coder:)`) and then sends it `awakeFromNib`. Flutter's
  /// view controller sets up its engine in `awakeFromNib`, and only a view controller set up there tells the plugins that
  /// the app has launched (`willFinishLaunching` and `didFinishLaunching`, which UIKit did not send them because they
  /// were not registered yet). `init()` skips both, so make the view controller the way a storyboard does.
  private func makeFlutterViewController() -> FlutterViewController {
    let archiver = NSKeyedArchiver(requiringSecureCoding: false)
    archiver.finishEncoding()
    let coder = try! NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
    coder.requiresSecureCoding = false
    let controller = FlutterViewController(coder: coder)
    controller.awakeFromNib()
    return controller
  }
}
