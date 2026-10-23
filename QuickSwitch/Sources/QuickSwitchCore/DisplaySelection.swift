import Foundation

public struct DisplayDescriptor: Identifiable, Equatable, Sendable {
    public let id: UInt32
    public let stableID: String?
    public let title: String
    public let sourceIndex: Int
    public init(id: UInt32, stableID: String?, title: String, sourceIndex: Int) {
        self.id = id
        self.stableID = stableID
        self.title = title
        self.sourceIndex = sourceIndex
    }
}

public struct DisplaySelection: Equatable, Sendable {
    public let displayID: UInt32?
    public let savedDisplayMissing: Bool

    /// Resolving a temporarily missing display never overwrites the saved preference.
    /// An explicit UUID remains authoritative; the source index applies only to legacy configurations.
    public static func resolve(
        displays: [DisplayDescriptor], savedStableID: String?, sourceIndex: Int, currentSelection: UInt32? = nil
    ) -> Self {
        if let savedStableID {
            if let saved = displays.first(where: { $0.stableID == savedStableID }) {
                return Self(displayID: saved.id, savedDisplayMissing: false)
            }
            return Self(
                displayID: nil, savedDisplayMissing: true)
        }
        if let currentSelection {
            let connected = displays.first { $0.id == currentSelection }
            return Self(displayID: connected?.id, savedDisplayMissing: connected == nil)
        }
        let source = displays.first { $0.sourceIndex == sourceIndex }
        return Self(
            displayID: source?.id, savedDisplayMissing: source == nil)
    }
}

public enum DisplayRollbackPolicy {
    /// Restore only the mode we applied to this same physical display. External changes win.
    public static func shouldRestore(
        savedStableID: String, currentStableID: String?, online: Bool,
        appliedModeID: Int32, currentModeID: Int32?
    ) -> Bool {
        online && currentStableID == savedStableID && currentModeID == appliedModeID
    }
}

public struct DisplayModeDescriptor: Identifiable, Equatable, Sendable {
    public let displayID: UInt32
    public let modeID: Int32
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let usable: Bool
    public var id: String { "\(displayID)-\(modeID)" }
    public var isHiDPI: Bool { pixelWidth > width || pixelHeight > height }
    public init(
        displayID: UInt32, modeID: Int32, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int,
        refreshRate: Double, usable: Bool = true
    ) {
        self.displayID = displayID
        self.modeID = modeID
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.usable = usable
    }
    public var title: String {
        var title = "\(width) × \(height)"
        if refreshRate > 0 {
            title += " · " + refreshRate.formatted(.number.precision(.fractionLength(0...2))) + " Hz"
        }
        if isHiDPI { title += " · HiDPI" }
        return title
    }
}

public enum DisplayModePolicy {
    public static func visibleModes(
        _ modes: [DisplayModeDescriptor], displayID: UInt32?, onlyHiDPI: Bool, currentModeID: Int32?
    ) -> [DisplayModeDescriptor] {
        var fingerprints: Set<String> = []
        return modes.filter {
            $0.displayID == displayID && $0.usable && $0.width > 0 && $0.height > 0
                && $0.pixelWidth > 0 && $0.pixelHeight > 0 && $0.refreshRate.isFinite && $0.refreshRate >= 0
                && (!onlyHiDPI || $0.isHiDPI || $0.modeID == currentModeID)
        }.sorted {
            // Keep the actual current mode when identical public modes have different I/O IDs.
            if ($0.modeID == currentModeID) != ($1.modeID == currentModeID) { return $0.modeID == currentModeID }
            return $0.modeID < $1.modeID
        }.filter {
            fingerprints.insert(
                "\($0.width):\($0.height):\($0.pixelWidth):\($0.pixelHeight):\($0.refreshRate.bitPattern)"
            ).inserted
        }.sorted {
            if $0.width != $1.width { return $0.width < $1.width }
            if $0.height != $1.height { return $0.height < $1.height }
            if $0.pixelWidth != $1.pixelWidth { return $0.pixelWidth < $1.pixelWidth }
            if $0.pixelHeight != $1.pixelHeight { return $0.pixelHeight < $1.pixelHeight }
            if $0.refreshRate != $1.refreshRate { return $0.refreshRate < $1.refreshRate }
            return $0.modeID < $1.modeID
        }
    }
}
