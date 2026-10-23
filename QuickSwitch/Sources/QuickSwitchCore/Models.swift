import Foundation

public enum SwitchID: String, Codable, CaseIterable, Identifiable, Sendable {
    case stageManager = "StageManagerSwitch"
    case hideWidgets = "HideWidgetsSwitch"
    case muteMicrophone = "MuteMicrophoneSwitch"
    case hideDesktop = "HideDesktopIconSwitch"
    case darkMode = "EnableDarkModeSwitch"
    case keepAwake = "KeepAwakeSwitch"
    case screenSaver = "EnableScreensaveSwitch"
    case headphones = "AirPodsSwitch"
    case focus = "DoNotDisturbSwitch"
    case nightShift = "NightShiftSwitchItem"
    case trueTone = "TrueToneSwitch"
    case music = "PlayMusicSwitch"
    case hiddenFiles = "ShowHiddenFilesSwitch"
    case displaySleep = "DisplaySleepSwitch"
    case resolution = "ScreenResolutionSwitch"
    case screenClean = "ScreenCleanSwitch"
    case lockKeyboard = "LockKeyboardSwitch"
    case lockScreen = "LockScreenSwitch"
    case xcodeClean = "XcodeCleanSwitch"
    case emptyTrash = "EmptyTrashSwitch"
    case ejectDisks = "EjectDiskSwitch"
    case clearClipboard = "EmptyPasteboardSwitch"
    case hideWindows = "HideWindowsSwitch"
    case hideDock = "HideDockSwitch"
    case lowPower = "LowPowerModeSwitch"
    case energyMode = "EnergyModeSwitch"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .stageManager: return L10n.text("幕前調度")
        case .hideWidgets: return L10n.text("隱藏小工具")
        case .muteMicrophone: return L10n.text("麥克風靜音")
        case .hideDesktop: return L10n.text("隱藏桌面圖示")
        case .darkMode: return L10n.text("深色模式")
        case .keepAwake: return L10n.text("保持清醒")
        case .screenSaver: return L10n.text("螢幕保護程式")
        case .headphones: return L10n.text("耳機連線")
        case .focus: return L10n.text("勿擾模式")
        case .nightShift: return L10n.text("夜覽")
        case .trueTone: return L10n.text("原彩顯示")
        case .music: return L10n.text("播放音樂")
        case .hiddenFiles: return L10n.text("顯示隱藏檔案")
        case .displaySleep: return L10n.text("顯示器休眠")
        case .resolution: return L10n.text("螢幕解像度")
        case .screenClean: return L10n.text("清潔螢幕")
        case .lockKeyboard: return L10n.text("鎖定鍵盤")
        case .lockScreen: return L10n.text("鎖定螢幕")
        case .xcodeClean: return L10n.text("清理 Xcode 快取")
        case .emptyTrash: return L10n.text("清空垃圾桶")
        case .ejectDisks: return L10n.text("推出磁碟")
        case .clearClipboard: return L10n.text("清空剪貼簿")
        case .hideWindows: return L10n.text("隱藏所有視窗")
        case .hideDock: return L10n.text("自動隱藏 Dock")
        case .lowPower: return L10n.text("低耗電模式")
        case .energyMode: return L10n.text("電源模式")
        }
    }
    public var symbol: String {
        switch self {
        case .stageManager: return "rectangle.3.group"
        case .hideWidgets: return "square.grid.2x2"
        case .muteMicrophone: return "mic.slash"
        case .hideDesktop: return "desktopcomputer"
        case .darkMode: return "moon"
        case .keepAwake: return "cup.and.saucer"
        case .screenSaver: return "sparkles.tv"
        case .headphones: return "headphones"
        case .focus: return "moon.zzz"
        case .nightShift: return "sun.horizon"
        case .trueTone: return "sun.max"
        case .music: return "music.note"
        case .hiddenFiles: return "eye"
        case .displaySleep: return "display"
        case .resolution: return "arrow.up.left.and.arrow.down.right"
        case .screenClean: return "sparkles"
        case .lockKeyboard: return "keyboard"
        case .lockScreen: return "lock"
        case .xcodeClean: return "hammer"
        case .emptyTrash: return "trash"
        case .ejectDisks: return "eject"
        case .clearClipboard: return "clipboard"
        case .hideWindows: return "rectangle.on.rectangle.slash"
        case .hideDock: return "dock.rectangle"
        case .lowPower: return "battery.50percent"
        case .energyMode: return "bolt"
        }
    }
    public var isAction: Bool {
        [
            .screenSaver, .displaySleep, .resolution, .lockScreen, .xcodeClean, .emptyTrash, .ejectDisks,
            .clearClipboard, .energyMode,
        ].contains(self)
    }
    public var defaultsEnabled: Bool {
        [.hideDesktop, .darkMode, .keepAwake, .screenSaver, .headphones, .focus, .nightShift, .trueTone, .screenClean]
            .contains(self)
    }
}

