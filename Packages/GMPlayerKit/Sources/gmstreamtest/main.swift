import AVFoundation
import Foundation
import GMPlayerKit

// Diagnostic harness for the streaming engines. Assembles the single-resource fMP4
// the resource loader serves, then reports:
//   • engine duration / segment count
//   • the top-level box sequence + mfhd sequence_numbers per fragment (the PROVEN
//     first-fragment-stall cause: per-segment muxer resets seq to 1,2,1,2,...; mfra
//     was a red herring, stripping it changes nothing)
//   • how many frames AVFoundation (AVAssetReader) decodes and the last PTS reached
// Env: GM_STRIP_MFRA=1 removes interior mfra (proves mfra is NOT the cause).
// Usage: gmstreamtest <file-or-url> [resourceloader|loopback] [targetSegSeconds]
setvbuf(stdout, nil, _IONBF, 0)
let url = CommandLine.arguments[1]
let target = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 2.0 : 2.0

// GM_INSPECT_SEG=<i>: print the RAW (pre-normalize) tfdt baseMediaDecodeTime of every
// traf in segment i, straight from the C engine via the session. Grounds the question
// "does the loopback path need normalizeFragments?" empirically instead of assuming:
// a value with the top bit set (> 2^63 for v1) is a wrapped-negative time that the
// resource-loader's normalizeFragments clamps to 0 but the loopback path does not.
if let segStr = ProcessInfo.processInfo.environment["GM_INSPECT_SEG"], let segIdx = Int(segStr) {
    let src: GMByteSource = url.hasPrefix("http") ? GMHTTPByteSource(url: URL(string: url)!)! : GMFileByteSource(path: url)!
    let sess = try! GMStreamSession(source: src, targetSegmentSeconds: target)
    let seg = try! sess.segment(segIdx)
    func u32(_ d: Data, _ o: Int) -> UInt32 {
        (UInt32(d[o]) << 24) | (UInt32(d[o + 1]) << 16) | (UInt32(d[o + 2]) << 8) | UInt32(d[o + 3])
    }
    var i = 0, found = 0
    func walk(_ lo: Int, _ hi: Int, _ depth: Int) {
        var p = lo
        while p + 8 <= hi {
            let sz = Int(u32(seg, p))
            if sz < 8 { break }
            let type = String(bytes: seg[(p + 4) ..< (p + 8)], encoding: .ascii) ?? "????"
            if ["moof", "traf"].contains(type) { walk(p + 8, min(p + sz, hi), depth + 1) }
            else if type == "tfdt" {
                let ver = seg[p + 8]
                var v: UInt64 = 0
                if ver == 1, p + 20 <= hi { for k in 0 ..< 8 {
                    v = (v << 8) | UInt64(seg[p + 12 + k])
                } } else if p + 16 <= hi { v = UInt64(u32(seg, p + 12)) }
                let wrapped = (ver == 1) ? (v > (UInt64(1) << 63)) : (v > (UInt64(1) << 31))
                print("  tfdt v\(ver) baseMediaDecodeTime=\(v) \(wrapped ? "<< WRAPPED-NEGATIVE" : "")")
                found += 1
            }
            p += sz
        }
        _ = i
    }
    print("segment \(segIdx) (\(seg.count) bytes) tfdt scan:")
    walk(0, seg.count, 0)
    if found == 0 { print("  (no tfdt found)") }
    exit(0)
}

// GM_DEMUX=<audioSrc>: produce the video-only init+seg0 and the audio-only init+seg0
// for the given audio source index, write each (init++seg0) to a temp .mp4, and verify
// AVFoundation opens each as a valid single-track asset. Proves the demuxed renditions
// are independently decodable (the basis for multivariant HLS).
if let demux = ProcessInfo.processInfo.environment["GM_DEMUX"], let aSrc = Int(demux) {
    let src: GMByteSource = url.hasPrefix("http") ? GMHTTPByteSource(url: URL(string: url)!)! : GMFileByteSource(path: url)!
    let session = try! GMStreamSession(source: src, targetSegmentSeconds: target)
    func check(_ label: String, _ data: Data, mediaType: AVMediaType) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gm-demux-\(label)-\(UUID().uuidString).mp4")
        try! data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let asset = AVURLAsset(url: tmp)
        let sem = DispatchSemaphore(value: 0)
        var tracks: [AVAssetTrack] = []
        asset.loadTracks(withMediaType: mediaType) { t, _ in tracks = t ?? []
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        print("  \(label): \(data.count) bytes, \(mediaType.rawValue) tracks=\(tracks.count) \(tracks.isEmpty ? "FAIL" : "OK")")
    }
    let vInit = try! session.videoInit(), vSeg = try! session.videoSegment(0)
    check("video", vInit + vSeg, mediaType: .video)
    let aInit = try! session.audioInit(source: aSrc), aSeg = try! session.audioSegment(source: aSrc, 0)
    check("audio[\(aSrc)]", aInit + aSeg, mediaType: .audio)
    exit(0)
}

