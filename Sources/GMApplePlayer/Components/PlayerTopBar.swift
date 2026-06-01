//
//  PlayerTopBar.swift
//  The player's auto-hiding top chrome, modeled on QuickTime Player: a centered
//  title with a trailing Liquid Glass control cluster, sitting over a soft top
//  scrim so it stays legible against bright video. Visibility is owned by the
//  caller (ControlsVisibilityModel); this view is pure presentation and emits
//  intents via closures.
//
//  On macOS a leading inset keeps the centered title clear of the traffic-light
//  buttons (which the window chrome fades in/out in lockstep with this bar).
//

import GMPlayerKit
import SwiftUI

struct PlayerTopBar: View {
    @ObservedObject var monitor: GMPlaybackMonitor
    let title: String
    @Binding var showHUD: Bool
    let onTracks: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: GMSpace.md) {
            ZStack {
                titleLabel
                HStack {
                    Spacer(minLength: 0)
                    buttonCluster
                }
            }
            .frame(maxWidth: .infinity)

            if showHUD {
                TelemetryHUD(monitor: monitor)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, GMSpace.lg)
        .padding(.top, topInset)
        .padding(.bottom, GMSpace.md)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(scrim)
        .transition(.opacity)
    }

    // MARK: - Title

    private var titleLabel: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.middle)
            .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
            // Keep the centered title clear of the leading traffic lights and the
            // trailing cluster so it truncates instead of colliding.
            .padding(.horizontal, titleClearance)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Controls

    @ViewBuilder
    private var buttonCluster: some View {
        let buttons = HStack(spacing: GMSpace.sm) {
            GlassIconButton(
                systemImage: showHUD ? "info.circle.fill" : "info.circle",
                label: showHUD ? "Hide diagnostics" : "Show diagnostics"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { showHUD.toggle() }
            }
            GlassIconButton(systemImage: "slider.horizontal.3", label: "Tracks", action: onTracks)
            GlassIconButton(systemImage: "xmark", label: "Close", action: onClose)
        }

        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            GlassEffectContainer(spacing: GMSpace.sm) { buttons }
        } else {
            buttons
        }
    }

    // MARK: - Scrim

    /// A soft top-to-clear gradient so white controls stay readable over bright
    /// video, the way every system video player darkens behind its top chrome.
    private var scrim: some View {
        LinearGradient(
            colors: [.black.opacity(0.55), .black.opacity(0.0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    // MARK: - Metrics

    /// Extra top padding so the bar clears the system menu/notch area.
    private var topInset: CGFloat {
        #if os(macOS)
            GMSpace.sm
        #else
            GMSpace.xs
        #endif
    }

    /// Horizontal breathing room reserved on each side of the centered title.
    /// Wider on macOS to clear the traffic-light cluster on the leading edge.
    private var titleClearance: CGFloat {
        #if os(macOS)
            96
        #else
            64
        #endif
    }
}
