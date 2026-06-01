//
//  GlassIconButton.swift
//  A circular Liquid Glass icon button for the player overlay. Carries an
//  accessibility label (icon-only buttons are otherwise opaque to VoiceOver) and
//  honors Apple's 44pt minimum hit target.
//
//  NOTE: uses non-interactive `.regular` glass on purpose, `.interactive()`
//  forces a per-frame SDFLayer recompute that drops video frames when overlaid
//  on the live player (see GlassStyle.gmGlassCapsule).
//

import SwiftUI

struct GlassIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .gmGlassCapsule()
        .accessibilityLabel(label)
    }
}
