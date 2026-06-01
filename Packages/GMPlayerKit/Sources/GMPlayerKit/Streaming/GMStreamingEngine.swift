//
//  GMStreamingEngine.swift
//  Builds an on-demand streaming AVURLAsset for a source (local path or remote
//  http(s) URL), backed by the C engine served over an in-process loopback HTTP
//  server.
//
//  Why a loopback server (proven, not a choice): AVFoundation will not let an
//  AVAssetResourceLoaderDelegate vend HLS media-segment bytes; it requires segment
//  bytes to be fetched over HTTP (returning data for a segment fails with -12881,
//  "custom url not redirect"). The same segments play fine over HTTP. So playback
//  is served from a 127.0.0.1 ephemeral-port server (in-process, nothing exposed),
//  the documented approach used by Infuse/VLCKit/KTVHTTPCache.
//
//  The returned GMStreamingPlayback owns the server; the caller MUST retain it for
//  the lifetime of playback (the server stops on deinit).
//

import AVFoundation
import Foundation

public enum GMStreamingEngine {
    /// Which transport feeds AVPlayer. Both keep AVPlayerViewController + all AVKit UI.
    public enum Kind: String {
        /// Feed AVPlayer ONE fragmented-MP4 resource via a custom-scheme
        /// AVAssetResourceLoaderDelegate (no HLS, no server). LAZY for what's watched,
        /// but AVFoundation walks every `moof` at OPEN to build its own index, so a
        /// large many-fragment movie (e.g. a 40 GB+ REMUX) forces muxing nearly the
        /// whole file = "loads forever". Best kept for small/medium files. Opt-in.
        case resourceLoader
        /// DEFAULT: on-demand HLS fMP4 over a 127.0.0.1 loopback server. AVFoundation
        /// trusts the .m3u8 time map and fetches segments lazily as the playhead moves,
        /// so even a 70 GB movie starts in well under a second and never scans the whole
        /// file. This is Apple's documented random-access path for fragmented MP4.
        case loopback
    }

    /// User-facing engine preference, persisted by the app (e.g. via @AppStorage) and
    /// passed into makePlayback. `auto` resolves to the best default (loopback).
    public enum Preference: String, CaseIterable, Sendable {
        /// Let the app choose the best engine (currently loopback for everything).
        case auto
        /// Force the loopback HLS server engine.
        case loopback
        /// Force the single-file resource-loader engine (experimental for large files).
        case resourceLoader

        /// A short human label for a settings picker.
        public var label: String {
            switch self {
            case .auto: "Automatic (recommended)"
            case .loopback: "HLS loopback server"
            case .resourceLoader: "Single file (experimental)"
            }
        }
    }

    /// The default engine when nothing overrides it. Loopback is proven to start
    /// instantly and play/seek cleanly on the largest real files (measured on 35-81 GB
    /// REMUX MKVs over LAN); the resource loader hangs on those. See the streaming plan.
    public static let defaultKind: Kind = .loopback

    /// Resolve the active engine from an explicit preference plus the
    /// GM_PLAYER_ENGINE env override (env wins, for tests/debugging).
    /// `preference` is the persisted user choice; nil means "use the default".
    public static func resolveKind(preference: Preference? = nil) -> Kind {
        switch ProcessInfo.processInfo.environment["GM_PLAYER_ENGINE"]?.lowercased() {
        case "loopback", "hls", "server": return .loopback
        case "resourceloader", "resource", "fmp4", "loader": return .resourceLoader
        default: break
        }
        switch preference ?? .auto {
        case .auto: return defaultKind
        case .loopback: return .loopback
        case .resourceLoader: return .resourceLoader
        }
    }

    /// Resolve the active engine. Override with GM_PLAYER_ENGINE=loopback|resourceloader.
    public static var selectedKind: Kind {
        resolveKind(preference: nil)
    }

    /// Build a streaming playback for `input` (a local file path or http(s) URL).
    /// Runs synchronous open/probe (+ starts the loopback server for the legacy
    /// engine) on the calling thread, so call it off the main actor. Throws if the
    /// source can't be opened.
    /// `onProbeProgress`, if given, is called as input bytes stream in during OPEN
    /// (remote sources only), with cumulative bytes read and a smoothed bytes/sec.
    /// Use it to drive a live "inspecting…" label; the call may come from any thread.
    public static func makePlayback(
        input: String,
        preference: Preference? = nil,
        targetSegmentSeconds: Double = 6.0,
        onProbeProgress: ((_ bytesRead: Int64, _ bytesPerSec: Double) -> Void)? = nil
    ) throws -> GMStreamingPlayback {
        try makePlayback(
            input: input,
            engine: resolveKind(preference: preference),
            targetSegmentSeconds: targetSegmentSeconds,
            onProbeProgress: onProbeProgress
        )
    }

    /// Build a streaming playback with an explicit engine choice.
    public static func makePlayback(
        input: String,
        engine: Kind,
        targetSegmentSeconds: Double = 6.0,
        onProbeProgress: ((_ bytesRead: Int64, _ bytesPerSec: Double) -> Void)? = nil
    ) throws -> GMStreamingPlayback {
        let source = try makeByteSource(input: input)
        source.onProgress = onProbeProgress
        let session = try GMStreamSession(source: source, targetSegmentSeconds: targetSegmentSeconds)
        // OPEN/probe is done once the session is built; stop reporting so the hook
        // doesn't keep firing for normal playback segment fetches.
        source.onProgress = nil

        switch engine {
        case .resourceLoader:
            let loader = try GMResourceLoaderDelegate(session: session)
            let asset = loader.makeAsset() // gmstream://stream/movie.mp4
            return GMStreamingPlayback(asset: asset, session: session, loader: loader)
        case .loopback:
            let server = try GMLoopbackServer(session: session)
            let base = try server.start() // http://127.0.0.1:<port>/
            // The multivariant master exposes every audio track as an EXT-X-MEDIA rendition
            // so the native AVKit picker lists + switches them; non-default audio is muxed
            // only when actually selected. ON by default. GM_MULTIVARIANT=0 forces the
            // legacy single muxed media playlist (no audio picker), a known-good fallback.
            let multivariant = ProcessInfo.processInfo.environment["GM_MULTIVARIANT"] != "0"
            let leaf = multivariant ? "master.m3u8" : "index.m3u8"
            let asset = AVURLAsset(url: base.appendingPathComponent(leaf))
            return GMStreamingPlayback(asset: asset, session: session, server: server)
        }
    }

    /// Pick the right byte source: HTTP(S) URL → ranged GETs; anything else → local
    /// file path (also accepts a file:// URL).
    private static func makeByteSource(input: String) throws -> GMByteSource {
        if let url = URL(string: input), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https"
        {
            guard let s = GMHTTPByteSource(url: url) else {
                throw GMStreamError.openFailed("cannot reach \(input)")
            }
            return s
        }
        // Local: accept a file:// URL or a bare path.
        let path = (URL(string: input)?.scheme == "file")
            ? (URL(string: input)?.path ?? input)
            : input
        guard let s = GMFileByteSource(path: path) else {
            throw GMStreamError.openFailed("cannot open file \(path)")
        }
        return s
    }
}
