//
//  HDRTag.swift
//  A small colored token for the stream's HDR format, the way a media inspector
//  badges the format. Dolby Vision shows its profile.
//

import GMPlayerKit
import SwiftUI

/// A small colored token for the stream's HDR format, the way a media inspector badges
/// the format. Dolby Vision shows its profile.
struct HDRTag: View {
    let format: GMPlaybackMonitor.HDRFormat
    var doviProfile = 0

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.22), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 0.5))
            .foregroundStyle(tint)
    }

    private var label: String {
        switch format {
        case .dolbyVision: doviProfile > 0 ? "Dolby Vision · P\(doviProfile)" : "Dolby Vision"
        default: format.rawValue
        }
    }

    private var tint: Color {
        switch format {
        case .dolbyVision: .purple
        case .hdr10Plus: .orange
        case .hdr10: .yellow
        case .hlg: .teal
        case .hdrPQ: .mint
        case .sdr: .secondary
        case .unknown: .secondary
        }
    }
}
