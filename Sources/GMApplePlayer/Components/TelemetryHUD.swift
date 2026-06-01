//
//  TelemetryHUD.swift
//  A compact live inspector over the player: playback health plus HDR shown as three
//  DISTINCT facts, because they answer different questions and change independently:
//    • Stream , what the content IS (Dolby Vision / HDR10+ / HDR10 / HLG / SDR). Static.
//    • Display, whether this display + player CAN present HDR. Changes on display swap.
//    • Active , whether EDR is engaged on screen right NOW. Volatile (brightness, etc).
//  Reads GMPlaybackMonitor.snapshot, which observes display/EDR changes live.
//

import GMPlayerKit
import SwiftUI

struct TelemetryHUD: View {
    @ObservedObject var monitor: GMPlaybackMonitor

    var body: some View {
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 8) {
            row("Status", value: s.status, ok: s.status == "readyToPlay")
            row(
                "Rate",
                value: String(format: "%.2f×", s.realtimeRate),
                ok: s.realtimeRate >= 0.85 || s.realtimeRate == 0
            )

            Divider().opacity(0.2)

            // 1) STREAM format as a colored tag.
            labeled("Stream") { HDRTag(format: s.hdrFormat, doviProfile: s.doviProfile) }
            // 2) DISPLAY support.
            row(
                "Display",
                value: s.displaySupportsHDR ? "HDR capable" : "SDR only",
                ok: s.displaySupportsHDR || !s.hdrFormat.isHDR
            )
            // 3) Currently ACTIVE (live EDR engagement).
            labeled("Active now") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(s.hdrActive ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(activeText(s))
                        .foregroundStyle(s.hdrActive ? .primary : .secondary)
                }
            }
            #if os(macOS)
                row(
                    "EDR headroom",
                    value: String(format: "%.1f / %.1f", s.displayCurrentHeadroom, s.displayMaxHeadroom),
                    ok: s.displayCurrentHeadroom > 1.0 || !s.hdrFormat.isHDR
                )
            #endif

            Divider().opacity(0.2)

            row("Stalls", value: "\(s.stallCount)", ok: s.stallCount == 0)
            if s.presentationSize != .zero {
                row("Video", value: "\(Int(s.presentationSize.width))×\(Int(s.presentationSize.height))", ok: true)
            }
            if s.observedBitrateMbps > 0 {
                row("Bitrate", value: String(format: "%.1f Mbps", s.observedBitrateMbps), ok: true)
            }
            if !s.lastError.isEmpty {
                Text(s.lastError).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
        .font(.caption.monospaced())
        .gmGlassCard(cornerRadius: 14)
        .frame(maxWidth: 280)
        .animation(.easeInOut(duration: 0.2), value: s.hdrActive)
        .animation(.easeInOut(duration: 0.2), value: s.displaySupportsHDR)
    }

    private func activeText(_ s: GMPlaybackMonitor.Snapshot) -> String {
        if s.hdrActive { return "HDR engaged" }
        if !s.hdrFormat.isHDR { return "SDR content" }
        if !s.displaySupportsHDR { return "display can't show HDR" }
        return "tone-mapped (no EDR headroom)"
    }

    private func row(_ k: String, value: String, ok: Bool) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).foregroundColor(ok ? .primary : .orange)
        }
    }

    private func labeled(_ k: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            content()
        }
    }
}
