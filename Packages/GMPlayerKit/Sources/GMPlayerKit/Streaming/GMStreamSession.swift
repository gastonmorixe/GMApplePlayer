//
//  GMStreamSession.swift
//  Swift wrapper over the CGMStream C engine: owns one gm_stream, builds the HLS
//  media playlist, and produces the init segment + media segments on demand.
//
//  All engine calls are serialized on an internal queue (the demuxer is stateful:
//  each segment seeks the shared input). The resource loader calls into this from
//  AVFoundation's loader queue; we hop onto our serial queue to do the muxing.
//

import AVFoundation
import CGMStream
import Foundation

/// Errors from the streaming engine.
public enum GMStreamError: Error, LocalizedError {
    case openFailed(String)
    case segmentFailed(String)
    public var errorDescription: String? {
        switch self {
        case let .openFailed(m): "Stream open failed: \(m)"
        case let .segmentFailed(m): "Segment failed: \(m)"
        }
    }
}

/// Owns a gm_stream and serves init/media segments. Thread-safe: every engine call
/// runs on `queue`.
public final class GMStreamSession {
    private var handle: OpaquePointer?
    private let bridge: GMSourceBridge
    private let queue = DispatchQueue(label: "com.gm.appleplayer.stream")

    public let duration: Double
    public let segmentCount: Int

    /// Color info from the demuxer's source codec parameters. The matroska demuxer
    /// often leaves the transfer function UNSPECIFIED for HEVC even when the source is
    /// HDR (PQ/HLG live in the SPS VUI), so `transfer` here may be 2 (unspecified) for a
    /// genuinely HDR file. `resolvedColor` recovers the real value via AVFoundation.
    public let color: ColorInfo

    /// All source tracks, read at open. Cheap (metadata only).
    public let tracks: [Track]
    /// Source index of the default video track (-1 if none).
    public let selectedVideoIndex: Int
    /// Source index of the default audio track (-1 if none).
    public let selectedAudioIndex: Int

    /// HDR detection that is correct on every engine, including HLS. The container's
    /// codec params can report the transfer function as unspecified for HDR HEVC, and
    /// AVFoundation does NOT expose per-track color for an HLS (m3u8) asset, so the HUD
    /// read "HDR = no" for genuinely HDR movies. We instead mux the init + first segment
    /// (already needed to start playback, so no extra work), hand those bytes to
    /// AVFoundation as a tiny temp asset, and read the video track's transfer function
    /// the way AVFoundation itself parses the HEVC SPS. Cached after first resolve.
    let resolvedLock = NSLock()
    var _resolvedColor: ColorInfo?

    /// The fully resolved color info: the source's format metadata (Dolby Vision /
    /// HDR10 / HDR10+ from coded side data) merged with the transfer function recovered
    /// via AVFoundation when the container left it unspecified. This is what the HDR
    /// inspector reads. Resolved (and cached) on first access.
    public var resolvedColor: ColorInfo {
        resolveColor()
    }

    /// True when the video is HDR (PQ/HLG transfer or a Dolby Vision config).
    public var isHDR: Bool {
        resolveColor().isHDR
    }

    /// A short transfer-function name (e.g. "SMPTE ST 2084 (PQ)").
    public var transferFunctionName: String {
        resolveColor().transferName
    }

    /// Total byte size of the INPUT media (-1 if unknown). The assembled fMP4 is a
    /// stream-copy of a subset of the input's tracks, so the input size is a good,
    /// safe UPPER bound for the assembled resource's content length, far more accurate
    /// than extrapolating from the first segment's bitrate (a low-motion opening
    /// segment badly under-estimates a 4K average, which made AVPlayer report a
    /// fraction of the real duration).
    public let sourceTotalSize: Int64