// GM_TREE=<audioSrc>: write a COMPLETE on-disk multivariant HLS tree (master + video +
// one audio rendition, first 4 segments each) to /tmp/hlsval so Apple's
// mediastreamvalidator can pinpoint the exact problem. Uses RELATIVE URIs.
if let d = ProcessInfo.processInfo.environment["GM_TREE"], let aSrc = Int(d) {
    let root = URL(fileURLWithPath: "/tmp/hlsval")
    let fm = FileManager.default
    try? fm.removeItem(at: root)
    try! fm.createDirectory(at: root.appendingPathComponent("video"), withIntermediateDirectories: true)
    try! fm.createDirectory(at: root.appendingPathComponent("audio/\(aSrc)"), withIntermediateDirectories: true)
    let src: GMByteSource = url.hasPrefix("http") ? GMHTTPByteSource(url: URL(string: url)!)! : GMFileByteSource(path: url)!
    let s = try! GMStreamSession(source: src, targetSegmentSeconds: target)
    let n = min(4, s.segmentCount)
    // Master with ONLY the one rendition we write segments for (so the on-disk tree is
    // complete for the validator/player).
    let a = s.tracks.first { $0.sourceIndex == aSrc }!
    var master = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
    master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"\(a.displayName)\",LANGUAGE=\"\(a.bcp47Language.isEmpty ? "und" : a.bcp47Language)\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio/\(aSrc)/index.m3u8\"\n"
    let vt = s.tracks.first { $0.kind == .video }!
    let vcodec = vt.codec == "h264" ? "avc1" : "hvc1"
    var inf = "#EXT-X-STREAM-INF:BANDWIDTH=30000000,CODECS=\"\(vcodec),ac-3\",RESOLUTION=\(vt.width)x\(vt.height)"
    if let fr = vt.frameRate, fr > 0 { inf += ",FRAME-RATE=\(String(format: "%.3f", fr))" }
    inf += ",VIDEO-RANGE=\(s.isHDR ? "PQ" : "SDR"),AUDIO=\"aud\"\nvideo/index.m3u8\n"
    master += inf
    try! master.write(to: root.appendingPathComponent("master.m3u8"), atomically: true, encoding: .utf8)
    let vInit = try! s.videoInit(), aInit = try! s.audioInit(source: aSrc)
    try! vInit.write(to: root.appendingPathComponent("video/init.mp4"))
    try! aInit.write(to: root.appendingPathComponent("audio/\(aSrc)/init.mp4"))
    /// Measure each segment's REAL duration (init+seg as an AVAsset) and write THAT as
    /// EXTINF, to test whether the planned-vs-real duration mismatch is the -12646 cause.
    func realDur(_ initData: Data, _ seg: Data) -> Double {
        let tmp = root.appendingPathComponent("probe-\(UUID().uuidString).mp4")
        try! (initData + seg).write(to: tmp)
        defer { try? fm.removeItem(at: tmp) }
        return AVURLAsset(url: tmp).duration.seconds
    }
    var vDur = [Double](), aDur = [Double]()
    for i in 0 ..< n {
        let vs = try! s.videoSegment(i), asg = try! s.audioSegment(source: aSrc, i)
        try! vs.write(to: root.appendingPathComponent("video/seg\(i).m4s"))
        try! asg.write(to: root.appendingPathComponent("audio/\(aSrc)/seg\(i).m4s"))
        vDur.append(realDur(vInit, vs))
        aDur.append(realDur(aInit, asg))
    }
    print("video MEASURED: \(vDur.map { String(format: "%.3f", $0) })")
    print("audio MEASURED: \(aDur.map { String(format: "%.3f", $0) })")
    print("video COMPUTED: \((0 ..< n).map { String(format: "%.3f", s.realSegmentDuration($0)) })")
    print("audio COMPUTED: \((0 ..< n).map { String(format: "%.3f", s.realAudioSegmentDuration(source: aSrc, $0)) })")
    func mediaPL(_ initName: String, _ durs: [Double]) -> String {
        var p = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(durs.max()!.rounded(.up)))\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"\(initName)\"\n"
        for i in 0 ..< n {
            p += "#EXTINF:\(String(format: "%.5f", durs[i])),\nseg\(i).m4s\n"
        }
        return p + "#EXT-X-ENDLIST\n"
    }
    try! mediaPL("init.mp4", vDur).write(to: root.appendingPathComponent("video/index.m3u8"), atomically: true, encoding: .utf8)
    try! mediaPL("init.mp4", aDur).write(to: root.appendingPathComponent("audio/\(aSrc)/index.m3u8"), atomically: true, encoding: .utf8)
    print("wrote /tmp/hlsval tree (\(n) segments). Validate: mediastreamvalidator /tmp/hlsval/master.m3u8")
    exit(0)
}

