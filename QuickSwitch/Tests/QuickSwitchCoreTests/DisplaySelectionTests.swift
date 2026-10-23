import XCTest

@testable import QuickSwitchCore

final class DisplaySelectionTests: XCTestCase {
    private let screens = [
        DisplayDescriptor(id: 10, stableID: "builtin", title: "Built-in", sourceIndex: 0),
        DisplayDescriptor(id: 20, stableID: "external", title: "External", sourceIndex: 1),
    ]

    func testImportedDisplayIndexSelectsTheCorrespondingScreenWithoutChangingConfiguration() {
        XCTAssertEqual(DisplaySelection.resolve(displays: screens, savedStableID: nil, sourceIndex: 1).displayID, 20)
        XCTAssertNil(DisplaySelection.resolve(displays: screens, savedStableID: nil, sourceIndex: -3).displayID)
        XCTAssertEqual(DisplaySelection.resolve(displays: [], savedStableID: nil, sourceIndex: 1).displayID, nil)
    }

    func testStableIdentitySurvivesTopologyReorderAndTemporaryDisconnect() {
        let changedIDs = [
            DisplayDescriptor(id: 30, stableID: "external", title: "External", sourceIndex: 0),
            DisplayDescriptor(id: 11, stableID: "builtin", title: "Built-in", sourceIndex: 1),
        ]
        let reconnected = DisplaySelection.resolve(displays: changedIDs, savedStableID: "external", sourceIndex: 1)
        XCTAssertEqual(reconnected.displayID, 30)
        XCTAssertFalse(reconnected.savedDisplayMissing)
        let missing = DisplaySelection.resolve(displays: [screens[0]], savedStableID: "external", sourceIndex: 1)
        XCTAssertNil(missing.displayID)
        XCTAssertTrue(missing.savedDisplayMissing)
        let restored = DisplaySelection.resolve(
            displays: changedIDs, savedStableID: "external", sourceIndex: 1, currentSelection: missing.displayID)
        XCTAssertEqual(restored.displayID, 30)
    }

    func testModeFilterNeverMixesDisplaysOrHidesTheActualCurrentMode() {
        let modes = [
            mode(10, 1, pixels: 1920), mode(10, 2, pixels: 3840), mode(20, 3, pixels: 3840),
        ]
        let filtered = DisplayModePolicy.visibleModes(modes, displayID: 10, onlyHiDPI: true, currentModeID: 1)
        XCTAssertEqual(Set(filtered.map(\.modeID)), [1, 2])
        XCTAssertTrue(filtered.allSatisfy { $0.displayID == 10 })
        XCTAssertEqual(DisplayModePolicy.visibleModes(modes, displayID: nil, onlyHiDPI: false, currentModeID: nil), [])
    }

    func testDedupKeepsCurrentIdentifierAndPreservesFractionalRefreshRates() {
        let modes = [
            mode(10, 1, pixels: 3840, rate: 59.94), mode(10, 2, pixels: 3840, rate: 59.94),
            mode(10, 3, pixels: 3840, rate: 60), mode(10, 4, pixels: 3840, rate: .nan),
        ]
        let filtered = DisplayModePolicy.visibleModes(modes, displayID: 10, onlyHiDPI: false, currentModeID: 2)
        XCTAssertEqual(filtered.map(\.modeID), [2, 3])
        XCTAssertTrue(filtered[0].title.contains("59.94"))
        XCTAssertFalse(mode(10, 5, pixels: 1920, rate: 0).title.contains("0 Hz"))
    }

    private func mode(_ display: UInt32, _ id: Int32, pixels: Int, rate: Double = 60) -> DisplayModeDescriptor {
        DisplayModeDescriptor(
            displayID: display, modeID: id, width: 1920, height: 1080, pixelWidth: pixels,
            pixelHeight: pixels == 3840 ? 2160 : 1080, refreshRate: rate)
    }

    func testRollbackDoesNotOverwriteAnotherDisplayOrAnExternalModeChange() {
        XCTAssertTrue(
            DisplayRollbackPolicy.shouldRestore(
                savedStableID: "external", currentStableID: "external", online: true, appliedModeID: 30,
                currentModeID: 30))
        XCTAssertFalse(
            DisplayRollbackPolicy.shouldRestore(
                savedStableID: "external", currentStableID: "other", online: true, appliedModeID: 30, currentModeID: 30)
        )
        XCTAssertFalse(
            DisplayRollbackPolicy.shouldRestore(
                savedStableID: "external", currentStableID: "external", online: false, appliedModeID: 30,
                currentModeID: 30))
        XCTAssertFalse(
            DisplayRollbackPolicy.shouldRestore(
                savedStableID: "external", currentStableID: nil, online: true, appliedModeID: 30, currentModeID: 30))
        XCTAssertFalse(
            DisplayRollbackPolicy.shouldRestore(
                savedStableID: "external", currentStableID: "external", online: true, appliedModeID: 30,
                currentModeID: 31))
        XCTAssertFalse(
            DisplayRollbackPolicy.shouldRestore(
                savedStableID: "external", currentStableID: "external", online: true, appliedModeID: 30,
                currentModeID: nil))
    }

    func testTypedDisplayImportRejectsAmbiguousOrMalformedValuesWithoutDiscardingArchive() throws {
        for bad: Any in [true, -1, 1.5, "1", [1]] {
            let archive = try PropertyListSerialization.data(
                fromPropertyList: ["screen-resolution-selected-display-index": bad], format: .binary, options: 0)
            let configuration = try OneSwitchImporter.translate(
                rows: [], preferences: archive, sourceVersion: "fixture")
            XCTAssertEqual(configuration.selectedDisplayIndex, -1)
            XCTAssertTrue(
                configuration.migration?.untranslatedPreferenceKeys.contains("screen-resolution-selected-display-index")
                    == true)
            XCTAssertEqual(configuration.importedPreferences, archive)
        }
        let archive = try PropertyListSerialization.data(
            fromPropertyList: ["screen-resolution-selected-display-index": 1, "screen-resolution-only-hidpi": true],
            format: .binary, options: 0)
        var configuration = try OneSwitchImporter.translate(rows: [], preferences: archive, sourceVersion: "fixture")
        XCTAssertEqual(configuration.selectedDisplayIndex, 1)
        XCTAssertTrue(configuration.onlyHiDPI)
        configuration.selectedDisplayUUID = "own-physical-display"
        configuration.selectedDisplayIndex = 0
        configuration.onlyHiDPI = false
        let roundtrip = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration))
        let upgraded = OneSwitchImporter.upgradingPreservedImport(roundtrip)
        XCTAssertEqual(upgraded.selectedDisplayUUID, "own-physical-display")
        XCTAssertEqual(upgraded.selectedDisplayIndex, 0)
        XCTAssertFalse(upgraded.onlyHiDPI)
    }
}
