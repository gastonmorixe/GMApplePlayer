//
//  GMPlayerModel.swift
//  Orchestrates: source -> probe -> remux (FFmpeg) -> AVPlayer item.
//
//  This is the object the SwiftUI shell observes. It keeps an AVPlayer alive,
//  drives the GMRemuxer on a background queue, and publishes load/progress/error
//  state on the main actor. It also owns a GMPlaybackMonitor for telemetry.
//

import AVFoundation
import Combine
import Foundation
import os

@MainActor
public final class GMPlayerModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case probing(ProbeStatus)
        case remuxing(progress: Double)
        case readyToPlay
        case failed(String)

        /// Convenience for the common "just started, nothing read yet" probing state.
        public static var probing: State {
            .probing(.connecting)
        }
    }

    /// Live status of the OPEN/probe phase, surfaced so the UI can show a moving
    /// label ("Connecting…" then "Inspecting · N MB · R/s") instead of an opaque spinner.
    public struct ProbeStatus: Equatable {
        public enum Phase: Equatable {
            case connecting // resolving the source / first bytes not yet flowing
            case inspecting // reading the stream index over the wire
        }

        public var phase: Phase
        /// Cumulative input bytes read so far (0 until the first chunk lands).
        public var bytesRead: Int64
        /// Smoothed read throughput in bytes/sec (0 until measurable).
        public var bytesPerSec: Double

        public init(phase: Phase, bytesRead: Int64 = 0, bytesPerSec: Double = 0) {
            self.phase = phase
            self.bytesRead = bytesRead
            self.bytesPerSec = bytesPerSec
        }

        public static let connecting = ProbeStatus(phase: .connecting)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var probe: GMProbeResult?
    /// True while an on-demand probe (triggered by the track picker on the
    /// streaming fast-path, which doesn't probe up front) is in flight.
    @Published public private(set) var isProbingTracks = false
    @Published public private(set) var sourceName = ""
    /// Currently chosen source stream indices (-1 == auto).
    @Published public private(set) var selectedVideo: Int = -1
    @Published public private(set) var selectedAudio: Int = -1

    public let player = AVPlayer()
    public let monitor = GMPlaybackMonitor()

    /// User-selected streaming engine, surfaced in app Settings and persisted by the
    /// app layer (e.g. @AppStorage). `.auto` (the default) picks the best engine
    /// (loopback HLS, which starts instantly and seeks cleanly on huge files). The
    /// GM_PLAYER_ENGINE env var still overrides this for tests. Set it before `open`.
    public var enginePreference: GMStreamingEngine.Preference = .auto

    /// When true, playback restarts from the beginning when it reaches the end (loop).
    /// Persisted by the app layer (e.g. @AppStorage) and can be toggled live during
    /// playback. Implemented by seeking to zero on AVPlayerItemDidPlayToEndTime rather
    /// than AVPlayerLooper (which needs a fresh AVQueuePlayer and would tear down our
    /// item + streaming server); a single-item seek-and-play loop is seamless enough
    /// for a movie and keeps the existing player/server alive.
    public var loops = false {
        didSet { if loops != oldValue { player.actionAtItemEnd = loops ? .none : .pause } }
    }

    private let engine: MediaEngine
    private let log = Logger(subsystem: "com.gm.appleplayer", category: "model")
    private var currentInput: String?
    private var currentTempURL: URL?
    /// Retained streaming playback (owns the loopback HTTP server serving the
    /// HLS to AVPlayer; the server stops when this is released).
    private var streaming: GMStreamingPlayback?
    /// When true, prefer on-demand streaming and fall back to batch remux only if
    /// streaming open fails. Disabled automatically for an explicit track reselect.
    private let preferStreaming: Bool
    /// AVPlayerItemDidPlayToEndTime observer that drives looping (see `loops`).
    private var endObserver: NSObjectProtocol?

    /// Inject any MediaEngine; defaults to the FFmpeg-backed one. Tests pass a fake.
    public init(engine: MediaEngine = FFmpegMediaEngine(), preferStreaming: Bool = true) {
        self.engine = engine
        self.preferStreaming = preferStreaming
        player.automaticallyWaitsToMinimizeStalling = true
    }

    public var backendVersion: String {
        engine.backendVersion
    }

    public var isBusy: Bool {
        switch state {
        case .probing, .remuxing: true
        default: false
        }
    }

    /// Coalesces bursty byte-source callbacks onto the main actor without piling up
    /// hops; only the most recent sample matters for the label.
    private var lastProbeSampleAt: CFAbsoluteTime = 0

    // MARK: - Entry points

    public func open(fileURL: URL) {
        sourceName = fileURL.lastPathComponent
        log.info("open file: \(fileURL.lastPathComponent, privacy: .public)")
        start(input: fileURL.path)
    }

    public func open(remoteURL: URL) {
        sourceName = remoteURL.lastPathComponent.isEmpty ? remoteURL.absoluteString : remoteURL.lastPathComponent
        log.info("open url: \(remoteURL.absoluteString, privacy: .public)")
        start(input: remoteURL.absoluteString)
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        monitor.detach()
        if let token = endObserver { NotificationCenter.default.removeObserver(token)
            endObserver = nil
        }
        streaming = nil
        cleanupTemp()
        state = .idle
    }

    public func openFailed(_ message: String) {
        log.error("open failed: \(message, privacy: .public)")
        state = .failed(message)
    }

    /// Populate `probe` on demand. The streaming fast-path begins playback
    /// without probing, so the track picker has no stream list to show; this
    /// fills it lazily from the current source. No-op if already probed, busy,
    /// or there is no source.
    public func ensureProbe() async {
        guard probe == nil, !isProbingTracks, let input = currentInput else { return }
        isProbingTracks = true
        defer { isProbingTracks = false }
        do {
            probe = try await engine.probe(input)
        } catch {
            log.error("on-demand probe failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-run the remux with explicit track choices (e.g. user picked a
    /// different audio track in the UI). Pass -1 for auto.
    public func selectTracks(video: Int, audio: Int) {
        guard let input = currentInput else { return }
        selectedVideo = video
        selectedAudio = audio
        log.info("reselect tracks v=\(video) a=\(audio); re-remuxing (batch)")
        start(input: input, video: Int32(video), audio: Int32(audio), forceBatch: true)
    }

    // MARK: - Pipeline

    /// `forceBatch` is set for an explicit track reselect (streaming auto-selects
    /// the best video+audio, so per-track choice must go through the batch remux).
    private func start(input: String, video: Int32 = -1, audio: Int32 = -1, forceBatch: Bool = false) {
        cleanupTemp()
        streaming = nil
        currentInput = input
        state = .probing

        Task {
            // Fast path: on-demand streaming. Starts playback in ~1-2s and fetches
            // only what is watched. Falls back to the batch remux if it can't open.
            if preferStreaming, !forceBatch {
                if await self.startStreaming(input: input) { return }
                self.log.info("streaming open failed; falling back to batch remux")
            }
            await self.startBatch(input: input, video: video, audio: audio)
        }
    }

    /// Fold a byte-source progress sample into the probing state. No-op once we've
    /// left `.probing` (a late callback after open finished must not clobber state).
    private func updateProbe(bytesRead: Int64, bytesPerSec: Double) {
        guard case .probing = state else { return }
        state = .probing(.init(phase: .inspecting, bytesRead: bytesRead, bytesPerSec: bytesPerSec))
    }

    /// Try to begin on-demand streaming. Returns true if playback started.
    private func startStreaming(input: String) async -> Bool {
        do {
            // Bridge byte-source progress (any thread) onto the main actor and into
            // the probing state so the landing label moves while OPEN reads the index.
            let onProbe: (Int64, Double) -> Void = { [weak self] bytes, bps in
                Task { @MainActor in self?.updateProbe(bytesRead: bytes, bytesPerSec: bps) }
            }
            let preference = enginePreference
            let playback = try await Task.detached(priority: .userInitiated) {
                try GMStreamingEngine.makePlayback(input: input, preference: preference, onProbeProgress: onProbe)
            }.value
            streaming = playback
            let ci = playback.colorInfo
            beginPlayback(
                asset: playback.asset,
                isLoopback: playback.isLoopback,
                hdrFormat: Self.monitorFormat(ci.format),
                doviProfile: ci.doviProfile,
                knownTransferName: playback.transferFunctionName
            )
            log
                .info(
                    "streaming: \(playback.segmentCount) segments, \(playback.duration, format: .fixed(precision: 1))s, HDR=\(ci.format.rawValue)"
                )
            return true
        } catch {
            return false
        }
    }

    /// Batch fallback: probe, remux the whole file to a temp fMP4, then play it.
    private func startBatch(input: String, video: Int32, audio: Int32) async {
        do {
            let result = try await engine.probe(input)
            probe = result
            guard result.hasPlayableVideo || result.hasPlayableAudio else {
                state = .failed("No AVFoundation-compatible video or audio streams in this file.")
                return
            }

            let temp = Self.makeTempURL()
            currentTempURL = temp
            state = .remuxing(progress: 0)

            try await engine.remux(
                input: input,
                outputURL: temp,
                videoStream: video,
                audioStream: audio
            ) { frac in
                Task { @MainActor in
                    if case .remuxing = self.state { self.state = .remuxing(progress: frac) }
                }
                return true
            }

            // Batch fallback is a single progressive file; its track format descriptions
            // are reliable, so let the monitor probe HDR from the asset (knownHDR nil).
            beginPlayback(asset: AVURLAsset(url: temp), isLoopback: false)
        } catch let e as GMRemuxError {
            self.state = .failed(e.errorDescription ?? "Unknown error")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Begin playback of `asset`. `isLoopback` is true for the HLS loopback streaming
    /// engine, false for the single-fMP4 resource loader and the batch-remux fallback.
    /// The two need OPPOSITE waiting policies (verified on real 35-81 GB REMUX MKVs):
    ///
    ///  • Loopback (HLS): keep automaticallyWaitsToMinimizeStalling = true (Apple's
    ///    documented HLS behavior). A far seek over the LAN can momentarily drain the
    ///    buffer; with waiting ON the player re-buffers and AUTO-RESUMES. With waiting
    ///    OFF, Apple's docs say a drained buffer flips timeControlStatus to paused and
    ///    rate to 0.0 and STAYS there (we have no stall-recovery), which showed up as an
    ///    intermittent "seek then frozen" stall. HLS doesn't suffer the resource-loader
    ///    many-moof buffering evaluation, so there's no startup cost to waiting here.
    ///
    ///  • Resource loader / batch: keep waiting OFF + playImmediately. The custom-scheme
    ///    single fragmented MP4 otherwise makes AVPlayer issue ~40 sequential many-moof
    ///    range probes (AVPlayerWaitingWhileEvaluatingBufferingRateReason) before it will
    ///    play, which over a slow origin times out the loader and fails the item.
    /// Map the streaming session's color format to the monitor's HDR-format enum (the
    /// monitor has no dependency on the streaming module, so they're separate types).
    private static func monitorFormat(_ f: GMStreamSession.ColorInfo.Format) -> GMPlaybackMonitor.HDRFormat {
        switch f {
        case .dolbyVision: .dolbyVision
        case .hdr10Plus: .hdr10Plus
        case .hdr10: .hdr10
        case .hlg: .hlg
        case .hdrPQ: .hdrPQ
        case .sdr: .sdr
        }
    }

    private func beginPlayback(
        asset: AVURLAsset,
        isLoopback: Bool,
        hdrFormat: GMPlaybackMonitor.HDRFormat? = nil,
        doviProfile: Int = 0,
        knownTransferName: String? = nil
    ) {
        // Required for iOS Picture-in-Picture + background audio (no-op elsewhere).
        GMAudioSession.activatePlayback()
        let item = AVPlayerItem(asset: asset)

        if isLoopback {
            // HLS: let AVPlayer manage buffering; it auto-resumes after a stall. Leave
            // preferredForwardBufferDuration at 0 (auto) so it can pick a healthy buffer.
            player.automaticallyWaitsToMinimizeStalling = true
            player.replaceCurrentItem(with: item)
            monitor.attach(
                player: player,
                item: item,
                knownFormat: hdrFormat,
                doviProfile: doviProfile,
                knownTransferName: knownTransferName
            )
            state = .readyToPlay
            player.play()
        } else {
            // Single-fMP4 / batch: start the moment the buffer is non-empty, skipping the
            // long many-moof buffering-rate evaluation. A small forward buffer keeps start
            // latency low; AVPlayer still refills as it plays.
            player.automaticallyWaitsToMinimizeStalling = false
            item.preferredForwardBufferDuration = 2 // seconds; 0 = auto. small = start sooner
            player.replaceCurrentItem(with: item)
            monitor.attach(
                player: player,
                item: item,
                knownFormat: hdrFormat,
                doviProfile: doviProfile,
                knownTransferName: knownTransferName
            )
            state = .readyToPlay
            // playImmediately starts at rate 1.0 without waiting to minimize stalls.
            player.playImmediately(atRate: 1.0)
        }
        observeItemEndForLooping(item)
    }

    /// Restart from the start when the item reaches the end, IF looping is on. Uses a
    /// seek-and-play on the same item (no AVPlayerLooper / AVQueuePlayer churn, so the
    /// streaming server and current item stay alive). Replaces any prior observer.
    private func observeItemEndForLooping(_ item: AVPlayerItem) {
        if let token = endObserver { NotificationCenter.default.removeObserver(token) }
        player.actionAtItemEnd = loops ? .none : .pause
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.loops else { return }
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                self.player.play()
                self.log.info("loop: restarting from start")
            }
        }
    }

    // MARK: - Temp files

    private static func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gm-\(UUID().uuidString).mp4")
    }

    private func cleanupTemp() {
        if let t = currentTempURL { try? FileManager.default.removeItem(at: t) }
        currentTempURL = nil
    }
}
