import Foundation
import QuickSwitchCore
import XCTest

final class SwitchProfileTests: XCTestCase {
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Hong_Kong")!; return value }
    func testClockDeadlineUsesTodayBeforeTimeAndTomorrowAfterTime() throws {
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10, minute: 30))!
        let end = try AwakeClock.next(minute: 1170, after: date, calendar: calendar)
        XCTAssertEqual(end.timeIntervalSince(date), 9 * 3600)
        let late = calendar.date(byAdding: .hour, value: 10, to: date)!
        let tomorrow = try AwakeClock.next(minute: 1170, after: late, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: tomorrow), 21)
        XCTAssertEqual(calendar.component(.hour, from: tomorrow), 19)
        XCTAssertThrowsError(try AwakeClock.next(minute: 1440, after: date, calendar: calendar))
    }
    func testClockHandlesSpringDSTGapAndAlwaysReturnsFutureDate() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let before = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 45))!
        let result = try AwakeClock.next(minute: 150, after: before, calendar: calendar)
        XCTAssertGreaterThan(result, before)
        XCTAssertEqual(calendar.component(.day, from: result), 8)
        XCTAssertEqual(calendar.component(.hour, from: result), 3)
    }
    func testOldConfigurationDefaultsAndProfilesRoundTrip() throws {
        let old = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(AppConfiguration()))
        XCTAssertNil(old.awakeClockMinute)
        XCTAssertEqual(old.effectiveProfiles.map(\.name), ["工作", "開會"])
        var changed = old; changed.awakeClockMinute = 1170; changed.profiles = [SwitchProfile.defaults[0]]
        XCTAssertEqual(try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(changed)), changed)
    }
    func testProfileUsesAbsoluteStatesAndRefusesDestructiveOrUnknownControls() throws {
        let profile = SwitchProfile(name: "Work", steps: [.init(.darkMode, enabled: true), .init(.keepAwake, enabled: true)])
        XCTAssertEqual(try profile.pending(states: [.darkMode: .toggle(true), .keepAwake: .toggle(false)]).map(\.control), [.keepAwake])
        XCTAssertThrowsError(try profile.pending(states: [.darkMode: .unknown("unavailable"), .keepAwake: .toggle(false)]))
        XCTAssertThrowsError(try SwitchProfile(name: "Bad", steps: [.init(.emptyTrash, enabled: true)]).validate())
        XCTAssertThrowsError(try SwitchProfile(name: "Duplicate", steps: [.init(.darkMode, enabled: true), .init(.darkMode, enabled: false)]).validate())
    }
    func testAbsoluteDeadlineRenewalCannotBeStoppedByOldTimer() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var timing = KeepAwakeDeadline()
        try timing.start(until: now.addingTimeInterval(60), now: now)
        let old = timing.generation
        try timing.start(until: now.addingTimeInterval(120), now: now)
        XCTAssertFalse(timing.due(generation: old, at: now.addingTimeInterval(60)))
        let unchanged = timing.deadline
        XCTAssertThrowsError(try timing.start(until: now.addingTimeInterval(-1), now: now))
        XCTAssertEqual(timing.deadline, unchanged)
    }
}
