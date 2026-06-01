import CGMTimestamp
import XCTest

/// Pure timestamp-policy tests. No FFmpeg, no media file: the fixture is the real
/// first 4506 video packets of the sample MKV in DECODE order, captured from
/// libavformat's av_read_frame() via the engine's GM_TS_DEBUG dump (NOT ffprobe,
/// whose displayed dts is a clean reconstruction). The demuxer delivers dts == pts
/// for every packet, which is non-monotonic for the B-frame reorder, exactly the
/// input the remux must fix.
///
/// We replicate av_packet_rescale_ts (1/1000 -> 1/16000 is an exact x16) and run
/// the sequence through gm_ts_next, then assert the muxed stream has the four
/// properties a correct MKV->MP4 remux must have.
final class CGMTimestampTests: XCTestCase {
    private let NOPTS = Int64.min
    private let OUT_DEN: Int64 = 16000
    private let FPS_NUM: Int64 = 24000, FPS_DEN: Int64 = 1001 // 23.976 fps

    private func rescale(_ v: Int64) -> Int64 {
        v == NOPTS ? NOPTS : v * OUT_DEN / kSrcTBDen
    }

    /// Run the whole fixture through the CFR video ladder (lead = 2 frames,
    /// which covers this stream's reorder depth).
    private func runLadder(lead: Int64 = 2)
        -> (pts: [Int64], dts: [Int64], clamps: Int)
    {
        var st = gm_ts_state()
        gm_ts_init(&st, FPS_NUM, FPS_DEN, kOutTBNum, OUT_DEN, lead)
        var outPTS: [Int64] = [], outDTS: [Int64] = [], clamps = 0
        for p in kFixture {
            let r = gm_ts_next(&st, rescale(p.pts), rescale(p.dts), rescale(p.dur))
            outPTS.append(r.pts)
            outDTS.append(r.dts)
            if r.pts_clamped != 0 { clamps += 1 }
        }
        return (outPTS, outDTS, clamps)
    }

    // MARK: 1. Muxer requirement: DTS strictly increasing.

    func testDTSStrictlyMonotonic() {
        let out = runLadder()
        for i in 1 ..< out.dts.count {
            XCTAssertGreaterThan(
                out.dts[i],
                out.dts[i - 1],
                "DTS must strictly increase at packet \(i): \(out.dts[i - 1]) -> \(out.dts[i])"
            )
        }
    }

    // MARK: 2. Presentation cadence preserved (PTS never altered).

    func testPTSNeverClamped() {
        let out = runLadder()
        XCTAssertEqual(
            out.clamps,
            0,
            "no packet's PTS may be dragged forward; \(out.clamps) were clamped"
        )
    }

    func testOutputPTSEqualsRescaledInputPTS() {
        let out = runLadder()
        XCTAssertEqual(
            out.pts,
            kFixture.map { rescale($0.pts) },
            "every output PTS must equal its rescaled source PTS, in order"
        )
    }

    // MARK: 3. Real cadence: 23.976fps, deltas only the source {656,672}.

    func testFrameRateIs23_976() throws {
        let out = runLadder()
        let sorted = out.pts.sorted()
        let avgTicks = try Double(XCTUnwrap(sorted.last) - sorted.first!) / Double(sorted.count - 1)
        let fps = Double(OUT_DEN) / avgTicks
        XCTAssertEqual(
            fps,
            23.976,
            accuracy: 0.01,
            "presentation cadence must be 23.976fps; got \(fps)fps"
        )
    }

    func testPTSDeltasAreOnlyTheSourceCadence() {
        let out = runLadder()
        let sorted = out.pts.sorted()
        var seen = Set<Int64>()
        for i in 1 ..< sorted.count {
            seen.insert(sorted[i] - sorted[i - 1])
        }
        XCTAssertEqual(
            seen,
            [656, 672],
            "presentation deltas must be exactly the source cadence {656,672}; got \(seen.sorted())"
        )
    }

    // MARK: 4. The ladder leads PTS: dts <= pts for every packet.

    func testDTSNeverExceedsPTS() {
        let out = runLadder()
        for i in 0 ..< out.dts.count {
            XCTAssertLessThanOrEqual(
                out.dts[i],
                out.pts[i],
                "dts must not exceed pts at packet \(i): dts=\(out.dts[i]) pts=\(out.pts[i])"
            )
        }
    }

    func testDTSDeltasMatchSourceCadence() {
        // Decode-order DTS is the uniform ladder: deltas are the same {656,672}
        // mix (667.3 ticks avg), never the bunched 1-tick steps of the old bug.
        let out = runLadder()
        var seen = Set<Int64>()
        for i in 1 ..< out.dts.count {
            seen.insert(out.dts[i] - out.dts[i - 1])
        }
        XCTAssertTrue(
            seen.isSubset(of: [666, 667, 668]),
            "decode-order DTS deltas must be the uniform ~667-tick step; got \(seen.sorted())"
        )
    }

    // MARK: 5. Audio path: preserve already-monotonic dts, bump only on collision.

    func testAudioPreservesMonotonicDTS() {
        var st = gm_ts_state()
        gm_ts_init(&st, 0, 0, kOutTBNum, OUT_DEN, 0) // fps_num=0 => audio path
        let pts: [Int64] = [0, 1024, 2048, 3072, 4096]
        var outDTS: [Int64] = []
        for p in pts {
            let r = gm_ts_next(&st, p, p, 1024) // audio: dts == pts, monotonic
            outDTS.append(r.dts)
        }
        XCTAssertEqual(outDTS, pts, "monotonic audio dts must pass through unchanged")
    }

    func testCollisionGuardBumpsEqualDTS() {
        var st = gm_ts_state()
        gm_ts_init(&st, 0, 0, kOutTBNum, OUT_DEN, 0)
        _ = gm_ts_next(&st, 100, 100, 10)
        let r = gm_ts_next(&st, 100, 100, 10) // duplicate dts
        XCTAssertEqual(r.dts, 101, "a colliding dts must be bumped to last+1")
    }
}
