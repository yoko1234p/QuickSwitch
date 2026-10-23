import XCTest

@testable import QuickSwitchCore

final class SystemObservationTests: XCTestCase {
    func testRecordingObservedLoginPreservesOtherPersonalEditsAndDoesNotActivateAutomation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        let data = try PropertyListSerialization.data(fromPropertyList: [:], format: .binary, options: 0)
        var configuration = try OneSwitchImporter.translate(rows: [], preferences: data, sourceVersion: "fixture")
        configuration.keepAwakeSeconds = 7200
        try store.save(configuration)
        let observation = SourceSystemObservation(
            bundleID: OneSwitchImporter.sourceBundleID, version: "fixture", observedAt: Date(), loginAtStartup: true,
            source: "native-preferences-checkbox", evidenceSHA256: String(repeating: "a", count: 64))
        try store.recordSystemObservation(observation)
        XCTAssertEqual(try store.load()?.sourceSystemObservation, observation)
        XCTAssertEqual(try store.load()?.keepAwakeSeconds, 7200)
        XCTAssertEqual(try store.load()?.restoreAutomations, false)
        XCTAssertEqual(try store.load()?.switches, configuration.switches)
        try store.recordSystemObservation(observation)
        XCTAssertEqual(try store.load()?.sourceSystemObservation, observation)
    }
    func testObservationFromAnotherApplicationIsRejected() throws {
        let observation = SourceSystemObservation(
            bundleID: "another.app", version: "fixture", observedAt: Date(), loginAtStartup: true,
            source: "native-preferences-checkbox", evidenceSHA256: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try observation.validate())
    }
}
