import AppKit
import ApplicationServices

// Bounded inspection: only One Switch, only opening/closing menu/settings.
// No switch, preference, shortcut, text field or destructive action can be written here.
let args = CommandLine.arguments
func fail(_ text: String) -> Never {
    fputs(text + "\n", stderr)
    exit(2)
}
guard args.count >= 3, let pid = Int32(args[2]), let owner = NSRunningApplication(processIdentifier: pid),
    owner.bundleIdentifier == "studio.fireball.OneSwitch-setapp"
else { fail("Original One Switch PID required") }
guard AXIsProcessTrusted() else { fail("Host AX permission missing") }
let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
guard session["CGSSessionScreenIsLocked"] as? Bool != true else { fail("Desktop locked") }
let app = AXUIElementCreateApplication(pid)
func get(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success else { return nil }
    return value
}
func walk(_ e: AXUIElement, depth: Int = 0, visit: (AXUIElement) -> Void) {
    guard depth < 15 else { return }
    visit(e)
    for child in get(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth: depth + 1, visit: visit) }
}
func roots() -> [AXUIElement] {
    var list = get(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    if let extra = get(app, kAXExtrasMenuBarAttribute) { list.append(extra as! AXUIElement) }
    return list
}
func json(_ value: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) else {
        fail("JSON failed")
    }
    print(String(decoding: data, as: UTF8.self))
}
switch args[1] {
case "dump":
    var records: [[String: Any]] = []
    for root in roots() {
        walk(root) { e in
            var record: [String: Any] = [:]
            for key in [kAXRoleAttribute, kAXTitleAttribute, kAXIdentifierAttribute, kAXDescriptionAttribute] {
                if let value = get(e, key) as? String { record[key] = value }
            }
            let role = get(e, kAXRoleAttribute) as? String ?? ""
            if role == kAXCheckBoxRole || role == kAXRadioButtonRole {
                record["AXValue"] = get(e, kAXValueAttribute) as? NSNumber
            }
            if role == kAXStaticTextRole, let value = get(e, kAXValueAttribute) as? String { record["AXValue"] = value }
            if let box = get(e, kAXPositionAttribute), CFGetTypeID(box) == AXValueGetTypeID() {
                var point = CGPoint.zero
                AXValueGetValue(box as! AXValue, .cgPoint, &point)
                record["position"] = ["x": point.x, "y": point.y]
            }
            if let box = get(e, kAXSizeAttribute), CFGetTypeID(box) == AXValueGetTypeID() {
                var size = CGSize.zero
                AXValueGetValue(box as! AXValue, .cgSize, &size)
                record["size"] = ["width": size.width, "height": size.height]
            }
            records.append(record)
        }
    }
    json(records)
case "open-menu":
    guard let extra = get(app, kAXExtrasMenuBarAttribute) else { fail("Own extra menu not found") }
    var item: AXUIElement?
    walk(extra as! AXUIElement) { e in if get(e, kAXRoleAttribute) as? String == kAXMenuBarItemRole { item = e } }
    guard let item, AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
        fail("Own menu could not open")
    }
case "open-settings":
    let names: Set<String> = [
        "Preferences…", "Preferences...", "Preferences", "偏好設定…", "偏好設定...", "偏好設定", "設定…", "設定", "Preferences...",
    ]
    var item: AXUIElement?
    for root in roots() {
        walk(root) { e in
            let role = get(e, kAXRoleAttribute) as? String ?? ""
            guard role == kAXButtonRole || role == kAXMenuItemRole else { return }
            let name = (get(e, kAXTitleAttribute) as? String) ?? (get(e, kAXDescriptionAttribute) as? String) ?? ""
            if names.contains(name) || names.contains(get(e, kAXDescriptionAttribute) as? String ?? "") { item = e }
        }
    }
    guard let item, AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
        fail("Known preferences control not found")
    }
case "tab":
    guard args.count >= 4, ["通用", "自定義", "快速鍵"].contains(args[3]) else {
        fail("Only non-sensitive settings tabs allowed")
    }
    var control: AXUIElement?
    for window in get(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    where get(window, kAXRoleAttribute) as? String == kAXWindowRole {
        walk(window) { e in
            if get(e, kAXRoleAttribute) as? String == kAXButtonRole && get(e, kAXTitleAttribute) as? String == args[3] {
                control = e
            }
        }
    }
    guard let control, AXUIElementPerformAction(control, kAXPressAction as CFString) == .success else {
        fail("Known toolbar tab not found")
    }
case "close-settings":
    for window in get(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    where get(window, kAXTitleAttribute) as? String == "偏好設定" {
        if let button = get(window, kAXCloseButtonAttribute) {
            _ = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }
case "finish-observation":
    owner.activate(options: [])
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    for window in get(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    where get(window, kAXTitleAttribute) as? String == "偏好設定" {
        if let button = get(window, kAXCloseButtonAttribute) {
            _ = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }
    let visible =
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        ?? []
    let menuVisible = visible.contains { row in
        guard (row[kCGWindowOwnerPID as String] as? Int32) == pid,
            let bounds = row[kCGWindowBounds as String] as? [String: Double]
        else { return false }
        return (bounds["Width"] ?? 0) >= 330 && (bounds["Width"] ?? 0) <= 350 && (bounds["Height"] ?? 0) > 100
    }
    if menuVisible, let extra = get(app, kAXExtrasMenuBarAttribute) {
        walk(extra as! AXUIElement) { e in
            if get(e, kAXRoleAttribute) as? String == kAXMenuBarItemRole {
                _ = AXUIElementPerformAction(e, kAXPressAction as CFString)
            }
        }
    }
case "windows":
    let windows =
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        ?? []
    json(
        windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.map {
            ["id": $0[kCGWindowNumber as String] ?? 0, "bounds": $0[kCGWindowBounds as String] ?? [:]]
        })
default: fail("Only read-only inspection and known UI entry points are supported")
}