    /// Open the source and build the segment plan. `targetSegmentSeconds` ~= 6 is a
    /// good default for VOD HLS.
    public init(source: GMByteSource, targetSegmentSeconds: Double = 6.0) throws {
        self.bridge = GMSourceBridge(source)
        self.sourceTotalSize = source.totalSize
        var errbuf = [CChar](repeating: 0, count: 256)
        let src = bridge.cSource()
        guard let h = withExtendedLifetime(bridge, { gm_stream_open(src, targetSegmentSeconds, &errbuf, 256) }) else {
            throw GMStreamError.openFailed(String(cString: errbuf))
        }
        self.handle = h
        self.duration = gm_stream_duration(h)
        self.segmentCount = Int(gm_stream_segment_count(h))
        // Enumerate all source tracks for the picker (metadata only; cheap).
        var trackList: [Track] = []
        let count = Int(gm_stream_track_count(h))
        for i in 0 ..< count {
            var ti = gm_track_info()
            guard gm_stream_track_info(h, Int32(i), &ti) == 0, let kind = Track.Kind(rawValue: Int(ti.kind))
            else { continue }
            func cstr(_ tuple: some Any) -> String {
                withUnsafeBytes(of: tuple) { raw in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    let end = bytes.firstIndex(of: 0) ?? bytes.count
                    return String(decoding: bytes[0 ..< end], as: UTF8.self)
                }
            }
            trackList.append(Track(
                sourceIndex: Int(ti.src_index),
                kind: kind,
                codec: cstr(ti.codec),
                language: cstr(ti.language),
                title: cstr(ti.title),
                channels: Int(ti.channels),
                width: Int(ti.width),
                height: Int(ti.height),
                fpsNum: Int(ti.fps_num),
                fpsDen: Int(ti.fps_den),
                isDefault: ti.is_default != 0,
                avfCompatible: ti.avf_compatible != 0,
                isTextSubtitle: ti.is_text_sub != 0
            ))
        }
        self.tracks = trackList
        self.selectedVideoIndex = Int(gm_stream_selected_video(h))
        self.selectedAudioIndex = Int(gm_stream_selected_audio(h))

        var ci = gm_color_info()
        _ = gm_stream_color_info(h, &ci)
        self.color = ColorInfo(
            transfer: Int(ci.transfer),
            primaries: Int(ci.primaries),
            matrix: Int(ci.matrix),
            range: Int(ci.range),
            dolbyVision: ci.dolby_vision != 0,
            doviProfile: Int(ci.dovi_profile),
            hasMastering: ci.has_mastering != 0,
            hasHDR10Plus: ci.has_hdr10plus != 0
        )
    }

    deinit {
        if let h = handle { gm_stream_close(h) }
    }

    /// Start time (seconds) of segment `i`.
    public func segmentStart(_ i: Int) -> Double {
        queue.sync { handle.map { gm_stream_segment_start($0, Int32(i)) } ?? 0 }
    }

    /// Duration (seconds) of segment `i`.
    public func segmentDuration(_ i: Int) -> Double {
        queue.sync { handle.map { gm_stream_segment_duration($0, Int32(i)) } ?? 0 }
    }

    /// The ACTUAL video keyframe-aligned duration of segment `i` (video rendition EXTINF).
    public func realSegmentDuration(_ i: Int) -> Double {
        queue.sync { handle.map { gm_stream_real_segment_duration($0, Int32(i)) } ?? 0 }
    }

    /// The ACTUAL audio-frame-aligned duration of segment `i` for `source` (its EXTINF).
    public func realAudioSegmentDuration(source: Int, _ i: Int) -> Double {
        queue.sync { handle.map { gm_stream_real_audio_segment_duration($0, Int32(source), Int32(i)) } ?? 0 }
    }

    /// The segment index that contains playback time `t`.
    public func segmentIndex(forTime t: Double) -> Int {
        queue.sync { handle.map { Int(gm_stream_time_to_segment($0, t)) } ?? 0 }
    }

