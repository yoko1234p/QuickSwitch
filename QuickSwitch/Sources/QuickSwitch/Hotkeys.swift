import AppKit
import Carbon
import QuickSwitchCore
import SwiftUI

@MainActor
final class HotkeyManager {
    private var handler: EventHandlerRef?
    private var registered: [EventHotKeyRef] = []
    private var ids: [UInt32: SwitchID] = [:]
    private var installed: [String: QuickSwitchCore.KeyboardShortcut] = [:]
    var activate: ((SwitchID) -> Void)?
    var errors: [String] = []
    func update(_ shortcuts: [String: QuickSwitchCore.KeyboardShortcut]) {
        guard shortcuts != installed else { return }
        unregister()
        errors = []
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let context = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, context in
                    guard let event, let context else { return OSStatus(eventNotHandledErr) }
                    var hotkey = EventHotKeyID()
                    let result = GetEventParameter(
                        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &hotkey)
                    guard result == noErr else { return result }
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
                    MainActor.assumeIsolated { if let id = manager.ids[hotkey.id] { manager.activate?(id) } }
                    return noErr
                }, 1, &type, context, &handler)
        }
        for (offset, entry) in shortcuts.sorted(by: { $0.key < $1.key }).enumerated() {
            guard let id = SwitchID(rawValue: entry.key) else { continue }
            var reference: EventHotKeyRef?
            let number = UInt32(offset + 1)
            let result = RegisterEventHotKey(
                entry.value.keyCode, entry.value.carbonModifiers, EventHotKeyID(signature: 0x5153_5754, id: number),
                GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference {
                registered.append(reference)
                ids[number] = id
            } else {
                errors.append(
                    L10n.text("%1$@：快捷鍵被其他程式使用（%2$@）", String(describing: id.title), String(describing: result)))
            }
        }
        installed = shortcuts
    }
    func unregister() {
        for reference in registered { UnregisterEventHotKey(reference) }
        registered = []
        ids = [:]
        installed = [:]
    }
    func shutdown() {
        unregister()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var value: QuickSwitchCore.KeyboardShortcut?
    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.changed = { value = $0 }
        return view
    }
    func updateNSView(_ view: RecorderView, context: Context) {
        view.shortcut = value
        view.changed = { value = $0 }
        view.updateLabel()
    }
    final class RecorderView: NSButton {
        var shortcut: QuickSwitchCore.KeyboardShortcut?
        var changed: ((QuickSwitchCore.KeyboardShortcut?) -> Void)?
        private var recording = false
        override var acceptsFirstResponder: Bool { true }
        init() {
            super.init(frame: .zero)
            isBordered = true
            bezelStyle = .rounded
            target = self
            action = #selector(beginRecording)
            updateLabel()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
        @objc func beginRecording() {
            recording = true
            window?.makeFirstResponder(self)
            title = L10n.text("按快捷鍵 · Esc 取消")
        }
        func updateLabel() { if !recording { title = shortcut?.display ?? L10n.text("錄製快捷鍵") } }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }
        override func keyDown(with event: NSEvent) {
            guard recording else {
                super.keyDown(with: event)
                return
            }
            if event.keyCode == 53 {
                recording = false
                updateLabel()
                return
            }
            if event.keyCode == 51 {
                shortcut = nil
                changed?(nil)
                recording = false
                updateLabel()
                return
            }
            let proposed = QuickSwitchCore.KeyboardShortcut(
                keyCode: UInt32(event.keyCode),
                modifiers: UInt32(event.modifierFlags.intersection([.control, .option, .shift, .command]).rawValue))
            guard proposed.valid else {
                NSSound.beep()
                return
            }
            shortcut = proposed
            changed?(proposed)
            recording = false
            updateLabel()
        }
        override func resignFirstResponder() -> Bool {
            recording = false
            updateLabel()
            return super.resignFirstResponder()
        }
    }
}
