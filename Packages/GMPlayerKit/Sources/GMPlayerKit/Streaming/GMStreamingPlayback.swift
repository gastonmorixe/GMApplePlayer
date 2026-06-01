//
//  GMStreamingPlayback.swift
//  A ready-to-play streaming asset plus the objects that keep it alive.
//
//  Playback is served by an in-process loopback HTTP server (127.0.0.1, ephemeral
//  port). AVFoundation requires HLS segment bytes to be fetched over HTTP and
//  rejects resource-loader-vended segment data (-12881), so the server is the
//  transport. It stops on deinit, hence the CALLER MUST RETAIN this value for the
//  whole playback.
//

import AVFoundation
import Foundation

public final class GMStreamingPlayback {
    public let asset: AVURLAsset
    public let session: GMStreamSession
    /// Loopback transport (legacy HLS engine). Nil when using the resource-loader engine.
    let server: GMLoopbackServer?
    /// Resource-loader transport (single fMP4 engine). Nil when using the loopback engine.
    /// MUST be retained for the lifetime of playback: AVAssetResourceLoader holds it weakly.
    let loader: GMResourceLoaderDelegate?

    init(asset: AVURLAsset, session: GMStreamSession, server: GMLoopbackServer) {
        self.asset = asset
        self.session = session
        self.server = server
        self.loader = nil
    }

    init(asset: AVURLAsset, session: GMStreamSession, loader: GMResourceLoaderDelegate) {
        self.asset = asset
        self.session = session
        self.server = nil
        self.loader = loader
    }

    deinit { server?.stop() }

    /// True when playback is served by the loopback HLS server (vs the single-fMP4
    /// resource loader). The caller configures AVPlayer differently per engine:
    /// HLS wants `automaticallyWaitsToMinimizeStalling = true` (Apple's documented
    /// HLS behavior; it auto-resumes after a buffer-drained stall, which a far seek
    /// over the network can briefly cause), whereas the resource-loader path is tuned
    /// to start with waiting OFF to skip a long many-moof buffering evaluation.
    public var isLoopback: Bool {
        server != nil
    }

    public var duration: Double {
        session.duration
    }

    /// True when the source video signals an HDR transfer function (PQ or HLG), read
    /// from the input stream's color info at open. Transport-independent, so it is
    /// correct on the HLS loopback engine (where AVFoundation does not expose per-track
    /// color descriptions) as well as the resource loader.
    public var isHDRContent: Bool {
        session.isHDR
    }

    /// A short transfer-function name for the HUD (e.g. "SMPTE ST 2084 (PQ)").
    public var transferFunctionName: String {
        session.transferFunctionName
    }

    /// The specific HDR format of the source (Dolby Vision / HDR10+ / HDR10 / HLG / SDR),
    /// for the inspector's stream tag. Includes the Dolby Vision profile when present.
    public var colorInfo: GMStreamSession.ColorInfo {
        session.resolvedColor
    }

    public var segmentCount: Int {
        session.segmentCount
    }

    /// Segments the resource-loader has muxed so far (0 for the loopback engine).
    /// For diagnostics: proves lazy init didn't assemble the whole movie.
    public var loaderBuiltSegments: Int {
        loader?.builtSegmentCount ?? 0
    }

    public var port: UInt16 {
        server?.port ?? 0
    }

    /// Distinct media segments the loopback server has served so far (0 for the
    /// resource-loader engine). For diagnostics: proves loopback streams lazily.
    public var loopbackServedSegments: Int {
        server?.servedSegments ?? 0
    }
}
