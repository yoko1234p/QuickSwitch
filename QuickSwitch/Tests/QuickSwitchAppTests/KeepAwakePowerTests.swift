import Foundation
import QuickSwitchCore
import XCTest

@testable import QuickSwitch

@MainActor final class KeepAwakePowerTests: XCTestCase {
    func testDiagnosticBackendRejectsWakeAndReschedule() async throws {
        let backend = SystemBackend(allowsSystemChanges: false)
        defer { backend.shutdown() }
        do {
            try await backend.activate(.keepAwake, desired: true, config: AppConfiguration())
            XCTFail("Diagnostic backend accepted a power mutation")
        } catch {}
        XCTAssertThrowsError(try backend.rescheduleAwake(seconds: 60))
        XCTAssertFalse(backend.awakeIsActive)
    }

    func testNativeExpiryDoesNotRequireReadStatePolling() async throws {
        try requirePowerFixture()
        let backend = SystemBackend()
        defer { backend.shutdown() }
        var config = AppConfiguration()
        config.keepAwakeSeconds = 0.2
        try await backend.activate(.keepAwake, desired: true, config: config)
        XCTAssertTrue(backend.awakeIsActive)
        try await waitForExpiry(backend)
        XCTAssertFalse(backend.awakeIsActive)
    }

    func testNativeRescheduleAndUnlimitedCancelPreviousTimer() async throws {
        try requirePowerFixture()
        let backend = SystemBackend()
        defer { backend.shutdown() }
        var config = AppConfiguration()
        config.keepAwakeSeconds = 0.1
        try await backend.activate(.keepAwake, desired: true, config: config)
        try backend.rescheduleAwake(seconds: 1)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(backend.awakeIsActive)
        try backend.rescheduleAwake(seconds: 0)
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(backend.awakeIsActive)
        try backend.rescheduleAwake(seconds: 0.1)
        try await waitForExpiry(backend)
        XCTAssertFalse(backend.awakeIsActive)
    }

    private func waitForExpiry(_ backend: SystemBackend) async throws {
        for _ in 0..<100 {
            if !backend.awakeIsActive { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private func requirePowerFixture() throws {
        guard ProcessInfo.processInfo.environment["QS_RUN_AWAKE_POWER_FIXTURE"] == "1" else {
            throw XCTSkip("Opt-in fixture briefly holds only this test process's idle-display-sleep assertion")
        }
    }
}
