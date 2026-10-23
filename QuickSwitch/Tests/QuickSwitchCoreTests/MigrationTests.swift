import CSQLite
import Foundation
import XCTest

@testable import QuickSwitchCore

final class MigrationTests: XCTestCase {
    private func plist(_ dictionary: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }
    func testPreservesActualOrderingHiddenStateAndUnknownDescriptors() throws {
        let rows = [
            SwitchConfiguration(id: SwitchID.darkMode.rawValue, enabled: false, order: 9, customName: "My Dark"),
            SwitchConfiguration(id: "FutureSwitch", enabled: true, order: 2),
            SwitchConfiguration(id: SwitchID.keepAwake.rawValue, enabled: true, order: 0),
        ]
        let input = try plist(["keep-awake-interval": 28800, "unknown-key": Data([1, 2, 3])])
        let config = try OneSwitchImporter.translate(rows: rows, preferences: input, sourceVersion: "fixture")
        XCTAssertEqual(
            Array(config.orderedSwitches.prefix(3).map(\.id)),
            [SwitchID.keepAwake.rawValue, "FutureSwitch", SwitchID.darkMode.rawValue])
        XCTAssertEqual(config.switches.first(where: { $0.knownID == .darkMode })?.customName, "My Dark")
        XCTAssertEqual(config.visibleSwitches.map(\.id), [SwitchID.keepAwake.rawValue])
        XCTAssertEqual(config.migration?.unknownSwitchIDs, ["FutureSwitch"])
        XCTAssertEqual(config.importedPreferences, input)
        XCTAssertEqual(config.migration?.untranslatedPreferenceKeys, ["unknown-key"])
        XCTAssertFalse(config.restoreAutomations)
    }
    func testExpiredAwakeDeadlineDoesNotReactivate() throws {
        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let config = try OneSwitchImporter.translate(
            rows: [],
            preferences: plist([
                "keep-awake-turn-off-date": now.addingTimeInterval(-10).timeIntervalSinceReferenceDate,
                "kEnableKeepAwake": true,
            ]), sourceVersion: "fixture", now: now)
        XCTAssertNil(config.awakeUntil)
        XCTAssertFalse(config.restoreAutomations)
    }
    func testShortcutRecorderModifiersTranslateToCarbonAndUnknownArchiveIsPreserved() throws {
        let blob = try plist(["keyCode": 18, "modifierFlags": (1 << 20) | (1 << 18)])
        let shortcut = try XCTUnwrap(OneSwitchImporter.parseShortcut(blob))
        XCTAssertEqual(shortcut.carbonModifiers, (1 << 8) | (1 << 12))
        let unknown = Data("unknown archive".utf8)
        let config = try OneSwitchImporter.translate(
            rows: [.init(id: SwitchID.keepAwake.rawValue, enabled: true, order: 0, originalShortcut: unknown)],
            preferences: plist([:]), sourceVersion: "fixture")
        XCTAssertEqual(config.migration?.untranslatedShortcutCount, 1)
        XCTAssertEqual(config.switches[0].originalShortcut, unknown)
        XCTAssertNil(OneSwitchImporter.parseShortcut(try plist(["keyCode": 999, "modifierFlags": 0])))
    }
    func testFingerprintIsIndependentOfPlistSerializationFormat() throws {
        let dictionary: [String: Any] = [
            "keep-awake-interval": 3600, "future": ["a": 1, "b": 2], "blob": Data([0, 1]),
        ]
        let binary = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        let xml = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        let one = try OneSwitchImporter.translate(rows: [], preferences: binary, sourceVersion: "fixture")
        let two = try OneSwitchImporter.translate(rows: [], preferences: xml, sourceVersion: "fixture")
        XCTAssertEqual(one.migration?.sourceFingerprint, two.migration?.sourceFingerprint)
    }
    func testReadOnlyDatabaseUsesWALAndDoesNotModifySource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("source.sqlite")
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &pointer), SQLITE_OK)
        defer { sqlite3_close(pointer) }
        let sql =
            "PRAGMA journal_mode=WAL; CREATE TABLE ZSWITCHDESCRIPTOR(Z_PK INTEGER PRIMARY KEY,ZSWITCHIDENTIFIER TEXT,ZENABLED INTEGER,ZSORTWEIGHT INTEGER,ZSWITCHNAME TEXT,ZSHORTCUTDICT BLOB); INSERT INTO ZSWITCHDESCRIPTOR VALUES(1,'KeepAwakeSwitch',1,5,'Custom Awake',NULL);"
        XCTAssertEqual(sqlite3_exec(pointer, sql, nil, nil, nil), SQLITE_OK)
        let originalDB = try Data(contentsOf: database)
        let rows = try OneSwitchImporter.descriptors(database: database)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].customName, "Custom Awake")
        XCTAssertEqual(rows[0].order, 5)
        XCTAssertEqual(try Data(contentsOf: database), originalDB)
    }
    func testImportOnceDoesNotOverwriteSubsequentPersonalEdits() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConfigurationStore(url: folder.appendingPathComponent("settings.json"))
        let config = try OneSwitchImporter.translate(rows: [], preferences: plist([:]), sourceVersion: "fixture")
        XCTAssertTrue(try store.importOnce(config))
        var edited = config
        edited.keepAwakeSeconds = 7200
        try store.save(edited)
        XCTAssertFalse(try store.importOnce(config))
        XCTAssertEqual(try store.load()?.keepAwakeSeconds, 7200)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
    func testInvalidAndDuplicateSourceRowsAreRejected() throws {
        let row = SwitchConfiguration(id: SwitchID.darkMode.rawValue, enabled: true, order: 0)
        XCTAssertThrowsError(
            try OneSwitchImporter.translate(rows: [row, row], preferences: plist([:]), sourceVersion: "fixture"))
        XCTAssertThrowsError(
            try OneSwitchImporter.translate(
                rows: [],
                preferences: PropertyListSerialization.data(fromPropertyList: ["array"], format: .binary, options: 0),
                sourceVersion: "fixture"))
    }
}

final class StoreRecoveryTests: XCTestCase {
    func testMalformedExistingFileIsNotOverwrittenByImport() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("settings.json")
        let broken = Data("incomplete original".utf8)
        try broken.write(to: url)
        let store = ConfigurationStore(url: url)
        XCTAssertThrowsError(try store.importOnce(AppConfiguration()))
        XCTAssertEqual(try Data(contentsOf: url), broken)
    }
    func testFutureSchemaDoesNotLoadAsCurrentDefaults() throws {
        var config = AppConfiguration()
        config.schemaVersion = 99
        XCTAssertThrowsError(try ConfigurationValidation.validate(config))
    }
}

final class SessionImportTests: XCTestCase {
    func testImportRetainsSourceSessionsWithoutActivatingThem() throws {
        let deadline = Date().addingTimeInterval(3600)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["dnd-turn-off-date": deadline.timeIntervalSinceReferenceDate, "kEnableKeepAwake": true],
            format: .binary, options: 0)
        let config = try OneSwitchImporter.translate(rows: [], preferences: data, sourceVersion: "fixture")
        XCTAssertEqual(
            config.importedFocusOffAt?.timeIntervalSinceReferenceDate ?? 0, deadline.timeIntervalSinceReferenceDate,
            accuracy: 0.001)
        XCTAssertEqual(config.importedAwakeActive, true)
        XCTAssertNil(config.focusOffAt)
        XCTAssertFalse(config.restoreAutomations)
    }
}
