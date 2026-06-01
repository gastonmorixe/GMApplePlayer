import AVFoundation
import XCTest
@testable import GMPlayerKit

/// The loop toggle drives AVPlayer.actionAtItemEnd, and end-of-item looping is wired
/// through a seek-and-play (verified by the model owning the observer). These checks
/// don't need media: they assert the player-config side of looping.
@MainActor
final class GMPlayerModelLoopTests: XCTestCase {
    func testLoopDefaultsOff() {
        let model = GMPlayerModel(engine: FakeEngine())
        XCTAssertFalse(model.loops)
        XCTAssertEqual(model.player.actionAtItemEnd, .pause)
    }

    func testEnablingLoopSetsActionAtItemEndToNone() {
        let model = GMPlayerModel(engine: FakeEngine())
        model.loops = true
        XCTAssertEqual(model.player.actionAtItemEnd, .none)
        model.loops = false
        XCTAssertEqual(model.player.actionAtItemEnd, .pause)
    }
}

/// Minimal MediaEngine stand-in so the model builds without FFmpeg/media for these
/// player-config tests. None of its methods are exercised here.
private struct FakeEngine: MediaEngine {
    var backendVersion: String {
        "fake"
    }

    func probe(_: String) async throws -> GMProbeResult {
        throw GMRemuxError.probeFailed("unused")
    }

    func remux(
        input _: String,
        outputURL _: URL,
        videoStream _: Int32,
        audioStream _: Int32,
        progress _: ((Double) -> Bool)?
    ) async throws {}
}