// GM_DUMP=<audioSrc>: write demuxed video init+seg0 and audio init+seg0 to /tmp for
// box/timescale inspection (kept, not deleted).
if let d = ProcessInfo.processInfo.environment["GM_DUMP"], let aSrc = Int(d) {
    let src: GMByteSource = url.hasPrefix("http") ? GMHTTPByteSource(url: URL(string: url)!)! : GMFileByteSource(path: url)!
    let s = try! GMStreamSession(source: src, targetSegmentSeconds: target)
    try! (s.videoInit() + s.videoSegment(0)).write(to: URL(fileURLWithPath: "/tmp/gm-video.mp4"))
    try! (s.audioInit(source: aSrc) + s.audioSegment(source: aSrc, 0)).write(to: URL(fileURLWithPath: "/tmp/gm-audio.mp4"))
    print("wrote /tmp/gm-video.mp4 and /tmp/gm-audio.mp4")
    exit(0)
}

// GM_SUBS=<src>: print the subtitle WebVTT playlist + the first few non-empty .vtt
// segments for that text-subtitle source, to eyeball cue timing + X-TIMESTAMP-MAP.
if let d = ProcessInfo.processInfo.environment["GM_SUBS"], let sSrc = Int(d) {
    let src: GMByteSource = url.hasPrefix("http") ? GMHTTPByteSource(url: URL(string: url)!)! : GMFileByteSource(path: url)!
    let session = try! GMStreamSession(source: src, targetSegmentSeconds: target)
    print("===== subs/\(sSrc)/index.m3u8 (head) =====")
    print(session.subtitlePlaylist(source: sSrc, scheme: "http", host: "127.0.0.1:9999")
        .split(separator: "\n").prefix(10).joined(separator: "\n"))
    var shown = 0
    for i in 0 ..< session.segmentCount where shown < 4 {
        let vtt = (try? session.subtitleSegment(source: sSrc, i)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        // Only print segments that actually carry a cue (more than the header).
        if vtt.contains("-->") {
            print("===== seg\(i).vtt =====")
            print(vtt)
            shown += 1
        }
    }
    if shown == 0 { print("(no cues found in any segment for source \(sSrc))") }
    exit(0)
}

// GM_MASTER=1: print the multivariant master playlist + the video and per-audio media
// playlists, to eyeball the EXT-X-MEDIA audio group the native picker reads.
if ProcessInfo.processInfo.environment["GM_MASTER"] != nil {
    let src: GMByteSource = url.hasPrefix("http") ? GMHTTPByteSource(url: URL(string: url)!)! : GMFileByteSource(path: url)!
    let session = try! GMStreamSession(source: src, targetSegmentSeconds: target)
    print("===== master.m3u8 =====")
    print(session.masterPlaylist(scheme: "http", host: "127.0.0.1:9999"))
    print("===== video/index.m3u8 (head) =====")
    print(session.videoPlaylist(scheme: "http", host: "127.0.0.1:9999").split(separator: "\n").prefix(9).joined(separator: "\n"))
    if let a = session.audioRenditions.first {
        print("===== audio/\(a.sourceIndex)/index.m3u8 (head) =====")
        print(session.audioPlaylist(source: a.sourceIndex, scheme: "http", host: "127.0.0.1:9999").split(separator: "\n").prefix(9)
            .joined(separator: "\n"))
    }
    exit(0)
}

// GM_SERVE=1: build playback (default multivariant loopback) and KEEP the loopback
// server alive, printing the asset URL so an external windowed player can hit it. Idles
// until killed. Lets a real NSWindow AVPlayer test the same live server the app uses.
if ProcessInfo.processInfo.environment["GM_SERVE"] != nil {
    let pb = try! GMStreamingEngine.makePlayback(input: url, engine: .loopback, targetSegmentSeconds: target)
    print("SERVE_URL \((pb.asset as! AVURLAsset).url.absoluteString)")
    withExtendedLifetime(pb) { RunLoop.current.run() }
    exit(0)
}

// GM_SELECT=1: print AVFoundation's audible media-selection options (what the native
// picker shows) for the chosen engine. GM_ENGINE=loopback|resourceloader.
if ProcessInfo.processInfo.environment["GM_SELECT"] != nil {
    let eng: GMStreamingEngine.Kind =
        (ProcessInfo.processInfo.environment["GM_ENGINE"]?.lowercased().hasPrefix("resource") == true) ? .resourceLoader : .loopback
    let pb = try! GMStreamingEngine.makePlayback(input: url, engine: eng, targetSegmentSeconds: target)
    let sem = DispatchSemaphore(value: 0)
    pb.asset.loadValuesAsynchronously(forKeys: ["availableMediaCharacteristicsWithMediaSelectionOptions"]) { sem.signal() }
    while sem.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    for charac in [AVMediaCharacteristic.audible, .legible] {
        if let g = pb.asset.mediaSelectionGroup(forMediaCharacteristic: charac) {
            print("\(eng) \(charac.rawValue): \(g.options.count) options")
            for o in g.options {
                print("  - \(o.displayName) [\(o.extendedLanguageTag ?? "?")]")
            }
        } else {
            print("\(eng) \(charac.rawValue): NO group")
        }
    }
    withExtendedLifetime(pb) {}
    exit(0)
}

// GM_TRACKS=1: list every source track the engine enumerates (for the native picker),
// marking AVFoundation compatibility and which are the default video/audio. No playback.
if ProcessInfo.processInfo.environment["GM_TRACKS"] != nil {
    let src: GMByteSource = url.hasPrefix("http") ? GMHTTPByteSource(url: URL(string: url)!)! : GMFileByteSource(path: url)!
    let session = try! GMStreamSession(source: src, targetSegmentSeconds: target)
    print("tracks: \(session.tracks.count)  selVideo=\(session.selectedVideoIndex) selAudio=\(session.selectedAudioIndex)")
    for t in session.tracks {
        let flags = [
            t.isDefault ? "default" : nil,
            t.avfCompatible ? "avf-ok" : "avf-NO",
            t.kind == .subtitle ? (t.isTextSubtitle ? "text" : "image") : nil,
        ].compactMap { $0 }.joined(separator: ",")
        let kindStr = "\(t.kind)".padding(toLength: 9, withPad: " ", startingAt: 0)
        let codecStr = t.codec.padding(toLength: 14, withPad: " ", startingAt: 0)
        print(
            "  [\(t.sourceIndex)] \(kindStr) \(codecStr) lang=\(t.language.isEmpty ? "?" : t.language) ch=\(t.channels)  \"\(t.title)\"  {\(flags)}  -> \(t.displayName)"
        )
    }
    exit(0)
}

// GM_HDR=1: probe what AVFoundation reports for HDR on the chosen engine, exactly the
// way the app's GMPlaybackMonitor.detectHDR does: load the video track's
// formatDescriptions and read the transfer function (PQ/ST-2084 or HLG => HDR), plus
// the color primaries + matrix. Compares engines so we can see whether the loopback
// (HLS) path loses the HDR signalling the resource-loader path carried.
//   GM_ENGINE=loopback|resourceloader (default loopback)
if ProcessInfo.processInfo.environment["GM_HDR"] != nil {
    let engineSel: GMStreamingEngine.Kind =
        (ProcessInfo.processInfo.environment["GM_ENGINE"]?.lowercased().hasPrefix("resource") == true) ? .resourceLoader : .loopback
    let pb = try! GMStreamingEngine.makePlayback(input: url, engine: engineSel, targetSegmentSeconds: target)
    FileHandle.standardError.write(Data("engine=\(engineSel)\n".utf8))
    // The engine-independent answer the app now uses: source color info from the C demuxer.
    print("SOURCE color (from C engine): isHDR=\(pb.isHDRContent) transfer=\(pb.transferFunctionName)")

    let sem = DispatchSemaphore(value: 0)
    var track: AVAssetTrack?
    pb.asset.loadTracks(withMediaType: .video) { t, _ in track = t?.first
        sem.signal()
    }
    while sem.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard let track else { print("HDR PROBE: no video track")
        exit(1)
    }

    let fmtSem = DispatchSemaphore(value: 0)
    var formats: [CMFormatDescription] = []
    track.loadValuesAsynchronously(forKeys: ["formatDescriptions"]) {
        formats = (track.formatDescriptions as? [CMFormatDescription]) ?? []
        fmtSem.signal()
    }
    while fmtSem.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    let pq = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
    let hlg = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
    print("formatDescriptions: \(formats.count)")
    var isHDR = false
    for (i, fmt) in formats.enumerated() {
        let tf = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        let prim = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
        let mtx = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
        let subType = CMFormatDescriptionGetMediaSubType(fmt)
        let codec = String(
            bytes: [UInt8((subType >> 24) & 0xFF), UInt8((subType >> 16) & 0xFF), UInt8((subType >> 8) & 0xFF), UInt8(subType & 0xFF)],
            encoding: .ascii
        ) ?? "?"
        if tf == pq || tf == hlg { isHDR = true }
        print("  [\(i)] codec=\(codec) transfer=\(tf ?? "nil") primaries=\(prim ?? "nil") matrix=\(mtx ?? "nil")")
    }
    print(isHDR ?
        "HDR: YES (\(formats.compactMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String }.first ?? ""))" :
        "HDR: NO (transfer function missing or SDR)")
    withExtendedLifetime(pb) {}
    exit(isHDR ? 0 : 2)
}

// GM_PIXFMT=1: rendering-side ground truth, INDEPENDENT of the display's EDR state.
// Play through a real AVPlayer + AVPlayerItemVideoOutput, pull a decoded CVPixelBuffer,
// and read its color attachments (transfer function/primaries/matrix). If the buffer
// carries PQ/2020, HDR is flowing through decode+render; the panel's EDR headroom
// (whether it actually lights up) is a separate, volatile thing we do NOT conflate here.
if ProcessInfo.processInfo.environment["GM_PIXFMT"] != nil {
    let engineSel: GMStreamingEngine.Kind =
        (ProcessInfo.processInfo.environment["GM_ENGINE"]?.lowercased().hasPrefix("resource") == true) ? .resourceLoader : .loopback
    let pb = try! GMStreamingEngine.makePlayback(input: url, engine: engineSel, targetSegmentSeconds: target)
    let ci = pb.colorInfo
    print(
        "engine=\(engineSel) source isHDR=\(pb.isHDRContent) transfer=\(pb.transferFunctionName) format=\(ci.format.rawValue)\(ci.dolbyVision ? " P\(ci.doviProfile)" : "") mastering=\(ci.hasMastering) hdr10+=\(ci.hasHDR10Plus)"
    )
    let item = AVPlayerItem(asset: pb.asset)
    let vout = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
    item.add(vout)
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = true
    var waited = 0.0
    while item.status != .readyToPlay, waited < 30 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        waited += 0.1
        if item.status == .failed { print("ITEM FAILED: \(String(describing: item.error))")
            exit(1)
        }
    }
    player.play()
    func attach(_ px: CVPixelBuffer, _ key: CFString) -> String {
        if let v = CVBufferCopyAttachment(px, key, nil) { return String(describing: v) }
        return "nil"
    }
    var read = false
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
        let host = vout.itemTime(forHostTime: CACurrentMediaTime())
        if vout.hasNewPixelBuffer(forItemTime: host),
           let px = vout.copyPixelBuffer(forItemTime: host, itemTimeForDisplay: nil)
        {
            let tf = attach(px, kCVImageBufferTransferFunctionKey)
            let pr = attach(px, kCVImageBufferColorPrimariesKey)
            let mx = attach(px, kCVImageBufferYCbCrMatrixKey)
            let fmt = CVPixelBufferGetPixelFormatType(px)
            let f4 = String(
                bytes: [UInt8((fmt >> 24) & 0xFF), UInt8((fmt >> 16) & 0xFF), UInt8((fmt >> 8) & 0xFF), UInt8(fmt & 0xFF)],
                encoding: .ascii
            ) ?? "\(fmt)"
            print(
                "PIXELBUFFER transfer=\(tf) primaries=\(pr) matrix=\(mx) pixfmt=\(f4) \(CVPixelBufferGetWidth(px))x\(CVPixelBufferGetHeight(px))"
            )
            let isPQ = tf.contains("2084") || tf.contains("PQ")
            let isHLG = tf.contains("HLG")
            print((isPQ || isHLG) ? "RENDER PATH: HDR (\(isPQ ? "PQ" : "HLG")) reaching the player" :
                "RENDER PATH: SDR transfer on the decoded buffer")
            read = true
            break
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    if !read { print("RENDER PATH: no pixel buffer pulled in 12s") }
    withExtendedLifetime(pb) {}
    exit(read ? 0 : 1)
}

// GM_LIVE_DURATION=1: feed AVPlayer the live gmstream:// asset (lazy loader) and
// report BOTH asset.duration (reliable) and item.duration after readyToPlay, to test
// whether AVURLAssetPreferPreciseDurationAndTimingKey yields the full duration.
if ProcessInfo.processInfo.environment["GM_LIVE_DURATION"] != nil {
    let engineSel: GMStreamingEngine.Kind =
        (ProcessInfo.processInfo.environment["GM_ENGINE"]?.lowercased().hasPrefix("loop") == true) ? .loopback : .resourceLoader
    let t0 = Date()
    let pb = try! GMStreamingEngine.makePlayback(input: url, engine: engineSel, targetSegmentSeconds: target)
    FileHandle.standardError.write(Data("engine=\(engineSel) makePlayback=\(String(format: "%.2f", -t0.timeIntervalSinceNow))s\n".utf8))
    let durSem = DispatchSemaphore(value: 0)
    var assetDur = Double.nan
    pb.asset.loadValuesAsynchronously(forKeys: ["duration"]) {
        assetDur = pb.asset.duration.seconds
        durSem.signal()
    }
    while durSem.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    let item = AVPlayerItem(asset: pb.asset)
    _ = AVPlayer(playerItem: item)
    var waited = 0.0
    while item.status != .readyToPlay, waited < 30 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        waited += 0.1
        if item.status == .failed { print("ITEM FAILED: \(String(describing: item.error))")
            exit(1)
        }
    }
    print(String(
        format: "engine=%.2fs  asset.duration=%.2fs  item.duration=%.2fs  builtSegs=%d/%d",
        pb.duration,
        assetDur,
        item.duration.seconds,
        pb.loaderBuiltSegments,
        pb.segmentCount
    ))
    let best = assetDur.isFinite ? assetDur : item.duration.seconds
    print(abs(best - pb.duration) < 5 ? "DURATION OK" : "DURATION WRONG (the 37s bug)")
    withExtendedLifetime(pb) {}
    exit(0)
}

