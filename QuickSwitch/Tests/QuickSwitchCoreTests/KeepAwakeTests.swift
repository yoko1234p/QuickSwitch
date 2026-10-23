import Foundation
import QuickSwitchCore
import XCTest

final class KeepAwakeTests: XCTestCase {
    func testCustomHoursAndMinutesIncludeBoundsAndEmptySingleField() throws {
        XCTAssertEqual(try KeepAwakeDuration.custom(hours: "1", minutes: "35"), 5700)
        XCTAssertEqual(try KeepAwakeDuration.custom(hours: "", minutes: "1"), 60)
        XCTAssertEqual(try KeepAwakeDuration.custom(hours: " 2 ", minutes: ""), 7200)
        XCTAssertEqual(try KeepAwakeDuration.custom(hours: "168", minutes: "0"), 604800)
    }
    func testInvalidDraftsNeverBecomeUnlimitedOrOverflow() {
        for (hours, minutes) in [
            ("", ""), ("0", "0"), ("-1", "0"), ("1.5", "0"), ("0", "60"), ("168", "1"),
            ("169", "0"), ("999999999999999999999999", "0"), ("nan", "5"), ("1", "five"),
        ] {
            XCTAssertThrowsError(try KeepAwakeDuration.custom(hours: hours, minutes: minutes))
        }
    }
    func testExistingSecondPrecisionAndExplicitUnlimitedRemainValid() throws {
        for seconds in [0.0, 0.5, 30, 28800, 604800] { try KeepAwakeDuration.validate(seconds) }
        for seconds in [Double.nan, .infinity, -.infinity, -1, 604801] {
            XCTAssertThrowsError(try KeepAwakeDuration.validate(seconds))
        }
        XCTAssertEqual(KeepAwakeDuration.title(5700), "1 小時 35 分鐘")
        XCTAssertEqual(KeepAwakeDuration.title(0), "直至手動關閉")
        XCTAssertEqual(KeepAwakeDuration.title(30), "30 秒")
    }
    func testRenewalRejectsOldCallbackAndExpiresAtNewDeadline() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var timer = KeepAwakeDeadline()
        try timer.start(seconds: 60, now: now)
        let previous = timer.generation
        try timer.start(seconds: 120, now: now.addingTimeInterval(30))
        XCTAssertFalse(timer.due(generation: previous, at: now.addingTimeInterval(60)))
        XCTAssertFalse(timer.due(generation: timer.generation, at: now.addingTimeInterval(149.9)))
        XCTAssertTrue(timer.due(generation: timer.generation, at: now.addingTimeInterval(150)))
    }
    func testUnlimitedAndStopInvalidateQueuedExpiration() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var timer = KeepAwakeDeadline()
        try timer.start(seconds: 60, now: now)
        let previous = timer.generation
        try timer.start(seconds: 0, now: now)
        XCTAssertNil(timer.deadline)
        XCTAssertFalse(timer.due(generation: previous, at: now.addingTimeInterval(10000)))
        XCTAssertFalse(timer.due(generation: timer.generation, at: now.addingTimeInterval(10000)))
        try timer.start(seconds: 60, now: now)
        let stopped = timer.generation
        timer.clear()
        XCTAssertFalse(timer.due(generation: stopped, at: now.addingTimeInterval(60)))
    }
    func testInvalidRescheduleRetainsExistingDeadline() throws {
        var timer = KeepAwakeDeadline()
        try timer.start(seconds: 120, now: Date(timeIntervalSince1970: 1000))
        let previous = timer.deadline
        let generation = timer.generation
        XCTAssertThrowsError(try timer.start(seconds: .nan, now: Date()))
        XCTAssertEqual(timer.deadline, previous)
        XCTAssertEqual(timer.generation, generation)
    }
    func testCustomDurationRoundTripPreservesOtherPreferences() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConfigurationStore(url: folder.appendingPathComponent("settings.json"))
        var configuration = AppConfiguration()
        configuration.keepAwakeSeconds = try KeepAwakeDuration.custom(hours: "1", minutes: "35")
        configuration.preventSystemSleep = true
        configuration.focusSeconds = 1500
        configuration.hotkeysEnabled = false
        try store.save(configuration)
        XCTAssertEqual(try store.load(), configuration)
    }
}
