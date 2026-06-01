//
//  GMResourceLoaderDelegate.swift
//  Feeds AVPlayer a SINGLE fragmented-MP4 resource (NOT HLS) via a custom-scheme
//  AVURLAsset + AVAssetResourceLoaderDelegate. This keeps AVPlayer (and therefore
//  AVPlayerViewController and all AVKit chrome: scrubber, PiP, AirPlay, Now Playing,
//  tvOS focus) while DROPPING HLS and the loopback HTTP server entirely.
//
//  Why this is allowed (and HLS segments are not): the -12881 "custom url not
//  redirect" restriction is HLS-SEGMENT-specific. A resource loader MAY vend the
//  bytes of a single non-HLS resource (a progressive/fragmented .mp4). Apple's own
//  "Progressively supply media data" guidance + KTVHTTPCache/VLCKit do exactly this:
//    contentType = "public.mpeg-4" (the UTI, NOT "video/mp4")
//    isByteRangeAccessSupported = true + contentLength describe the virtual file
//    each AVAssetResourceLoadingDataRequest is answered with respond(with:)
//
//  The virtual file is: [init: ftyp+moov] ++ [seg0: moof+mdat] ++ [seg1] ++ ...
//  exactly the bytes the C engine already produces (gm_stream emits fragmented MP4
//  with empty_moov+default_base_moof+frag_keyframe; each fragment's tfdt is at its
//  absolute timeline position). moov is at the FRONT, so AVPlayer parses track info
//  on the first read and can begin decoding after ~one fragment, NOT a whole segment.
//
//  Assembly is LAZY + STREAMING: we mux only enough fragments to satisfy each byte
//  range AVPlayer asks for, respond incrementally as fragments are produced, and
//  stop the moment AVPlayer cancels (it cancels once its forward buffer is full).
//  So a remote source fetches only what is watched, never the whole file up front.
//
//  The legacy loopback/HLS engine remains available and selectable; see
//  GMStreamingEngine.makePlayback / GM_PLAYER_ENGINE.
//

import AVFoundation
import Foundation
import os

/// Custom URL scheme that routes an AVURLAsset's loads through our delegate.
/// AVFoundation only invokes the resource loader for non-standard schemes.
private let gmScheme = "gmstream"

