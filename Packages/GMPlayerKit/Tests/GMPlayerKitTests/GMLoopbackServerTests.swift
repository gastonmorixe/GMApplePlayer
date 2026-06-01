import AVFoundation
import Foundation
import XCTest
@testable import GMPlayerKit

/// Verifies the loopback HTTP server (the transport that replaced the
/// resource-loader dead end) actually serves the playlist + init + segments over
/// 127.0.0.1, with range support, AND that an AVPlayer fed the server URL reaches
/// readyToPlay with a decoded video track (the thing the resource loader could not
/// do: AVFoundation rejects loader-vended HLS segment bytes with -12881).
final class GMLoopbackServerTests: XCTestCase {
    private var sampleMKV: String? {
        if let env = ProcessInfo.processInfo.environment["GM_TEST_MKV"],
           FileManager.default.fileExists(atPath: env) { return env }
        let fallback = NSString(string: "~/Movies/Dolby Vision Universe demo (4K HDR HEVC).mkv")
            .expandingTildeInPath
        return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }

    private func get(_ url: URL, range: String? = nil) throws -> (Int, Data) {
        var req = URLRequest(url: url)
        if let range { req.setValue(range, forHTTPHeaderField: "Range") }
        var status = -1
        var body = Data()
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            body = data ?? Data()
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        return (status, body)
    }

    func testServesPlaylistInitAndSegments() throws {
        guard let mkv = sampleMKV else { throw XCTSkip("sample MKV not present") }
        let session = try GMStreamSession(source: XCTUnwrap(GMFileByteSource(path: mkv)))
        let server = try GMLoopbackServer(session: session)
        let base = try server.start()
        defer { server.stop() }
        XCTAssertGreaterThan(server.port, 0)
        XCTAssertEqual(base.host, "127.0.0.1")

        // Playlist
        let (s1, pl) = try get(base.appendingPathComponent("index.m3u8"))
        XCTAssertEqual(s1, 200)
        let plText = String(decoding: pl, as: UTF8.self)
        XCTAssertTrue(plText.contains("#EXTM3U"))
        XCTAssertTrue(plText.contains("init.mp4"))
        XCTAssertTrue(plText.contains("http://127.0.0.1:\(server.port)/seg0.m4s"))

        // Init segment (ftyp...)
        let (s2, initSeg) = try get(base.appendingPathComponent("init.mp4"))
        XCTAssertEqual(s2, 200)
        XCTAssertEqual(String(decoding: initSeg[4 ..< 8], as: UTF8.self), "ftyp")

        // Segment 0 (moof...)
        let (s3, seg0) = try get(base.appendingPathComponent("seg0.m4s"))
        XCTAssertEqual(s3, 200)
        XCTAssertGreaterThan(seg0.count, 10000)
        XCTAssertEqual(String(decoding: seg0[4 ..< 8], as: UTF8.self), "moof")

        // Range request -> 206 + correct length
        let (s4, part) = try get(base.appendingPathComponent("init.mp4"), range: "bytes=0-99")
        XCTAssertEqual(s4, 206)
        XCTAssertEqual(part.count, 100)
    }

    func testAVPlayerReachesReadyToPlay() throws {
        guard let mkv = sampleMKV else { throw XCTSkip("sample MKV not present") }
        let playback = try GMStreamingEngine.makePlayback(input: mkv)
        let item = AVPlayerItem(asset: playback.asset)
        let player = AVPlayer(playerItem: item)
        player.play()

        // Poll up to 8s for readyToPlay (status 1). The resource-loader path failed
        // here with -12881; the loopback server reaches readyToPlay.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, item.status == .unknown {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(item.status, .readyToPlay, "loopback-served HLS must reach readyToPlay (error: \(String(describing: item.error)))")
        withExtendedLifetime(playback) {}
    }

    /// Loopback must stream LAZILY: reaching readyToPlay should serve only a handful of
    /// segments, not the whole movie. This is the property that makes a 40-80 GB file
    /// start instantly (the resource loader, by contrast, had AVFoundation walk the
    /// whole file at open). Uses the diagnostic servedSegments counter.
    func testLoopbackStreamsLazily() throws {
        guard let mkv = sampleMKV else { throw XCTSkip("sample MKV not present") }
        let playback = try GMStreamingEngine.makePlayback(input: mkv, preference: .loopback)
        XCTAssertTrue(playback.isLoopback, "preference .loopback must select the loopback engine")
        let item = AVPlayerItem(asset: playback.asset)
        let player = AVPlayer(playerItem: item)
        player.play()

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, item.status == .unknown {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(item.status, .readyToPlay)
        // Lazy: only a small prefix of segments fetched to start. Allow generous slack
        // but assert it is far below the total (the whole-movie walk would be N == total).
        XCTAssertLessThan(
            playback.loopbackServedSegments,
            max(20, playback.segmentCount / 4),
            "loopback should fetch only a few segments to start, not the whole movie"
        )
        XCTAssertGreaterThan(playback.segmentCount, 0)
        withExtendedLifetime(playback) {}
    }
}
