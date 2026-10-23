import AppKit
import CoreGraphics
import QuickSwitchCore

@MainActor
struct DisplayInventory {
    var displays: [DisplayDescriptor] = []
    var modes: [DisplayModeDescriptor] = []
    var nativeModes: [String: CGDisplayMode] = [:]
    var currentModes: [UInt32: DisplayModeDescriptor] = [:]

    static func capture() -> Self {
        var result = Self()
        for (index, screen) in NSScreen.screens.enumerated() {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let id = number.uint32Value
            result.displays.append(
                DisplayDescriptor(id: id, stableID: stableID(id), title: screen.localizedName, sourceIndex: index))
            if let current = CGDisplayCopyDisplayMode(id) { result.currentModes[id] = descriptor(current, display: id) }
            let available =
                CGDisplayCopyAllDisplayModes(
                    id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? []
            for mode in available {
                let value = descriptor(mode, display: id)
                result.modes.append(value)
                result.nativeModes[value.id] = mode
            }
        }
        return result
    }

    static func stableID(_ display: UInt32) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String?
    }

    static func descriptor(_ mode: CGDisplayMode, display: UInt32) -> DisplayModeDescriptor {
        DisplayModeDescriptor(
            displayID: display, modeID: mode.ioDisplayModeID, width: mode.width, height: mode.height,
            pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate,
            usable: mode.isUsableForDesktopGUI())
    }

    var readOnlySummary: [String: Any] {
        [
            "displayCount": displays.count, "systemMutations": 0, "guiStarted": false,
            "displays": displays.map { display -> [String: Any] in
                var row: [String: Any] = [
                    "index": display.sourceIndex, "displayID": display.id,
                    "stableIdentityAvailable": display.stableID != nil,
                    "availableModeCount": modes.filter { $0.displayID == display.id && $0.usable }.count,
                ]
                if let current = currentModes[display.id] {
                    row["currentModeID"] = current.modeID
                    row["currentWidth"] = current.width
                    row["currentHeight"] = current.height
                    row["currentHiDPI"] = current.isHiDPI
                }
                return row
            },
        ]
    }
}
