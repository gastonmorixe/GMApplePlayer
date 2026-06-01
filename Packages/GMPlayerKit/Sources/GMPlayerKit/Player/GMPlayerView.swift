//
//  GMPlayerView.swift
//  A SwiftUI view that wraps AVKit's native player UI on each platform. The
//  hosting policy (controls, gravity, focus, safe area) lives in
//  GMPlayerPresentation; this file is just the platform-specific plumbing that
//  realizes that policy with the right AVKit type.
//
//  macOS: AVKit does not vend AVPlayerViewController (that class is iOS / tvOS /
//         visionOS / Mac Catalyst only -- it's a UIViewController subclass, and
//         AppKit has none). The native AVKit player on macOS is AVPlayerView, an
//         NSView, wrapped via NSViewRepresentable. Floating transport controls,
//         full-screen toggle, PiP.
//
//  iOS:   AVPlayerViewController via UIViewControllerRepresentable. Native
//         transport bar + PiP. Touch-driven, so no focus concerns.
//
//  tvOS:  SwiftUI's first-party VideoPlayer (AVKit, tvOS 14+). It wraps
//         AVPlayerViewController *and* integrates with SwiftUI's focus engine,
//         so the Siri Remote reveals and drives the native transport bar. The
//         old hand-rolled UIViewControllerRepresentable embedded in a ZStack
//         never became the focused environment, so the remote did nothing and
//         no controls appeared. VideoPlayer fixes that. It also fills its frame
//         (resizeAspect) -- paired with the full safe-area policy in
//         PlayerScreen, the video finally fills the screen.
//
//  One public `GMPlayerView(player:)` for all three platforms.
//

import AVFoundation
import AVKit
import SwiftUI

#if os(macOS)
    import AppKit

    public struct GMPlayerView: NSViewRepresentable {
        private let player: AVPlayer
        private let presentation: GMPlayerPresentation

        /// `onExitFullScreen` is part of the uniform cross-platform API; it only has
        /// meaning on iOS (native full-screen dismissal). macOS hosts an inline
        /// AVPlayerView with its own full-screen toggle, so it's accepted and ignored.
        public init(
            player: AVPlayer,
            presentation: GMPlayerPresentation = .current,
            onExitFullScreen _: @escaping () -> Void = {}
        ) {
            self.player = player
            self.presentation = presentation
        }

        public func makeNSView(context: Context) -> AVPlayerView {
            let view = AVPlayerView()
            view.player = player
            // Floating transport controls = the macOS default (what QuickTime uses):
            // a rounded glassy control bar that auto-hides on mouse idle and floats
            // over the video. The earlier ~10fps judder was NOT these controls; it
            // was bad DTS in our remux (fixed in gmremux.c).
            view.controlsStyle = presentation.usesNativeTransportControls ? .floating : .none
            view.showsFullScreenToggleButton = true
            view.videoGravity = presentation.videoGravity.avLayerVideoGravity
            view.allowsPictureInPicturePlayback = true
            // NOTE: We intentionally do NOT poke the backing layer's EDR flag or
            // force the window colorspace. AVPlayerView hosts its own AVPlayerLayer
            // and drives HDR->EDR + GPU compositing automatically on capable
            // displays. Forcing wantsLayer/extendedSRGB on the host view pushed the
            // window onto a slow compositing path (visible judder despite zero
            // dropped frames in the AVPlayerItem access log). Let AVKit own it.
            return view
        }

        public func updateNSView(_ view: AVPlayerView, context: Context) {
            if view.player !== player { view.player = player }
            view.videoGravity = presentation.videoGravity.avLayerVideoGravity
        }
    }

#elseif os(tvOS)

    public struct GMPlayerView: View {
        private let player: AVPlayer
        private let presentation: GMPlayerPresentation

        /// `onExitFullScreen` is part of the uniform cross-platform API; it only has
        /// meaning on iOS. tvOS uses the focus-driven native player (the Menu button
        /// is the back action, handled by the caller), so it's accepted and ignored.
        public init(
            player: AVPlayer,
            presentation: GMPlayerPresentation = .current,
            onExitFullScreen _: @escaping () -> Void = {}
        ) {
            self.player = player
            self.presentation = presentation
        }

        public var body: some View {
            // VideoPlayer wraps AVPlayerViewController and cooperates with the
            // SwiftUI focus engine, so the Siri Remote reveals and drives the
            // native transport bar. The default gravity is resizeAspect, which
            // matches the policy; with the full safe-area policy applied by the
            // caller the video fills the screen.
            VideoPlayer(player: player)
        }
    }

#else
    import UIKit

    public struct GMPlayerView: UIViewControllerRepresentable {
        private let player: AVPlayer
        private let presentation: GMPlayerPresentation
        private let onExitFullScreen: () -> Void

        /// `onExitFullScreen` fires when the user dismisses the native full-screen
        /// player (its collapse "X"). The app uses it to return to the landing
        /// screen, so the native control IS the "back" affordance.
        public init(
            player: AVPlayer,
            presentation: GMPlayerPresentation = .current,
            onExitFullScreen: @escaping () -> Void = {}
        ) {
            self.player = player
            self.presentation = presentation
            self.onExitFullScreen = onExitFullScreen
        }

        public func makeUIViewController(context: Context) -> AVPlayerViewController {
            let vc = AVPlayerViewController()
            // Always full screen: present the native full-screen player the moment
            // playback begins (the app autoplays on open). Set BEFORE assigning the
            // player so the first play triggers the transition. The native player
            // then owns controls, PiP, and the X-to-dismiss back action.
            vc.entersFullScreenWhenPlaybackBegins = true
            vc.delegate = context.coordinator
            vc.player = player
            vc.showsPlaybackControls = presentation.usesNativeTransportControls
            vc.videoGravity = presentation.videoGravity.avLayerVideoGravity
            vc.allowsPictureInPicturePlayback = true
            vc.canStartPictureInPictureAutomaticallyFromInline = true
            return vc
        }

        public func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
            if vc.player !== player { vc.player = player }
            vc.videoGravity = presentation.videoGravity.avLayerVideoGravity
            context.coordinator.onExitFullScreen = onExitFullScreen
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator(onExitFullScreen: onExitFullScreen)
        }

        public final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
            var onExitFullScreen: () -> Void

            init(onExitFullScreen: @escaping () -> Void) {
                self.onExitFullScreen = onExitFullScreen
            }

            /// The user tapped the native full-screen collapse button (or swiped to
            /// dismiss). Tear the player down so the app returns to the landing
            /// screen, the native dismissal IS the app's "back".
            public func playerViewController(
                _: AVPlayerViewController,
                willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
            ) {
                coordinator.animate(alongsideTransition: nil) { [weak self] ctx in
                    guard !ctx.isCancelled else { return }
                    self?.onExitFullScreen()
                }
            }
        }
    }
#endif