    /// Build the HLS VOD media playlist (init via EXT-X-MAP, one EXTINF per segment).
    /// Every URI uses the given scheme/host so AVFoundation routes all requests
    /// through the resource loader.
    public func playlist(scheme: String, host: String) -> String {
        queue.sync {
            guard let h = handle else { return "" }
            var maxDur = 0.0
            for i in 0 ..< segmentCount {
                maxDur = max(maxDur, gm_stream_segment_duration(h, Int32(i)))
            }
            var s = "#EXTM3U\n"
            s += "#EXT-X-VERSION:7\n"
            s += "#EXT-X-TARGETDURATION:\(Int(maxDur.rounded(.up)))\n"
            s += "#EXT-X-MEDIA-SEQUENCE:0\n"
            s += "#EXT-X-PLAYLIST-TYPE:VOD\n"
            s += "#EXT-X-INDEPENDENT-SEGMENTS\n"
            s += "#EXT-X-MAP:URI=\"\(scheme)://\(host)/init.mp4\"\n"
            for i in 0 ..< segmentCount {
                let d = gm_stream_segment_duration(h, Int32(i))
                s += "#EXTINF:\(String(format: "%.3f", d)),\n"
                s += "\(scheme)://\(host)/seg\(i).m4s\n"
            }
            s += "#EXT-X-ENDLIST\n"
            return s
        }
    }

    // ── Multivariant HLS (alternate audio renditions for the native picker) ─────
    //
    // The master lists the video variant plus an EXT-X-MEDIA per AVFoundation-playable
    // audio track. AVPlayer fetches only the SELECTED audio rendition's playlist +
    // segments, so non-default audio is never muxed unless the user picks it. Audio is
    // DEMUXED (video segments carry video only), required for the picker to appear.

    /// The HEVC/H.264 CODECS token for the master's video variant. AVPlayer is lenient
    /// here; the base fourcc is enough for it to select the variant.
    private var videoHLSCodec: String {
        guard let v = tracks.first(where: { $0.kind == .video }) else { return "hvc1" }
        switch v.codec {
        case "hevc": return "hvc1"
        case "h264": return "avc1"
        default: return "hvc1"
        }
    }

