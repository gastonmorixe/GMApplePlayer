//
//  StreamDiagnostics.swift
//  Shows the failure message plus the probed stream list (which streams are
//  AVFoundation-compatible) when opening a file fails.
//

import GMPlayerKit
import SwiftUI

struct StreamDiagnostics: View {
    let message: String
    let probe: GMProbeResult?

    var body: some View {
        VStack(spacing: GMSpace.sm) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let probe {
                VStack(alignment: .leading, spacing: GMSpace.xs) {
                    ForEach(probe.streams) { stream in
                        Label(
                            stream.displayLabel,
                            systemImage: stream.avfCompatible ? "checkmark.circle" : "xmark.circle"
                        )
                        .font(.caption.monospaced())
                        .foregroundStyle(stream.avfCompatible ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    }
                }
                .padding(.top, GMSpace.xs)
            }
        }
        .frame(maxWidth: 360)
    }
}