public struct KeyboardShortcut: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
    /// ShortcutRecorder stores AppKit modifier flags; Carbon registration uses another bit layout.
    public var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers & (1 << 20) != 0 { flags |= 1 << 8 }
        if modifiers & (1 << 17) != 0 { flags |= 1 << 9 }
        if modifiers & (1 << 19) != 0 { flags |= 1 << 11 }
        if modifiers & (1 << 18) != 0 { flags |= 1 << 12 }
        return flags
    }
    public var display: String {
        var text = ""
        if modifiers & (1 << 18) != 0 { text += "⌃" }
        if modifiers & (1 << 19) != 0 { text += "⌥" }
        if modifiers & (1 << 17) != 0 { text += "⇧" }
        if modifiers & (1 << 20) != 0 { text += "⌘" }
        return text + "[\(keyCode)]"
    }
    public var valid: Bool { keyCode <= 127 && carbonModifiers != 0 }
}

public struct SwitchConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var enabled: Bool
    public var order: Int
    public var customName: String?
    public var shortcut: KeyboardShortcut?
    public var originalShortcut: Data?
    public var knownID: SwitchID? { SwitchID(rawValue: id) }
    public var title: String { customName?.isEmpty == false ? customName! : knownID?.title ?? id }
    public init(
        id: String, enabled: Bool, order: Int, customName: String? = nil, shortcut: KeyboardShortcut? = nil,
        originalShortcut: Data? = nil
    ) {
        self.id = id
        self.enabled = enabled
        self.order = order
        self.customName = customName
        self.shortcut = shortcut
        self.originalShortcut = originalShortcut
    }
}

public struct DailySchedule: Codable, Equatable, Sendable {
    public var enabled = false
    public var onMinute = 19 * 60
    public var offMinute = 7 * 60
    public init(enabled: Bool = false, onMinute: Int = 1140, offMinute: Int = 420) {
        self.enabled = enabled
        self.onMinute = onMinute
        self.offMinute = offMinute
    }
    public func desiredState(at date: Date, calendar: Calendar = .current) -> Bool? {
        guard enabled, (0..<1440).contains(onMinute), (0..<1440).contains(offMinute), onMinute != offMinute else {
            return nil
        }
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return onMinute < offMinute
            ? (minute >= onMinute && minute < offMinute) : (minute >= onMinute || minute < offMinute)
    }
}

/// One Switch 1.35.4 stores 0=manual, 1=sunset/sunrise, 2=fixed times.
/// Proven by REA 0x1000502c0; keep the raw source value separate from our policy.
public enum DarkScheduleMode: String, Codable, CaseIterable, Sendable {
    case manual, sunsetToSunrise, fixedTimes
    public static func sourceValue(_ value: Int) -> Self? {
        switch value {
        case 0: return .manual
        case 1: return .sunsetToSunrise
        case 2: return .fixedTimes
        default: return nil
        }
    }
}

