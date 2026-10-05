// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Waterline",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "Waterline", targets: ["Waterline"])
  ],
  targets: [
    // Measurement and analysis. No UI, no main-actor default: callers decide where it runs.
    .target(name: "WaterlineCore"),
    // The menu bar app.
    .executableTarget(
      name: "Waterline",
      dependencies: ["WaterlineCore"],
      swiftSettings: [.defaultIsolation(MainActor.self)]
    ),
    .testTarget(name: "WaterlineCoreTests", dependencies: ["WaterlineCore"]),
  ]
)