    /// Build the multivariant master playlist: the video variant + an EXT-X-MEDIA audio
    /// group (one rendition per playable audio track). Cheap; metadata only.
    public func masterPlaylist(scheme: String, host: String) -> String {
        let base = "\(scheme)://\(host)"
        let auds = audioRenditions
        var s = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"

        // Audio rendition group. Exactly one DEFAULT=YES (the engine's selected audio,
        // else the first). AUTOSELECT=YES so AVPlayer can pick by device language.
        // HLS requires UNIQUE NAMEs within a group; REMUX files often have several
        // identically-titled tracks (e.g. 3x "Surround 5.1"), so disambiguate dupes.
        let defaultIdx = auds.firstIndex { $0.sourceIndex == selectedAudioIndex } ?? 0
        var nameCounts: [String: Int] = [:]
        for a in auds {
            nameCounts[a.displayName, default: 0] += 1
        }
        var nameSeen: [String: Int] = [:]
        // All distinct audio codec tokens in the group (CODECS must cover every codec a
        // selected rendition might use, so the default's codec is always represented).
        var audioCodecTokens: [String] = []
        for a in auds where !audioCodecTokens.contains(a.hlsAudioCodec) {
            audioCodecTokens.append(a.hlsAudioCodec)
        }
        for (i, a) in auds.enumerated() {
            let isDefault = (i == defaultIdx)
            var name = a.displayName
            if (nameCounts[name] ?? 0) > 1 {
                nameSeen[name, default: 0] += 1
                name = "\(name) #\(nameSeen[name]!)"
            }
            var line = "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"\(m3uEscape(name))\""
            if !a.bcp47Language.isEmpty { line += ",LANGUAGE=\"\(a.bcp47Language)\"" }
            line += ",DEFAULT=\(isDefault ? "YES" : "NO"),AUTOSELECT=YES"
            // NB: CHANNELS is intentionally omitted. The container's channel count can
            // disagree with the decoded stream (e.g. E-AC-3 reporting 4 vs an actual
            // 7.1), which the HLS validator flags and AVPlayer rejects. CHANNELS is
            // optional, so leaving it off avoids a mismatch while the picker still works.
            line += ",URI=\"\(base)/audio/\(a.sourceIndex)/index.m3u8\"\n"
            s += line
        }

        // Subtitle rendition group (TYPE=SUBTITLES, WebVTT). Text subs only; image subs
        // (PGS/VobSub) are excluded by subtitleRenditions. AUTOSELECT=NO/DEFAULT=NO so subs
        // stay off until the user picks one (forced tracks could flip DEFAULT later).
        let subs = subtitleRenditions
        var subNameSeen: [String: Int] = [:]
        let subNameCounts = Dictionary(grouping: subs, by: { $0.displayName }).mapValues(\.count)
        for sub in subs {
            var name = sub.displayName
            if (subNameCounts[name] ?? 0) > 1 {
                subNameSeen[name, default: 0] += 1
                name = "\(name) #\(subNameSeen[name]!)"
            }
            var line = "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(m3uEscape(name))\""
            if !sub.bcp47Language.isEmpty { line += ",LANGUAGE=\"\(sub.bcp47Language)\"" }
            line += ",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO"
            line += ",URI=\"\(base)/subs/\(sub.sourceIndex)/index.m3u8\"\n"
            s += line
        }

        // The single video variant, linked to the audio group. CODECS lists video then
        // (one representative) audio codec; RESOLUTION + VIDEO-RANGE are REQUIRED for an
        // HEVC variant (mediastreamvalidator rejects without them) and a realistic
        // BANDWIDTH avoids the "measured exceeds declared" error.
        let codecs = ([videoHLSCodec] + audioCodecTokens).joined(separator: ",")
        let v = tracks.first { $0.kind == .video }
        // BANDWIDTH must be >= the MEASURED PEAK segment bitrate or mediastreamvalidator
        // flags "measured peak exceeds declared". We only know the AVERAGE cheaply
        // (size*8/duration), and remux peaks run ~1.5-2x average, so declare with healthy
        // headroom. Over-declaring on a single variant is harmless (no adaptation).
        let avg = (sourceTotalSize > 0 && duration > 0) ? Double(sourceTotalSize) * 8.0 / duration : 30_000_000
        let bw = max(8_000_000, Int(avg * 2.5))
        s += "#EXT-X-STREAM-INF:BANDWIDTH=\(bw),CODECS=\"\(codecs)\""
        if let v, v.width > 0, v.height > 0 { s += ",RESOLUTION=\(v.width)x\(v.height)" }
        // FRAME-RATE is REQUIRED on an HDR variant (mediastreamvalidator: "HDR
        // alternate is missing FRAME-RATE"); AVPlayer rejects the HDR stream without it.
        if let fr = v?.frameRate, fr > 0 { s += ",FRAME-RATE=\(String(format: "%.3f", fr))" }
        // VIDEO-RANGE must match the actual transfer. Use the RESOLVED color (which probes
        // via AVFoundation when the container left transfer unspecified), not the raw
        // C-open `color` (often UNSPECIFIED -> SDR), or we declare SDR on a PQ stream and
        // AVPlayer rejects the variant (-12927).
        let rc = resolvedColor
        s += ",VIDEO-RANGE=\(rc.isHDR ? (rc.isHLG ? "HLG" : "PQ") : "SDR")"
        if !auds.isEmpty { s += ",AUDIO=\"aud\"" }
        if !subs.isEmpty { s += ",SUBTITLES=\"subs\"" }
        s += "\n\(base)/video/index.m3u8\n"
        return s
    }

