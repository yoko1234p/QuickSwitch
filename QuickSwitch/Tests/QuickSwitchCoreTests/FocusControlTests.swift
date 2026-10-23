import Foundation
import XCTest

@testable import QuickSwitchCore

final class FocusControlTests: XCTestCase {
    func testOtherFocusIsNotDNDAndCachedCommandDoesNotBecomeCurrentState() throws {
        let other = FocusSnapshot(status: "exact", dndEnabled: false, otherFocusActive: true)
        XCTAssertEqual(FocusControlPolicy.state(snapshot: other, lastCommand: nil).isOn, false)
        let mixed = FocusSnapshot(status: "exact", dndEnabled: true, otherFocusActive: true)
        let mixedState = FocusControlPolicy.state(snapshot: mixed, lastCommand: nil)
        XCTAssertEqual(mixedState.isOn, true)
        XCTAssertFalse(mixedState.detail.contains("未開啟"))
        let cached = FocusCommandObservation(requestedEnabled: true)
        let denied = FocusSnapshot(status: "denied")
        XCTAssertNil(FocusControlPolicy.state(snapshot: denied, lastCommand: cached).isOn)
        XCTAssertTrue(FocusControlPolicy.state(snapshot: denied, lastCommand: cached).detail.contains("上次"))
        XCTAssertNil(FocusControlPolicy.state(snapshot: denied, lastCommand: nil).isOn)
    }
    func testMalformedNativeSnapshotAndUncertainWritesNeverBecomeSuccessOrDoubleFallback() throws {
        let valid = Data(#"{"status":"exact","dndEnabled":false,"mutationAttempted":false}"#.utf8)
        XCTAssertEqual(try FocusSnapshot.decode(valid).exactDND, false)
        for text in [
            #"{"status":"exact","mutationAttempted":false}"#,
            #"{"status":"exact","dndEnabled":1,"mutationAttempted":false}"#,
            #"{"status":"invented","mutationAttempted":false}"#,
            #"{"status":"denied"}"#,
        ] { XCTAssertThrowsError(try FocusSnapshot.decode(Data(text.utf8))) }
        XCTAssertThrowsError(try FocusSnapshot.decode(Data(repeating: 32, count: 8193)))
        XCTAssertFalse(FocusSnapshot(status: "unverified", mutationAttempted: true).permitsShortcutFallback)
        XCTAssertFalse(FocusSnapshot(status: "failed", mutationAttempted: true).permitsShortcutFallback)
        XCTAssertTrue(FocusSnapshot(status: "denied").permitsShortcutFallback)
    }
    func testOnlyKnownDefaultsMayUseOwnedPairAndCustomNamesArePreserved() {
        let installed: Set<String> = [FocusControlPolicy.ownedOnName, FocusControlPolicy.ownedOffName, "My Focus On"]
        XCTAssertEqual(
            FocusControlPolicy.shortcutName(
                configured: FocusControlPolicy.sourceOnName,
                enabled: true, installed: installed), FocusControlPolicy.ownedOnName)
        XCTAssertEqual(
            FocusControlPolicy.shortcutName(
                configured: "My Focus On", enabled: true,
                installed: installed), "My Focus On")
        XCTAssertNil(FocusControlPolicy.shortcutName(configured: "Missing custom", enabled: true, installed: installed))
        XCTAssertNil(FocusControlPolicy.shortcutName(configured: "a\nb", enabled: true, installed: ["a\nb"]))
    }
    func testListFailureShapesAreRejectedRatherThanClaimingInstallation() throws {
        XCTAssertEqual(try FocusControlPolicy.installedNames("A\nB\n"), ["A", "B"])
        XCTAssertEqual(try FocusControlPolicy.installedNames(""), [])
        XCTAssertThrowsError(try FocusControlPolicy.installedNames("A\nA\n"))
        XCTAssertThrowsError(try FocusControlPolicy.installedNames(String(repeating: "x", count: 65536)))
    }
    func testFailedExpiryRetainsDeadlineBacksOffAndOriginalPausesIt() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var timer = FocusDeadlineTracker(deadline: now.addingTimeInterval(-1))
        XCTAssertFalse(timer.due(at: now, originalRunning: true))
        XCTAssertTrue(timer.due(at: now, originalRunning: false))
        timer.complete(succeeded: false, at: now)
        XCTAssertNotNil(timer.deadline)
        XCTAssertFalse(timer.due(at: now.addingTimeInterval(29), originalRunning: false))
        XCTAssertTrue(timer.due(at: now.addingTimeInterval(30), originalRunning: false))
        timer.complete(succeeded: false, at: now.addingTimeInterval(30))
        XCTAssertFalse(timer.due(at: now.addingTimeInterval(89), originalRunning: false))
        timer.complete(succeeded: true, at: now.addingTimeInterval(90))
        XCTAssertNil(timer.deadline)
        XCTAssertNil(timer.retryAt)
    }
    func testIndependentShortcutDocumentsContainOnlyOneExplicitDNDAction() throws {
        for enabled in [false, true] {
            let object =
                try PropertyListSerialization.propertyList(
                    from: FocusShortcutDocument.make(enabled: enabled),
                    options: [], format: nil) as! [String: Any]
            let actions = try XCTUnwrap(object["WFWorkflowActions"] as? [[String: Any]])
            XCTAssertEqual(actions.count, 1)
            XCTAssertEqual(actions[0]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.dnd.set")
            let parameters = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
            XCTAssertEqual(parameters.keys.sorted(), ["Enabled"])
            XCTAssertEqual(parameters["Enabled"] as? Bool, enabled)
            XCTAssertEqual(
                object["WFWorkflowName"] as? String,
                enabled ? FocusControlPolicy.ownedOnName : FocusControlPolicy.ownedOffName)
        }
    }
    /// Opt-in integration fixture: signs generated documents only, never imports or executes them.
    func testGeneratedDocumentsPassSystemSignerWithoutInstalling() async throws {
        guard ProcessInfo.processInfo.environment["QS_RUN_SIGNING_FIXTURE"] == "1" else {
            throw XCTSkip(
                "Set QS_RUN_SIGNING_FIXTURE=1 to exercise Apple's signer without importing/running a shortcut")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = CommandRunner()
        for enabled in [false, true] {
            let input = directory.appendingPathComponent("input-\(enabled).shortcut")
            let output = directory.appendingPathComponent("signed-\(enabled).shortcut")
            try FocusShortcutDocument.make(enabled: enabled).write(to: input)
            let result = await runner.run(
                "/usr/bin/shortcuts",
                [
                    "sign", "--mode", "anyone",
                    "--input", input.path, "--output", output.path,
                ], timeout: 30)
            XCTAssertTrue(result.succeeded, "System signer rejected the generated shortcut (status \(result.status))")
            XCTAssertGreaterThan((try? Data(contentsOf: output).count) ?? 0, 100)
        }
    }
}
