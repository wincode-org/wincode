import Flutter
import SwiftUI

@main
struct CounterRunnerApp: App {
    var body: some Scene {
        WindowGroup {
            FlutterScreen()
                .ignoresSafeArea()
        }
    }
}

private struct FlutterScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> FlutterViewController {
        // With no project, the engine loads Frameworks/App.framework
        // (bundle ID io.flutter.flutter.app) and its flutter_assets.
        FlutterViewController(project: nil, nibName: nil, bundle: nil)
    }

    func updateUIViewController(_ controller: FlutterViewController, context: Context) {}
}
