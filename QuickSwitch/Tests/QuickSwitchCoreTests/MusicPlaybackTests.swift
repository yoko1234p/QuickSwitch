import Foundation
import XCTest

@testable import QuickSwitchCore

@MainActor
final class MusicPlaybackTests: XCTestCase {
    private final class Transport: MusicPlaybackTransport {
        var installations: Set<MusicPlayerChoice> = [.appleMusic, .spotify]
        var processes: Set<MusicPlayerChoice> = []
        var states: [MusicPlayerChoice: MusicPlaybackState] = [:]
        var commands: [(MusicPlayerChoice, Bool)] = []
        var reads: [(MusicPlayerChoice, Bool)] = []
        var commandFailure = false
        var ignoreCommand = false
        func installed(_ player: MusicPlayerChoice) -> Bool { installations.contains(player) }
        func running(_ player: MusicPlayerChoice) -> Bool { processes.contains(player) }
        func state(_ player: MusicPlayerChoice, requestPermission: Bool) async -> MusicPlaybackState {
            reads.append((player, requestPermission))
            return processes.contains(player) ? states[player] ?? .unknown : .notRunning
        }
        func setPlaying(_ enabled: Bool, player: MusicPlayerChoice) async throws {
            commands.append((player, enabled))
            if commandFailure { throw ConfigurationError.invalid("fixture denied") }
            if !ignoreCommand {
                processes.insert(player)
                states[player] = enabled ? .playing : .paused
            }
        }
    }

    func testExplicitPlayAndPauseRemainIdempotent() async throws {
        let transport = Transport()
        transport.processes = [.appleMusic]
        transport.states[.appleMusic] = .playing
        let controller = MusicPlaybackController(transport: transport)
        try await controller.set(true, choice: .appleMusic)
        XCTAssertTrue(transport.commands.isEmpty)
        try await controller.set(false, choice: .appleMusic)
        try await controller.set(false, choice: .appleMusic)
        XCTAssertEqual(transport.commands.count, 1)
        XCTAssertFalse(transport.commands[0].1)
        XCTAssertEqual(transport.states[.appleMusic], .paused)
        try await controller.set(true, choice: .appleMusic)
        XCTAssertEqual(transport.states[.appleMusic], .playing)
    }

    func testPauseNeverLaunchesAnAbsentPlayerOrControlsOtherPlayer() async throws {
        let transport = Transport()
        transport.processes = [.spotify]
        transport.states[.spotify] = .playing
        let controller = MusicPlaybackController(transport: transport)
        try await controller.set(false, choice: .appleMusic)
        XCTAssertTrue(transport.commands.isEmpty)
        XCTAssertEqual(transport.states[.spotify], .playing)
        XCTAssertFalse(transport.processes.contains(.appleMusic))
    }

    func testExplicitSelectionWinsOverAnotherRunningPlayer() async throws {
        let transport = Transport()
        transport.processes = [.spotify]
        transport.states[.spotify] = .playing
        let controller = MusicPlaybackController(transport: transport)
        XCTAssertEqual(controller.selectedPlayer(.automatic), .spotify)
        try await controller.set(true, choice: .appleMusic)
        XCTAssertEqual(transport.commands.first?.0, .appleMusic)
        transport.installations.remove(.appleMusic)
        XCTAssertNil(controller.selectedPlayer(.appleMusic))
        do {
            try await controller.set(true, choice: .appleMusic)
            XCTFail("Missing selected app must not silently fall back")
        } catch { XCTAssertEqual(transport.commands.count, 1) }
    }

    func testReadOnlyStateDoesNotRequestPermissionOrLaunchApp() async {
        let transport = Transport()
        transport.processes = [.spotify]
        let controller = MusicPlaybackController(transport: transport)
        let state = await controller.read(.spotify)
        XCTAssertNil(state.isOn)
        XCTAssertTrue(transport.commands.isEmpty)
        XCTAssertTrue(transport.reads.allSatisfy { !$0.1 })
        let inactive = await controller.read(.appleMusic)
        XCTAssertEqual(inactive.isOn, false)
        XCTAssertFalse(transport.processes.contains(.appleMusic))
    }

