import Foundation

public struct BluetoothBattery: Equatable, Sendable {
    public var left: Int?
    public var right: Int?
    public var single: Int?
    public var chargingCase: Int?
    public var summary: String {
        var values: [String] = []
        if let left { values.append(L10n.text("左 %1$@%", String(describing: left))) }
        if let right { values.append(L10n.text("右 %1$@%", String(describing: right))) }
        if let single, left == nil, right == nil { values.append("\(single)%") }
        if let chargingCase { values.append(L10n.text("盒 %1$@%", String(describing: chargingCase))) }
        return values.joined(separator: " · ")
    }
}

public enum BluetoothBatteryParser {
    public static func addressKey(_ address: String) -> String? {
        let normalized = address.lowercased().filter { "0123456789abcdef".contains($0) }
        return normalized.count == 12 ? normalized : nil
    }
    /// Retain only connected-device battery readings. Names, serials and full profiler data are discarded.
    public static func parse(_ data: Data) throws -> [String: BluetoothBattery] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let controllers = root["SPBluetoothDataType"] as? [[String: Any]]
        else { throw ConfigurationError.invalid(L10n.text("Bluetooth 系統資料格式未支援")) }
        var result: [String: BluetoothBattery] = [:]
        for controller in controllers {
            for group in controller["device_connected"] as? [[String: Any]] ?? [] {
                for raw in group.values {
                    guard let device = raw as? [String: Any], let address = device["device_address"] as? String,
                        let key = addressKey(address)
                    else { continue }
                    let battery = BluetoothBattery(
                        left: percent(device["device_batteryLevelLeft"]),
                        right: percent(device["device_batteryLevelRight"]),
                        single: percent(device["device_batteryLevelMain"]),
                        chargingCase: percent(device["device_batteryLevelCase"]))
                    if !battery.summary.isEmpty { result[key] = battery }
                }
            }
        }
        return result
    }
    private static func percent(_ value: Any?) -> Int? {
        let number: Double?
        if let raw = value as? NSNumber {
            number = raw.doubleValue
        } else if let raw = value as? String, raw.contains("%") {
            number = Double(raw.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
        } else {
            number = nil
        }
        guard let number, number.isFinite, (0...100).contains(number) else { return nil }
        return Int(number.rounded())
    }
}