/// Serves one fragmented-MP4 resource to AVPlayer by muxing fragments on demand.
public final class GMResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    private let session: GMStreamSession
    /// Delegate-callback queue (AVFoundation invokes us here; keep it responsive).
    private let queue = DispatchQueue(label: "com.gm.appleplayer.resourceloader")
    /// Where the (potentially long) muxing + responding runs, so the delegate queue
    /// stays free to deliver didCancel while we stream a request. CONCURRENT: a big
    /// "to-end" read must not block AVPlayer's structure-probing seek requests.
    private let work = DispatchQueue(label: "com.gm.appleplayer.resourceloader.work", attributes: .concurrent)
    private let log = Logger(subsystem: "com.gm.appleplayer", category: "resourceloader")

    private let segmentCount: Int
    private let initData: Data
    private let contentLengthEstimate: Int64

    /// LAZY single-fMP4 assembly. `assembled` grows as fragments are muxed ON DEMAND:
    /// initData ++ normalized seg0 ++ seg1 ++ ... AVPlayer requests byte ranges and we
    /// mux just enough to answer each one, so OPEN returns fast and only what is
    /// watched is fetched/muxed (mpv-like) instead of assembling the whole movie up
    /// front (which hung remote URLs for minutes). Guarded by `cond`; ONE serial muxer
    /// runs at a time (the `building` flag), so the buffer is append-only and race-free
    /// (a concurrent builder once corrupted the moof chain).
    private let cond = NSCondition()
    private var assembled: Data
    private var builtSegs = 0
    private var nextSeq: UInt32 = 1
    private var building = false
    private var muxFailed = false

    public init(session: GMStreamSession) throws {
        self.session = session
        self.segmentCount = session.segmentCount
        var initData = try session.initSegment()
        // The per-segment muxer's moov advertises only the FIRST segment's duration.
        // Patch mvhd/tkhd to full duration, zero per-track tkhd/mdhd (fragments define
        // the track timeline), so AVFoundation's reported duration is correct.
        Self.patchMoovDuration(&initData, fullSeconds: session.duration)
        self.initData = initData

        // Mux ONLY the init segment + the first fragment up front (fast). The first
        // fragment gives moov-at-front + a real bitrate sample for the size estimate.
        // Per-segment muxers reset mfhd sequence_number and emit a wrapped-negative
        // audio tfdt; normalizeFragments rewrites both so the concatenation is a valid
        // single fMP4. Remaining fragments are muxed lazily in serve().
        var data = initData
        var seq: UInt32 = 1
        var estimate = Int64(initData.count)
        if session.segmentCount > 0 {
            var seg0 = try session.segment(0)
            if !seg0.isEmpty {
                Self.normalizeFragments(&seg0, nextSequenceNumber: &seq)
                data.append(seg0)
                self.builtSegs = 1
                // Estimate total bytes from seg0's bitrate, biased slightly HIGH so the
                // declared contentLength never truncates real content (a read past the
                // true end returns clean EOF).
                let seg0Dur = max(0.001, session.segmentDuration(0))
                let bytesPerSec = Double(seg0.count) / seg0Dur
                estimate = Int64(Double(initData.count) + bytesPerSec * max(session.duration, seg0Dur) * 1.12)
            }
        }
        // The seg0-bitrate extrapolation badly under-estimates for 4K (a low-motion
        // opening segment is far below the average), and a SHORT contentLength makes
        // AVFoundation think the resource ends early and report a fraction of the real
        // duration (the "shows 37s" bug). The INPUT media size is a stream-copy upper
        // bound that is far more accurate; use the larger of the two. Over-declaring is
        // safe: a read past true EOF returns clean 0.
        if session.sourceTotalSize > 0 {
            estimate = max(estimate, session.sourceTotalSize)
        }
        self.nextSeq = seq
        self.assembled = data
        self.contentLengthEstimate = max(estimate, Int64(data.count))
        super.init()
    }

    /// Mux forward (serially, race-free) until `assembled` holds byte `targetEnd`, all
    /// segments are built, or muxing fails. Returns the current assembled length.
    /// Multiple serve() calls may enter; only one muxes at a time (others wait on cond).
    @discardableResult
    private func ensureBuilt(throughByte targetEnd: Int) -> Int {
        cond.lock()
        defer { cond.unlock() }
        while true {
            if assembled.count >= targetEnd || builtSegs >= segmentCount || muxFailed {
                return assembled.count
            }
            if building {
                cond.wait() // another thread is muxing the next segment; wait for it
                continue
            }
            // Claim the build slot and mux the next segment OUTSIDE the lock.
            building = true
            let idx = builtSegs
            var seq = nextSeq
            cond.unlock()
            var seg: Data?
            do {
                var s = try session.segment(idx)
                if !s.isEmpty { Self.normalizeFragments(&s, nextSequenceNumber: &seq) }
                seg = s
            } catch {
                log.error("lazy mux failed at segment \(idx): \(error.localizedDescription)")
                seg = nil
            }
            cond.lock()
            building = false
            if let seg, !seg.isEmpty {
                assembled.append(seg)
                builtSegs += 1
                nextSeq = seq
            } else {
                muxFailed = (seg == nil) // empty trailing segment is a clean end
                builtSegs = segmentCount // stop; we've reached the end (or a hard error)
            }
            cond.broadcast()
        }
    }

    /// Rewrite a freshly-muxed segment's fragment headers so the concatenation is a
    /// valid single fMP4: every `moof`'s `mfhd` sequence_number becomes the next global
    /// value, and any wrapped-negative `tfdt` baseMediaDecodeTime is clamped to 0.
    /// Walks top-level boxes; descends only moof -> (mfhd, traf -> tfdt).
    static func normalizeFragments(_ seg: inout Data, nextSequenceNumber: inout UInt32) {
        let n = seg.count
        func u32(_ o: Int) -> UInt32 {
            (UInt32(seg[o]) << 24) | (UInt32(seg[o + 1]) << 16) | (UInt32(seg[o + 2]) << 8) | UInt32(seg[o + 3])
        }
        func put32(_ o: Int, _ v: UInt32) {
            seg[o] = UInt8((v >> 24) & 0xFF)
            seg[o + 1] = UInt8((v >> 16) & 0xFF)
            seg[o + 2] = UInt8((v >> 8) & 0xFF)
            seg[o + 3] = UInt8(v & 0xFF)
        }
        /// Descend into a moof: fix its mfhd seq, and clamp any wrapped-negative tfdt.
        func fixMoof(_ start: Int, _ end: Int) {
            var i = start
            while i + 8 <= end {
                let sz = Int(u32(i))
                if sz < 8 { break }
                let type = String(bytes: seg[(i + 4) ..< (i + 8)], encoding: .ascii) ?? ""
                switch type {
                case "mfhd":
                    if i + 16 <= end { put32(i + 12, nextSequenceNumber)
                        nextSequenceNumber &+= 1
                    }
                case "traf":
                    fixMoof(i + 8, min(i + sz, end)) // tfdt lives inside traf
                case "tfdt":
                    // version 1 => u64 at +12; clamp if it is a wrapped-negative value.
                    if seg[i + 8] == 1, i + 20 <= end {
                        var v: UInt64 = 0
                        for k in 0 ..< 8 {
                            v = (v << 8) | UInt64(seg[i + 12 + k])
                        }
                        if v > (UInt64(1) << 63) {
                            for k in 0 ..< 8 {
                                seg[i + 12 + k] = 0
                            }
                        }
                    } else if seg[i + 8] == 0, i + 16 <= end {
                        // version 0 => u32; a value with the top bit set is wrapped-negative.
                        if u32(i + 12) > (UInt32(1) << 31) { put32(i + 12, 0) }
                    }
                default:
                    break
                }
                i += sz
            }
        }
        var i = 0
        var mfraRanges: [(Int, Int)] = []
        while i + 8 <= n {
            let sz = Int(u32(i))
            if sz < 8 { break }
            let type = String(bytes: seg[(i + 4) ..< (i + 8)], encoding: .ascii) ?? ""
            if type == "moof" {
                fixMoof(i + 8, min(i + sz, n))
            } else if type == "mfra" {
                // Each per-segment muxer appends a trailing `mfra` (Movie Fragment
                // Random Access) whose `tfra` offsets are relative to THIS segment's
                // start. Concatenated, those become garbage absolute offsets. AVPlayer
                // tries to use the trailing mfra to index the file and, finding it
                // wrong, falls back to walking every moof (the open-time forward scan
                // that makes huge files load forever). Strip these interior mfra; a
                // correct whole-file index is added once, at the end of assembly.
                mfraRanges.append((i, min(i + sz, n)))
            }
            i += sz
        }
        // Remove mfra ranges back-to-front so earlier offsets stay valid.
        for (lo, hi) in mfraRanges.reversed() where hi <= seg.count {
            seg.removeSubrange(lo ..< hi)
        }
    }

    /// Number of media segments muxed so far (for tests: proves lazy init does NOT
    /// assemble the whole movie up front).
    public var builtSegmentCount: Int {
        cond.lock()
        defer { cond.unlock() }
        return builtSegs
    }

    /// The exact bytes served to AVPlayer (init moov + all fragments). For tests and
    /// diagnostics: forces the full lazy build, then returns the complete stream so a
    /// decoder can verify the WHOLE movie, not just the first fragment.
    public var assembledBytes: Data {
        ensureBuilt(throughByte: Int.max)
        cond.lock()
        defer { cond.unlock() }
        return assembled
    }

    /// The content length declared to AVFoundation. Must be close to the real assembled
    /// size: too SHORT makes AVFoundation think the resource ends early and report a
    /// fraction of the real duration. (For tests.)
    public var declaredContentLength: Int64 {
        contentLengthEstimate
    }

    /// Patch every mvhd/tkhd/mdhd box in the moov so its 32-bit duration field is the
    /// full movie length (in that box's own timescale), instead of the single-segment
    /// duration the per-segment muxer wrote. Walks boxes; tolerant of layout.
    static func patchMoovDuration(_ data: inout Data, fullSeconds: Double) {
        guard fullSeconds > 0 else { return }
        let n = data.count
        func u32(_ o: Int) -> UInt32 {
            guard o + 4 <= n else { return 0 }
            return (UInt32(data[o]) << 24) | (UInt32(data[o + 1]) << 16) | (UInt32(data[o + 2]) << 8) | UInt32(data[o + 3])
        }
        func put32(_ o: Int, _ v: UInt32) {
            guard o + 4 <= n else { return }
            data[o] = UInt8((v >> 24) & 0xFF)
            data[o + 1] = UInt8((v >> 16) & 0xFF)
            data[o + 2] = UInt8((v >> 8) & 0xFF)
            data[o + 3] = UInt8(v & 0xFF)
        }
        func put64(_ o: Int, _ v: UInt64) {
            guard o + 8 <= n else { return }
            for k in 0 ..< 8 {
                data[o + k] = UInt8((v >> (8 * (7 - UInt64(k)))) & 0xFF)
            }
        }
        func scaled32(_ ts: UInt32) -> UInt32 {
            UInt32(min(Double(UInt32.max), fullSeconds * Double(ts)))
        }
        func scaled64(_ ts: UInt32) -> UInt64 {
            UInt64(min(Double(UInt64.max), fullSeconds * Double(ts)))
        }

        var movieTS: UInt32 = 0
        /// Per-box rewrite. mvhd is moov's first child, so movieTS is set before
        /// tkhd/mvex are visited. Correct fullbox offsets (v0): ts@+20, dur@+24.
        func patchBox(_ type: String, _ i: Int) {
            let ver = data[i + 8]
            switch type {
            case "elst": // zero edit segment_duration (else added to fragment timeline -> 2x)
                if u32(i + 12) >= 1 { if ver == 1 { put64(i + 16, 0) } else { put32(i + 16, 0) } }
            case "mvhd": // overall movie duration = full length (what the scrubber reports)
                if ver == 1 { movieTS = u32(i + 28)
                    put64(i + 32, scaled64(movieTS))
                } else { movieTS = u32(i + 20)
                    put32(i + 24, scaled32(movieTS))
                }
            case "mehd" where movieTS > 0: // movie-extends fragment_duration = full length
                if ver == 1 { put64(i + 12, scaled64(movieTS)) } else { put32(i + 12, scaled32(movieTS)) }
            case "tkhd", "mdhd": // per-track durations MUST be 0 (fragments define the timeline)
                let durOff = type == "tkhd" ? (ver == 1 ? i + 36 : i + 28) : (ver == 1 ? i + 32 : i + 24)
                if ver == 1 { put64(durOff, 0) } else { put32(durOff, 0) }
            default: break
            }
        }
        func scan(_ start: Int, _ end: Int) {
            var i = start
            while i + 8 <= end {
                let size = Int(u32(i))
                if size < 8 { break }
                let type = String(bytes: data[(i + 4) ..< (i + 8)], encoding: .ascii) ?? ""
                if ["moov", "trak", "mdia", "mvex", "edts"].contains(type) {
                    scan(i + 8, min(i + size, end))
                } else {
                    patchBox(type, i)
                }
                i += size
            }
        }
        scan(0, n)
    }

    /// Build a custom-scheme asset wired to this delegate. Retain the delegate for the
    /// lifetime of playback (AVAssetResourceLoader holds it weakly).
    public func makeAsset() -> AVURLAsset {
        let url = URL(string: "\(gmScheme)://stream/movie.mp4")!
        // PreferPreciseDurationAndTiming=true makes AVFoundation do the extra parsing
        // to determine the accurate duration of a fragmented MP4 up front (mehd/sidx),
        // instead of the default approximate path that latches a partial duration from
        // only the fragments buffered at readyToPlay (the "shows 37s" bug). Apple docs:
        // MPEG-4 provides sufficient timing info; this opts into reading it precisely.
        // NOTE: do NOT set AVURLAssetPreferPreciseDurationAndTimingKey: true here. It
        // makes AVFoundation scan the whole file for precise timing, which on a 41 GB /
        // 3152-fragment movie forces us to mux nearly the entire thing at open (the
        // "loads forever" hang). The default (approximate) timing is fine for playback;
        // correct duration comes from the accurate contentLength we declare.
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    // MARK: - AVAssetResourceLoaderDelegate

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = AVFileType.mp4.rawValue // == "public.mpeg-4"
            info.isByteRangeAccessSupported = true
            info.contentLength = contentLengthEstimate
            if #available(macOS 13.0, iOS 16.0, tvOS 16.0, *) {
                info.isEntireLengthAvailableOnDemand = false
            }
        }
        // Stream the data request off the delegate queue so cancellation is observable.
        work.async { [weak self] in self?.serve(loadingRequest) }
        return true
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // serve() polls loadingRequest.isCancelled and bails; nothing else to do.
    }

    // MARK: - Serve

    /// Answer one byte-range request, muxing fragments LAZILY until the requested
    /// window exists (or EOF). Race-free: the append-only buffer is grown by exactly
    /// one serial muxer (ensureBuilt); reads snapshot the needed slice under `cond`.
    /// This is what makes OPEN fast over a remote URL: we mux only what AVPlayer asks
    /// for, instead of assembling the whole movie before playback can start.
    private func serve(_ loadingRequest: AVAssetResourceLoadingRequest) {
        guard let dr = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return
        }
        let start = Int(dr.requestedOffset)
        let toEnd = dr.requestsAllDataToEndOfResource
        let reqLen = dr.requestedLength
        let debug = ProcessInfo.processInfo.environment["GM_LOADER_DEBUG"] != nil
        if debug {
            log.info("req off=\(start) len=\(reqLen) cur=\(dr.currentOffset) toEnd=\(toEnd)")
        }
        // CAP how much one request muxes. A `toEnd` request (AVFoundation asks for
        // "everything from offset") must NOT make us mux the whole movie: on a 41 GB /
        // 3152-segment file that is the "loads forever" hang. Serve a bounded window
        // then finishLoading(); AVPlayer immediately re-requests the next range, so it
        // drives the pace and we only ever mux a little ahead of the playhead. This is
        // how a normal HTTP server behaves (it returns the requested bytes, not the
        // whole file) and what keeps memory + CPU bounded.
        let chunkCap = 8 * 1024 * 1024
        var offset = max(start, Int(dr.currentOffset))
        let limit = toEnd ? offset + chunkCap : start + reqLen
        while !loadingRequest.isCancelled, offset < limit {
            let have = ensureBuilt(throughByte: min(limit, offset + chunkCap))
            if offset >= have { break } // can't produce more -> EOF for this resource
            let hi = min(limit, have)
            if hi > offset {
                cond.lock()
                let cap = min(hi, assembled.count)
                let slice = offset < cap ? assembled.subdata(in: offset ..< cap) : Data()
                cond.unlock()
                if slice.isEmpty { break }
                dr.respond(with: slice)
                offset += slice.count
            } else {
                break
            }
        }
        if debug { log.info("served up to off=\(offset)") }
        loadingRequest.finishLoading()
    }
}
