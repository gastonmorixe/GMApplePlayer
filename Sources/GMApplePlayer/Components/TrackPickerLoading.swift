//
//  TrackPickerLoading.swift
//  Placeholder shown while the model probes the source on demand (the streaming
//  fast-path doesn't probe up front, so the picker has no streams to list yet).
//

import SwiftUI

/// Placeholder shown while the model probes the source on demand (the streaming
/// fast-path doesn't probe up front, so the picker has no streams to list yet).
struct TrackPickerLoading: View {
    var body: some View {
        VStack(alignment: .leading, spacing: GMSpace.xl) {
            Text("Tracks").font(.title2).bold()
            HStack(spacing: GMSpace.md) {
                ProgressView()
                Text("Reading tracks…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(GMSpace.xxl)
        #if os(macOS)
            .frame(width: 460)
        #endif
            .gmCompactSheet()
    }
}
