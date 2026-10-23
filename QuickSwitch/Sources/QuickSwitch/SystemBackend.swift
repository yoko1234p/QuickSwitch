import AppKit
import CoreAudio
import CoreGraphics
import IOKit.pwr_mgt
import QuickSwitchCore
import QuickSwitchNative

@MainActor
final class SystemBackend {
    private let allowsSystemChanges: Bool
    init(allowsSystemChanges: Bool = true) {
        self.allowsSystemChanges = allowsSystemChanges
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: .QSKeyboardLockDidStop, object: nil, queue: .main
        ) { [weak self] notification in
            let stoppedGeneration = (notification.userInfo?["generation"] as? NSNumber)?.uint64Value
            let reason = notification.userInfo?["reason"] as? String
            Task { @MainActor in
                guard let self else { return }
                if self.cleaningGeneration == stoppedGeneration { self.closeCleaningOverlays() }
                if reason == "permissionLost" || reason == "systemDisabled" {
                    self.onError?(L10n.text("鍵盤鎖定已因權限或系統狀態改變而結束；已解除鎖定。"))
                }
                self.onChange?()
            }
        }
    }
    private let runner = CommandRunner()
    private lazy var music = MusicPlaybackController(transport: AppleScriptMusicTransport(runner: runner))
    private var mediaVisible = false
    private var mediaChoice = MusicPlayerChoice.automatic
    private var awakeAssertion: IOPMAssertionID = 0
    private var systemAssertion: IOPMAssertionID = 0
    private var awakeTiming = KeepAwakeDeadline()
    private var awakeTimer: Timer?
    var awakeIsActive: Bool { awakeAssertion != 0 }
    private lazy var hiddenApplications = HiddenApplicationsSession<NSRunningApplication>(
        applications: {
            NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }
        }, terminated: { $0.isTerminated }, hidden: { $0.isHidden }, hide: { $0.hide() }, unhide: { $0.unhide() },
        sameInstance: { $0.processIdentifier == $1.processIdentifier && !$0.isTerminated && !$1.isTerminated })
    private var cleanWindows: [NSWindow] = []
    private var cleaningGeneration: UInt64?
    private var keyboardObserver: NSObjectProtocol?
    private var focusTimer = FocusDeadlineTracker()
    private var focusLastCommand: FocusCommandObservation?
    let focusController = FocusController()
    private var powerOperationRunning = false
    private var batteryReadings: [String: BluetoothBattery] = [:]
    private var batteryReadAt: Date?
    private var batteryAttemptAt: Date?
    private var batteryReading = false
    private(set) var lidSleepDisabled = false
    private(set) var headphones: [[String: Any]] = []
    var onChange: (() -> Void)?
    var onFocusDeadlineChanged: ((Date?) -> Void)?
    var onFocusCommandChanged: ((FocusCommandObservation) -> Void)?
    func restoreSession(_ configuration: AppConfiguration) {
        guard allowsSystemChanges else { return }
        focusTimer.start(configuration.focusOffAt)
        focusLastCommand = configuration.focusLastCommand
    }
    var onError: ((String) -> Void)?
    var requestResolution: (() -> Void)?
    var requestEnergy: (() -> Void)?
    var needsTimer: Bool { focusTimer.deadline != nil }
    var originalRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: OneSwitchImporter.sourceBundleID).contains {
            !$0.isTerminated
        }
            || NSRunningApplication.runningApplications(withBundleIdentifier: "studio.fireball.OneSwitch").contains {
                !$0.isTerminated
            }
    }

    func readStates(config: AppConfiguration, includeDevices: Bool, mediaPanelVisible: Bool = false) async -> [SwitchID:
        SwitchState]
    {
        let now = Date()
        if let deadline = awakeTiming.deadline, deadline <= now { releaseAwake() }
        var focusSnapshot = await focusController.read()
        if includeDevices { await focusController.refreshInstalled() }
        if allowsSystemChanges, focusTimer.due(at: now, originalRunning: originalRunning) {
            do {
                // A different Focus or an already-ended native lifetime must not be switched off.
                if focusSnapshot.exactDND != false {
                    try await focusController.set(false, config: config, duration: 0, interactive: false)
                    recordFocusCommand(false)
                    focusSnapshot = await focusController.read(force: true)
                }
                focusTimer.complete(succeeded: true, at: now)
                onFocusDeadlineChanged?(nil)
            } catch {
                focusTimer.complete(succeeded: false, at: now)
                onError?(L10n.text("勿擾時限已到，但關閉失敗；已保留時限並稍後重試：%1$@", String(describing: error.localizedDescription)))
            }
        }
        var states: [SwitchID: SwitchState] = [:]
        states[.stageManager] = .toggle(prefBool("GloballyEnabled", domain: "com.apple.WindowManager") ?? false)
        states[.hideWidgets] = .toggle(prefBool("StandardHideWidgets", domain: "com.apple.WindowManager") ?? false)
        states[.hideDesktop] = .toggle(!(prefBool("CreateDesktop", domain: "com.apple.finder") ?? true))
        states[.darkMode] = .toggle(
            (CFPreferencesCopyValue(
                "AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost) as? String) == "Dark")
        states[.hiddenFiles] = .toggle(prefBool("AppleShowAllFiles", domain: "com.apple.finder") ?? false)
        states[.hideDock] = .toggle(prefBool("autohide", domain: "com.apple.dock") ?? false)
        let awakeDetail =
            awakeTiming.deadline.map { L10n.text("直至 ") + $0.formatted(date: .omitted, time: .shortened) }
            ?? (awakeAssertion != 0 ? L10n.text("直至手動關閉") : "")
        states[.keepAwake] = .toggle(awakeAssertion != 0, awakeDetail)
        states[.muteMicrophone] = microphoneState()
        if includeDevices {
            headphones = QSHeadphones() ?? []
            updateBatteryIfNeeded()
            if let device = selectedDevice(config: config) {
                let connected = device["connected"] as? Bool ?? false
                var detail = device["name"] as? String ?? ""
                if connected, let readAt = batteryReadAt, Date().timeIntervalSince(readAt) < 120,
                    let address = device["address"] as? String, let key = BluetoothBatteryParser.addressKey(address),
                    let battery = batteryReadings[key]
                {
                    detail += " · " + battery.summary
                }
                states[.headphones] = .toggle(connected, detail)
            } else {
                states[.headphones] = .unavailable(L10n.text("未選擇已配對耳機；請在設定選擇"))
            }
        } else {
            states[.headphones] = .unknown(L10n.text("開啟面板時讀取已配對耳機"))
        }
        states[.focus] = FocusControlPolicy.state(snapshot: focusSnapshot, lastCommand: focusLastCommand)
        for (id, name) in [(SwitchID.nightShift, "nightShift"), (.trueTone, "trueTone")] {
            let state = QSDisplaySettingState(name)
            states[id] = state >= 0 ? .toggle(state == 1) : .unavailable(L10n.text("此系統／顯示器未提供可用介面"))
        }
        states[.music] =
            mediaPanelVisible && mediaVisible && mediaChoice == (config.musicPlayerChoice ?? .automatic)
                && config.switches.contains(where: { $0.knownID == .music && $0.enabled })
            ? await music.read(config.musicPlayerChoice ?? .automatic)
            : .unknown(L10n.text("開啟面板時讀取播放器"))
        states[.screenSaver] = .action()
        states[.displaySleep] = .action()
        states[.resolution] = .action(L10n.text("按下選擇顯示器及解像度"))
        let keyboardRemaining = Int(ceil(QSKeyboardLockSecondsRemaining()))
        let keyboardDetail =
            QSKeyboardIsLocked()
            ? L10n.text("%1$@ 秒後自動解鎖；連按三次 Esc 可提早結束", String(describing: keyboardRemaining))
            : L10n.text("連按三次 Esc 可解鎖；最長 10 分鐘自動結束")
        states[.screenClean] = .toggle(
            !cleanWindows.isEmpty, !cleanWindows.isEmpty ? keyboardDetail : L10n.text("滑鼠按畫面或連按三次 Esc 退出"))
        states[.lockKeyboard] = .toggle(QSKeyboardIsLocked(), keyboardDetail)
        states[.lockScreen] = .action()
        states[.xcodeClean] = .action(L10n.text("將 DerivedData 移到垃圾桶"))
        states[.emptyTrash] = .action(L10n.text("需要確認"))
        states[.ejectDisks] = .action(L10n.text("保留你設定的排除磁碟"))
        states[.clearClipboard] = .action()
        states[.hideWindows] = hiddenApplications.state
        let power = await runner.run("/usr/bin/pmset", ["-g"], timeout: 4)
        lidSleepDisabled = Self.powerValue("SleepDisabled", output: power.output) == 1
        if power.succeeded, let low = Self.powerValue("lowpowermode", output: power.output) {
            states[.lowPower] = .toggle(low != 0, L10n.text("更改時需要管理員授權"))
        } else {
            states[.lowPower] = .unavailable(L10n.text("此 Mac 未提供低耗電模式"))
        }
        states[.energyMode] =
            Self.powerValue("powermode", output: power.output) != nil
            ? .action(L10n.text("按下選擇；更改需要管理員授權")) : .unavailable(L10n.text("此 Mac 未提供電源模式"))
        return states
    }

    func activate(_ id: SwitchID, desired: Bool?, config: AppConfiguration) async throws {
        try requireSystemChanges()
        switch id {
        case .hideDesktop:
            try setPreference("CreateDesktop", domain: "com.apple.finder", value: !(desired ?? true))
            try await restart("Finder")
        case .hiddenFiles:
            try setPreference("AppleShowAllFiles", domain: "com.apple.finder", value: desired ?? true)
            try await restart("Finder")
        case .darkMode:
            try require(
                await runner.appleScript(
                    "tell application \"System Events\" to tell appearance preferences to set dark mode to \(desired == true ? "true" : "false")"
                ))
        case .hideDock:
            try require(
                await runner.appleScript(
                    "tell application \"System Events\" to tell dock preferences to set autohide to \(desired == true ? "true" : "false")"
                ))
        case .stageManager:
            try setPreference("GloballyEnabled", domain: "com.apple.WindowManager", value: desired ?? true)
        case .hideWidgets:
            try setPreference("StandardHideWidgets", domain: "com.apple.WindowManager", value: desired ?? true)
        case .muteMicrophone: try setMicrophoneMuted(desired ?? true)
        case .keepAwake:
            if desired == false { releaseAwake() } else if awakeAssertion == 0 { try acquireAwake(config: config) }
        case .screenSaver:
            let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        case .headphones:
            guard let device = selectedDevice(config: config), let address = device["address"] as? String else {
                throw ConfigurationError.invalid(L10n.text("請先在設定選擇已配對耳機"))
            }
            let result = await Task.detached { QSSetHeadphoneConnection(address, desired ?? true) }.value
            guard result == 0 else {
                throw ConfigurationError.invalid(
                    L10n.text("耳機操作失敗（%1$@）；請確認 Bluetooth 已開啟及耳機未連到其他裝置", String(describing: result)))
            }
        case .focus:
            let enable: Bool
            if let desired {
                enable = desired
            } else {
                let alert = NSAlert()
                alert.messageText = L10n.text("切換勿擾模式")
                alert.informativeText = L10n.text("目前無法讀取勿擾狀態，請選擇開啟或關閉。")
                alert.addButton(withTitle: L10n.text("開啟"))
                alert.addButton(withTitle: L10n.text("關閉"))
                alert.addButton(withTitle: L10n.text("取消"))
                let response = alert.runModal()
                guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
                enable = response == .alertFirstButtonReturn
            }
            try await focusController.set(enable, config: config)
            recordFocusCommand(enable)
            focusTimer.start(enable && config.focusSeconds > 0 ? Date().addingTimeInterval(config.focusSeconds) : nil)
            onFocusDeadlineChanged?(focusTimer.deadline)
        case .nightShift, .trueTone:
            guard QSSetDisplaySetting(id == .nightShift ? "nightShift" : "trueTone", desired ?? true) else {
                throw ConfigurationError.invalid(L10n.text("此系統未支援該顯示器設定"))
            }
        case .music:
            try await music.set(desired, choice: config.musicPlayerChoice ?? .automatic)
        case .displaySleep: try require(await runner.run("/usr/bin/pmset", ["displaysleepnow"]))
        case .resolution: requestResolution?()
        case .screenClean:
            if desired ?? cleanWindows.isEmpty {
                if cleanWindows.isEmpty { try startCleaning(timeout: config.effectiveKeyboardLockSeconds) }
            } else {
                stopCleaning()
            }
        case .lockKeyboard:
            if desired ?? !QSKeyboardIsLocked() {
                guard QSStartKeyboardLockWithTimeout(config.effectiveKeyboardLockSeconds) else {
                    throw ConfigurationError.invalid(L10n.text("未能鎖定鍵盤；請檢查輔助使用權限"))
                }
            } else {
                closeCleaningOverlays()
                QSStopKeyboardLock()
            }
        case .lockScreen:
            guard QSLockScreen() else { throw ConfigurationError.invalid(L10n.text("系統鎖定介面不可用，請使用 Control–Command–Q")) }
        case .xcodeClean: try await cleanDerivedData()
        case .emptyTrash:
            guard confirm(title: L10n.text("清空垃圾桶？"), detail: L10n.text("垃圾桶內所有檔案會永久刪除。"), button: L10n.text("清空"))
            else { return }
            try require(await runner.appleScript("tell application \"Finder\" to empty trash", timeout: 120))
        case .ejectDisks: try await ejectDisks(config: config)
        case .clearClipboard: NSPasteboard.general.clearContents()
        case .hideWindows:
            try await hiddenApplications.set(desired)
        case .lowPower: try await setPowerMode(low: desired == true ? 1 : 0)
        case .energyMode: requestEnergy?()
        }
        onChange?()
    }
    private func recordFocusCommand(_ enabled: Bool) {
        let value = FocusCommandObservation(requestedEnabled: enabled)
        focusLastCommand = value
        onFocusCommandChanged?(value)
    }
    var installedMusicPlayers: [MusicPlayerChoice] { music.installedPlayers() }
    var observedMusicPlayer: MusicPlayerChoice? { music.observedPlayer }
    func cancelMediaRead() { music.cancelRead() }
    func setMediaContext(visible: Bool, choice: MusicPlayerChoice) {
        if mediaVisible != visible || mediaChoice != choice { music.cancelRead() }
        mediaVisible = visible
        mediaChoice = choice
    }
    func prepareMusicSelection(from old: MusicPlayerChoice, to new: MusicPlayerChoice) async throws {
        try requireSystemChanges()
        try await music.prepareSelection(from: old, to: new)
    }
    func setLidSleepDisabled(_ disabled: Bool) async throws -> Bool {
        try requireSystemChanges()
        guard !powerOperationRunning else { throw ConfigurationError.invalid(L10n.text("另一項電源操作尚未完成")) }
        powerOperationRunning = true
        defer { powerOperationRunning = false }
        if disabled {
            guard
                confirm(
                    title: L10n.text("合蓋時繼續運行？"),
                    detail: L10n.text("這會更改系統的合蓋休眠設定，需要管理員授權。請保持電源接駁；關閉 App 不會自動改回系統設定，可在此關閉。"), button: L10n.text("開啟")
                )
            else { return false }
        }
        try require(
            await runner.appleScript(
                "do shell script \"/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)\" with administrator privileges",
                timeout: 120))
        return true
    }
    func setPowerMode(low: Int) async throws {
        try requireSystemChanges()
        guard !powerOperationRunning else { throw ConfigurationError.invalid(L10n.text("另一項電源操作尚未完成")) }
        powerOperationRunning = true
        defer { powerOperationRunning = false }
        guard (0...1).contains(low) else { throw ConfigurationError.invalid(L10n.text("電源模式無效")) }
        try require(
            await runner.appleScript(
                "do shell script \"/usr/bin/pmset -a lowpowermode \(low)\" with administrator privileges", timeout: 120)
        )
    }
    func setHighPowerMode(_ value: Int) async throws {
        try requireSystemChanges()
        guard !powerOperationRunning else { throw ConfigurationError.invalid(L10n.text("另一項電源操作尚未完成")) }
        powerOperationRunning = true
        defer { powerOperationRunning = false }
        guard (0...2).contains(value) else { throw ConfigurationError.invalid(L10n.text("電源模式無效")) }
        try require(
            await runner.appleScript(
                "do shell script \"/usr/bin/pmset -a powermode \(value)\" with administrator privileges", timeout: 120))
    }
    private func require(_ result: CommandResult) throws {
        guard result.succeeded else {
            throw ConfigurationError.invalid(
                result.output.isEmpty ? L10n.text("系統操作失敗（%1$@）", String(describing: result.status)) : result.output)
        }
    }
    private func requireSystemChanges() throws {
        guard allowsSystemChanges else { throw ConfigurationError.invalid(L10n.text("診斷模式不會更改系統狀態")) }
    }
    private func restart(_ name: String) async throws { try require(await runner.run("/usr/bin/killall", [name])) }
    private func prefBool(_ key: String, domain: String) -> Bool? {
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return
            (CFPreferencesCopyValue(
                key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?
            .boolValue
    }
    private func setPreference(_ key: String, domain: String, value: Bool) throws {
        CFPreferencesSetValue(
            key as CFString, value ? kCFBooleanTrue : kCFBooleanFalse, domain as CFString, kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw ConfigurationError.invalid(L10n.text("系統設定寫入失敗"))
        }
    }
    private func acquireAwake(config: AppConfiguration) throws {
        try KeepAwakeDuration.validate(config.keepAwakeSeconds)
        let now = Date()
        let deadline = try config.awakeDeadline(at: now)
        releaseAwake()
        let reason = "QuickSwitch user request" as CFString
        guard
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason, &awakeAssertion) == kIOReturnSuccess
        else { throw ConfigurationError.invalid(L10n.text("無法阻止顯示器休眠")) }
        if config.preventSystemSleep {
            guard
                IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    reason, &systemAssertion) == kIOReturnSuccess
            else {
                releaseAwake()
                throw ConfigurationError.invalid(L10n.text("無法阻止系統閒置休眠"))
            }
        }
        try awakeTiming.start(until: deadline, now: now)
        scheduleAwakeTimer()
    }
    func rescheduleAwake(seconds: TimeInterval) throws {
        try requireSystemChanges()
        try KeepAwakeDuration.validate(seconds)
        let now = Date()
        if let deadline = awakeTiming.deadline, deadline <= now { releaseAwake() }
        guard awakeIsActive else {
            onChange?()
            throw ConfigurationError.invalid(L10n.text("本次保持清醒已結束；時長已儲存，請重新開啟。"))
        }
        try awakeTiming.start(seconds: seconds, now: now)
        scheduleAwakeTimer()
        onChange?()
    }
    func rescheduleAwake(configuration: AppConfiguration) throws {
        try requireSystemChanges()
        let now = Date()
        let deadline = try configuration.awakeDeadline(at: now)
        if let previous = awakeTiming.deadline, previous <= now { releaseAwake() }
        guard awakeIsActive else { throw ConfigurationError.invalid(L10n.text("本次保持清醒已結束；設定已儲存，請重新開啟。")) }
        try awakeTiming.start(until: deadline, now: now)
        scheduleAwakeTimer()
        onChange?()
    }
    private func scheduleAwakeTimer() {
        awakeTimer?.invalidate()
        awakeTimer = nil
        guard let deadline = awakeTiming.deadline, awakeIsActive else { return }
        let request = awakeTiming.generation
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.awakeTiming.generation == request, self.awakeIsActive else { return }
                if self.awakeTiming.due(generation: request, at: Date()) {
                    self.releaseAwake()
                    self.onChange?()
                } else {
                    self.scheduleAwakeTimer()
                }
            }
        }
        timer.tolerance = 0.05
        awakeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func releaseAwake() {
        awakeTimer?.invalidate()
        awakeTimer = nil
        if awakeAssertion != 0 {
            IOPMAssertionRelease(awakeAssertion)
            awakeAssertion = 0
        }
        if systemAssertion != 0 {
            IOPMAssertionRelease(systemAssertion)
            systemAssertion = 0
        }
        awakeTiming.clear()
    }
    private func updateBatteryIfNeeded() {
        guard !batteryReading, batteryAttemptAt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        batteryReading = true
        batteryAttemptAt = Date()
        Task {
            let snapshot = await runner.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 5)
            if snapshot.succeeded, let parsed = try? BluetoothBatteryParser.parse(Data(snapshot.output.utf8)) {
                batteryReadings = parsed
                batteryReadAt = Date()
            }
            batteryReading = false
            onChange?()
        }
    }
    private func selectedDevice(config: AppConfiguration) -> [String: Any]? {
        if let selected = config.selectedHeadphone {
            return headphones.first { ($0["address"] as? String) == selected || ($0["name"] as? String) == selected }
        }
        let connected = headphones.filter { $0["connected"] as? Bool == true }
        if let airpods = connected.first(where: {
            ($0["name"] as? String ?? "").localizedCaseInsensitiveContains("AirPods")
        }) {
            return airpods
        }
        if connected.count == 1 { return connected.first }
        let apple = headphones.filter { ($0["name"] as? String ?? "").localizedCaseInsensitiveContains("AirPods") }
        if apple.count == 1 { return apple.first }
        return headphones.count == 1 ? headphones.first : nil
    }
    private func inputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
                == noErr, device != 0
        else { return nil }
        return device
    }
    private func microphoneState() -> SwitchState {
        guard let device = inputDevice() else { return .unavailable(L10n.text("未找到輸入裝置")) }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else {
            return .unavailable(L10n.text("此麥克風不提供硬件靜音控制"))
        }
        return .toggle(muted != 0)
    }
    private func setMicrophoneMuted(_ value: Bool) throws {
        guard let device = inputDevice() else { throw ConfigurationError.invalid(L10n.text("未找到輸入裝置")) }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = value ? 1 : 0
        guard AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muted) == noErr
        else { throw ConfigurationError.invalid(L10n.text("無法更改麥克風靜音狀態")) }
    }
    private func startCleaning(timeout: TimeInterval) throws {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw ConfigurationError.invalid(L10n.text("未找到可清潔的螢幕")) }
        guard QSStartKeyboardLockWithTimeout(timeout) else {
            throw ConfigurationError.invalid(L10n.text("請先授予輔助使用權限，才能同時鎖定鍵盤"))
        }
        let generation = QSKeyboardLockGeneration()
        guard generation != 0 else { throw ConfigurationError.invalid(L10n.text("鍵盤鎖定已結束；未開啟清潔畫面")) }
        cleaningGeneration = generation
        for screen in screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            let button = NSButton(
                title: L10n.text("螢幕清潔中 · 按一下退出\n連按三次 Esc 或到達時限會自動退出"), target: self, action: #selector(stopCleaning))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor.black.cgColor
            button.contentTintColor = .white
            window.contentView = button
            window.makeKeyAndOrderFront(nil)
            cleanWindows.append(window)
        }
    }
    @objc func stopCleaning() {
        let ownedGeneration = cleaningGeneration
        closeCleaningOverlays()
        if let ownedGeneration, QSKeyboardLockGeneration() == ownedGeneration { QSStopKeyboardLock() }
        onChange?()
    }
    func endInputSession() {
        stopCleaning()
        QSStopKeyboardLock()
        onChange?()
    }
    private func closeCleaningOverlays() {
        for window in cleanWindows { window.close() }
        cleanWindows = []
        cleaningGeneration = nil
    }
    private func confirm(title: String, detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: L10n.text("取消"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func cleanDerivedData() async throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Developer/Xcode/DerivedData")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigurationError.invalid(L10n.text("未找到 DerivedData"))
        }
        guard
            confirm(
                title: L10n.text("清理 Xcode 快取？"),
                detail: L10n.text("只將 DerivedData 內容移到垃圾桶。下次編譯需重新建立快取；請先停止 Xcode 編譯。"), button: L10n.text("移到垃圾桶"))
        else { return }
        let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle(children) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    private func ejectDisks(config: AppConfiguration) async throws {
        let keys: Set<URLResourceKey> = [.volumeIsEjectableKey, .volumeNameKey, .volumeUUIDStringKey]
        let volumes =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        var errors: [String] = []
        for url in volumes {
            let values = try url.resourceValues(forKeys: keys)
            guard values.volumeIsEjectable == true else { continue }
            guard
                !config.excludedVolumes.contains(where: {
                    $0 == url.path || $0 == values.volumeName || $0 == values.volumeUUIDString
                })
            else { continue }
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) } catch {
                errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if !errors.isEmpty { throw ConfigurationError.invalid(errors.joined(separator: "\n")) }
    }
    static func powerValue(_ name: String, output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, fields[0] == name { return Int(fields[1]) }
        }
        return nil
    }
    func shutdown() {
        music.cancelRead()
        releaseAwake()
        stopCleaning()
        QSStopKeyboardLock()
        if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
        keyboardObserver = nil
    }
}
