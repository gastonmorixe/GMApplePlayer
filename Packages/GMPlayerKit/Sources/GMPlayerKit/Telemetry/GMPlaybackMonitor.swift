//
//  GMPlaybackMonitor.swift
//  Runtime telemetry for playback quality. Logs (via os.Logger, subsystem
//  "com.gm.appleplayer") and publishes a live snapshot the UI can show:
//   - item readiness + errors
//   - real-time playback rate (mediaΔ / wallΔ): catches slow/stuttery playback
//   - stall events (playbackBufferEmpty)
//   - HDR/EDR: whether the asset is HDR and whether the display/AVPlayer is
//     eligible to render it in EDR
//
//  Stream this to the console with:
//    log stream --predicate 'subsystem == "com.gm.appleplayer"' --info
//

import AVFoundation
import Combine
import Foundation
import os

#if canImport(AppKit)
    import AppKit
#endif
#if canImport(UIKit)
    import UIKit
#endif

@MainActor
public final class GMPlaybackMonitor: ObservableObject {
    /// The specific HDR format of the source stream, for a UI tag. Mirrors
    /// GMStreamSession.ColorInfo.Format but lives here so the HUD has no streaming
    /// dependency. `.unknown` until the stream is inspected.
    public enum HDRFormat: String, Sendable, Equatable {
        case dolbyVision = "Dolby Vision"
        case hdr10Plus = "HDR10+"
        case hdr10 = "HDR10"
        case hlg = "HLG"
        case hdrPQ = "HDR (PQ)"
        case sdr = "SDR"
        case unknown = "—"

        /// True for any actual HDR format (not SDR/unknown).
        public var isHDR: Bool {
            switch self { case .sdr, .unknown: false
            default: true }
        }
    }

    public struct Snapshot: Sendable, Equatable {
        public var status = "idle"

        // ── HDR, as three DISTINCT facts (don't conflate them) ──────────────────────
        /// 1) STREAM: what the content is. Static for a given movie.
        public var hdrFormat: HDRFormat = .unknown
        public var doviProfile = 0 // Dolby Vision profile (5/7/8), 0 if not DoVi
        public var transferFunction = "" // raw CoreMedia transfer name, for detail
        /// 2) DISPLAY SUPPORT: can the current display + player present HDR at all.
        ///    Changes when displays connect/disconnect or HDR is toggled in settings.
        public var displaySupportsHDR = false // == AVPlayer.eligibleForHDRPlayback
        public var displayMaxHeadroom = 1.0 // potential EDR headroom of the panel
        /// 3) CURRENTLY ACTIVE: is EDR actually engaged on screen right now. Volatile
        ///    (brightness, window position, low-power mode, what's on screen).
        public var hdrActive = false
        public var displayCurrentHeadroom = 1.0 // live EDR headroom (1.0 == not ramped)

        /// legacy aliases (kept so existing readers compile); prefer the fields above.
        public var isHDRContent: Bool {
            hdrFormat.isHDR
        }

        public var eligibleForHDR: Bool {
            displaySupportsHDR
        }

        public var displayEDRHeadroom: Double {
            displayCurrentHeadroom
        }

        public var edrActive: Bool {
            hdrActive
        }

        public var realtimeRate: Double = 0 // 1.0 == real time
        public var stallCount = 0
        public var presentationSize: CGSize = .zero
        public var droppedFrames = 0 // cumulative, from access log
        public var observedBitrateMbps: Double = 0 // network/read throughput
        public var lastError = ""
    }

    @Published public private(set) var snapshot = Snapshot()

    private let log = Logger(subsystem: "com.gm.appleplayer", category: "playback")
    private weak var player: AVPlayer?
    private var item: AVPlayerItem?
    private var observers: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var notifTokens: [NSObjectProtocol] = []
    private var displayTimer: Timer?
    private var lastWall = Date()
    private var lastMedia: Double = 0

    public init() {}