// GM_PLAYTHROUGH=1: the real bug-free gate. Build playback (default loopback unless
// GM_ENGINE=resourceloader), reach readyToPlay, PLAY for a few seconds, SEEK to ~70%,
// play again, and assert the player's currentTime actually advances at both spots and
// the item stays .readyToPlay (never stalls/fails). Reports lazy fetch growth (loopback
// servedSegments / loader builtSegs) at each checkpoint so a "whole movie up front"
// regression is visible. This validates SUSTAINED playback + seek, not just first frame
// (the headless AVAssetReader/VideoOutput probes are unreliable per the handoff; the
// reliable signal is player.currentTime advancing while status stays readyToPlay).
//   GM_PT_PLAY=<sec> first play window (default 6)
//   GM_PT_SEEK=<frac> seek target fraction of duration (default 0.70)
if ProcessInfo.processInfo.environment["GM_PLAYTHROUGH"] != nil {
    let env = ProcessInfo.processInfo.environment
    let engineSel: GMStreamingEngine.Kind =
        (env["GM_ENGINE"]?.lowercased().hasPrefix("resource") == true) ? .resourceLoader : .loopback
    let playWindow = Double(env["GM_PT_PLAY"] ?? "") ?? 6.0
    let seekFrac = Double(env["GM_PT_SEEK"] ?? "") ?? 0.70

    func fetched(_ pb: GMStreamingPlayback) -> String {
        engineSel == .loopback ? "served=\(pb.loopbackServedSegments)/\(pb.segmentCount)"
            : "builtSegs=\(pb.loaderBuiltSegments)/\(pb.segmentCount)"
    }
    func pump(_ sec: Double) {
        let until = Date().addingTimeInterval(sec)
        while Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    let t0 = Date()
    let pb = try! GMStreamingEngine.makePlayback(input: url, engine: engineSel, targetSegmentSeconds: target)
    let makeDt = -t0.timeIntervalSinceNow
    print(String(format: "engine=\(engineSel) makePlayback=%.2fs duration=%.1fs segs=%d", makeDt, pb.duration, pb.segmentCount))

    let item = AVPlayerItem(asset: pb.asset)
    let player = AVPlayer(playerItem: item)
    // GM_PT_WAITS=1 -> leave automaticallyWaitsToMinimizeStalling at Apple's default
    // (true: player buffers and auto-resumes after a stall). Default here is false to
    // match the app (commit 860191b), which pairs it with GMPlaybackMonitor-driven
    // stall recovery the bare harness lacks.
    player.automaticallyWaitsToMinimizeStalling = (env["GM_PT_WAITS"] == "1")

    var waited = 0.0
    while item.status != .readyToPlay, waited < 30 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        waited += 0.1
        if item.status == .failed { print("FAIL: item failed before play: \(String(describing: item.error))")
            for ev in item.errorLog()?.events ?? [] {
                print(
                    "  errorLog: status=\(ev.errorStatusCode) domain=\(ev.errorDomain) comment=\(ev.errorComment ?? "") uri=\(ev.uri ?? "")"
                )
            }
            exit(1)
        }
    }
    guard item.status == .readyToPlay else { print("FAIL: not readyToPlay after \(Int(waited))s")
        exit(1)
    }
    print(String(format: "readyToPlay in %.2fs  %@", waited, fetched(pb)))

    // ── PLAY 1 (from start) ──────────────────────────────────────────────────────
    let startT = player.currentTime().seconds
    player.play()
    pump(playWindow)
    let afterPlay1 = player.currentTime().seconds
    let advanced1 = afterPlay1 - (startT.isFinite ? startT : 0)
    print(String(
        format: "PLAY1: %.2fs -> %.2fs (advanced %.2fs)  status=%d  %@",
        startT,
        afterPlay1,
        advanced1,
        item.status.rawValue,
        fetched(pb)
    ))

    // ── SEEK to ~70% ─────────────────────────────────────────────────────────────
    let target70 = pb.duration * seekFrac
    print(String(format: "SEEK -> %.1fs (%.0f%%) ...", target70, seekFrac * 100))
    let seekSem = DispatchSemaphore(value: 0)
    var seekOK = false
    player.seek(
        to: CMTime(seconds: target70, preferredTimescale: 600),
        toleranceBefore: CMTime(seconds: 2, preferredTimescale: 600),
        toleranceAfter: CMTime(seconds: 2, preferredTimescale: 600)
    ) { ok in seekOK = ok
        seekSem.signal()
    }
    while seekSem.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    let afterSeek = player.currentTime().seconds
    print(String(
        format: "  seek finished=%@ landed=%.2fs  status=%d  %@",
        seekOK ? "true" : "false",
        afterSeek,
        item.status.rawValue,
        fetched(pb)
    ))

    // ── PLAY 2 (after seek) ──────────────────────────────────────────────────────
    player.play()
    // Sample the player every 2s so a pinned playhead is visible with its buffer state.
    var t = 0.0
    while t < playWindow {
        pump(2.0)
        t += 2.0
        let ranges = item.loadedTimeRanges.map { v -> String in
            let r = v.timeRangeValue
            return String(format: "[%.0f..%.0f]", r.start.seconds, (r.start + r.duration).seconds)
        }.joined(separator: ",")
        print(String(
            format: "  t+%.0fs cur=%.2f rate=%.1f keepUp=%@ buffded=%@ %@ loaded=%@",
            t,
            player.currentTime().seconds,
            player.rate,
            item.isPlaybackLikelyToKeepUp ? "Y" : "N",
            item.isPlaybackBufferFull ? "Y" : "N",
            fetched(pb),
            ranges.isEmpty ? "none" : ranges
        ))
    }
    let afterPlay2 = player.currentTime().seconds
    let advanced2 = afterPlay2 - afterSeek
    print(String(
        format: "PLAY2: %.2fs -> %.2fs (advanced %.2fs)  status=%d  %@",
        afterSeek,
        afterPlay2,
        advanced2,
        item.status.rawValue,
        fetched(pb)
    ))

    // ── verdict ──────────────────────────────────────────────────────────────────
    let okStart = makeDt < 8.0
    let okPlay1 = advanced1 > playWindow * 0.4
    let okSeek = abs(afterSeek - target70) < 15 && item.status == .readyToPlay
    let okPlay2 = advanced2 > playWindow * 0.4
    let okStatus = item.status == .readyToPlay
    print("--- VERDICT ---")
    print("  fast start (<8s):        \(okStart ? "OK" : "FAIL") (\(String(format: "%.2f", makeDt))s)")
    print("  play1 advances:          \(okPlay1 ? "OK" : "FAIL") (\(String(format: "%.2f", advanced1))s)")
    print("  seek lands near target:  \(okSeek ? "OK" : "FAIL")")
    print("  play2 advances:          \(okPlay2 ? "OK" : "FAIL") (\(String(format: "%.2f", advanced2))s)")
    print("  status readyToPlay:      \(okStatus ? "OK" : "FAIL")")
    let allOK = okStart && okPlay1 && okSeek && okPlay2 && okStatus
    print(allOK ? "PLAYTHROUGH OK" : "PLAYTHROUGH FAIL")
    withExtendedLifetime(pb) {}
    exit(allOK ? 0 : 1)
}

