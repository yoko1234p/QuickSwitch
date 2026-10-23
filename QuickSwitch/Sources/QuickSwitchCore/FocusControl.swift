import Foundation

public struct FocusSnapshot: Codable, Equatable, Sendable {
    public var status: String
    public var dndEnabled: Bool?
    public var otherFocusActive: Bool?
    public var mutationAttempted: Bool
    public var readbackVerified: Bool?
    public var errorDomain: String?
    public var errorCode: Int?
    public init(
        status: String, dndEnabled: Bool? = nil, otherFocusActive: Bool? = nil,
        mutationAttempted: Bool = false, readbackVerified: Bool? = nil
    ) {
        self.status = status
        self.dndEnabled = dndEnabled
        self.otherFocusActive = otherFocusActive
        self.mutationAttempted = mutationAttempted
        self.readbackVerified = readbackVerified
    }
    public var exactDND: Bool? { status == "exact" ? dndEnabled : nil }
    /// A private call may have changed state before a timeout or failed readback.
    public var permitsShortcutFallback: Bool { !mutationAttempted && exactDND == nil }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8192 else { throw ConfigurationError.invalid(L10n.text("勿擾狀態回覆過大")) }
        let value = try JSONDecoder().decode(Self.self, from: data)
        let statuses = [
            "exact", "denied", "unavailable", "abiMismatch", "unknown", "failed", "unverified", "invalidDuration",
        ]
        guard statuses.contains(value.status), value.status != "exact" || value.dndEnabled != nil else {
            throw ConfigurationError.invalid(L10n.text("勿擾狀態回覆無效"))
        }
        return value
    }
}

public struct FocusCommandObservation: Codable, Equatable, Sendable {
    public var requestedEnabled: Bool
    public var completedAt: Date
    public init(requestedEnabled: Bool, completedAt: Date = Date()) {
        self.requestedEnabled = requestedEnabled
        self.completedAt = completedAt
    }
}

public enum FocusControlPolicy {
    public static let ownedOnName = "QuickSwitch DND On"
    public static let ownedOffName = "QuickSwitch DND Off"
    public static let sourceOnName = "One Switch DND On"
    public static let sourceOffName = "One Switch DND Off"
    public static func shortcutName(configured: String, enabled: Bool, installed: Set<String>) -> String? {
        guard validShortcutName(configured) else { return nil }
        if installed.contains(configured) { return configured }
        let owned = enabled ? ownedOnName : ownedOffName
        let source = enabled ? sourceOnName : sourceOffName
        // Preserve custom shortcut semantics; only our known default pair may substitute.
        guard configured == source || configured == owned else { return nil }
        if installed.contains(owned) { return owned }
        return installed.contains(source) ? source : nil
    }
    public static func validShortcutName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && !value.contains(where: { $0.isNewline || $0 == "\0" })
    }
    public static func installedNames(_ output: String) throws -> Set<String> {
        guard output.utf8.count < 65536 else { throw ConfigurationError.invalid(L10n.text("捷徑清單過大，未能確認安裝狀態")) }
        let names = output.split(whereSeparator: \.isNewline).map(String.init)
        guard names.count <= 2048, names.allSatisfy(validShortcutName), Set(names).count == names.count else {
            throw ConfigurationError.invalid(L10n.text("捷徑清單無效或有重複名稱，未能確認安裝狀態"))
        }
        return Set(names)
    }
    public static func state(snapshot: FocusSnapshot, lastCommand: FocusCommandObservation?) -> SwitchState {
        if let value = snapshot.exactDND {
            let detail =
                snapshot.otherFocusActive == true
                ? (value ? L10n.text("勿擾與其他專注模式運行中") : L10n.text("其他專注模式運行中；勿擾未開啟")) : L10n.text("系統實際狀態")
            return .toggle(value, detail)
        }
        if let lastCommand {
            return .unknown(
                L10n.text("上次捷徑成功") + (lastCommand.requestedEnabled ? L10n.text("開啟") : L10n.text("關閉"))
                    + L10n.text("；目前系統狀態未能讀取"))
        }
        return .unknown(L10n.text("選擇開啟／關閉；目前無法讀取勿擾狀態"))
    }
}

public struct FocusDeadlineTracker: Equatable, Sendable {
    public private(set) var deadline: Date?
    public private(set) var retryAt: Date?
    public private(set) var failureCount = 0
    public init(deadline: Date? = nil) { self.deadline = deadline }
    public mutating func start(_ deadline: Date?) {
        self.deadline = deadline
        retryAt = nil
        failureCount = 0
    }
    public func due(at now: Date, originalRunning: Bool) -> Bool {
        !originalRunning && deadline.map { $0 <= now } == true && retryAt.map { $0 <= now } != false
    }
    public mutating func complete(succeeded: Bool, at now: Date) {
        if succeeded {
            start(nil)
        } else {
            failureCount = min(failureCount + 1, 5)
            retryAt = now.addingTimeInterval(min(300, 30 * pow(2, Double(failureCount - 1))))
        }
    }
}
