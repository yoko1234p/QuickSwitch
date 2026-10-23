import XCTest

@testable import QuickSwitchCore

@MainActor
final class HiddenApplicationsSessionTests: XCTestCase {
    private final class Application {
        var isHidden = false
        var isTerminated = false
        var allowHide = true
        var allowUnhide = true
        var deferredVisibility = false
        var acknowledgeOnly = false
        var hides = 0
        var unhides = 0
    }

    private func session(_ applications: @escaping () -> [Application]) -> HiddenApplicationsSession<Application> {
        HiddenApplicationsSession(
            applications: applications, terminated: { $0.isTerminated }, hidden: { $0.isHidden },
            hide: {
                $0.hides += 1
                if $0.allowHide && !$0.acknowledgeOnly {
                    if $0.deferredVisibility {
                        let app = $0
                        Task {
                            try? await Task.sleep(nanoseconds: 20_000_000)
                            guard !Task.isCancelled else { return }
                            app.isHidden = true
                        }
                    } else {
                        $0.isHidden = true
                    }
                }
                return $0.allowHide
            },
            unhide: {
                $0.unhides += 1
                if $0.allowUnhide {
                    if $0.deferredVisibility {
                        let app = $0
                        Task {
                            try? await Task.sleep(nanoseconds: 20_000_000)
                            guard !Task.isCancelled else { return }
                            app.isHidden = false
                        }
                    } else {
                        $0.isHidden = false
                    }
                }
                return $0.allowUnhide
            }, sameInstance: { $0 === $1 })
    }

    func testExplicitOffNeverHidesAndRepeatedOnNeverUnhides() async throws {
        let app = Application()
        let control = session { [app] }
        try await control.set(false)
        XCTAssertEqual(app.hides, 0)
        try await control.set(true)
        try await control.set(true)
        XCTAssertTrue(app.isHidden)
        XCTAssertEqual(app.hides, 1)
        XCTAssertEqual(app.unhides, 0)
        try await control.set(false)
        try await control.set(false)
        XCTAssertEqual(app.unhides, 1)
        XCTAssertFalse(control.isActive)
    }

    func testNeverRestoresPreviouslyHiddenOrTerminatedApplications() async throws {
        let preexisting = Application()
        preexisting.isHidden = true
        let owned = Application()
        let control = session { [preexisting, owned] }
        try await control.set(true)
        owned.isTerminated = true
        try await control.set(false)
        XCTAssertTrue(preexisting.isHidden)
        XCTAssertEqual(preexisting.unhides, 0)
        XCTAssertEqual(owned.unhides, 0)
    }

    func testPartialFailuresRemainRetryableWithoutLosingOwnership() async throws {
        let first = Application()
        let second = Application()
        second.allowHide = false
        let control = session { [first, second] }
        do {
            try await control.set(true)
            XCTFail("Expected hide failure")
        } catch {}
        XCTAssertTrue(control.isActive)
        XCTAssertTrue(first.isHidden)
        second.allowHide = true
        try await control.set(true)
        XCTAssertTrue(second.isHidden)
        first.allowUnhide = false
        do {
            try await control.set(false)
            XCTFail("Expected restore failure")
        } catch {}
        XCTAssertTrue(control.isActive)
        XCTAssertFalse(second.isHidden)
        first.allowUnhide = true
        try await control.set(false)
        XCTAssertFalse(control.isActive)
        XCTAssertEqual(second.unhides, 1)
    }

    func testExternalRestoreAndNewApplicationAreRereadWithoutStaleToggle() async throws {
        let first = Application()
        var apps = [first]
        let control = session { apps }
        try await control.set(true)
        first.isHidden = false
        XCTAssertFalse(control.isActive)
        let next = Application()
        apps.append(next)
        try await control.set(false)
        XCTAssertFalse(first.isHidden)
        XCTAssertFalse(next.isHidden)
        try await control.set(true)
        XCTAssertTrue(first.isHidden)
        XCTAssertTrue(next.isHidden)
        try await control.set(nil)
        XCTAssertFalse(control.isActive)
    }

    func testDelayedAppKitObservationIsConfirmedWithoutLosingOwnership() async throws {
        let app = Application()
        app.deferredVisibility = true
        let control = session { [app] }
        try await control.set(true)
        XCTAssertTrue(app.isHidden)
        XCTAssertEqual(control.state.isOn, true)
        try await control.set(false)
        XCTAssertFalse(app.isHidden)
        XCTAssertFalse(control.isActive)
        XCTAssertEqual(app.unhides, 1)
    }

    func testAcknowledgedButUnconfirmedHideRemainsRecoverableAndUnknown() async throws {
        let app = Application()
        app.acknowledgeOnly = true
        let control = session { [app] }
        do {
            try await control.set(true)
            XCTFail("A request acknowledgement is not a hidden-state confirmation")
        } catch {}
        XCTAssertNil(control.state.isOn)
        XCTAssertTrue(control.isActive)
        try await control.set(false)
        XCTAssertEqual(app.unhides, 1)
        XCTAssertFalse(control.isActive)
    }

    func testCancellationRetainsAcceptedRequestsForExplicitRecovery() async throws {
        let app = Application()
        app.acknowledgeOnly = true
        let control = session { [app] }
        let request = Task { try await control.set(true) }
        for _ in 0..<8 {
            if app.hides > 0 { break }
            await Task.yield()
        }
        XCTAssertEqual(app.hides, 1)
        request.cancel()
        do {
            try await request.value
            XCTFail("Expected cancellation")
        } catch {}
        XCTAssertNil(control.state.isOn)
        try await control.set(false)
        XCTAssertEqual(app.unhides, 1)
        XCTAssertFalse(control.isActive)
    }
}
