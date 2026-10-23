import AppKit
import Combine
import QuickSwitchCore
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published var configuration: AppConfiguration
    @Published var states: [SwitchID: SwitchState] = [:]
    @Published var busy: Set<SwitchID> = []
    @Published var error: String?
    @Published var originalRunning = false
    @Published var hotkeyErrors: [String] = []
    @Published var showingSettings = false
    @Published var loginEnabled = false
    @Published var importSummary = ""
    @Published var devices: [[String: Any]] = []
    @Published var query = ""
    @Published var settingsSection = "switches"
    @Published var dashboardMaximumHeight: CGFloat = 980
    @Published var resolutionChoices: [DisplayModeDescriptor] = []
    @Published var resolutionDisplays: [DisplayDescriptor] = []
    @Published var selectedResolutionDisplay: UInt32?
    @Published var savedResolutionDisplayMissing = false
    @Published var currentResolutionMode: DisplayModeDescriptor?
    @Published var showingResolution = false
    @Published var resolutionConfirmationDeadline: Date?
    @Published var currentPowerMode = 0
    @Published var lidSleepDisabled = false
    @Published var focusNativeAvailable = false
    @Published var focusOnInstalled = false
    @Published var focusOffInstalled = false
    @Published var focusInstallationBusy = false
    @Published var focusSetupSummary = L10n.text("讀取中")
    @Published var installedMusicPlayers: [MusicPlayerChoice] = []
    @Published var observedMusicPlayer: MusicPlayerChoice?
    @Published var applyingProfile: UUID?
    @Published var profileStatus = ""
    private var profileTask: Task<Void, Never>?
    let backend: SystemBackend
    let diagnosticMode: Bool
    private let hotkeys = HotkeyManager()
    private let store: ConfigurationStore
    private var timer: Timer?
    private var refreshing = false
    private var refreshAgain = false
    private var configurationWritable = true
    private var panelOpen = false
    private var mediaVisibilityGeneration: UInt64 = 0
    private var workspaceObservers: [NSObjectProtocol] = []
    private var rollbackMode: (display: CGDirectDisplayID, stableID: String, previous: CGDisplayMode, applied: Int32)?
    private var rollbackTimer: Timer?
    private var displayInventory = DisplayInventory()
    private var legacyResolutionDisplayUUID: String?
    private var screenObserver: NSObjectProtocol?
    var openSettings: (() -> Void)?
    var openResolution: (() -> Void)?
    var openEnergy: (() -> Void)?
    var dataDirectory: URL { store.url.deletingLastPathComponent() }
    init(store: ConfigurationStore, options: GUIStartupOptions) {
        self.store = store
        diagnosticMode = options.diagnosticMode
        backend = SystemBackend(allowsSystemChanges: !options.diagnosticMode)
        do {
            if let loaded = try store.load() {
                configuration = loaded
            } else {
                let source = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                    "Library/Application Support/One Switch/OneSwitch.sqlite")
                if options.importOriginalOnFirstLaunch, FileManager.default.fileExists(atPath: source.path) {
                    let imported = try OneSwitchImporter.load(
                        database: source, preferences: OneSwitchImporter.sourcePreferenceData())
                    try store.importOnce(imported)
                    configuration = imported
                } else {
                    configuration = AppConfiguration()
                    try store.save(configuration)
                }
            }
        } catch {
            configuration = AppConfiguration()
            configurationWritable = false
            self.error = L10n.text("設定載入失敗：%1$@；未覆蓋原有資料", String(describing: error.localizedDescription))
        }
        if !diagnosticMode { backend.restoreSession(configuration) }
        backend.onFocusDeadlineChanged = { [weak self] date in
            self?.configuration.focusOffAt = date
            self?.save()
        }
        backend.onFocusCommandChanged = { [weak self] value in
            self?.configuration.focusLastCommand = value
            self?.save()
        }
        backend.focusController.onSetupNeeded = { [weak self] in
            self?.settingsSection = "focus"
            self?.openSettings?()
        }
        originalRunning = backend.originalRunning
        hotkeys.activate = { [weak self] id in self?.activate(id) }
        backend.onChange = { [weak self] in self?.requestRefresh() }
        backend.onError = { [weak self] error in self?.error = error }
        backend.requestResolution = { [weak self] in self?.presentResolution() }
        backend.requestEnergy = { [weak self] in self?.openEnergy?() }
        for name in [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didWakeNotification, NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            workspaceObservers.append(
                NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        if name == NSWorkspace.willSleepNotification
                            || name == NSWorkspace.sessionDidResignActiveNotification
                        {
                            self.backend.endInputSession()
                        }
                        self.originalRunning = self.backend.originalRunning
                        self.updateHotkeys()
                        self.updateTimer()
                        self.requestRefresh()
                    }
                })
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.showingResolution else { return }
                self.loadResolutions()
            }
        }
        updateHotkeys()
        updateTimer()
    }
    var visibleItems: [SwitchConfiguration] {
        configuration.visibleSwitches.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                || ($0.knownID?.title.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
    func panelVisibility(_ visible: Bool) {
        if panelOpen != visible { mediaVisibilityGeneration &+= 1 }
        panelOpen = visible
        updateMediaContext()
        if !visible {
            backend.cancelMediaRead()
            states[.music] = .unknown(L10n.text("開啟面板時讀取播放器"))
            observedMusicPlayer = nil
        }
        updateTimer()
        if visible { requestRefresh() }
    }
    func requestRefresh() {
        if refreshing {
            refreshAgain = true
            return
        }
        Task { await refresh() }
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer {
            refreshing = false
            if refreshAgain {
                refreshAgain = false
                requestRefresh()
            }
        }
        originalRunning = backend.originalRunning
        updateMediaContext()
        let queriedPlayer = configuration.musicPlayerChoice
        let mediaGeneration = mediaVisibilityGeneration
        var fresh = await backend.readStates(
            config: configuration, includeDevices: !diagnosticMode && (panelOpen || showingSettings),
            mediaPanelVisible: panelOpen)
        if !panelOpen || busy.contains(.music) || mediaGeneration != mediaVisibilityGeneration
            || configuration.musicPlayerChoice != queriedPlayer
        {
            fresh[.music] = .unknown(panelOpen ? L10n.text("正在讀取選定播放器") : L10n.text("開啟面板時讀取播放器"))
            if panelOpen && !busy.contains(.music) { refreshAgain = true }
        }
        states = fresh
        installedMusicPlayers = backend.installedMusicPlayers
        observedMusicPlayer = panelOpen ? backend.observedMusicPlayer : nil
        devices = backend.headphones
        lidSleepDisabled = backend.lidSleepDisabled
        updateFocusSetup()
        updateHotkeys()
        if !diagnosticMode, applyingProfile == nil,
            let desired = AutomationPolicy.desiredDarkMode(
                configuration: configuration, originalRunning: originalRunning, now: Date(), current: states[.darkMode]),
            !busy.contains(.darkMode)
        {
            await execute(.darkMode, desired: desired)
        }
    }
    private func updateFocusSetup() {
        focusNativeAvailable = backend.focusController.nativeAvailable
        focusOnInstalled = backend.focusController.available(true, config: configuration)
        focusOffInstalled = backend.focusController.available(false, config: configuration)
        focusSetupSummary = backend.focusController.summary
    }
    func refreshFocusSetup() {
        Task {
            await backend.focusController.refreshInstalled(force: true)
            _ = await backend.focusController.read(force: true)
            updateFocusSetup()
        }
    }
    func installFocusShortcut(enabled: Bool) {
        guard allowSystemAction() else { return }
        guard !focusInstallationBusy else { return }
        focusInstallationBusy = true
        Task {
            defer { focusInstallationBusy = false }
            do {
                try await backend.focusController.prepareInstallation(
                    enabled: enabled,
                    directory: store.url.deletingLastPathComponent().appendingPathComponent(
                        "FocusShortcuts", isDirectory: true))
            } catch { self.error = error.localizedDescription }
            await backend.focusController.refreshInstalled(force: true)
            updateFocusSetup()
        }
    }
    func activate(_ id: SwitchID, desired: Bool? = nil) {
        guard applyingProfile == nil else { return }
        guard !busy.contains(id), states[id]?.canActivate != false else { return }
        let requested = desired ?? states[id]?.isOn.map { !$0 }
        Task { await execute(id, desired: requested) }
    }
    private func execute(_ id: SwitchID, desired: Bool?) async {
        guard allowSystemAction() else { return }
        guard !busy.contains(id) else { return }
        busy.insert(id)
        if id == .music { updateMediaContext() }
        defer {
            busy.remove(id)
            updateTimer()
            if id == .music {
                updateMediaContext()
                requestRefresh()
            }
        }
        do { try await backend.activate(id, desired: desired, config: configuration) } catch {
            self.error = "\(id.title)：\(error.localizedDescription)"
        }
        if !refreshing { await refresh() }
    }
    func save() {
        guard configurationWritable else {
            error = L10n.text("現有新版設定無法讀取；請先在「匯入及資料」備份並重新匯入。原有檔案未被覆蓋。")
            return
        }
        do {
            try store.save(configuration)
            updateHotkeys()
            updateTimer()
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func setKeepAwakeDuration(_ seconds: TimeInterval, restartCurrent: Bool = false) -> Bool {
        guard configurationWritable else {
            error = L10n.text("現有設定無法讀取，未覆蓋原有資料。")
            return false
        }
        guard !busy.contains(.keepAwake) else { return false }
        if restartCurrent, !allowSystemAction() { return false }
        do {
            var proposed = configuration
            proposed.keepAwakeSeconds = seconds
            proposed.awakeClockMinute = nil
            try store.save(proposed)
            configuration = proposed
            if restartCurrent { try backend.rescheduleAwake(seconds: seconds) }
            updateTimer()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    var awakePlanTitle: String {
        configuration.awakeClockMinute.map(AwakeClock.title) ?? KeepAwakeDuration.title(configuration.keepAwakeSeconds)
    }
    @discardableResult func setKeepAwakeClock(_ minute: Int, restartCurrent: Bool = false) -> Bool {
        guard configurationWritable, !busy.contains(.keepAwake) else { return false }
        if restartCurrent, !allowSystemAction() { return false }
        do {
            var proposed = configuration
            proposed.awakeClockMinute = minute
            _ = try proposed.awakeDeadline()
            try store.save(proposed)
            configuration = proposed
            if restartCurrent { try backend.rescheduleAwake(configuration: proposed) }
            updateTimer()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    func saveProfile(_ profile: SwitchProfile) {
        guard configurationWritable else { return }
        do {
            try profile.validate()
            var proposed = configuration
            var profiles = proposed.effectiveProfiles
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index] = profile
            } else {
                profiles.append(profile)
            }
            proposed.profiles = profiles
            try store.save(proposed)
            configuration = proposed
        } catch { self.error = error.localizedDescription }
    }
    func deleteProfile(_ id: UUID) {
        guard configurationWritable else { return }
        do {
            var proposed = configuration
            proposed.profiles = proposed.effectiveProfiles.filter { $0.id != id }
            try store.save(proposed)
            configuration = proposed
        } catch { self.error = error.localizedDescription }
    }
    func applyProfile(_ id: UUID) {
        guard applyingProfile == nil, busy.isEmpty, allowSystemAction(),
            let profile = configuration.effectiveProfiles.first(where: { $0.id == id })
        else { return }
        applyingProfile = id
        profileStatus = L10n.text("正在套用「") + profile.name + "」…"
        profileTask = Task { [weak self] in
            guard let self else { return }
            var applied: [String] = []
            var ownedBusy: Set<SwitchID> = []
            defer {
                applyingProfile = nil
                profileTask = nil
                busy.subtract(ownedBusy)
                updateTimer()
                requestRefresh()
            }
            do {
                let current = await backend.readStates(
                    config: configuration, includeDevices: false, mediaPanelVisible: false)
                let steps = try profile.pending(states: current)
                var selected = configuration
                selected.keepAwakeSeconds = profile.awakeSeconds
                selected.awakeClockMinute = profile.awakeClockMinute
                ownedBusy = Set(steps.map(\.control))
                busy.formUnion(ownedBusy)
                for step in steps {
                    try Task.checkCancellation()
                    try await backend.activate(step.control, desired: step.enabled, config: selected)
                    applied.append(step.control.title)
                }
                if profile.steps.contains(where: { $0.control == .keepAwake && $0.enabled }),
                    current[.keepAwake]?.isOn == true
                {
                    try backend.rescheduleAwake(configuration: selected)
                }
                let checked = await backend.readStates(
                    config: selected, includeDevices: false, mediaPanelVisible: false)
                states = checked
                let mismatch = profile.steps.filter { checked[$0.control]?.isOn != $0.enabled }
                guard mismatch.isEmpty else {
                    throw ConfigurationError.invalid(
                        L10n.text("以下狀態未能確認：") + mismatch.map { $0.control.title }.joined(separator: "、"))
                }
                profileStatus = L10n.text("已套用「") + profile.name + "」"
            } catch {
                profileStatus =
                    applied.isEmpty
                    ? L10n.text("配方未有套用：") + error.localizedDescription
                    : L10n.text("已變更：") + applied.joined(separator: "、") + L10n.text("；其餘未完成：")
                        + error.localizedDescription
                self.error = profileStatus
            }
        }
    }
    func setShortcut(_ id: String, value: KeyboardShortcut?) {
        guard let index = configuration.switches.firstIndex(where: { $0.id == id }) else { return }
        let old = configuration.switches[index].shortcut
        configuration.switches[index].shortcut = value
        do {
            try ConfigurationValidation.validate(configuration)
            save()
        } catch {
            configuration.switches[index].shortcut = old
            self.error = error.localizedDescription
        }
    }
    func move(_ moving: String, relativeTo target: String, after: Bool) {
        configuration.switches = SwitchOrder.moving(
            configuration.switches, id: moving, relativeTo: target, after: after)
        save()
    }
    func setEnabled(_ id: String, _ value: Bool) {
        guard let index = configuration.switches.firstIndex(where: { $0.id == id }) else { return }
        configuration.switches[index].enabled = value
        if id == SwitchID.music.rawValue {
            mediaVisibilityGeneration &+= 1
            updateMediaContext()
        }
        save()
    }
    func selectMusicPlayer(_ value: MusicPlayerChoice) {
        guard configuration.musicPlayerChoice != value, !busy.contains(.music), configurationWritable else { return }
        guard value == .automatic || backend.installedMusicPlayers.contains(value) else {
            error = L10n.text("選定的播放器未安裝；保留目前選擇。")
            return
        }
        backend.cancelMediaRead()
        mediaVisibilityGeneration &+= 1
        backend.setMediaContext(visible: false, choice: value)
        states[.music] = .unknown(L10n.text("正在讀取選定播放器"))
        if diagnosticMode {
            configuration.musicPlayerChoice = value
            save()
            updateMediaContext()
            requestRefresh()
            return
        }
        busy.insert(.music)
        let previous = configuration.musicPlayerChoice ?? .automatic
        Task {
            defer {
                busy.remove(.music)
                updateMediaContext()
                requestRefresh()
            }
            do {
                try await backend.prepareMusicSelection(from: previous, to: value)
                var proposed = configuration
                proposed.musicPlayerChoice = value
                try store.save(proposed)
                configuration = proposed
            } catch { self.error = L10n.text("未更新播放器選擇：%1$@", String(describing: error.localizedDescription)) }
            requestRefresh()
        }
    }
    private func updateMediaContext() {
        backend.setMediaContext(
            visible: panelOpen && !busy.contains(.music)
                && configuration.switches.contains(where: { $0.knownID == .music && $0.enabled }),
            choice: configuration.musicPlayerChoice ?? .automatic)
    }
    func setLidSleep(_ value: Bool) {
        guard allowSystemAction() else { return }
        Task {
            do {
                if try await backend.setLidSleepDisabled(value) {
                    configuration.preventLidSleep = value
                    save()
                }
                await refresh()
            } catch { self.error = error.localizedDescription }
        }
    }
    func setLogin(_ value: Bool) {
        guard allowSystemAction() else { return }
        guard !value || !backend.originalRunning else {
            error = L10n.text("原版 One Switch 仍在運行；請先關閉原版，再沿用登入啟動設定。")
            return
        }
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            self.error = L10n.text("開機啟動設定失敗：%1$@", String(describing: error.localizedDescription))
            loginEnabled = SMAppService.mainApp.status == .enabled
        }
    }
    func reimport() {
        guard !diagnosticMode else {
            error = L10n.text("診斷模式不會讀取或匯入原版設定。")
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("重新匯入 One Switch 設定？")
        alert.informativeText = L10n.text("新版設定會先另存備份，再匯入目前原版設定。原版不會被修改，也不會啟動任何開關。")
        alert.addButton(withTitle: L10n.text("備份並匯入"))
        alert.addButton(withTitle: L10n.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let data =
                FileManager.default.fileExists(atPath: store.url.path)
                ? try Data(contentsOf: store.url) : try JSONEncoder().encode(configuration)
            let backup = store.url.deletingLastPathComponent().appendingPathComponent(
                "settings.before-import.\(Int(Date().timeIntervalSince1970)).json")
            try data.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            let database = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support/One Switch/OneSwitch.sqlite")
            let imported = try OneSwitchImporter.load(
                database: database, preferences: OneSwitchImporter.sourcePreferenceData())
            try store.save(imported)
            configuration = imported
            configurationWritable = true
            backend.restoreSession(imported)
            updateHotkeys()
            updateTimer()
            requestRefresh()
            importSummary = L10n.text(
                "已匯入 %1$@ 個開關；備份位於 QuickSwitch 設定資料夾。", String(describing: imported.migration?.descriptorCount ?? 0))
        } catch { self.error = error.localizedDescription }
    }
    func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "QuickSwitch-settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { self.error = error.localizedDescription }
    }
    private func updateHotkeys() {
        hotkeys.update(
            diagnosticMode
                ? [:]
                : AutomationPolicy.registerHotkeys(
                    configuration: configuration, originalRunning: originalRunning))
        hotkeyErrors = hotkeys.errors
    }
    private func updateTimer() {
        guard !diagnosticMode else {
            timer?.invalidate()
            timer = nil
            return
        }
        let timed =
            panelOpen || showingSettings || (!diagnosticMode && backend.needsTimer)
            || (!diagnosticMode && configuration.restoreAutomations && configuration.darkSchedule.enabled
                && configuration.effectiveDarkScheduleMode != .manual && !originalRunning)
        guard timed else {
            timer?.invalidate()
            timer = nil
            return
        }
        let interval: TimeInterval = panelOpen || showingSettings ? 3 : 30
        if timer?.timeInterval == interval { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestRefresh() }
        }
        timer?.tolerance = panelOpen ? 0.2 : 3
    }
    func loadResolutions() {
        displayInventory = DisplayInventory.capture()
        resolutionDisplays = displayInventory.displays
        let selected = DisplaySelection.resolve(
            displays: resolutionDisplays,
            savedStableID: configuration.selectedDisplayUUID ?? legacyResolutionDisplayUUID,
            sourceIndex: configuration.selectedDisplayIndex, currentSelection: selectedResolutionDisplay)
        selectedResolutionDisplay = selected.displayID
        if configuration.selectedDisplayUUID == nil, legacyResolutionDisplayUUID == nil {
            legacyResolutionDisplayUUID = resolutionDisplays.first { $0.id == selected.displayID }?.stableID
        }
        savedResolutionDisplayMissing = selected.savedDisplayMissing
        updateResolutionChoices()
    }
    func presentResolution() {
        loadResolutions()
        openResolution?()
    }
    func selectResolutionDisplay(_ id: UInt32?) {
        guard let display = resolutionDisplays.first(where: { $0.id == id }) else { return }
        selectedResolutionDisplay = display.id
        configuration.selectedDisplayIndex = display.sourceIndex
        configuration.selectedDisplayUUID = display.stableID
        legacyResolutionDisplayUUID = display.stableID
        savedResolutionDisplayMissing = false
        save()
        updateResolutionChoices()
    }
    private func updateResolutionChoices() {
        currentResolutionMode = selectedResolutionDisplay.flatMap { displayInventory.currentModes[$0] }
        resolutionChoices = DisplayModePolicy.visibleModes(
            displayInventory.modes, displayID: selectedResolutionDisplay, onlyHiDPI: configuration.onlyHiDPI,
            currentModeID: currentResolutionMode?.modeID)
    }
    func applyResolution(_ id: String) {
        guard allowSystemAction() else { return }
        guard rollbackMode == nil, let choice = resolutionChoices.first(where: { $0.id == id }),
            let display = resolutionDisplays.first(where: { $0.id == choice.displayID }),
            let stableID = display.stableID, stableID == DisplayInventory.stableID(choice.displayID),
            let mode = displayInventory.nativeModes[choice.id], CGDisplayIsOnline(choice.displayID) != 0,
            let previous = CGDisplayCopyDisplayMode(choice.displayID)
        else { return }
        if previous.ioDisplayModeID == choice.modeID { return }
        let result = CGDisplaySetDisplayMode(choice.displayID, mode, nil)
        guard result == .success else {
            error = L10n.text("解像度更改失敗（%1$@）", String(describing: result.rawValue))
            return
        }
        rollbackMode = (choice.displayID, stableID, previous, choice.modeID)
        resolutionConfirmationDeadline = Date().addingTimeInterval(15)
        loadResolutions()
        rollbackTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.restoreResolution() }
        }
    }
    func keepResolution() {
        rollbackTimer?.invalidate()
        rollbackTimer = nil
        rollbackMode = nil
        resolutionConfirmationDeadline = nil
        loadResolutions()
    }
    func restoreResolution() {
        if let rollback = rollbackMode {
            let current = CGDisplayCopyDisplayMode(rollback.display)
            if DisplayRollbackPolicy.shouldRestore(
                savedStableID: rollback.stableID,
                currentStableID: DisplayInventory.stableID(rollback.display),
                online: CGDisplayIsOnline(rollback.display) != 0,
                appliedModeID: rollback.applied, currentModeID: current?.ioDisplayModeID)
            {
                let result = CGDisplaySetDisplayMode(rollback.display, rollback.previous, nil)
                if result != .success { error = L10n.text("還原解像度失敗；請在系統設定手動還原") }
            } else if current?.ioDisplayModeID != rollback.previous.ioDisplayModeID {
                error = L10n.text("螢幕已斷線或模式已由其他地方更改；未覆蓋目前解像度。")
            }
        }
        keepResolution()
    }
    private func allowSystemAction() -> Bool {
        guard !diagnosticMode else {
            error = L10n.text("診斷模式只讀取狀態；系統操作、快捷鍵及自動排程已停用。")
            return false
        }
        return true
    }
    func shutdown() {
        profileTask?.cancel()
        profileTask = nil
        timer?.invalidate()
        restoreResolution()
        hotkeys.shutdown()
        backend.shutdown()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