// GM_TIMING=1: break down byte-source init / open / per-segment / full-assemble
// latency (used to reproduce the URL "inspecting forever" hang). Then exit.
if ProcessInfo.processInfo.environment["GM_TIMING"] != nil {
    let t0 = Date()
    let tsrc: GMByteSource = url.hasPrefix("http") ? GMHTTPByteSource(url: URL(string: url)!)! : GMFileByteSource(path: url)!
    print(String(format: "byte-source init (HEAD probe): %.2fs size=%lld", -t0.timeIntervalSinceNow, tsrc.totalSize))
    let t1 = Date()
    let ts = try! GMStreamSession(source: tsrc, targetSegmentSeconds: target)
    print(String(format: "gm_stream_open(OPEN): %.2fs  %d segs  %.1fs", -t1.timeIntervalSinceNow, ts.segmentCount, ts.duration))
    let t2 = Date()
    _ = try! ts.initSegment()
    print(String(format: "initSegment(): %.2fs", -t2.timeIntervalSinceNow))
    let t3 = Date()
    let s0 = try! ts.segment(0)
    let segDt = -t3.timeIntervalSinceNow
    print(String(format: "segment(0): %.2fs %d bytes", segDt, s0.count))
    // The real metric now: how fast does the resource-loader makePlayback return?
    let t4 = Date()
    let pb = try! GMStreamingEngine.makePlayback(input: url, engine: .resourceLoader, targetSegmentSeconds: target)
    print(String(
        format: "makePlayback(resourceLoader) init: %.2fs  builtSegs=%d/%d  (lazy => should be <=1)",
        -t4.timeIntervalSinceNow,
        pb.loaderBuiltSegments,
        ts.segmentCount
    ))
    exit(0)
}

