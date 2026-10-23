// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AppLocalizationKit",
  platforms: [.macOS(.v14)],
  products: [.library(name: "AppLocalizationKit", targets: ["AppLocalizationKit"])],
  targets: [
    .target(name: "AppLocalizationKit", swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(
      name: "AppLocalizationKitTests", dependencies: ["AppLocalizationKit"],
      resources: [.copy("Fixtures")]),
  ]
)
