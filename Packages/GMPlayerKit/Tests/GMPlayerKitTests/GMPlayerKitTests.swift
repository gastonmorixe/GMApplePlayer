import AVFoundation
import XCTest
@testable import GMPlayerKit

/// Engine tests. The remux/probe cases need a real MKV; they look for the
/// project sample and skip gracefully when it is absent (e.g. CI), so the suite
/// is always runnable. Override the path with GM_TEST_MKV.
final class GMPlayerKitTests: XCTestCase {
    private var sampleMKV: String? {
        if let env = ProcessInfo.processInfo.environment["GM_TEST_MKV"],
           FileManager.default.fileExists(atPath: env) { return env }
        let fallback = NSString(string: "~/Movies/Dolby Vision Universe demo (4K HDR HEVC).mkv")
            .expandingTildeInPath
        return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }

    // MARK: Version

    func testFFmpegVersion() {
        XCTAssertEqual(GMRemuxer.ffmpegVersion, "8.1.1")
    }

    // MARK: Probe + AVFoundation-compat flags

    func testProbeReportsStreamsAndCompatFlags() throws {
        guard let mkv = sampleMKV else { throw XCTSkip("sample MKV not present") }
        let probe = try GMRemuxer.probeSync(mkv)

        XCTAssertEqual(probe.formatName.contains("matroska"), true)
        XCTAssertGreaterThan(probe.durationSeconds, 180)
        XCTAssertTrue(probe.hasPlayableVideo, "HEVC video must be AVF-compatible")
        XCTAssertTrue(probe.hasPlayableAudio, "AC-3/E-AC-3 audio must be AVF-compatible")

        // HEVC video present and flagged compatible.
        let video = probe.videoStreams.first
        XCTAssertEqual(video?.codecName, "hevc")
        XCTAssertEqual(video?.avfCompatible, true)

        // TrueHD must be present but flagged NOT AVF-compatible (the honest limit).
        let truehd = probe.audioStreams.first { $0.codecName == "truehd" }
        XCTAssertNotNil(truehd, "sample has a TrueHD track")
        XCTAssertEqual(truehd?.avfCompatible, false)
    }

    // MARK: Remux timing regression guard (the bug that caused ~10fps judder)

    func testRemuxProducesUniform23_976CFR() async throws {
        guard let mkv = sampleMKV else { throw XCTSkip("sample MKV not present") }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmtest-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }

        try await GMRemuxer.remux(input: mkv, outputURL: out)

        // AVFoundation must see a proper ~23.976 fps constant-frame-rate track.
        let asset = AVURLAsset(url: out)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let fps = try await track?.load(.nominalFrameRate) ?? 0
        XCTAssertEqual(
            Double(fps),
            23.976,
            accuracy: 0.05,
            "remux must preserve CFR cadence (regression guard for the DTS bug)"
        )

        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable, "remuxed output must be AVFoundation-playable")
    }

    // MARK: Auto track selection (EAC3 feature track over AC3 companion)

    func testAutoSelectionRemuxesCompatibleAudio() async throws {
        guard let mkv = sampleMKV else { throw XCTSkip("sample MKV not present") }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmtest-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }

        // Auto-select (-1/-1): must NOT pick the TrueHD track (incompatible);
        // the muxed audio must be one AVFoundation can play.
        try await GMRemuxer.remux(input: mkv, outputURL: out)

        let asset = AVURLAsset(url: out)
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        XCTAssertNotNil(audio, "an AVF-compatible audio track must be muxed")
        let formats = try await audio?.load(.formatDescriptions) ?? []
        XCTAssertFalse(formats.isEmpty)
    }
}
