import Foundation

public enum MusicPlayerChoice: String, Codable, CaseIterable, Sendable {
    case automatic, appleMusic, spotify
    public var title: String {
        switch self {
        case .automatic: return L10n.text("自動選擇已開啟的播放器")
        case .appleMusic: return "Music"
        case .spotify: return "Spotify"
        }
    }
    public var bundleIdentifier: String? {
        switch self {
        case .automatic: return nil
        case .appleMusic: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }
    /// Actual source stores its player's localized display name, not an index or bundle identifier.
    /// These are the shipped English, Traditional Chinese and Simplified Chinese `music` values.
    public static func sourceValue(_ value: Any?) -> Self? {
        guard let name = value as? String else { return nil }
        switch name {
        case "Music", "音樂", "音乐": return .appleMusic
        case "Spotify": return .spotify
        default: return nil
        }
    }
}

public enum MusicPlaybackState: String, Codable, Equatable, Sendable {
    case notRunning, playing, paused, unknown
    public var isPlaying: Bool? {
        switch self {
        case .notRunning, .paused: return false
        case .playing: return true
        case .unknown: return nil
        }
    }
}

public struct MusicTrackMetadata: Equatable, Sendable {
    public let title: String
    public let artist: String
    public var subtitle: String { [title, artist].filter { !$0.isEmpty }.joined(separator: " — ") }
    public init?(title: String?, artist: String?) {
        let values = [title ?? "", artist ?? ""]
        guard values.allSatisfy({ $0.utf16.count <= 1024 && $0.utf8.count <= 4096 }) else { return nil }
        let cleaned = values.map {
            $0.components(separatedBy: CharacterSet.controlCharacters.union(.newlines)).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard cleaned.contains(where: { !$0.isEmpty }) else { return nil }
        self.title = cleaned[0]
        self.artist = cleaned[1]
    }
}

public struct MusicPlaybackObservation: Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case ready, notRunning, permissionDenied, unavailable }
    public let state: MusicPlaybackState
    public let status: Status
    public let metadata: MusicTrackMetadata?
    public init(state: MusicPlaybackState, status: Status = .ready, metadata: MusicTrackMetadata? = nil) {
        self.state = state
        self.status = status
        self.metadata = state == .playing ? metadata : nil
    }
    public static func decode(_ data: Data, player: MusicPlayerChoice) throws -> Self {
        struct Wire: Decodable {
            let player: MusicPlayerChoice
            let state: MusicPlaybackState
            let status: Status
            let title: String?
            let artist: String?
        }
        guard data.count <= 16384, player != .automatic else {
            throw ConfigurationError.invalid(L10n.text("播放器資料超出上限"))
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard wire.player == player,
            (wire.status == .ready && [.playing, .paused].contains(wire.state))
                || (wire.status == .notRunning && wire.state == .notRunning)
                || ([.permissionDenied, .unavailable].contains(wire.status) && wire.state == .unknown),
            [wire.title, wire.artist].compactMap({ $0 }).allSatisfy({ $0.utf16.count <= 1024 && $0.utf8.count <= 4096 })
        else { throw ConfigurationError.invalid(L10n.text("播放器資料格式無效")) }
        return Self(
            state: wire.state, status: wire.status,
            metadata: MusicTrackMetadata(title: wire.title, artist: wire.artist))
    }
}

@MainActor
public protocol MusicPlaybackTransport {
    func installed(_ player: MusicPlayerChoice) -> Bool
    func running(_ player: MusicPlayerChoice) -> Bool
    func state(_ player: MusicPlayerChoice, requestPermission: Bool) async -> MusicPlaybackState
    func observation(_ player: MusicPlayerChoice) async -> MusicPlaybackObservation
    func setPlaying(_ enabled: Bool, player: MusicPlayerChoice) async throws
}

extension MusicPlaybackTransport {
    public func observation(_ player: MusicPlayerChoice) async -> MusicPlaybackObservation {
        let value = await state(player, requestPermission: false)
        return MusicPlaybackObservation(
            state: value, status: value == .unknown ? .unavailable : value == .notRunning ? .notRunning : .ready)
    }
}

/// Explicit commands are idempotent; neither an absent player nor an unreadable state is a toggle.
@MainActor
public final class MusicPlaybackController {
    private let transport: any MusicPlaybackTransport
    private var changing = false
    private var readGeneration: UInt64 = 0
    private var readTask: Task<MusicPlaybackObservation, Never>?
    public private(set) var observedPlayer: MusicPlayerChoice?
    public init(transport: any MusicPlaybackTransport) { self.transport = transport }

