// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "QuickSwitch", defaultLocalization: "en", platforms: [.macOS(.v14)],
    products: [.executable(name: "QuickSwitch", targets: ["QuickSwitch"])],
    dependencies: [.package(path: "../Shared/MacProcessKit"), .package(path: "../Shared/AppLocalizationKit")],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "QuickSwitchCore", dependencies: ["CSQLite", .product(name: "MacProcessKit", package: "MacProcessKit"), .product(name: "AppLocalizationKit", package: "AppLocalizationKit")], resources: [.process("Resources/Localization")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "QuickSwitchNative", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("IOBluetooth"), .linkedFramework("ApplicationServices")]),
        .executableTarget(name: "QuickSwitch", dependencies: ["QuickSwitchCore", "QuickSwitchNative"], swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreAudio"), .linkedFramework("Carbon")]),
        .testTarget(name: "QuickSwitchCoreTests", dependencies: ["QuickSwitchCore"]),
        .testTarget(name: "QuickSwitchAppTests", dependencies: ["QuickSwitch"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
