import XCTest
import CGMStream

/// Pure tests for the segmentation plan (gm_plan.*). No FFmpeg, no network, no
/// media file: just the keyframe-grouping and time->segment math that decides how
/// the on-demand HLS fMP4 segments tile the timeline.
final class CGMPlanTests: XCTestCase {

    /// Build a plan and return the segment start times.
    private func plan(_ kf: [Double], duration: Double, target: Double) -> [Double] {
        var starts = [Double](repeating: 0, count: 4096)
        let n = kf.withUnsafeBufferPointer { kfp in
            gm_plan_segments(kfp.baseAddress, Int32(kf.count), duration, target,
                             &starts, 4096)
        }
        XCTAssertGreaterThanOrEqual(n, 1, "plan must produce at least one segment")
        return Array(starts.prefix(Int(n)))
    }

    // Keyframes every ~2s for ~60s; 6s target -> ~10 segments, each >= 6s, aligned.
    func testGroupsKeyframesIntoTargetSizedSegments() {
        let kf = stride(from: 0.0, through: 58.0, by: 2.0).map { $0 }   // 0,2,...,58
        let starts = plan(kf, duration: 60.0, target: 6.0)

        XCTAssertEqual(starts.first, 0.0, "first segment starts at 0")
        // Every boundary must be one of the real keyframe times.
        for s in starts { XCTAssertTrue(kf.contains(where: { abs($0 - s) < 1e-9 }),
                                        "boundary \(s) must be a keyframe") }
        // Every segment except possibly the last must be >= target.
        for i in 1..<starts.count {
            XCTAssertGreaterThanOrEqual(starts[i] - starts[i - 1], 6.0 - 1e-9,
                                        "segment \(i-1) shorter than target")
        }
        XCTAssertGreaterThanOrEqual(starts.count, 7)
        XCTAssertLessThanOrEqual(starts.count, 10)
    }

    func testMonotonicStarts() {
        let kf = stride(from: 0.0, through: 100.0, by: 1.001).map { $0 }
        let starts = plan(kf, duration: 101.0, target: 6.0)
        for i in 1..<starts.count {
            XCTAssertGreaterThan(starts[i], starts[i - 1], "starts must strictly increase")
        }
    }

    func testTinyTailIsAbsorbed() {
        // Keyframes 0,6,12,18 and duration 18.5: the 0.5s tail after 18 must NOT
        // become its own segment (absorbed into the previous one).
        let kf = [0.0, 6.0, 12.0, 18.0]
        let starts = plan(kf, duration: 18.5, target: 6.0)
        XCTAssertFalse(starts.contains(where: { abs($0 - 18.0) < 1e-9 }),
                       "the 0.5s tail keyframe must not start its own segment")
    }

    func testTimeToIndex() {
        let starts: [Double] = [0, 6, 12, 18, 24]
        func idx(_ t: Double) -> Int {
            Int(starts.withUnsafeBufferPointer {
                gm_plan_time_to_index($0.baseAddress, Int32(starts.count), t)
            })
        }
        XCTAssertEqual(idx(-5), 0)     // clamps below
        XCTAssertEqual(idx(0), 0)
        XCTAssertEqual(idx(5.9), 0)
        XCTAssertEqual(idx(6), 1)
        XCTAssertEqual(idx(13.2), 2)
        XCTAssertEqual(idx(23.9), 3)
        XCTAssertEqual(idx(24), 4)
        XCTAssertEqual(idx(999), 4)    // clamps above
    }

    func testSegmentDuration() {
        let starts: [Double] = [0, 6, 12, 18]
        func dur(_ i: Int) -> Double {
            starts.withUnsafeBufferPointer {
                gm_plan_segment_duration($0.baseAddress, Int32(starts.count), 20.0, Int32(i))
            }
        }
        XCTAssertEqual(dur(0), 6, accuracy: 1e-9)
        XCTAssertEqual(dur(2), 6, accuracy: 1e-9)
        XCTAssertEqual(dur(3), 2, accuracy: 1e-9)   // last runs to duration (20-18)
    }

    func testSingleKeyframeSingleSegment() {
        let starts = plan([0.0], duration: 90.0, target: 6.0)
        XCTAssertEqual(starts, [0.0])
    }

    // MARK: Uniform fallback plan (used when the demuxer index is sparse)

    private func uniform(duration: Double, target: Double) -> [Double] {
        var starts = [Double](repeating: 0, count: 4096)
        let n = gm_plan_uniform(duration, target, &starts, 4096)
        XCTAssertGreaterThanOrEqual(n, 1)
        return Array(starts.prefix(Int(n)))
    }

    func testUniformGridCoversDuration() {
        let starts = uniform(duration: 100.0, target: 6.0)
        XCTAssertEqual(starts.first, 0.0)
        // 100/6 = 16.67 -> 17 segments (last is the short tail to 100).
        XCTAssertEqual(starts.count, 17)
        for i in 1..<starts.count {
            XCTAssertEqual(starts[i] - starts[i - 1], 6.0, accuracy: 1e-9)
        }
        XCTAssertLessThan(starts.last!, 100.0)
    }

    func testUniformExactMultiple() {
        let starts = uniform(duration: 18.0, target: 6.0)
        XCTAssertEqual(starts, [0.0, 6.0, 12.0])   // 18/6 = 3 exact segments
    }

    func testUniformShortMediaSingleSegment() {
        let starts = uniform(duration: 4.0, target: 6.0)
        XCTAssertEqual(starts, [0.0])
    }
}
