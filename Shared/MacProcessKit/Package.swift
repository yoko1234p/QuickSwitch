// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MacProcessKit",
  platforms: [.macOS(.v14)],
  products: [.library(name: "MacProcessKit", targets: ["MacProcessKit"])],
  targets: [
    .target(name: "MacProcessKit", swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "MacProcessKitTests", dependencies: ["MacProcessKit"]),
  ]
)
