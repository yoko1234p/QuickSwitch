import AppKit
import Darwin
import QuickSwitchCore
import QuickSwitchNative
import SwiftUI

@main
@MainActor
enum QuickSwitchMain {
    static func main() {
        if L10n.catalog.printDiagnosticsIfRequested() { return }
        let args = Array(CommandLine.arguments.dropFirst())
        let headlessModes: Set<String> = [
            "--probe-focus-readonly", "--set-focus", "--record-system-observation", "--import-original",
            "--audit-import",
            "--probe-readonly", "--probe-displays-readonly", "--probe-media-readonly", "--control-media",
        ]
        if args.contains("--diagnostic-mode"), !headlessModes.isDisjoint(with: args) {
            fputs("--diagnostic-mode is a GUI-only mode and cannot be combined with headless commands.\n", stderr)
            exit(2)
        }
        if args.contains("--probe-focus-readonly") {
            guard args == ["--probe-focus-readonly"] else {
                fputs("Usage: --probe-focus-readonly\n", stderr)
                exit(2)
            }
            emitFocus(QSReadFocusState())
            exit(0)
        }
        if args.contains("--probe-displays-readonly") {
            guard args == ["--probe-displays-readonly"] else { exit(2) }
            emitFocus(DisplayInventory.capture().readOnlySummary)
            exit(0)
        }
        if args.first == "--probe-media-readonly" {
            guard args.count == 2 || (args.count == 3 && args[2] == "--state-only"),
                ["appleMusic", "spotify"].contains(args[1])
            else { exit(2) }
            alarm(3)  // Also bound a native IPC if the parent disappears before cancellation cleanup.
            emitFocus(QSReadMediaSnapshot(args[1], args.count == 2))
            exit(0)
        }
        if args.first == "--control-media" {
            guard args.count == 3, ["appleMusic", "spotify"].contains(args[1]), ["play", "pause"].contains(args[2])
            else { exit(2) }
            alarm(20)
            emitFocus(QSSetMediaPlaying(args[1], args[2] == "play"))
            exit(0)
        }
        if args.first == "--set-focus" {
            guard args.count == 4, ["on", "off"].contains(args[1]), args[2] == "--duration",
                let duration = Double(args[3]), duration.isFinite, (0...604800).contains(duration)
            else {
                fputs("Usage: --set-focus on|off --duration <0...604800>\n", stderr)
                exit(2)
            }
            emitFocus(QSSetFocusEnabled(args[1] == "on", duration))
            exit(0)
        }
        if let observationPath = argument("--record-system-observation", in: args) {
            do {
                let directory =
                    argument("--data-directory", in: args).map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                        "Library/Application Support/QuickSwitch")
                let observation = try JSONDecoder().decode(
                    SourceSystemObservation.self, from: Data(contentsOf: URL(fileURLWithPath: observationPath)))
                try ConfigurationStore(url: directory.appendingPathComponent("settings.json")).recordSystemObservation(
                    observation)
                print(
                    "{\"observationRecorded\":true,\"loginItemRegistered\":false,\"guiStarted\":false,\"systemMutations\":0}"
                )
                exit(0)
            } catch {
                fputs("QuickSwitch observation error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if args.contains("--import-original") || args.contains("--audit-import") {
            do {
                try auditImport(args)
                exit(0)
            } catch {
                fputs("QuickSwitch import error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if args.contains("--probe-readonly") {
            let report: [String: Any] = [
                "nightShift": QSDisplaySettingState("nightShift"), "trueTone": QSDisplaySettingState("trueTone"),
                "guiStarted": false, "systemMutations": 0,
            ]
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            print(String(decoding: data, as: UTF8.self))
            exit(0)
        }
        let options: GUIStartupOptions
        do {
            options = try GUIStartupOptions.parse(
                arguments: args, home: FileManager.default.homeDirectoryForCurrentUser)
        } catch {
            fputs("QuickSwitch startup error: \(error.localizedDescription)\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        if options.diagnosticMode {
            switch ProcessInfo.processInfo.environment["QUICKSWITCH_DIAGNOSTIC_APPEARANCE"] {
            case "light": app.appearance = NSAppearance(named: .aqua)
            case "dark": app.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
        }
        let delegate = AppDelegate(options: options)
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
    private static func emitFocus(_ state: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { exit(1) }
        print(String(decoding: data, as: UTF8.self))
    }
    private static func argument(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1), !args[index + 1].hasPrefix("--")
        else { return nil }
        return args[index + 1]
    }
    private static func auditImport(_ args: [String]) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory =
            argument("--data-directory", in: args).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent("Library/Application Support/QuickSwitch")
        let database =
            argument("--source-database", in: args).map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Library/Application Support/One Switch/OneSwitch.sqlite")
        let prefs =
            try argument("--source-preferences", in: args).map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
            ?? OneSwitchImporter.sourcePreferenceData()
        let config = try OneSwitchImporter.load(database: database, preferences: prefs)
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        let wrote = args.contains("--import-original") ? try store.importOnce(config) : false
        let report = config.migration!
        let telemetry = report.untranslatedPreferenceKeys.filter {
            $0.hasPrefix("MSAppCenter") || $0.hasPrefix("STP_") || $0.hasPrefix("NSStatusItem") || $0 == "switchCount"
                || $0 == "firstLaunch"
        }
        let payload: [String: Any] = [
            "application": "QuickSwitch", "sourceVersion": report.sourceVersion,
            "knownCatalogCount": SwitchID.allCases.count,
            "sourceDescriptorCount": report.descriptorCount, "enabledCount": config.visibleSwitches.count,
            "sourceFingerprint": report.sourceFingerprint, "orderedIDs": config.orderedSwitches.map(\.id),
            "enabledIDs": config.visibleSwitches.map(\.id), "mappedPreferenceCount": report.translatedPreferenceCount,
            "preservedUntranslatedPreferenceCount": report.untranslatedPreferenceKeys.count,
            "preservedUntranslatedShortcutCount": report.untranslatedShortcutCount,
            "preservedUnknownSwitchCount": report.unknownSwitchIDs.count,
            "skippedNonfunctionalPreferenceCount": telemetry.count, "rejectedCount": 0,
            "written": wrote, "guiStarted": false, "hooksRegistered": 0, "systemMutations": 0,
            "automationActivated": false, "originalReadOnly": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        if let path = argument("--report-json", in: args) {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print(String(decoding: data, as: UTF8.self))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let options: GUIStartupOptions
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var resolutionWindow: NSWindow?
    private var energyWindow: NSWindow?
    private var model: AppModel?
    private var pendingLinks: [URL] = []
    init(options: GUIStartupOptions) {
        self.options = options
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = ConfigurationStore(url: options.dataDirectory.appendingPathComponent("settings.json"))
        let model = AppModel(store: store, options: options)
        self.model = model
        let links = pendingLinks
        pendingLinks = []
        if !links.isEmpty { DispatchQueue.main.async { [weak self] in self?.application(NSApp, open: links) } }
        model.openSettings = { [weak self] in self?.showSettings() }
        model.openResolution = { [weak self] in self?.showResolution() }
        model.openEnergy = { [weak self] in self?.showEnergy() }
        let item = NSStatusBar.system.statusItem(withLength: 26)
        if !options.diagnosticMode { item.autosaveName = "QuickSwitch.Control" }
        if let button = item.button {
            button.image = QuickSwitchBrand.statusImage()
            button.imagePosition = .imageOnly
            button.toolTip = L10n.text("QuickSwitch — 系統開關")
            button.setAccessibilityLabel(L10n.text("QuickSwitch — 系統開關"))
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityIdentifier("quickswitch.status")
        }
        statusItem = item
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let controller = NSViewController()
        controller.view = NSHostingView(rootView: DashboardView(model: model))
        popover.contentViewController = controller
        self.popover = popover
        if options.showSettings { showSettings() }
    }
    @objc private func togglePanel() {
        guard let popover, let button = statusItem?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showSettings()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
            model?.panelVisibility(false)
        } else {
            model?.dashboardMaximumHeight = max(300, min(860, (button.window?.screen?.visibleFrame.height ?? 980) - 72))
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            model?.panelVisibility(true)
        }
    }
    func popoverDidClose(_ notification: Notification) { model?.panelVisibility(false) }
    private func makeWindow<V: View>(_ title: String, root: V) -> NSWindow {
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
    private func showSettings() {
        guard let model else { return }
        popover?.performClose(nil)
        if settingsWindow == nil {
            settingsWindow = makeWindow(L10n.text("QuickSwitch — 設定"), root: SettingsView(model: model))
            settingsWindow?.setContentSize(NSSize(width: 740, height: 680))
        }
        model.showingSettings = true
        model.requestRefresh()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func showResolution() {
        guard let model else { return }
        popover?.performClose(nil)
        if resolutionWindow == nil {
            resolutionWindow = makeWindow(L10n.text("QuickSwitch — 解像度"), root: ResolutionView(model: model))
        }
        model.showingResolution = true
        resolutionWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func showEnergy() {
        guard let model else { return }
        popover?.performClose(nil)
        if energyWindow == nil {
            energyWindow = makeWindow(L10n.text("QuickSwitch — 電源模式"), root: EnergyView(model: model))
        }
        energyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow {
            model?.showingSettings = false
            model?.panelVisibility(false)
        }
        if let window = notification.object as? NSWindow, window === resolutionWindow {
            model?.showingResolution = false
            model?.restoreResolution()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else {
            pendingLinks = Array((pendingLinks + urls).suffix(8))
            return
        }
        for url in urls {
            guard url.scheme == "quickswitch", url.user == nil, url.password == nil, url.query == nil,
                url.fragment == nil,
                url.host == "profile", let id = UUID(uuidString: String(url.path.dropFirst()))
            else { continue }
            model.applyProfile(id)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}
