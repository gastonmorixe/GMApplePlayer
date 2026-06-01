//
//  LandingStatusView.swift
//  Busy/progress state on the landing screen (probing / remuxing). Pure
//  presentation driven by the player state value.
//

import GMPlayerKit
import SwiftUI

struct LandingStatusView: View {
    let state: GMPlayerModel.State
    let sourceName: String

    var body: some View {
        VStack(spacing: GMSpace.md) {
            switch state {
            case let .probing(status):
                ProgressView().controlSize(.small)
                Text("\(probePhaseLabel(status.phase)) \(sourceName)…")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if status.bytesRead > 0 {
                    probeDetailText(status)
                        .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                        .animation(.default, value: status.bytesRead)
                }
            case let .remuxing(progress):
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
                Text("Preparing \(sourceName) · \(Int(progress * 100))%")
                    .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: 320)
    }

    private func probePhaseLabel(_ phase: GMPlayerModel.ProbeStatus.Phase) -> String {
        switch phase {
        case .connecting: "Connecting to"
        case .inspecting: "Inspecting"
        }
    }

    /// The live byte/rate readout, with a smooth digit roll where the OS supports it.
    @ViewBuilder
    private func probeDetailText(_ status: GMPlayerModel.ProbeStatus) -> some View {
        let label = Text(probeDetail(status))
        if #available(macOS 13.0, iOS 16.0, tvOS 16.0, *) {
            label.contentTransition(.numericText())
        } else {
            label
        }
    }

    /// "2.4 MB read · 310 KB/s", bytes always, rate only once measurable.
    private func probeDetail(_ status: GMPlayerModel.ProbeStatus) -> String {
        let read = Self.byteFormatter.string(fromByteCount: status.bytesRead)
        guard status.bytesPerSec > 0 else { return "\(read) read" }
        let rate = Self.byteFormatter.string(fromByteCount: Int64(status.bytesPerSec))
        return "\(read) read · \(rate)/s"
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()
}