let src: GMByteSource = url.hasPrefix("http") ? GMHTTPByteSource(url: URL(string: url)!)! : GMFileByteSource(path: url)!
let s = try! GMStreamSession(source: src, targetSegmentSeconds: target)
let loader = try! GMResourceLoaderDelegate(session: s)
var data = loader.assembledBytes

/// Strip every top-level `mfra` box (keeps all other boxes), returning the new bytes.
/// Used to test causation: does removing the interior mfra boxes let AVFoundation
/// decode the whole stream?
func stripMfra(_ input: Data) -> Data {
    var out = Data(capacity: input.count)
    var j = 0
    var removed = 0
    while j + 8 <= input.count {
        let sz = Int(input[j]) << 24 | Int(input[j + 1]) << 16 | Int(input[j + 2]) << 8 | Int(input[j + 3])
        let type = String(bytes: input[(j + 4) ..< (j + 8)], encoding: .ascii) ?? "????"
        if sz < 8 { out.append(input.subdata(in: j ..< input.count))
            break
        }
        let endIdx = min(j + sz, input.count)
        if type == "mfra" { removed += 1 } else { out.append(input.subdata(in: j ..< endIdx)) }
        j += sz
    }
    print("stripMfra: removed \(removed) mfra box(es), \(input.count) -> \(out.count) bytes")
    return out
}

