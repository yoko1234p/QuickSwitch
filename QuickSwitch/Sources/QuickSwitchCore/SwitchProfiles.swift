import Foundation

public enum AwakeClock {
    public static func next(minute: Int, after now: Date, calendar: Calendar = .current) throws -> Date {
        guard (0..<1440).contains(minute), now.timeIntervalSince1970.isFinite,
            let date = calendar.nextDate(
                after: now, matching: DateComponents(hour: minute / 60, minute: minute % 60, second: 0),
                matchingPolicy: .nextTime, repeatedTimePolicy: .first),
            date > now, date.timeIntervalSince(now) <= 26 * 3600
        else { throw ConfigurationError.invalid(L10n.text("請選擇有效的結束時間。")) }
        return date
    }
    public static func title(_ minute: Int) -> String {
        L10n.text("直至 %1$@", String(format: "%02d:%02d", minute / 60, minute % 60))
    }
}

public struct SwitchProfileStep: Codable, Equatable, Sendable, Identifiable {
    public var control: SwitchID
    public var enabled: Bool
    public var id: String { control.rawValue }
    public init(_ control: SwitchID, enabled: Bool) {
        self.control = control
        self.enabled = enabled
    }
}

public struct SwitchProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var steps: [SwitchProfileStep]
    public var awakeSeconds: TimeInterval
    public var awakeClockMinute: Int?
    public init(
        id: UUID = UUID(), name: String, steps: [SwitchProfileStep], awakeSeconds: TimeInterval = 3600,
        awakeClockMinute: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.steps = steps
        self.awakeSeconds = awakeSeconds
        self.awakeClockMinute = awakeClockMinute
    }
    public static let controls: [SwitchID] = [
        .keepAwake, .darkMode, .nightShift, .trueTone, .focus, .muteMicrophone, .hideWidgets, .hideDesktop, .hideDock,
        .hiddenFiles,
    ]
    public static let defaults: [Self] = [
        .init(
            id: UUID(uuidString: "2F841B68-AB1D-4F86-A402-000000000001")!, name: L10n.text("工作"),
            steps: [.init(.keepAwake, enabled: true)], awakeClockMinute: 1170),
        .init(
            id: UUID(uuidString: "2F841B68-AB1D-4F86-A402-000000000002")!, name: L10n.text("開會"),
            steps: [.init(.keepAwake, enabled: true)], awakeSeconds: 3600),
    ]
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
            !steps.isEmpty, steps.count <= Self.controls.count, Set(steps.map(\.control)).count == steps.count,
            steps.allSatisfy({ Self.controls.contains($0.control) }),
            awakeClockMinute == nil || (0..<1440).contains(awakeClockMinute!)
        else { throw ConfigurationError.invalid(L10n.text("配方需要名稱及至少一項支援開關，不能包含重複或破壞性動作。")) }
        try KeepAwakeDuration.validate(awakeSeconds)
    }
    public func pending(states: [SwitchID: SwitchState]) throws -> [SwitchProfileStep] {
        try validate()
        let unavailable = steps.filter { states[$0.control]?.canActivate != true || states[$0.control]?.isOn == nil }
        guard unavailable.isEmpty else {
            throw ConfigurationError.invalid(
                L10n.text("以下開關狀態未能確認，未套用配方：") + unavailable.map { $0.control.title }.joined(separator: "、"))
        }
        return steps.filter { states[$0.control]?.isOn != $0.enabled }
    }
}

extension AppConfiguration {
    public var effectiveProfiles: [SwitchProfile] { profiles ?? SwitchProfile.defaults }
    public func awakeDeadline(at now: Date = Date(), calendar: Calendar = .current) throws -> Date? {
        if let minute = awakeClockMinute { return try AwakeClock.next(minute: minute, after: now, calendar: calendar) }
        try KeepAwakeDuration.validate(keepAwakeSeconds)
        return keepAwakeSeconds > 0 ? now.addingTimeInterval(keepAwakeSeconds) : nil
    }
}