    // EXTINF uses the instant planned-grid duration. The "exact real per-segment span"
    // alternative mux-PRODUCES every segment to measure it (minutes on a 2-hour movie ->
    // AVPlayer times out, -1008/-12884). Apple's HLS spec only requires EXTINF <= target
    // duration, not byte-exact spans, and AVPlayer aligns demuxed renditions by absolute
    // tfdt anyway, so the plan grid is both correct and instant.

    /// Video-only media playlist (segments carry no audio).
    public func videoPlaylist(scheme: String, host: String) -> String {
        mediaPlaylist(prefix: "\(scheme)://\(host)/video", initName: "init.mp4")
    }

    /// Audio-only media playlist for the audio track at SOURCE index `source`.
    public func audioPlaylist(source: Int, scheme: String, host: String) -> String {
        mediaPlaylist(prefix: "\(scheme)://\(host)/audio/\(source)", initName: "init.mp4")
    }

    /// Shared media-playlist body. Every rendition (video + each audio) tiles on the SAME
    /// planned segment grid, so EXTINF is the planned per-segment duration. AVPlayer aligns
    /// the demuxed renditions by absolute tfdt, not by equal segment lengths.
    private func mediaPlaylist(prefix: String, initName: String) -> String {
        queue.sync {
            guard let h = handle else { return "" }
            var durs = [Double]()
            var maxDur = 0.0
            for i in 0 ..< segmentCount {
                let d = gm_stream_segment_duration(h, Int32(i))
                durs.append(d)
                maxDur = max(maxDur, d)
            }
            var s = "#EXTM3U\n#EXT-X-VERSION:7\n"
            s += "#EXT-X-TARGETDURATION:\(Int(maxDur.rounded(.up)))\n"
            s += "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n"
            s += "#EXT-X-MAP:URI=\"\(prefix)/\(initName)\"\n"
            for i in 0 ..< segmentCount {
                s += "#EXTINF:\(String(format: "%.5f", durs[i])),\n\(prefix)/seg\(i).m4s\n"
            }
            s += "#EXT-X-ENDLIST\n"
            return s
        }
    }

