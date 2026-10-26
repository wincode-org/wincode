// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "launch_events_recorder",
  platforms: [
    .iOS("13.0")
  ],
  products: [
    .library(name: "launch-events-recorder", targets: ["launch_events_recorder"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "launch_events_recorder",
      dependencies: []
    )
  ]
)