    /// HDR state known up front from the streaming engine's source color info. For HLS
    /// playback AVFoundation does NOT reliably surface the per-track transfer function
    /// (formatDescriptions come back empty for an m3u8 asset), so the app passes the
    /// source's resolved color/format here and we trust it. `knownFormat == nil` means
    /// "fall back to probing the asset's track format descriptions".
    public func attach(
        player: AVPlayer,
        item: AVPlayerItem,
        knownFormat: HDRFormat? = nil,
        doviProfile: Int = 0,
        knownTransferName: String? = nil
    ) {
        detach()
        self.player = player
        self.item = item
        log.info("attach: monitoring new player item")

        if let knownFormat {
            // Authoritative: from the demuxer's source color info, engine-independent.
            snapshot.hdrFormat = knownFormat
            snapshot.doviProfile = doviProfile
            if let knownTransferName { snapshot.transferFunction = knownTransferName }
            log.info("HDR stream format = \(knownFormat.rawValue, privacy: .public)\(doviProfile > 0 ? " P\(doviProfile)" : "")")
        } else {
            // Fall back to probing the asset's video track (works for progressive/
            // fragmented single-file assets; unreliable for HLS).
            Task { await detectHDR(asset: item.asset) }
        }
        startObservingDisplay()
        refreshDisplayEDR()

        observers.append(item.observe(\.status, options: [.new, .initial]) { [weak self] it, _ in
            Task { @MainActor in self?.onStatus(it) }
        })
        observers.append(item.observe(\.presentationSize, options: [.new]) { [weak self] it, _ in
            Task { @MainActor in
                let size = it.presentationSize
                self?.snapshot.presentationSize = size
                self?.log.info("presentationSize \(Int(size.width))x\(Int(size.height))")
            }
        })
        observers.append(item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] it, _ in
            Task { @MainActor in
                if it.isPlaybackBufferEmpty {
                    self?.snapshot.stallCount += 1
                    let n = self?.snapshot.stallCount ?? 0
                    self?.log.warning("STALL (buffer empty) count=\(n)")
                }
            }
        })

        // Rate sampling: media time advanced vs wall-clock advanced.
        lastWall = Date()
        lastMedia = 0
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] t in
            Task { @MainActor in self?.sampleRate(currentMedia: CMTimeGetSeconds(t)) }
        }

        let failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main,
            using: { [weak self] note in
                let e = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "unknown"
                Task { @MainActor in
                    self?.snapshot.lastError = e
                    self?.log.error("failed to play to end: \(e, privacy: .public)")
                }
            }
        )
        if let token = failObserver as NSObjectProtocol? { notifTokens.append(token) }
    }

    public func detach() {
        observers.forEach { $0.invalidate() }
        observers.removeAll()
        if let t = timeObserver { player?.removeTimeObserver(t)
            timeObserver = nil
        }
        notifTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notifTokens.removeAll()
        displayTimer?.invalidate()
        displayTimer = nil
        player = nil
        item = nil
    }

    // MARK: - Display / EDR observation

    //
    // The "currently active" HDR state is VOLATILE: EDR headroom changes with display
    // brightness, which screen the window is on, low-power mode, and what is on screen.
    // Apple's guidance (WWDC21 "Explore HDR rendering with EDR") is to re-query the EDR
    // parameters when the screen changes. We subscribe to the relevant notifications AND
    // poll on a light timer, because the *current* headroom can drift without any
    // notification (e.g. a slow brightness ramp), and refresh display support from
    // AVPlayer.eligibleForHDRPlayback when its change notification fires.

    private func startObservingDisplay() {
        // Display support (HDR eligibility) change: display connect/disconnect, HDR
        // toggled in System Settings, etc.
        let elig = NotificationCenter.default.addObserver(
            forName: AVPlayer.eligibleForHDRPlaybackDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refreshDisplayEDR() } }
        notifTokens.append(elig)

        #if canImport(AppKit)
            // Screen parameters changed (resolution, EDR capability, arrangement) and the
            // window moved to another screen.
            let params = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshDisplayEDR() } }
            notifTokens.append(params)
            let moved = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshDisplayEDR() } }
            notifTokens.append(moved)
        #endif

        // Light poll for the volatile current headroom (brightness ramps post no
        // notification). 1 Hz is plenty for a HUD and negligible cost.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplayEDR() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    // MARK: - Sampling

    private func onStatus(_ it: AVPlayerItem) {
        switch it.status {
        case .readyToPlay:
            snapshot.status = "readyToPlay"
            log.info("status readyToPlay")
        case .failed:
            snapshot.status = "failed"
            let message = it.error?.localizedDescription ?? "unknown"
            snapshot.lastError = message
            log.error("status failed: \(message, privacy: .public)")
        default:
            snapshot.status = "unknown"
        }
        refreshDisplayEDR()
    }

    private func sampleRate(currentMedia: Double) {
        let now = Date()
        let wallΔ = now.timeIntervalSince(lastWall)
        let mediaΔ = currentMedia - lastMedia
        guard wallΔ > 0.2 else { return }
        let rate = mediaΔ / wallΔ
        // Only report while actually playing forward.
        if (player?.rate ?? 0) > 0, mediaΔ >= 0 {
            snapshot.realtimeRate = rate
            // (EDR/HDR-active state is maintained by refreshDisplayEDR on its own timer +
            // notifications; we don't recompute it here so the two never disagree.)

            // The real judder signal: dropped video frames + read throughput,
            // pulled from the AVPlayerItem access log. Playback clock (rate)
            // tracks AUDIO, so video judder shows up here, not in `rate`.
            var droppedDelta = 0
            if let event = item?.accessLog()?.events.last {
                let dropped = max(0, Int(event.numberOfDroppedVideoFrames))
                droppedDelta = dropped - snapshot.droppedFrames
                snapshot.droppedFrames = dropped
                if event.observedBitrate > 0 {
                    snapshot.observedBitrateMbps = event.observedBitrate / 1_000_000
                }
            }
            let totalDropped = snapshot.droppedFrames
            let rateStr = String(format: "%.2f", rate)
            if droppedDelta > 0 {
                log.warning("DROPPED \(droppedDelta) frames this second (total \(totalDropped)); rate=\(rateStr)x")
            } else if rate < 0.85 {
                let m = String(format: "%.2f", mediaΔ), w = String(format: "%.2f", wallΔ)
                log.warning("SLOW rate=\(rateStr)x (media \(m)s / wall \(w)s)")
            } else {
                // HDR is a content fact (stable); hdrActive is a display-ramp fact
                // (volatile). Log distinctly so "edr not lit" never reads as "no HDR".
                let fmt = snapshot.hdrFormat.rawValue
                let active = snapshot.hdrActive
                log.info("rate=\(rateStr)x dropped=\(totalDropped) hdr=\(fmt) active=\(active)")
            }
        }
        lastWall = now
        lastMedia = currentMedia
    }

    /// HDR detection is PURELY informational telemetry for the HUD. It must NEVER
    /// affect playback or surface as a user-facing error: it loads the video track's
    /// format descriptions, which over a slow origin can take many seconds or time out
    /// (competing with the actual playback reads). We do it lazily and swallow any
    /// failure as a debug note (not .error, which reads like a real failure in logs),
    /// and we never write to snapshot.lastError from here.
    private func detectHDR(asset: AVAsset) async {
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
            let formats = try await track.load(.formatDescriptions)
            for fmt in formats {
                let tf = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                if let tf {
                    await MainActor.run {
                        self.snapshot.transferFunction = tf
                        // PQ (ST 2084) or HLG => HDR. This fallback path can't see the
                        // DoVi/HDR10+ side data, so it reports the transfer-based format.
                        let pq = (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
                        let hlg = (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                        self.snapshot.hdrFormat = (tf == pq) ? .hdrPQ : ((tf == hlg) ? .hlg : .sdr)
                        self.log.info("video transferFunction=\(tf, privacy: .public) format=\(self.snapshot.hdrFormat.rawValue)")
                    }
                }
            }
        } catch {
            // Informational only: do NOT set lastError or change status. A slow/timed-
            // out HDR probe is not a playback failure.
            log.debug("HDR detect skipped (telemetry only): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Single source of truth for the three display-side HDR facts. Called from the
    /// attach point, item-status changes, the EDR notifications, and the 1 Hz timer.
    /// Cheap; only publishes a new snapshot if a value actually changed.
    private func refreshDisplayEDR() {
        // DISPLAY SUPPORT: can this display + player present HDR at all.
        let supports = AVPlayer.eligibleForHDRPlayback

        var current = 1.0
        var potential = 1.0
        #if canImport(AppKit)
            // Prefer the screen the player's window is on; fall back to the main screen.
            let screen = NSApplication.shared.keyWindow?.screen ?? NSScreen.main
            if let screen {
                current = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
                potential = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
            }
        #elseif canImport(UIKit)
            // iOS/tvOS: no public EDR headroom API; AVKit drives EDR. Treat an HDR-eligible
            // display as having headroom so "active" reflects content + eligibility.
            potential = supports ? 2.0 : 1.0
            current = potential
        #endif

        // CURRENTLY ACTIVE: HDR content + display supports it + the panel is actually in
        // EDR (current headroom risen above SDR, or, on iOS, eligible).
        let active = snapshot.hdrFormat.isHDR && supports && current > 1.0001

        // Publish only on change (the 1 Hz timer would otherwise churn @Published).
        if snapshot.displaySupportsHDR != supports
            || abs(snapshot.displayCurrentHeadroom - current) > 0.001
            || abs(snapshot.displayMaxHeadroom - potential) > 0.001
            || snapshot.hdrActive != active
        {
            snapshot.displaySupportsHDR = supports
            snapshot.displayCurrentHeadroom = current
            snapshot.displayMaxHeadroom = potential
            snapshot.hdrActive = active
            let c = String(format: "%.2f", current), p = String(format: "%.2f", potential)
            log.info("HDR display: supports=\(supports) headroom=\(c)/\(p) active=\(active)")
        }
    }
}
