// swift-tools-version: 6.0

import PackageDescription

// Spike B runner: a SwiftUI app that hosts Flutter's counter app.
// Flutter.xcframework (the prebuilt engine) is staged next to this file by
// stage.sh and is never committed. App.framework (the Dart AOT snapshot built
// on Linux in spike A) is not a dependency: it has no exports trie, so it
// cannot be linked. build.sh embeds it after the build, and the engine
// dlopens it at runtime, as in a regular Flutter app.
let package = Package(
    name: "CounterRunner",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        // An xtool project contains exactly one library product: the app.
        .library(
            name: "CounterRunner",
            targets: ["CounterRunner"]
        ),
    ],
    targets: [
        .target(
            name: "CounterRunner",
            dependencies: ["Flutter"]
        ),
        .binaryTarget(name: "Flutter", path: "Flutter.xcframework"),
    ]
)
