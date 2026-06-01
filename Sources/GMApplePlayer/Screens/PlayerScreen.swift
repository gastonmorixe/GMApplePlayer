//
//  PlayerScreen.swift
//  Full-screen playback: the native AVKit player plus our auto-hiding top bar.
//
//  One screen, three platforms. Everything shared lives in the body: the native
//  player (GMPlayerView), the custom top bar (PlayerTopBar), and the single
//  source of truth for chrome visibility (ControlsVisibilityModel). Only three
//  things differ per platform, and they are isolated to small `#if` islands:
//
//    • macOS , immersive window (QuickTime-style: full-bleed video under a
//               transparent titlebar; traffic lights fade in lockstep with the
//               bar). Pointer movement drives visibility via MouseActivityView.
//    • iOS   , tap toggles the bar; the status bar and home indicator hide with
//               it. Native transport + PiP stay; the top bar is auxiliary chrome.
//    • tvOS  , the focus-driven native player owns the screen. No custom overlay
//               (presentation.usesCustomOverlay == false); the Menu button tears
//               the player down. No window chrome concept.
//

import GMPlayerKit
import SwiftUI

struct PlayerScreen: View {
    @ObservedObject var model: GMPlayerModel
    @Binding var showURLSheet: Bool

    @StateObject private var controls = ControlsVisibilityModel()
    @State private var showHUD = false
    @State private var showTrackPicker = false

    private let presentation = GMPlayerPresentation.current

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            // onExitFullScreen fires only on iOS, when the user dismisses the
            // native full-screen player, that's the app's "back" to the landing
            // screen. The closure is a no-op on macOS/tvOS (GMPlayerView default).
            GMPlayerView(player: model.player, onExitFullScreen: { model.stop() })
                .ignoresSafeArea(presentation.ignoredSafeAreaEdges)

            if presentation.usesCustomOverlay, controls.isVisible {
                PlayerTopBar(
                    monitor: model.monitor,
                    title: model.sourceName,
                    showHUD: $showHUD,
                    onTracks: { showTrackPicker = true },
                    onClose: { model.stop() }
                )
                .zIndex(1)
            }
        }
        // macOS: become the QuickTime-style immersive window. No-op off macOS, so
        // the call stays unconditional and the body reads the same everywhere.
        .gmImmersiveWindow(chromeVisible: controls.isVisible, title: model.sourceName)
        .modifier(PlayerInputModifier(controls: controls, onExit: { model.stop() }))
        .sheet(isPresented: $showTrackPicker) {
            // On the streaming fast-path the model hasn't probed yet, so
            // `model.probe` is nil here. Probe on demand and show a spinner
            // meanwhile instead of an empty sheet.
            Group {
                if let probe = model.probe {
                    TrackPicker(
                        probe: probe,
                        initialVideo: model.selectedVideo,
                        initialAudio: model.selectedAudio,
                        onApply: { video, audio in model.selectTracks(video: video, audio: audio) }
                    )
                } else {
                    TrackPickerLoading()
                }
            }
            .task { await model.ensureProbe() }
        }
    }
}

/// The per-platform input + system-chrome wiring, kept in one place so the main
/// body stays declarative and identical across platforms. Each platform only
/// feeds the shared ControlsVisibilityModel and hides/shows system overlays.
private struct PlayerInputModifier: ViewModifier {
    @ObservedObject var controls: ControlsVisibilityModel
    let onExit: () -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
            content
                // Passive pointer observation. Movement (or entering the window)
                // reveals the bar; an idle timeout hides it; and the pointer
                // LEAVING the window hides it at once, the way QuickTime fades its
                // titlebar + controls the moment the mouse is out of the app.
                // MouseActivityView's hitTest returns nil, so it NEVER intercepts a
                // click/drag, the native AVPlayerView controls underneath get every
                // event. We only observe, the same movement signal AVKit's floating
                // controls use, so the two ride together without us touching the
                // native control UI.
                .overlay(
                    MouseActivityView(
                        onActivity: { controls.registerActivity() },
                        onExit: { controls.hideNow() }
                    )
                    .allowsHitTesting(false)
                )
                .onAppear { controls.begin() }
                .onDisappear { controls.cancel() }
        #elseif os(iOS)
            // The native AVPlayerViewController auto-enters full screen and owns the
            // whole experience (controls, status bar, home indicator, and the X that
            // returns to the landing screen). There's no custom overlay on iOS, so
            // there's nothing to tap-toggle or hide here, adding gestures/overlays
            // would only compete with the native full-screen player.
            content
        #elseif os(tvOS)
            // The player is swapped in as the window root (no NavigationStack), so
            // the Siri Remote's Menu/Back at the root would otherwise quit the app.
            // Capture it and tear the player down, returning to the landing screen.
            content.onExitCommand(perform: onExit)
        #else
            content
        #endif
    }
}
