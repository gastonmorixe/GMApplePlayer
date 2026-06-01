//
//  GMStreamSession+Color.swift
//  HDR/color resolution for GMStreamSession. The container's codec params often
//  leave the transfer function UNSPECIFIED for HDR HEVC (PQ/HLG live in the SPS
//  VUI) and AVFoundation does not surface per-track color for an HLS asset, so we
//  recover the real transfer by muxing the init + first segment (already needed to
//  start playback) and reading the value back via AVAsset. Split out of
//  GMStreamSession.swift to keep that file within the project's file-size limit.
//

import AVFoundation
import Foundation

extension GMStreamSession {
    /// Resolve HDR by handing the muxed init + first segment to AVFoundation and reading
    /// the video track's transfer function (AVFoundation parses the HEVC SPS, which is
    /// where PQ/HLG actually lives, even when the container's codec params and an HLS
    /// asset's track descriptions do not surface it). Cached. Falls back to the source
    /// codec params if the probe can't run.
    func resolveColor() -> ColorInfo {
        resolvedLock.lock()
        if let c = _resolvedColor { resolvedLock.unlock()
            return c
        }
        resolvedLock.unlock()

        var resolved = color
        // If the container left the transfer unspecified (matroska/HEVC), recover the
        // real one via AVFoundation parsing the muxed SPS. The format-metadata flags
        // (DoVi/HDR10/HDR10+) come from coded side data and are already populated.
        if resolved.transfer <= 0 || resolved.transfer == 2 {
            if let t = try? probeTransferViaAVFoundation() { resolved.transfer = t }
        }

        resolvedLock.lock()
        _resolvedColor = resolved
        resolvedLock.unlock()
        return resolved
    }

    /// Mux init + seg0 (already needed for playback), write them to a temp .mp4, and read
    /// the video track's transfer function via AVAsset, returning the AVColor* transfer
    /// code (16=PQ, 18=HLG, 1=BT.709). Returns nil if no track/format.
    private func probeTransferViaAVFoundation() throws -> Int? {
        guard let probe = try probeColorViaAVFoundation() else { return nil }
        switch probe.name {
        case "SMPTE ST 2084 (PQ)": return 16
        case "HLG": return 18
        default: return probe.isHDR ? 16 : 1
        }
    }

    /// Mux init + seg0 (already needed for playback), write them to a temp .mp4, and read
    /// the video track's transfer function via AVAsset. Returns nil if no track/format.
    private func probeColorViaAVFoundation() throws -> (isHDR: Bool, name: String)? {
        let initData = try initSegment()
        let seg0 = try segment(0)
        var file = initData
        file.append(seg0)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-hdrprobe-\(UUID().uuidString).mp4")
        try file.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let asset = AVURLAsset(url: tmp)
        let sem = DispatchSemaphore(value: 0)
        var track: AVAssetTrack?
        asset.loadTracks(withMediaType: .video) { tracks, _ in track = tracks?.first
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        guard let track else { return nil }

        let fsem = DispatchSemaphore(value: 0)
        var formats: [CMFormatDescription] = []
        track.loadValuesAsynchronously(forKeys: ["formatDescriptions"]) {
            formats = (track.formatDescriptions as? [CMFormatDescription]) ?? []
            fsem.signal()
        }
        _ = fsem.wait(timeout: .now() + 5)

        let pq = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
        let hlg = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
        for fmt in formats {
            guard let tf = CMFormatDescriptionGetExtension(
                fmt, extensionKey: kCMFormatDescriptionExtension_TransferFunction
            ) as? String else { continue }
            if tf == pq { return (true, "SMPTE ST 2084 (PQ)") }
            if tf == hlg { return (true, "HLG") }
            return (false, tf)
        }
        return nil
    }
}