    func testUnknownStateUsesExplicitCommandAndVerifiesReadback() async throws {
        let transport = Transport()
        transport.processes = [.spotify]
        let controller = MusicPlaybackController(transport: transport)
        try await controller.set(false, choice: .spotify)
        XCTAssertEqual(transport.commands.count, 1)
        XCTAssertEqual(transport.commands.first?.1, false)
        XCTAssertEqual(transport.states[.spotify], .paused)
        XCTAssertTrue(transport.reads.last?.1 == true)
    }

    func testFailedOrUnverifiedCommandNeverClaimsSuccessAndCanRetry() async throws {
        let transport = Transport()
        transport.processes = [.appleMusic]
        transport.states[.appleMusic] = .paused
        transport.commandFailure = true
        let controller = MusicPlaybackController(transport: transport)
        do {
            try await controller.set(true, choice: .appleMusic)
            XCTFail("Expected denial")
        } catch {}
        transport.commandFailure = false
        transport.ignoreCommand = true
        do {
            try await controller.set(true, choice: .appleMusic)
            XCTFail("Expected readback failure")
        } catch {}
        XCTAssertEqual(transport.states[.appleMusic], .paused)
        transport.ignoreCommand = false
        try await controller.set(true, choice: .appleMusic)
        XCTAssertEqual(transport.states[.appleMusic], .playing)
    }

    func testCancelledRequestDoesNotIssuePlaybackCommand() async {
        let transport = Transport()
        let controller = MusicPlaybackController(transport: transport)
        let task = Task { try await controller.set(true, choice: .appleMusic) }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {}
        XCTAssertTrue(transport.commands.isEmpty)
    }

    func testSourceLocalizedPlayerNamesAndConservativeUpgrade() throws {
        for name in ["Music", "音樂", "音乐", "Spotify"] {
            let archive = try PropertyListSerialization.data(
                fromPropertyList: ["play-music-current-player": name], format: .binary, options: 0)
            var imported = try OneSwitchImporter.translate(rows: [], preferences: archive, sourceVersion: "fixture")
            XCTAssertEqual(imported.musicPlayerChoice, name == "Spotify" ? .spotify : .appleMusic)
            XCTAssertEqual(imported.migration?.translatedPreferenceCount, 1)
            imported.musicPlayerChoice = nil  // Simulate the previous importer.
            imported.migration?.translatedPreferenceCount = 0
            imported.migration?.untranslatedPreferenceKeys = ["play-music-current-player"]
            let upgraded = OneSwitchImporter.upgradingPreservedImport(imported)
            XCTAssertNotNil(upgraded.musicPlayerChoice)
            XCTAssertEqual(upgraded.migration?.translatedPreferenceCount, 1)
            XCTAssertEqual(upgraded.importedPreferences, archive)
            XCTAssertEqual(upgraded.migration?.sourceFingerprint, imported.migration?.sourceFingerprint)
            imported.musicPlayerChoice = .automatic  // An explicit own choice belongs to the user.
            XCTAssertEqual(OneSwitchImporter.upgradingPreservedImport(imported).musicPlayerChoice, .automatic)
        }
        for unknown: Any in ["Future Player", 1, ["name": "Spotify"]] {
            let archive = try PropertyListSerialization.data(
                fromPropertyList: ["play-music-current-player": unknown], format: .binary, options: 0)
            let imported = try OneSwitchImporter.translate(rows: [], preferences: archive, sourceVersion: "fixture")
            XCTAssertNil(imported.musicPlayerChoice)
            XCTAssertTrue(imported.migration?.untranslatedPreferenceKeys.contains("play-music-current-player") == true)
            XCTAssertEqual(imported.importedPreferences, archive)
        }
    }

    func testLegacyKeyboardTimeoutDefaultsAndMalformedValuesAreRejected() throws {
        var config = AppConfiguration()
        XCTAssertEqual(config.effectiveKeyboardLockSeconds, 120)
        let roundtrip = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertNil(roundtrip.keyboardLockSeconds)
        XCTAssertEqual(roundtrip.effectiveKeyboardLockSeconds, 120)
        for timeout in [0, 4.9, 601, Double.nan, .infinity] {
            config.keyboardLockSeconds = timeout
            XCTAssertThrowsError(try ConfigurationValidation.validate(config))
        }
    }
}