if ProcessInfo.processInfo.environment["GM_STRIP_MFRA"] != nil {
    data = stripMfra(data)
}

print("engine duration \(String(format: "%.2f", s.duration))s, \(s.segmentCount) segs, assembled \(data.count) bytes")

// Top-level box sequence.
var boxes: [String] = []
var i = 0
while i + 8 <= data.count {
    let sz = Int(data[i]) << 24 | Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
    boxes.append(String(bytes: data[(i + 4) ..< (i + 8)], encoding: .ascii) ?? "????")
    if sz < 8 { break }
    i += sz
}

let mfra = boxes.enumerated().filter { $0.element == "mfra" }.map(\.offset)
print("boxes: \(boxes.joined(separator: ","))")
print("interior mfra at indices \(mfra.filter { $0 != boxes.count - 1 }) (red herring, not the cause)")

// mfhd sequence_numbers per fragment, the PROVEN stall cause when non-monotonic.
var seqs: [UInt32] = []
var p = 0
while p + 8 <= data.count {
    let sz = Int(data[p]) << 24 | Int(data[p + 1]) << 16 | Int(data[p + 2]) << 8 | Int(data[p + 3])
    if sz < 8 { break }
    if String(bytes: data[(p + 4) ..< (p + 8)], encoding: .ascii) == "moof" {
        let k = p + 8
        if k + 16 <= data.count, String(bytes: data[(k + 4) ..< (k + 8)], encoding: .ascii) == "mfhd" {
            let o = k + 12
            seqs.append(UInt32(data[o]) << 24 | UInt32(data[o + 1]) << 16 | UInt32(data[o + 2]) << 8 | UInt32(data[o + 3]))
        }
    }
    p += sz
}

