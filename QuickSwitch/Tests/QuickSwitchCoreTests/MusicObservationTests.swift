import Foundation
import XCTest

@testable import QuickSwitchCore

@MainActor
final class MusicObservationTests: XCTestCase {
    private final class Transport: MusicPlaybackTransport {
        var states: [MusicPlayerChoice: MusicPlaybackState] = [.appleMusic: .playing, .spotify: .playing]
        var observationReads: [MusicPlayerChoice] = []
        var stateReads = 0
        var cancelledReads = 0
        var commands: [(MusicPlayerChoice, Bool)] = []
        var blockMusicRead = false
        var failPause = false
        func installed(_ player: MusicPlayerChoice) -> Bool { player != .automatic }
        func running(_ player: MusicPlayerChoice) -> Bool { player != .automatic }
        func state(_ player: MusicPlayerChoice, requestPermission: Bool) async -> MusicPlaybackState {
            stateReads += 1
            return states[player] ?? .unknown
        }
        func observation(_ player: MusicPlayerChoice) async -> MusicPlaybackObservation {
            observationReads.append(player)
            if blockMusicRead && player == .appleMusic {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { cancelledReads += 1 }
            }
            // Intentionally return an obsolete value even after cancellation. The controller must reject it.
            return MusicPlaybackObservation(
                state: .playing, metadata: MusicTrackMetadata(title: player.rawValue, artist: "Fixture"))
        }
        func setPlaying(_ enabled: Bool, player: MusicPlayerChoice) async throws {
            if failPause { throw ConfigurationError.invalid("Fixture denial") }
            commands.append((player, enabled))
            states[player] = enabled ? .playing : .paused
        }
    }

    private func wire(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    func testWireDecoderValidatesPlayerStateBoundsAndClearsNonplayingMetadata() throws {
        let data = try wire([
            "player": "spotify", "state": "playing", "status": "ready", "title": "A\nB", "artist": "C",
        ])
        let value = try MusicPlaybackObservation.decode(data, player: .spotify)
        XCTAssertEqual(value.metadata?.subtitle, "A B — C")
        XCTAssertThrowsError(try MusicPlaybackObservation.decode(data, player: .appleMusic))
        XCTAssertThrowsError(try MusicPlaybackObservation.decode(data, player: .automatic))
        for object: [String: Any] in [
            ["player": "spotify", "state": "playing", "status": "permissionDenied"],
            ["player": "spotify", "state": "unknown", "status": "ready"],
            ["player": "spotify", "state": "playing", "status": "ready", "title": 1],
            [
                "player": "spotify", "state": "playing", "status": "ready",
                "artist": String(repeating: "a", count: 1025),
            ],
        ] {
            XCTAssertThrowsError(try MusicPlaybackObservation.decode(wire(object), player: .spotify))
        }
        XCTAssertThrowsError(try MusicPlaybackObservation.decode(Data(repeating: 32, count: 16385), player: .spotify))
        let paused = try MusicPlaybackObservation.decode(
            wire(["player": "spotify", "state": "paused", "status": "ready", "title": "Old"]), player: .spotify)
        XCTAssertNil(paused.metadata)
        let denied = try MusicPlaybackObservation.decode(
            wire(["player": "spotify", "state": "unknown", "status": "permissionDenied"]), player: .spotify)
        XCTAssertEqual(denied.status, .permissionDenied)
        XCTAssertNil(denied.metadata)
    }

    func testClosingPanelCancelsOwnedReadAndRejectsLateMetadata() async {
        let transport = Transport()
        transport.blockMusicRead = true
        let controller = MusicPlaybackController(transport: transport)
        let oldRead = Task { await controller.read(.appleMusic) }
        while transport.observationReads.isEmpty { await Task.yield() }
        controller.cancelRead()
        let result = await oldRead.value
        XCTAssertNil(result.isOn)
        XCTAssertEqual(transport.cancelledReads, 1)
        XCTAssertNil(controller.observedPlayer)
        XCTAssertTrue(transport.commands.isEmpty)
    }

    func testSelectingAnotherPlayerCancelsOldGenerationWithoutReplacingNewSubtitle() async {
        let transport = Transport()
        transport.blockMusicRead = true
        let controller = MusicPlaybackController(transport: transport)
        let oldRead = Task { await controller.read(.appleMusic) }
        while transport.observationReads.isEmpty { await Task.yield() }
        let current = await controller.read(.spotify)
        let stale = await oldRead.value
        XCTAssertTrue(current.detail.contains("spotify"))
        XCTAssertNil(stale.isOn)
        XCTAssertEqual(controller.observedPlayer, .spotify)
        XCTAssertEqual(transport.cancelledReads, 1)
    }

    func testCancellingCallerPropagatesToOwnedRead() async {
        let transport = Transport()
        transport.blockMusicRead = true
        let controller = MusicPlaybackController(transport: transport)
        let read = Task { await controller.read(.appleMusic) }
        while transport.observationReads.isEmpty { await Task.yield() }
        read.cancel()
        let result = await read.value
        XCTAssertNil(result.isOn)
        XCTAssertEqual(transport.cancelledReads, 1)
        XCTAssertNil(controller.observedPlayer)
    }

    func testStateOnlyReadNeverRequestsMetadata() async {
        let transport = Transport()
        let controller = MusicPlaybackController(transport: transport)
        let value = await controller.read(.spotify, includeMetadata: false)
        XCTAssertEqual(value.isOn, true)
        XCTAssertTrue(transport.observationReads.isEmpty)
        XCTAssertEqual(transport.stateReads, 1)
    }

    func testSelectionPausesKnownOldPlayerWithoutStartingNewOne() async throws {
        let transport = Transport()
        let controller = MusicPlaybackController(transport: transport)
        try await controller.prepareSelection(from: .spotify, to: .appleMusic)
        XCTAssertEqual(transport.commands.count, 1)
        XCTAssertEqual(transport.commands[0].0, .spotify)
        XCTAssertFalse(transport.commands[0].1)
        XCTAssertEqual(transport.states[.appleMusic], .playing)
        transport.commands.removeAll()
        transport.states[.spotify] = .unknown
        try await controller.prepareSelection(from: .spotify, to: .appleMusic)
        XCTAssertTrue(transport.commands.isEmpty)
        try await controller.prepareSelection(from: .automatic, to: .appleMusic)
        XCTAssertTrue(transport.commands.isEmpty)
    }

    func testFailedPausePropagatesRatherThanClaimingPlayerChanged() async {
        let transport = Transport()
        transport.failPause = true
        let controller = MusicPlaybackController(transport: transport)
        do {
            try await controller.prepareSelection(from: .spotify, to: .appleMusic)
            XCTFail("Expected pause denial")
        } catch {}
        XCTAssertTrue(transport.commands.isEmpty)
        XCTAssertEqual(transport.states[.spotify], .playing)
    }
}
