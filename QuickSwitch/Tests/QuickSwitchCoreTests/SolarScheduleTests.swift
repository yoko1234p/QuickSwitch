import XCTest

@testable import QuickSwitchCore

final class SolarScheduleTests: XCTestCase {
    private func calendar(_ offset: Int) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: offset)!
        return value
    }
    func testHongKongCivilDaySpansPreviousUTCDay() throws {
        let local = calendar(8 * 3600)
        let day = local.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        guard
            case .events(let sunrise, let sunset) = SolarSchedule.day(
                at: day, location: .init(latitude: 22.3, longitude: 114.2), calendar: local)
        else { return XCTFail("Missing solar events") }
        XCTAssertEqual(local.component(.day, from: sunrise), 14)
        XCTAssertEqual(local.component(.day, from: sunset), 14)
        XCTAssertEqual(local.component(.hour, from: sunrise), 6)
        XCTAssertEqual(local.component(.hour, from: sunset), 17)
        XCTAssertLessThan(sunrise, sunset)
        XCTAssertFalse(SolarDay.events(sunrise: sunrise, sunset: sunset).dark(at: day))
    }
    func testPolarSummerAndWinterDoNotInventEvents() {
        let utc = calendar(0)
        let summer = utc.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 12))!
        let winter = utc.date(from: DateComponents(year: 2026, month: 12, day: 21, hour: 12))!
        XCTAssertEqual(
            SolarSchedule.day(at: summer, location: .init(latitude: 80, longitude: 0), calendar: utc), .polarDay)
        XCTAssertEqual(
            SolarSchedule.day(at: winter, location: .init(latitude: 80, longitude: 0), calendar: utc), .polarNight)
    }
    func testInvalidCoordinatesRejectBeforeTrigonometry() {
        XCTAssertNil(SolarSchedule.day(at: Date(), location: .init(latitude: .nan, longitude: 0)))
        XCTAssertNil(SolarSchedule.day(at: Date(), location: .init(latitude: 0, longitude: 200)))
    }
    func testSolarAutomationRequiresLocationAndDoesNotRunAlongsideOriginal() {
        var config = AppConfiguration()
        config.restoreAutomations = true
        config.darkSchedule.enabled = true
        config.usesSolarSchedule = true
        let local = calendar(8 * 3600)
        let night = local.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 23))!
        XCTAssertNil(
            AutomationPolicy.desiredDarkMode(
                configuration: config, originalRunning: false, now: night, current: .toggle(false), calendar: local))
        config.solarLocation = .init(latitude: 22.3, longitude: 114.2)
        XCTAssertEqual(
            AutomationPolicy.desiredDarkMode(
                configuration: config, originalRunning: false, now: night, current: .toggle(false), calendar: local),
            true)
        XCTAssertNil(
            AutomationPolicy.desiredDarkMode(
                configuration: config, originalRunning: true, now: night, current: .toggle(false), calendar: local))
    }
}
