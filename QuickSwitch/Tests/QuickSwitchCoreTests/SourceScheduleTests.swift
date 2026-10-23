import Foundation
import XCTest

@testable import QuickSwitchCore

final class SourceScheduleTests: XCTestCase {
    private func imported(_ values: [String: Any]) throws -> AppConfiguration {
        try OneSwitchImporter.translate(
            rows: [],
            preferences: PropertyListSerialization.data(
                fromPropertyList: values, format: .binary, options: 0), sourceVersion: "fixture")
    }
    func testSourceEnumMapsAllThreeModesWithoutActivatingAutomation() throws {
        for (raw, mode) in [(0, DarkScheduleMode.manual), (1, .sunsetToSunrise), (2, .fixedTimes)] {
            let value = try imported(["dark-mode-switch-type": raw, "dark-mode-enable-auto-schedule": true])
            XCTAssertEqual(value.effectiveDarkScheduleMode, mode)
            XCTAssertFalse(value.restoreAutomations)
        }
        var manual = try imported(["dark-mode-switch-type": 0, "dark-mode-enable-auto-schedule": true])
        manual.restoreAutomations = true
        XCTAssertNil(
            AutomationPolicy.desiredDarkMode(
                configuration: manual, originalRunning: false,
                now: Date(), current: .toggle(false)))
    }
    func testSourceLocationDictionaryIsTypedAndBadArchivesStayInactive() throws {
        let valid = try imported([
            "dark-mode-switch-type": 1,
            "dark-mode-location": ["latitude": 22.3, "longitude": 114.2],
        ])
        XCTAssertEqual(valid.solarLocation, SolarLocation(latitude: 22.3, longitude: 114.2))
        XCTAssertEqual(valid.migration?.translatedPreferenceCount, 2)
        for value: Any in [
            ["latitude": true, "longitude": 1], ["latitude": 91, "longitude": 1],
            ["latitude": "22.3", "longitude": 114.2], ["latitude": 0, "longitude": 181],
            Data("unsupported object archive".utf8),
        ] {
            let result = try imported(["dark-mode-location": value])
            XCTAssertNil(result.solarLocation)
            XCTAssertEqual(result.migration?.untranslatedPreferenceKeys, ["dark-mode-location"])
            XCTAssertEqual(result.migration?.translatedPreferenceCount, 0)
            XCTAssertNotNil(result.importedPreferences)
        }
    }
    func testUnknownSourceModeDoesNotBecomeFixedSchedule() throws {
        for value: Any in [3, -1, true, "1", 1.5] {
            let config = try imported(["dark-mode-switch-type": value])
            XCTAssertEqual(config.effectiveDarkScheduleMode, .manual)
            XCTAssertEqual(config.migration?.untranslatedPreferenceKeys, ["dark-mode-switch-type"])
            XCTAssertEqual(config.migration?.translatedPreferenceCount, 0)
        }
    }
    func testUpgradeFillsOnlyUntouchedFieldsAndIsIdempotent() throws {
        var previous = try imported([
            "dark-mode-switch-type": 1,
            "dark-mode-location": ["latitude": 22.3, "longitude": 114.2],
        ])
        previous.darkScheduleMode = nil
        previous.usesSolarSchedule = nil
        previous.solarLocation = nil
        let updated = OneSwitchImporter.upgradingPreservedImport(previous)
        XCTAssertEqual(updated.effectiveDarkScheduleMode, .sunsetToSunrise)
        XCTAssertEqual(updated.solarLocation, SolarLocation(latitude: 22.3, longitude: 114.2))
        XCTAssertEqual(OneSwitchImporter.upgradingPreservedImport(updated), updated)
        var changed = previous
        changed.usesSolarSchedule = false
        changed.darkSchedule.onMinute = 123
        changed.solarLocation = SolarLocation(latitude: 40, longitude: -74)
        XCTAssertEqual(OneSwitchImporter.upgradingPreservedImport(changed), changed)
        changed = previous
        changed.restoreAutomations = true
        XCTAssertEqual(OneSwitchImporter.upgradingPreservedImport(changed), changed)
        changed = previous
        changed.darkSchedule.onMinute = 321
        XCTAssertEqual(OneSwitchImporter.upgradingPreservedImport(changed), changed)
    }
    func testSourceCachedDNDIsNotRestoredAsCurrentSystemState() throws {
        let config = try imported(["dnd-shortcut-cached-state": true, "dnd-shortcuts-installed": true])
        XCTAssertEqual(config.importedFocusCachedState, true)
        XCTAssertEqual(config.importedFocusShortcutsInstalled, true)
        XCTAssertNil(config.focusOffAt)
        XCTAssertFalse(config.restoreAutomations)
    }
}
