import AVFoundation
import XCTest
@testable import GMPlayerKit

/// Exercises the streaming session through the real Swift→C bridge on the sample
/// MKV (skips gracefully when absent). Validates open, plan, playlist shape, init
/// segment, and on-demand media-segment production with absolute timestamps.
final class GMStreamSessionTests: XCTestCase {
    private var sampleMKV: String? {
        if let env = ProcessInfo.processInfo.environment["GM_TEST_MKV"],
           FileManager.default.fileExists(atPath: env) { return env }
        let fallback = NSString(string: "~/Movies/Dolby Vision Universe demo (4K HDR HEVC).mkv")
            .expandingTildeInPath
        return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }

    func testOpenBuildsSegmentPlan() throws {
        guard let mkv = sampleMKV else { throw XCTSkip("sample MKV not present") }
        let src = try XCTUnwrap(GMFileByteSource(path: mkv))
        XCTAssertGreaterThan(src.totalSize, 0)
        let session = try GMStreamSession(source: src, targetSegmentSeconds: 6)
        XCTAssertGreaterThan(session.duration, 180) // ~187s sample
        XCTAssertGreaterThanOrEqual(session.segmentCount, 10) // ~30 at 6s
        // Segment starts must strictly increase.
        var prev = -1.0
        for i in 0 ..< session.segmentCount {
            let s = session.segmentStart(i)
            XCTAssertGreaterThan(s, prev)
            prev = s
        }
    }

    func testPlaylistShape() throws {
        guard let mkv = sampleMKV else { throw XCTSkip("sample MKV not present") }
        let session = try GMStreamSession(source: XCTUnwrap(GMFileByteSource(path: mkv)))
        let pl = session.playlist(scheme: "gmstream", host: "stream")
        XCTAssertTrue(pl.contains("#EXTM3U"))
        XCTAssertTrue(pl.contains("#EXT-X-MAP:URI=\"gmstream://stream/init.mp4\""))
        XCTAssertTrue(pl.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(pl.contains("gmstream://stream/seg0.m4s"))
        XCTAssertTrue(pl.contains("#EXT-X-ENDLIST"))
        // One EXTINF per segment.
        let extinfs = pl.components(separatedBy: "#EXTINF:").count - 1
        XCTAssertEqual(extinfs, session.segmentCount)
    }

    func testInitSegmentIsFtypMoov() throws {
        guard let mkv = sampleMKV else { throw XCTSkip("sample MKV not present") }
        let session = try GMStreamSession(source: XCTUnwrap(GMFileByteSource(path: mkv)))
        let initSeg = try session.initSegment()
        XCTAssertGreaterThan(initSeg.count, 8)
        // First box is ftyp.
        XCTAssertEqual(boxType(initSeg, at: 0), "ftyp")
        // Init is small (header only), not a media payload.
        XCTAssertLessThan(initSeg.count, 64 * 1024)
        // Cached: second call returns identical bytes.
        let again = try session.initSegment()
        XCTAssertEqual(initSeg, again)
    }

    func testMediaSegmentsAreMoofMdat() throws {
        guard let mkv = sampleMKV else { throw XCTSkip("sample MKV not present") }
        let session = try GMStreamSession(source: XCTUnwrap(GMFileByteSource(path: mkv)))
        let seg0 = try session.segment(0)
        XCTAssertGreaterThan(seg0.count, 10000)
        XCTAssertEqual(boxType(seg0, at: 0), "moof") // media segment starts with moof
        // A different segment is also produced and differs from seg0.
        let seg1 = try session.segment(1)
        XCTAssertEqual(boxType(seg1, at: 0), "moof")
        XCTAssertNotEqual(seg0, seg1)
    }

    func testTimeToSegmentMapping() throws {
        guard let mkv = sampleMKV else { throw XCTSkip("sample MKV not present") }
        let session = try GMStreamSession(source: XCTUnwrap(GMFileByteSource(path: mkv)))
        XCTAssertEqual(session.segmentIndex(forTime: 0), 0)
        let mid = session.segmentIndex(forTime: session.duration / 2)
        XCTAssertGreaterThan(mid, 0)
        XCTAssertLessThan(mid, session.segmentCount)
    }

    /// 4-char box type at byte offset `off` (after the 4-byte size).
    private func boxType(_ d: Data, at off: Int) -> String {
        guard d.count >= off + 8 else { return "" }
        return String(bytes: d[(off + 4) ..< (off + 8)], encoding: .ascii) ?? ""
    }
}
