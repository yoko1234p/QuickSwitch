import CSQLite
import CryptoKit
import Foundation

public enum OneSwitchImporter {
    public static let sourceBundleID = "studio.fireball.OneSwitch-setapp"
    public static let recognizedPreferenceKeys: Set<String> = [
        "keep-awake-interval", "keep-awake-disable-sleep", "keep-awake-turn-off-date", "kEnableKeepAwake",
        "dark-mode-enable-auto-schedule", "dark-mode-switch-type", "dark-mode-from-date", "dark-mode-to-date",
        "dark-mode-location",
        "air-pods-current-name-address", "eject-disk-exclude-items", "dnd-turn-off-after", "dnd-turn-off-date",
        "screen-resolution-selected-display-index", "screen-resolution-only-hidpi", "menuBarIconName",
        "dnd-shortcut-cached-state", "dnd-shortcuts-installed", "play-music-current-player",
    ]
    public static func sourcePreferenceData() throws -> Data {
        let keys =
            CFPreferencesCopyKeyList(sourceBundleID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [String] ?? []
        let dictionary =
            CFPreferencesCopyMultiple(
                keys as CFArray, sourceBundleID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [String: Any] ?? [:]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }
    public static func load(database: URL, preferences: Data, sourceVersion: String = "1.35.4", now: Date = Date())
        throws -> AppConfiguration
    {
        let rows = try descriptors(database: database)
        return try translate(rows: rows, preferences: preferences, sourceVersion: sourceVersion, now: now)
    }
    public static func translate(
        rows: [SwitchConfiguration], preferences: Data, sourceVersion: String, now: Date = Date()
    ) throws -> AppConfiguration {
        let object = try PropertyListSerialization.propertyList(from: preferences, options: [], format: nil)
        guard let prefs = object as? [String: Any] else {
            throw ConfigurationError.invalid(L10n.text("One Switch 設定不是字典"))
        }
        var result = AppConfiguration()
        let unique = Dictionary(grouping: rows, by: \.id)
        guard unique.values.allSatisfy({ $0.count == 1 }) else {
            throw ConfigurationError.invalid(L10n.text("One Switch 資料有重複識別碼"))
        }
        result.switches = rows.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        // Every known capability remains available in Customize; omitted source rows stay disabled.
        for id in SwitchID.allCases where !result.switches.contains(where: { $0.id == id.rawValue }) {
            result.switches.append(
                SwitchConfiguration(
                    id: id.rawValue, enabled: false, order: (result.switches.map(\.order).max() ?? -1) + 1))
        }
        if let interval = prefs["keep-awake-interval"] as? NSNumber, interval.doubleValue.isFinite,
            (0...604800).contains(interval.doubleValue)
        {
            result.keepAwakeSeconds = interval.doubleValue
        }
        result.importedAwakeActive = prefs["kEnableKeepAwake"] as? Bool
        result.importedFocusCachedState = bool(prefs["dnd-shortcut-cached-state"])
        result.importedFocusShortcutsInstalled = bool(prefs["dnd-shortcuts-installed"])
        result.importedFocusOffAt = date(prefs["dnd-turn-off-date"])
        result.preventLidSleep = (prefs["keep-awake-disable-sleep"] as? Bool) ?? false
        if let cutoff = date(prefs["keep-awake-turn-off-date"]), cutoff > now { result.awakeUntil = cutoff }
        result.darkSchedule.enabled = (prefs["dark-mode-enable-auto-schedule"] as? Bool) ?? false
        let sourceMode = prefs["dark-mode-switch-type"] as? NSNumber
        let sourceModeValid =
            sourceMode.map {
                CFGetTypeID($0) != CFBooleanGetTypeID() && [0.0, 1.0, 2.0].contains($0.doubleValue)
            } ?? (prefs["dark-mode-switch-type"] == nil)
        result.darkScheduleType = sourceModeValid ? sourceMode?.intValue ?? 0 : -1
        result.darkScheduleMode = DarkScheduleMode.sourceValue(result.darkScheduleType) ?? .manual
        result.usesSolarSchedule = result.darkScheduleMode == .sunsetToSunrise
        result.solarLocation = solarLocation(prefs["dark-mode-location"])
        let calendar = Calendar.current
        if let from = date(prefs["dark-mode-from-date"]) {
            result.darkSchedule.onMinute =
                calendar.component(.hour, from: from) * 60 + calendar.component(.minute, from: from)
        }
        if let to = date(prefs["dark-mode-to-date"]) {
            result.darkSchedule.offMinute =
                calendar.component(.hour, from: to) * 60 + calendar.component(.minute, from: to)
        }
        if let selected = prefs["air-pods-current-name-address"] as? String { result.selectedHeadphone = selected }
        if let selected = prefs["air-pods-current-name-address"] as? [String: String] {
            result.selectedHeadphone = selected["address"] ?? selected["deviceAddress"]
        }
        result.musicPlayerChoice = MusicPlayerChoice.sourceValue(prefs["play-music-current-player"])
        if let excludes = prefs["eject-disk-exclude-items"] as? [String] { result.excludedVolumes = excludes }
        if let seconds = prefs["dnd-turn-off-after"] as? Double, seconds.isFinite, (0...604800).contains(seconds) {
            result.focusSeconds = seconds
        }
        let displayIndex = nonnegativeIndex(prefs["screen-resolution-selected-display-index"])
        result.selectedDisplayIndex =
            displayIndex ?? (prefs["screen-resolution-selected-display-index"] == nil ? 0 : -1)
        result.onlyHiDPI = bool(prefs["screen-resolution-only-hidpi"]) ?? false
        // Store original icon choice as data; only our own SF Symbols are rendered.
        result.importedPreferences = preferences
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys]
        let canonicalRows = try canonicalEncoder.encode(rows)
        let canonicalPreferences = Data(canonical(prefs).utf8)
        let digest = SHA256.hash(data: canonicalRows + canonicalPreferences).map { String(format: "%02x", $0) }.joined()
        var unknown = prefs.keys.filter { !recognizedPreferenceKeys.contains($0) }
        if prefs["dark-mode-location"] != nil, result.solarLocation == nil { unknown.append("dark-mode-location") }
        if !sourceModeValid {
            unknown.append("dark-mode-switch-type")
        }
        if prefs["play-music-current-player"] != nil, result.musicPlayerChoice == nil {
            unknown.append("play-music-current-player")
        }
        if prefs["screen-resolution-selected-display-index"] != nil, displayIndex == nil {
            unknown.append("screen-resolution-selected-display-index")
        }
        if prefs["screen-resolution-only-hidpi"] != nil, bool(prefs["screen-resolution-only-hidpi"]) == nil {
            unknown.append("screen-resolution-only-hidpi")
        }
        for key in ["dnd-shortcut-cached-state", "dnd-shortcuts-installed"]
        where prefs[key] != nil && bool(prefs[key]) == nil {
            unknown.append(key)
        }
        unknown.sort()
        let invalidShortcuts = rows.filter { $0.originalShortcut != nil && $0.shortcut == nil }.count
        var notes = [
            L10n.text("保留原有排序、顯示／隱藏及自訂名稱；匯入不會啟動任何開關。"), L10n.text("未知設定以原始 plist 保留，不執行。"),
            L10n.text("原版運行時，自動排程及全域快捷鍵暫停。"),
        ]
        if result.darkScheduleMode == .sunsetToSunrise, result.solarLocation == nil {
            notes.append(L10n.text("已沿用日落至日出模式；原版未有可用位置，需設定位置才可計算。"))
        }
        if result.darkScheduleMode == .manual { notes.append(L10n.text("原版深色模式為手動，匯入後不會當作固定時段排程。")) }
        if result.importedFocusCachedState != nil { notes.append(L10n.text("原版勿擾值是捷徑快取，已保留但不當作系統實際狀態。")) }
        if result.awakeUntil == nil, prefs["keep-awake-turn-off-date"] != nil {
            notes.append(L10n.text("已過期的保持清醒時限不會重新啟動。"))
        }
        if prefs["menuBarIconName"] != nil { notes.append(L10n.text("原選單列圖案已保留於匯入資料；新版使用自製圖示。")) }
        result.migration = MigrationReport(
            sourceVersion: sourceVersion, importedAt: now, sourceFingerprint: digest, descriptorCount: rows.count,
            translatedPreferenceCount: prefs.keys.filter {
                recognizedPreferenceKeys.contains($0) && !unknown.contains($0)
            }.count,
            untranslatedPreferenceKeys: unknown, unknownSwitchIDs: rows.filter { $0.knownID == nil }.map(\.id),
            untranslatedShortcutCount: invalidShortcuts, notes: notes)
        try ConfigurationValidation.validate(result)
        return result
    }
    private static func canonical(_ value: Any) -> String {
        if let dictionary = value as? [String: Any] {
            return "{"
                + dictionary.keys.sorted().map { String(reflecting: $0) + ":" + canonical(dictionary[$0]!) }.joined(
                    separator: ",") + "}"
        }
        if let array = value as? [Any] { return "[" + array.map(canonical).joined(separator: ",") + "]" }
        if let data = value as? Data { return "data:" + data.base64EncodedString() }
        if let date = value as? Date { return "date:" + String(date.timeIntervalSinceReferenceDate) }
        if let number = value as? NSNumber {
            return (CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool:" : "number:") + number.stringValue
        }
        if let string = value as? String { return "string:" + String(reflecting: string) }
        return "unsupported"
    }
    private static func date(_ value: Any?) -> Date? {
        if let value = value as? Date { return value }
        if let value = value as? NSNumber, value.doubleValue.isFinite {
            return Date(timeIntervalSinceReferenceDate: value.doubleValue)
        }
        return nil
    }
    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func nonnegativeIndex(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let index = Int(exactly: number.doubleValue), index >= 0
        else { return nil }
        return index
    }
    /// The shipped source stores a plain latitude/longitude dictionary, not an object archive.
    /// Parse only that proven shape; never instantiate arbitrary archived source classes.
    public static func solarLocation(_ value: Any?) -> SolarLocation? {
        guard let values = value as? [String: Any],
            let latitude = values["latitude"] as? NSNumber, let longitude = values["longitude"] as? NSNumber,
            CFGetTypeID(latitude) != CFBooleanGetTypeID(), CFGetTypeID(longitude) != CFBooleanGetTypeID()
        else { return nil }
        let location = SolarLocation(latitude: latitude.doubleValue, longitude: longitude.doubleValue)
        return location.valid ? location : nil
    }
    /// Fill newly understood source fields only when the previous importer left them untouched.
    /// A saved mode choice, coordinate, time edit, or automation opt-in belongs to the user.
    public static func upgradingPreservedImport(_ configuration: AppConfiguration) -> AppConfiguration {
        guard configuration.migration != nil, let archive = configuration.importedPreferences,
            let source = try? translate(rows: [], preferences: archive, sourceVersion: "upgrade")
        else { return configuration }
        var result = configuration
        if let music = source.musicPlayerChoice {
            if result.musicPlayerChoice == nil { result.musicPlayerChoice = music }
            if var report = result.migration,
                let index = report.untranslatedPreferenceKeys.firstIndex(of: "play-music-current-player")
            {
                report.untranslatedPreferenceKeys.remove(at: index)
                report.translatedPreferenceCount += 1
                result.migration = report
            }
        }
        if result.darkScheduleMode == nil, result.usesSolarSchedule == nil, !result.restoreAutomations,
            result.darkScheduleType == source.darkScheduleType,
            result.darkSchedule.onMinute == source.darkSchedule.onMinute,
            result.darkSchedule.offMinute == source.darkSchedule.offMinute,
            result.darkSchedule.enabled == source.darkSchedule.enabled
        {
            result.darkScheduleMode = source.darkScheduleMode
            result.usesSolarSchedule = source.usesSolarSchedule
            if result.solarLocation == nil { result.solarLocation = source.solarLocation }
        }
        if result.importedFocusCachedState == nil { result.importedFocusCachedState = source.importedFocusCachedState }
        if result.importedFocusShortcutsInstalled == nil {
            result.importedFocusShortcutsInstalled = source.importedFocusShortcutsInstalled
        }
        return result
    }
    public static func descriptors(database: URL) throws -> [SwitchConfiguration] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
            let db
        else {
            if db != nil { sqlite3_close(db) }
            throw ConfigurationError.invalid(L10n.text("無法唯讀開啟 One Switch 設定資料庫"))
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        var statement: OpaquePointer?
        let query =
            "SELECT ZSWITCHIDENTIFIER,ZENABLED,ZSORTWEIGHT,ZSWITCHNAME,ZSHORTCUTDICT FROM ZSWITCHDESCRIPTOR ORDER BY ZSORTWEIGHT,Z_PK"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ConfigurationError.invalid(L10n.text("One Switch 資料庫結構未支援"))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [SwitchConfiguration] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let identifier = sqlite3_column_text(statement, 0) else {
                throw ConfigurationError.invalid(L10n.text("開關識別碼遺失"))
            }
            let name = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let count = sqlite3_column_bytes(statement, 4)
            let blob =
                (count > 0 && sqlite3_column_blob(statement, 4) != nil)
                ? Data(bytes: sqlite3_column_blob(statement, 4)!, count: Int(count)) : nil
            rows.append(
                SwitchConfiguration(
                    id: String(cString: identifier), enabled: sqlite3_column_int(statement, 1) != 0,
                    order: Int(sqlite3_column_int64(statement, 2)), customName: name,
                    shortcut: blob.flatMap(parseShortcut), originalShortcut: blob))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw ConfigurationError.invalid(L10n.text("One Switch 資料庫讀取未完成")) }
        return rows
    }
    public static func parseShortcut(_ data: Data) -> KeyboardShortcut? {
        // Do not instantiate archived source classes. Unsupported archives are retained unchanged.
        guard
            let dictionary = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
                as? [String: Any],
            let key = dictionary["keyCode"] as? NSNumber, let flags = dictionary["modifierFlags"] as? NSNumber,
            key.int64Value >= 0, key.uint64Value <= 127, flags.uint64Value <= UInt32.max
        else { return nil }
        let shortcut = KeyboardShortcut(keyCode: key.uint32Value, modifiers: flags.uint32Value)
        return shortcut.valid ? shortcut : nil
    }
}

public struct ConfigurationStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> AppConfiguration? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url))
        try ConfigurationValidation.validate(value)
        return OneSwitchImporter.upgradingPreservedImport(value)
    }
    public func save(_ config: AppConfiguration) throws {
        try ConfigurationValidation.validate(config)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(config).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    @discardableResult public func importOnce(_ imported: AppConfiguration) throws -> Bool {
        if let current = try load(), current.migration?.sourceFingerprint == imported.migration?.sourceFingerprint {
            return false
        }
        if try load() != nil { return false }  // Re-import requires an explicit UI action and backup.
        try save(imported)
        return true
    }
}
