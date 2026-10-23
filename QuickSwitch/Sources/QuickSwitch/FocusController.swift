import AppKit
import QuickSwitchCore

@MainActor
final class FocusController {
    private let runner = CommandRunner()
    private var snapshot = FocusSnapshot(status: "unknown")
    private var snapshotAt: Date?
    private var installed = Set<String>()
    private var installedAt: Date?
    private var listError: String?
    private var reading = false
    private var changing = false
    private var snapshotGeneration = 0
    private var listTask: (id: UUID, value: Task<CommandResult, Never>)?
    private(set) var preparingInstallation = false
    var onSetupNeeded: (() -> Void)?

    func read(force: Bool = false) async -> FocusSnapshot {
        let maximumAge: TimeInterval = snapshot.exactDND == nil ? 120 : 3
        guard force || snapshotAt.map({ Date().timeIntervalSince($0) >= maximumAge }) ?? true else { return snapshot }
        guard let executable = Bundle.main.executableURL else { return snapshot }
        guard !reading else { return snapshot }
        reading = true
        defer { reading = false }
        let generation = snapshotGeneration
        let result = await runner.run(executable.path, ["--probe-focus-readonly"], timeout: 5)
        guard generation == snapshotGeneration else { return snapshot }
        snapshot =
            result.succeeded
            ? (try? FocusSnapshot.decode(Data(result.output.utf8))) ?? FocusSnapshot(status: "unknown")
            : FocusSnapshot(status: "unavailable")
        snapshotAt = Date()
        return snapshot
    }
    func refreshInstalled(force: Bool = false) async {
        guard force || installedAt.map({ Date().timeIntervalSince($0) >= 30 }) ?? true else { return }
        let request: (id: UUID, value: Task<CommandResult, Never>)
        if let active = listTask {
            request = active
        } else {
            request = (UUID(), Task { await runner.run("/usr/bin/shortcuts", ["list"], timeout: 8) })
            listTask = request
        }
        let result = await request.value.value
        guard listTask?.id == request.id else { return }
        listTask = nil
        do {
            guard result.succeeded else { throw ConfigurationError.invalid(L10n.text("系統捷徑清單讀取失敗，請重試")) }
            installed = try FocusControlPolicy.installedNames(result.output)
            listError = nil
        } catch {
            installed = []
            listError = error.localizedDescription
        }
        installedAt = Date()
    }
    func available(_ enabled: Bool, config: AppConfiguration) -> Bool {
        FocusControlPolicy.shortcutName(
            configured: enabled ? config.focusOnShortcut : config.focusOffShortcut,
            enabled: enabled, installed: installed) != nil
    }
    var nativeAvailable: Bool { snapshot.exactDND != nil }
    var summary: String {
        if nativeAvailable { return L10n.text("可顯示目前勿擾狀態；關閉使用系統勿擾捷徑") }
        return listError ?? L10n.text("目前無法讀取勿擾狀態；可透過系統捷徑開啟或關閉。")
    }
    /// Native calls run in a bounded child. A timed-out/uncertain mutation never triggers another backend.
    func set(_ enabled: Bool, config: AppConfiguration, duration: TimeInterval? = nil, interactive: Bool = true)
        async throws
    {
        guard !changing else { throw ConfigurationError.invalid(L10n.text("另一項勿擾操作尚未完成")) }
        changing = true
        snapshotGeneration += 1
        defer { changing = false }
        if nativeAvailable, let executable = Bundle.main.executableURL {
            let result = await runner.run(
                executable.path,
                ["--set-focus", enabled ? "on" : "off", "--duration", String(duration ?? config.focusSeconds)],
                timeout: 8)
            guard result.succeeded, let native = try? FocusSnapshot.decode(Data(result.output.utf8)) else {
                snapshot = FocusSnapshot(status: "unverified", mutationAttempted: true)
                snapshotAt = Date()
                throw ConfigurationError.invalid(L10n.text("系統未能確認操作結果，已停止重複執行；請重新讀取狀態"))
            }
            snapshot = native
            snapshotAt = Date()
            if native.readbackVerified == true, native.exactDND == enabled { return }
            guard native.permitsShortcutFallback else {
                throw ConfigurationError.invalid(L10n.text("勿擾操作未能由系統確認，已停止重複執行"))
            }
        }
        await refreshInstalled(force: true)
        if let listError { throw ConfigurationError.invalid(listError) }
        let configured = enabled ? config.focusOnShortcut : config.focusOffShortcut
        guard let name = FocusControlPolicy.shortcutName(configured: configured, enabled: enabled, installed: installed)
        else {
            if interactive { onSetupNeeded?() }
            throw ConfigurationError.invalid(L10n.text("尚未安裝可用的勿擾捷徑；請在設定按「安裝開啟／關閉捷徑」，加入後按「重新檢查」。"))
        }
        let result = await runner.run("/usr/bin/shortcuts", ["run", name], timeout: 40)
        guard result.succeeded else {
            installedAt = nil
            throw ConfigurationError.invalid(result.output.isEmpty ? L10n.text("系統捷徑執行失敗，未更新勿擾狀態") : result.output)
        }
        snapshotAt = nil
        _ = await read(force: true)
    }
    func prepareInstallation(enabled: Bool, directory: URL) async throws {
        guard !preparingInstallation else { throw ConfigurationError.invalid(L10n.text("另一個捷徑正在準備，請稍候")) }
        preparingInstallation = true
        defer { preparingInstallation = false }
        await refreshInstalled(force: true)
        let name = enabled ? FocusControlPolicy.ownedOnName : FocusControlPolicy.ownedOffName
        guard !installed.contains(name) else { return }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let source = directory.appendingPathComponent(name + ".unsigned.shortcut")
        let signed = directory.appendingPathComponent(name + ".shortcut")
        try FocusShortcutDocument.make(enabled: enabled).write(to: source, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        let result = await runner.run(
            "/usr/bin/shortcuts",
            ["sign", "--mode", "anyone", "--input", source.path, "--output", signed.path], timeout: 30)
        guard result.succeeded, let attributes = try? FileManager.default.attributesOfItem(atPath: signed.path),
            let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 2_097_152
        else {
            throw ConfigurationError.invalid(
                L10n.text(
                    "系統未能簽署捷徑；%1$@",
                    String(describing: result.output.isEmpty ? L10n.text("請確認已登入 iCloud，再重試") : result.output)))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: signed.path)
        let shortcutsApp = URL(fileURLWithPath: "/System/Applications/Shortcuts.app", isDirectory: true)
        guard Bundle(url: shortcutsApp)?.bundleIdentifier == "com.apple.shortcuts" else {
            throw ConfigurationError.invalid(L10n.text("未找到系統捷徑 App，已保留準備好的檔案"))
        }
        _ = try await NSWorkspace.shared.open([signed], withApplicationAt: shortcutsApp, configuration: .init())
        installedAt = nil
    }
}