public struct MigrationReport: Codable, Equatable, Sendable {
    public var sourceVersion: String
    public var importedAt: Date
    public var sourceFingerprint: String
    public var descriptorCount: Int
    public var translatedPreferenceCount: Int
    public var untranslatedPreferenceKeys: [String]
    public var unknownSwitchIDs: [String]
    public var untranslatedShortcutCount: Int
    public var notes: [String]
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var switches: [SwitchConfiguration] = SwitchID.allCases.enumerated().map {
        SwitchConfiguration(id: $1.rawValue, enabled: $1.defaultsEnabled, order: $0)
    }
    public var keepAwakeSeconds: TimeInterval = 28800
    public var awakeClockMinute: Int?
    public var profiles: [SwitchProfile]?
    public var preventSystemSleep = false
    public var keyboardLockSeconds: TimeInterval?
    public var awakeUntil: Date?
    public var darkSchedule = DailySchedule()
    public var darkScheduleType = 0
    public var darkScheduleMode: DarkScheduleMode?
    public var solarLocation: SolarLocation?
    public var usesSolarSchedule: Bool?
    public var preventLidSleep: Bool?
    public var selectedHeadphone: String?
    public var musicPlayerChoice: MusicPlayerChoice?
    public var excludedVolumes: [String] = []
    public var focusOnShortcut = "One Switch DND On"
    public var focusOffShortcut = "One Switch DND Off"
    public var focusSeconds: TimeInterval = 0
    public var focusOffAt: Date?
    public var focusLastCommand: FocusCommandObservation?
    public var importedFocusOffAt: Date?
    public var importedAwakeActive: Bool?
    public var importedFocusCachedState: Bool?
    public var importedFocusShortcutsInstalled: Bool?
    public var selectedDisplayIndex = 0
    public var selectedDisplayUUID: String?
    public var onlyHiDPI = false
    public var restoreAutomations = false
    public var hotkeysEnabled = true
    public var iconStyle = "switch.2"
    public var importedPreferences: Data?
    public var sourceSystemObservation: SourceSystemObservation?
    public var migration: MigrationReport?
    public init() {}
    public var orderedSwitches: [SwitchConfiguration] {
        switches.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
    }
    public var visibleSwitches: [SwitchConfiguration] { orderedSwitches.filter { $0.enabled && $0.knownID != nil } }
    public var effectiveKeyboardLockSeconds: TimeInterval { keyboardLockSeconds ?? 120 }
    /// Existing QuickSwitch fixed-time/solar choices retain their behavior when upgrading.
    public var effectiveDarkScheduleMode: DarkScheduleMode {
        darkScheduleMode ?? (usesSolarSchedule == true ? .sunsetToSunrise : .fixedTimes)
    }
}

public enum SwitchState: Equatable, Sendable {
    case toggle(Bool, String = "")
    case action(String = "")
    case unavailable(String)
    case unknown(String)
    public var isOn: Bool? {
        if case .toggle(let value, _) = self { return value }
        return nil
    }
    public var detail: String {
        switch self {
        case .toggle(_, let text), .action(let text), .unavailable(let text), .unknown(let text): return text
        }
    }
    public var canActivate: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

public enum ConfigurationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

public enum ConfigurationValidation {
    public static func validate(_ config: AppConfiguration) throws {
        guard config.schemaVersion == 1 else { throw ConfigurationError.invalid(L10n.text("設定格式版本未支援")) }
        if let location = config.solarLocation, !location.valid { throw ConfigurationError.invalid(L10n.text("經緯度無效")) }
        guard Set(config.switches.map(\.id)).count == config.switches.count else {
            throw ConfigurationError.invalid(L10n.text("重複開關識別碼"))
        }
        try KeepAwakeDuration.validate(config.keepAwakeSeconds)
        guard config.awakeClockMinute == nil || (0..<1440).contains(config.awakeClockMinute!),
            config.effectiveProfiles.count <= 30,
            Set(config.effectiveProfiles.map(\.id)).count == config.effectiveProfiles.count
        else { throw ConfigurationError.invalid(L10n.text("結束時間或配方清單不正確。")) }
        for profile in config.effectiveProfiles { try profile.validate() }
        guard config.focusSeconds.isFinite, (0...604800).contains(config.focusSeconds) else {
            throw ConfigurationError.invalid(L10n.text("勿擾時限必須介乎 0 至 7 日"))
        }
        guard config.effectiveKeyboardLockSeconds.isFinite, (5...600).contains(config.effectiveKeyboardLockSeconds)
        else { throw ConfigurationError.invalid(L10n.text("鍵盤鎖定時限必須介乎 5 秒至 10 分鐘")) }
        guard (0..<1440).contains(config.darkSchedule.onMinute), (0..<1440).contains(config.darkSchedule.offMinute)
        else { throw ConfigurationError.invalid(L10n.text("時間設定無效")) }
        let shortcuts = config.switches.compactMap(\.shortcut)
        guard shortcuts.allSatisfy(\.valid), Set(shortcuts).count == shortcuts.count else {
            throw ConfigurationError.invalid(L10n.text("快捷鍵無效或重複"))
        }
    }
}