    public func cancelRead() {
        readGeneration &+= 1
        readTask?.cancel()
        readTask = nil
        observedPlayer = nil
    }

    public func selectedPlayer(_ choice: MusicPlayerChoice) -> MusicPlayerChoice? {
        if choice != .automatic { return transport.installed(choice) ? choice : nil }
        let supported: [MusicPlayerChoice] = [.appleMusic, .spotify]
        return supported.first { transport.running($0) } ?? supported.first { transport.installed($0) }
    }

    public func read(_ choice: MusicPlayerChoice, includeMetadata: Bool = true) async -> SwitchState {
        cancelRead()
        let generation = readGeneration
        guard let player = selectedPlayer(choice) else {
            return .unavailable(
                choice == .automatic
                    ? L10n.text("未安裝 Music 或 Spotify")
                    : L10n.text("未安裝 %1$@；請在設定更改播放器", String(describing: choice.title)))
        }
        let task = Task { [transport] in
            if includeMetadata { return await transport.observation(player) }
            let state = await transport.state(player, requestPermission: false)
            return MusicPlaybackObservation(state: state, status: state == .unknown ? .unavailable : .ready)
        }
        readTask = task
        let observation = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard generation == readGeneration, !Task.isCancelled, !task.isCancelled else {
            return .unknown(L10n.text("播放器資料讀取已取消"))
        }
        readTask = nil
        observedPlayer = player
        switch observation.state {
        case .notRunning: return .toggle(false, L10n.text("%1$@ · 未開啟", String(describing: player.title)))
        case .playing:
            return .toggle(
                true, observation.metadata?.subtitle ?? L10n.text("%1$@ · 播放中；未有曲目資料", String(describing: player.title))
            )
        case .paused: return .toggle(false, L10n.text("%1$@ · 已暫停", String(describing: player.title)))
        case .unknown:
            return .unknown(
                observation.status == .permissionDenied
                    ? L10n.text("%1$@ · 需要自動化權限；操作時才要求", String(describing: player.title))
                    : L10n.text("%1$@ · 未能讀取播放狀態", String(describing: player.title)))
        }
    }

    public func installedPlayers() -> [MusicPlayerChoice] {
        [.appleMusic, .spotify].filter { transport.installed($0) }
    }

    /// Original source pauses its playing old selection, then selects the new player without autoplay.
    /// Use an explicit pause only after a fresh known playing state; never toggle unknown playback.
    public func prepareSelection(from old: MusicPlayerChoice, to new: MusicPlayerChoice) async throws {
        guard old != new, let previous = selectedPlayer(old), previous != selectedPlayer(new),
            transport.running(previous)
        else { return }
        try Task.checkCancellation()
        if await transport.state(previous, requestPermission: false) == .playing {
            try await set(false, choice: previous)
        }
    }

    public func set(_ desired: Bool?, choice: MusicPlayerChoice) async throws {
        guard !changing else { throw ConfigurationError.invalid(L10n.text("播放操作尚未完成")) }
        guard let player = selectedPlayer(choice) else { throw ConfigurationError.invalid(L10n.text("選定的播放器未安裝")) }
        changing = true
        defer { changing = false }
        try Task.checkCancellation()
        let before = await transport.state(player, requestPermission: false)
        let target = desired ?? before.isPlaying.map { !$0 } ?? true
        if before.isPlaying == target { return }
        // A pause command must never launch an app just to pause it.
        if !target && !transport.running(player) { return }
        try Task.checkCancellation()
        try await transport.setPlaying(target, player: player)
        for attempt in 0..<4 {
            try Task.checkCancellation()
            if await transport.state(player, requestPermission: true).isPlaying == target { return }
            if attempt < 3 { try await Task.sleep(nanoseconds: 150_000_000) }
        }
        throw ConfigurationError.invalid(
            L10n.text("已傳送 %1$@ 播放操作，但未能確認結果；請檢查播放器及自動化權限。", String(describing: player.title)))
    }
}