    private func m3uEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "'")
    }

    /// The fMP4 init segment (ftyp+moov) + the first media segment, both produced from
    /// ONE demux+mux pass over segment 0 and cached. Building them separately muxed
    /// seg0 twice, which over a slow remote origin doubled startup latency (two ~10s
    /// reads of the same first cluster). See makeUnit.
    private var cachedInit: Data?
    private var cachedSeg0: Data?

    public func initSegment() throws -> Data {
        try queue.sync {
            if let c = cachedInit { return c }
            try buildUnit0Locked()
            return cachedInit ?? Data()
        }
    }

    /// Media segment `i` (moof+mdat, absolute timestamps). Segment 0 is served from
    /// the cached single-pass unit so it is never muxed twice.
    public func segment(_ i: Int) throws -> Data {
        try queue.sync {
            guard let h = handle else { throw GMStreamError.segmentFailed("closed") }
            if i == 0 {
                if let c = cachedSeg0 { return c }
                try buildUnit0Locked()
                return cachedSeg0 ?? Data()
            }
            return try Self.build { buf, err in gm_stream_make_segment(h, Int32(i), buf, err, 256) }
        }
    }

    /// Produce segment 0 once as a full unit and split it into cached init + media.
    /// Caller holds `queue`.
    private func buildUnit0Locked() throws {
        guard let h = handle else { throw GMStreamError.segmentFailed("closed") }
        var moovEnd: Int32 = 0
        let unit = try Self.build { buf, err in
            withUnsafeMutablePointer(to: &moovEnd) { mp in
                gm_stream_make_unit(h, 0, buf, mp, err, 256)
            }
        }
        let split = Int(moovEnd)
        guard split > 0, split < unit.count else { throw GMStreamError.segmentFailed("bad moov split") }
        cachedInit = unit.subdata(in: 0 ..< split)
        cachedSeg0 = unit.subdata(in: split ..< unit.count)
    }

    // ── Demuxed per-rendition segments (multivariant HLS) ──────────────────────
    // Produced on demand: only the SELECTED rendition's segments are ever muxed.

    /// Video-only init segment (ftyp+moov, video track only).
    public func videoInit() throws -> Data {
        try queue.sync {
            guard let h = handle else { throw GMStreamError.segmentFailed("closed") }
            return try Self.build { buf, err in gm_stream_video_init(h, buf, err, 256) }
        }
    }

    /// Video-only media segment `i`.
    public func videoSegment(_ i: Int) throws -> Data {
        try queue.sync {
            guard let h = handle else { throw GMStreamError.segmentFailed("closed") }
            return try Self.build { buf, err in gm_stream_video_segment(h, Int32(i), buf, err, 256) }
        }
    }

    /// Audio-only init segment for the audio track at SOURCE index `source`.
    public func audioInit(source: Int) throws -> Data {
        try queue.sync {
            guard let h = handle else { throw GMStreamError.segmentFailed("closed") }
            return try Self.build { buf, err in gm_stream_audio_init(h, Int32(source), buf, err, 256) }
        }
    }

    /// Audio-only media segment `i` for the audio track at SOURCE index `source`.
    public func audioSegment(source: Int, _ i: Int) throws -> Data {
        try queue.sync {
            guard let h = handle else { throw GMStreamError.segmentFailed("closed") }
            return try Self.build { buf, err in gm_stream_audio_segment(h, Int32(source), Int32(i), buf, err, 256) }
        }
    }

    /// Run a gm_buf-producing C call and copy the result into Data.
    private static func build(_ call: (UnsafeMutablePointer<gm_buf>, UnsafeMutablePointer<CChar>) -> Int32) throws -> Data {
        var buf = gm_buf()
        var errbuf = [CChar](repeating: 0, count: 256)
        let rc = call(&buf, &errbuf)
        defer { if buf.data != nil { free(buf.data) } }
        guard rc == 0, let p = buf.data, buf.len > 0 else {
            throw GMStreamError.segmentFailed(String(cString: errbuf))
        }
        return Data(bytes: p, count: Int(buf.len))
    }
}

// MARK: - Subtitle (WebVTT) renditions

public extension GMStreamSession {
    /// WebVTT text segment `i` for the (TEXT) subtitle track at SOURCE index `source`.
    func subtitleSegment(source: Int, _ i: Int) throws -> Data {
        try queue.sync {
            guard let h = handle else { throw GMStreamError.segmentFailed("closed") }
            return try Self.build { buf, err in gm_stream_subtitle_segment(h, Int32(source), Int32(i), buf, err, 256) }
        }
    }

    /// WebVTT media playlist for the subtitle track at SOURCE index `source`. Same segment
    /// grid as video/audio (plan durations), one `.vtt` segment per entry, no EXT-X-MAP.
    func subtitlePlaylist(source: Int, scheme: String, host: String) -> String {
        queue.sync {
            guard let h = handle else { return "" }
            let prefix = "\(scheme)://\(host)/subs/\(source)"
            var maxDur = 0.0
            for i in 0 ..< segmentCount {
                maxDur = max(maxDur, gm_stream_segment_duration(h, Int32(i)))
            }
            var s = "#EXTM3U\n#EXT-X-VERSION:7\n"
            s += "#EXT-X-TARGETDURATION:\(Int(maxDur.rounded(.up)))\n"
            s += "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
            for i in 0 ..< segmentCount {
                let d = gm_stream_segment_duration(h, Int32(i))
                s += "#EXTINF:\(String(format: "%.5f", d)),\n\(prefix)/seg\(i).vtt\n"
            }
            s += "#EXT-X-ENDLIST\n"
            return s
        }
    }
}
