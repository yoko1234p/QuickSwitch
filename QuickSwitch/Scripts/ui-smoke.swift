import AppKit
import ApplicationServices

let arguments = CommandLine.arguments
func fail(_ message: String, _ code: Int32 = 2) -> Never {
    fputs(message + "\n", stderr)
    exit(code)
}
guard arguments.count >= 3, let pid = Int32(arguments[2]), let running = NSRunningApplication(processIdentifier: pid),
    running.bundleIdentifier == "local.pakwingho.quickswitch"
else { fail("Only a running QuickSwitch PID is allowed") }
let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
if session["CGSSessionScreenIsLocked"] as? Bool == true { fail("Desktop locked", 8) }
guard AXIsProcessTrusted() else { fail("Host accessibility permission unavailable") }
let app = AXUIElementCreateApplication(pid)
func get(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}
func children(_ element: AXUIElement) -> [AXUIElement] { get(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func walk(_ element: AXUIElement, depth: Int = 0, visit: (AXUIElement) -> Void) {
    guard depth < 16 else { return }
    visit(element)
    for child in children(element) { walk(child, depth: depth + 1, visit: visit) }
}
func roots() -> [AXUIElement] {
    var list = get(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    if let extras = get(app, kAXExtrasMenuBarAttribute) { list.append(extras as! AXUIElement) }
    return list
}
func find(_ token: String) -> AXUIElement? {
    var found: AXUIElement?
    for root in roots() {
        walk(root) { element in
            if [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute].contains(where: {
                (get(element, $0) as? String) == token
            }) {
                found = element
            }
        }
    }
    return found
}
func output(_ value: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
        fail("JSON failed")
    }
    print(String(decoding: data, as: UTF8.self))
}
switch arguments[1] {
case "dump":
    var records: [[String: Any]] = []
    for root in roots() {
        walk(root) { element in
            var entry: [String: Any] = [:]
            for key in [
                kAXRoleAttribute, kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
            ] { if let value = get(element, key), value is String || value is NSNumber { entry[key] = value } }
            if !entry.isEmpty { records.append(entry) }
        }
    }
    output(records)
case "activate": running.activate(options: [])
case "press":
    guard arguments.count >= 4, let element = find(arguments[3]) else { fail("Own target not found") }
    guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { fail("AXPress failed") }
case "set":
    guard arguments.count >= 5, let element = find(arguments[3]) else { fail("Own field not found") }
    guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, arguments[4] as CFString) == .success
    else { fail("AXSet failed") }
case "windows":
    let list =
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        ?? []
    output(
        list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.map { item in
            [
                "id": item[kCGWindowNumber as String] ?? 0, "bounds": item[kCGWindowBounds as String] ?? [:],
                "name": item[kCGWindowName as String] ?? "",
            ]
        })
case "quit": running.terminate()
default: fail("Unknown operation")
}