let monotonic = zip(seqs, seqs.dropFirst()).allSatisfy { $0 < $1 }
print("mfhd seq: \(seqs) -> \(monotonic ? "monotonic OK" : "NON-MONOTONIC (stall cause)")")

/// AVFoundation decode ground truth.
let path = NSTemporaryDirectory() + "gm-diag.mp4"
try! data.write(to: URL(fileURLWithPath: path))
let asset = AVURLAsset(url: URL(fileURLWithPath: path))
let sem = DispatchSemaphore(value: 0)
var vt: AVAssetTrack?
asset.loadTracks(withMediaType: .video) { t, _ in vt = t?.first
    sem.signal()
}

sem.wait()
let reader = try! AVAssetReader(asset: asset)
let out = AVAssetReaderTrackOutput(track: vt!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
reader.add(out)
reader.startReading()
var frames = 0, lastPTS = 0.0
while let sb = out.copyNextSampleBuffer() {
    lastPTS = CMSampleBufferGetPresentationTimeStamp(sb).seconds
    frames += 1
    CMSampleBufferInvalidate(sb)
}

print("AVFoundation decoded \(frames) frames, lastPTS \(String(format: "%.2f", lastPTS))s of \(String(format: "%.2f", s.duration))s")
print(lastPTS > s.duration - 2 ? "OK: decoded full stream" : "BUG: stalled after the first fragment")

/// ── SEEK reproduction (BUG #1018baf): seek shows black ────────────────────────
/// Faithful repro: a real AVPlayer + AVPlayerItemVideoOutput, seek mid-movie, then
/// poll for a NEW pixel buffer near the seek target (what the app's UI shows).
let seekTo: Double = s.duration * 0.7
print("--- SEEK test: seeking to \(String(format: "%.1f", seekTo))s ---")
let seekItem = AVPlayerItem(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
let vout = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
seekItem.add(vout)
let player = AVPlayer(playerItem: seekItem)
/// Wait for readyToPlay.
var waited = 0.0
while seekItem.status != .readyToPlay, waited < 10 {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    waited += 0.05
}

player.play()
let seekTarget = CMTime(seconds: seekTo, preferredTimescale: 600)
let seekMode = ProcessInfo.processInfo.environment["GM_SEEK_MODE"] ?? "exact"
let seekSem = DispatchSemaphore(value: 0)
if seekMode == "default" {
    // AVKit scrubber uses the default-tolerance seek.
    player.seek(to: seekTarget) { ok in
        print("seek completion (default tol): finished=\(ok)")
        seekSem.signal()
    }
} else {
    let seekTol = CMTime(seconds: 1, preferredTimescale: 600)
    player.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: seekTol) { ok in
        print("seek completion (exact): finished=\(ok)")
        seekSem.signal()
    }
}

// Pump the run loop until seek completes.
while seekSem.wait(timeout: .now()) == .timedOut {
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
}

// Now poll for a decoded frame at/after the seek target.
var gotFrame = false
var gotPTS = -1.0
let seekDeadline = Date().addingTimeInterval(6)
while Date() < seekDeadline {
    let host = vout.itemTime(forHostTime: CACurrentMediaTime())
    if vout.hasNewPixelBuffer(forItemTime: host), let _ = vout.copyPixelBuffer(forItemTime: host, itemTimeForDisplay: nil) {
        gotFrame = true
        gotPTS = host.seconds
        break
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
}

print(
    "after seek: gotFrame=\(gotFrame) atPTS=\(String(format: "%.2f", gotPTS)) playerTime=\(String(format: "%.2f", player.currentTime().seconds)) itemStatus=\(seekItem.status.rawValue)"
)
print(gotFrame ? "SEEK OK: decoded a frame after seeking" :
    "SEEK BUG: black, no frame after seeking to \(String(format: "%.1f", seekTo))s")
