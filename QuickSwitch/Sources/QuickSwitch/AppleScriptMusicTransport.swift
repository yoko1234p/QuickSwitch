import AppKit
import QuickSwitchCore
import QuickSwitchNative

@MainActor
struct AppleScriptMusicTransport: MusicPlaybackTransport {
    let runner: CommandRunner
    private let reader = CommandRunner(maximumOutputBytes: 16384, capturesStandardError: false)
    func installed(_ player: MusicPlayerChoice) -> Bool {
        guard let bundle = player.bundleIdentifier else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil
    }
    func running(_ player: MusicPlayerChoice) -> Bool {
        guard let bundle = player.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains { !$0.isTerminated }
    }
    func state(_ player: MusicPlayerChoice, requestPermission: Bool) async -> MusicPlaybackState {
        await snapshot(player, includeMetadata: false).state
    }
    func observation(_ player: MusicPlayerChoice) async -> MusicPlaybackObservation {
        await snapshot(player, includeMetadata: true)
    }
    private func snapshot(_ player: MusicPlayerChoice, includeMetadata: Bool) async -> MusicPlaybackObservation {
        guard running(player) else { return MusicPlaybackObservation(state: .notRunning, status: .notRunning) }
        guard let executable = Bundle.main.executableURL, player != .automatic else {
            return MusicPlaybackObservation(state: .unknown, status: .unavailable)
        }
        let arguments = ["--probe-media-readonly", player.rawValue] + (includeMetadata ? [] : ["--state-only"])
        let result = await reader.run(executable.path, arguments, timeout: 4)
        guard result.succeeded,
            let observation = try? MusicPlaybackObservation.decode(Data(result.output.utf8), player: player)
        else { return MusicPlaybackObservation(state: .unknown, status: .unavailable) }
        return observation
    }
    func setPlaying(_ enabled: Bool, player: MusicPlayerChoice) async throws {
        guard let bundle = player.bundleIdentifier else { throw ConfigurationError.invalid(L10n.text("播放器無效")) }
        if !running(player) {
            guard enabled else { return }
            guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
                throw ConfigurationError.invalid(L10n.text("選定的播放器未安裝"))
            }
            try Task.checkCancellation()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: application, configuration: configuration)
            try Task.checkCancellation()
        }
        guard let executable = Bundle.main.executableURL else {
            throw ConfigurationError.invalid(L10n.text("未能啟動播放器控制"))
        }
        let result = await reader.run(
            executable.path, ["--control-media", player.rawValue, enabled ? "play" : "pause"], timeout: 20)
        struct Reply: Decodable {
            let success: Bool
            let reason: String?
        }
        guard result.succeeded, let reply = try? JSONDecoder().decode(Reply.self, from: Data(result.output.utf8)),
            reply.success
        else {
            try Task.checkCancellation()
            throw ConfigurationError.invalid(L10n.text("播放器未能完成操作；請檢查播放器及自動化權限。"))
        }
    }
}
