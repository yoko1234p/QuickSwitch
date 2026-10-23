import Foundation

public enum KeepAwakeDuration {
    public static let maximum: TimeInterval = 604800
    public static let presets: [TimeInterval] = [0, 1500, 3600, 7200, 18000, 28800]

    public static func validate(_ seconds: TimeInterval) throws {
        guard seconds.isFinite, (0...maximum).contains(seconds) else {
            throw ConfigurationError.invalid(L10n.text("清醒時限必須介乎 0 至 7 日"))
        }
    }

    public static func custom(hours: String, minutes: String) throws -> TimeInterval {
        let hours = hours.trimmingCharacters(in: .whitespacesAndNewlines)
        let minutes = minutes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let h = Int(hours.isEmpty ? "0" : hours), let m = Int(minutes.isEmpty ? "0" : minutes),
            (0...168).contains(h), (0...59).contains(m)
        else { throw ConfigurationError.invalid(L10n.text("小時請輸入 0–168，分鐘請輸入 0–59。")) }
        let seconds = TimeInterval(h * 3600 + m * 60)
        guard seconds >= 60, seconds <= maximum else {
            throw ConfigurationError.invalid(L10n.text("自訂時長為 1 分鐘至 7 日；不限時請選「直至手動關閉」。"))
        }
        return seconds
    }

    public static func title(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, (0...maximum).contains(seconds) else { return L10n.text("未設定") }
        if seconds == 0 { return L10n.text("直至手動關閉") }
        let total = Int(ceil(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append(L10n.text("%1$@ 小時", String(describing: hours))) }
        if minutes > 0 { parts.append(L10n.text("%1$@ 分鐘", String(describing: minutes))) }
        if remainder > 0 { parts.append(L10n.text("%1$@ 秒", String(describing: remainder))) }
        return parts.joined(separator: " ")
    }
}

/// Generation-bound deadlines keep an already queued timer from stopping a renewed session.
public struct KeepAwakeDeadline: Sendable {
    public private(set) var deadline: Date?
    public private(set) var generation: UInt64 = 0
    public init() {}

    public mutating func start(seconds: TimeInterval, now: Date) throws {
        try KeepAwakeDuration.validate(seconds)
        generation &+= 1
        deadline = seconds > 0 ? now.addingTimeInterval(seconds) : nil
    }

    public mutating func clear() {
        generation &+= 1
        deadline = nil
    }
    public mutating func start(until date: Date?, now: Date) throws {
        if let date {
            guard date > now, date.timeIntervalSince(now) <= KeepAwakeDuration.maximum else {
                throw ConfigurationError.invalid(L10n.text("保持清醒的結束時間已過期或超過七日。"))
            }
        }
        generation &+= 1
        deadline = date
    }

    public func due(generation request: UInt64, at now: Date) -> Bool {
        request == generation && deadline.map { $0 <= now } == true
    }
}
