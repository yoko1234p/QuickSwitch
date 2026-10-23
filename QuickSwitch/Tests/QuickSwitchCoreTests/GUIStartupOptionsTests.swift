import Foundation
import XCTest

@testable import QuickSwitchCore

final class GUIStartupOptionsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/fixture/home", isDirectory: true)

    func testNormalLaunchKeepsLiveStoreAndFirstLaunchImport() throws {
        let options = try GUIStartupOptions.parse(arguments: [], home: home)
        XCTAssertEqual(options.dataDirectory.path, "/fixture/home/Library/Application Support/QuickSwitch")
        XCTAssertTrue(options.importOriginalOnFirstLaunch)
        XCTAssertFalse(options.diagnosticMode)
    }

    func testDiagnosticRequiresAnIsolatedExplicitStore() throws {
        let options = try GUIStartupOptions.parse(
            arguments: ["--diagnostic-mode", "--data-directory", "/tmp/qs-fixture", "--show-settings"], home: home)
        XCTAssertEqual(options.dataDirectory.path, "/tmp/qs-fixture")
        XCTAssertTrue(options.diagnosticMode)
        XCTAssertTrue(options.showSettings)
        XCTAssertFalse(options.importOriginalOnFirstLaunch)
        XCTAssertThrowsError(try GUIStartupOptions.parse(arguments: ["--diagnostic-mode"], home: home))
        XCTAssertThrowsError(
            try GUIStartupOptions.parse(
                arguments: [
                    "--diagnostic-mode", "--data-directory", "/fixture/home/Library/Application Support/QuickSwitch",
                ], home: home))
    }

    func testExplicitAlternateStoreNeverImportsOriginalImplicitly() throws {
        let options = try GUIStartupOptions.parse(arguments: ["--data-directory", "/tmp/qs-fixture"], home: home)
        XCTAssertFalse(options.importOriginalOnFirstLaunch)
    }

    func testDiagnosticStoreFileSymlinkCannotAliasTheLiveStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("Library/Application Support/QuickSwitch")
        let isolated = root.appendingPathComponent("diagnostic")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        let liveFile = live.appendingPathComponent("settings.json")
        try Data("fixture".utf8).write(to: liveFile)
        try FileManager.default.createSymbolicLink(
            at: isolated.appendingPathComponent("settings.json"), withDestinationURL: liveFile)
        XCTAssertThrowsError(
            try GUIStartupOptions.parse(
                arguments: ["--diagnostic-mode", "--data-directory", isolated.path], home: root))
        XCTAssertEqual(try Data(contentsOf: liveFile), Data("fixture".utf8))
    }

    func testMalformedOrAmbiguousArgumentsAreRejected() {
        for args in [
            ["--data-directory"], ["--data-directory", "relative"], ["--data-directory", "/tmp/a\0b"],
            ["--show-settings", "--show-settings"], ["--data-directory", "/tmp/a", "--data-directory", "/tmp/b"],
            ["--unknown"],
        ] { XCTAssertThrowsError(try GUIStartupOptions.parse(arguments: args, home: home), "\(args)") }
    }
}
