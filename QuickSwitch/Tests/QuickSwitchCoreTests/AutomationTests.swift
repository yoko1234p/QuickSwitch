import XCTest

@testable import QuickSwitchCore

final class AutomationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar
    }
    private func date(hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: hour, minute: minute))!
    }
    func testOvernightScheduleUsesLocalCalendarAndBoundary() {
        let schedule = DailySchedule(enabled: true, onMinute: 19 * 60, offMinute: 7 * 60)
        XCTAssertEqual(schedule.desiredState(at: date(hour: 19), calendar: calendar), true)
        XCTAssertEqual(schedule.desiredState(at: date(hour: 23), calendar: calendar), true)
        XCTAssertEqual(schedule.desiredState(at: date(hour: 6, minute: 59), calendar: calendar), true)
        XCTAssertEqual(schedule.desiredState(at: date(hour: 7), calendar: calendar), false)
        XCTAssertEqual(schedule.desiredState(at: date(hour: 12), calendar: calendar), false)
    }
    func testSameDayScheduleAndInvalidDuration() {
        let schedule = DailySchedule(enabled: true, onMinute: 600, offMinute: 900)
        XCTAssertEqual(schedule.desiredState(at: date(hour: 10), calendar: calendar), true)
        XCTAssertEqual(schedule.desiredState(at: date(hour: 15), calendar: calendar), false)
        XCTAssertNil(
            DailySchedule(enabled: true, onMinute: 600, offMinute: 600).desiredState(
                at: date(hour: 10), calendar: calendar))
        XCTAssertNil(
            DailySchedule(enabled: true, onMinute: -1, offMinute: 60).desiredState(
                at: date(hour: 10), calendar: calendar))
    }
    func testOriginalProcessSuppressesDuplicateHotkeysAndAutomation() {
        var config = AppConfiguration()
        let shortcut = KeyboardShortcut(keyCode: 18, modifiers: 1 << 20)
        config.switches = [.init(id: SwitchID.darkMode.rawValue, enabled: true, order: 0, shortcut: shortcut)]
        config.restoreAutomations = true
        config.darkSchedule.enabled = true
        XCTAssertTrue(AutomationPolicy.registerHotkeys(configuration: config, originalRunning: true).isEmpty)
        XCTAssertEqual(AutomationPolicy.registerHotkeys(configuration: config, originalRunning: false).count, 1)
        XCTAssertNil(
            AutomationPolicy.desiredDarkMode(
                configuration: config, originalRunning: true, now: date(hour: 23), current: .toggle(false),
                calendar: calendar))
        XCTAssertEqual(
            AutomationPolicy.desiredDarkMode(
                configuration: config, originalRunning: false, now: date(hour: 23), current: .toggle(false),
                calendar: calendar), true)
    }
    func testUnknownStateNeverPretendsFalseAndNoAutomationWithoutOptIn() {
        var config = AppConfiguration()
        config.darkSchedule.enabled = true
        XCTAssertNil(
            AutomationPolicy.desiredDarkMode(
                configuration: config, originalRunning: false, now: date(hour: 23), current: .toggle(false),
                calendar: calendar))
        config.restoreAutomations = true
        XCTAssertNil(
            AutomationPolicy.desiredDarkMode(
                configuration: config, originalRunning: false, now: date(hour: 23), current: .unknown("permission"),
                calendar: calendar))
        XCTAssertNil(
            AutomationPolicy.desiredDarkMode(
                configuration: config, originalRunning: false, now: date(hour: 23), current: .toggle(true),
                calendar: calendar))
    }
    func testDisabledAndUnknownItemsNeverRegisterHotkeys() {
        var config = AppConfiguration()
        let shortcut = KeyboardShortcut(keyCode: 18, modifiers: 1 << 20)
        config.switches = [
            .init(id: SwitchID.darkMode.rawValue, enabled: false, order: 0, shortcut: shortcut),
            .init(id: "Unknown", enabled: true, order: 1, shortcut: shortcut),
        ]
        XCTAssertTrue(AutomationPolicy.registerHotkeys(configuration: config, originalRunning: false).isEmpty)
    }
}

final class SwitchOrderTests: XCTestCase {
    private var items: [SwitchConfiguration] {
        ["a", "b", "c"].enumerated().map { .init(id: $1, enabled: $0 != 1, order: $0) }
    }
    func testDropAfterLastAllowsActualLastPosition() {
        let moved = SwitchOrder.moving(items, id: "a", relativeTo: "c", after: true)
        XCTAssertEqual(moved.map(\.id), ["b", "c", "a"])
        XCTAssertEqual(moved.map(\.order), [0, 1, 2])
        XCTAssertEqual(moved.first?.enabled, false)
    }
    func testAdjacentRowSupportsBothSidesAndDoesNotLoseUnknownRows() {
        XCTAssertEqual(SwitchOrder.moving(items, id: "a", relativeTo: "b", after: true).map(\.id), ["b", "a", "c"])
        XCTAssertEqual(SwitchOrder.moving(items, id: "c", relativeTo: "a", after: false).map(\.id), ["c", "a", "b"])
        XCTAssertEqual(SwitchOrder.moving(items, id: "missing", relativeTo: "a", after: true), items)
    }
}
