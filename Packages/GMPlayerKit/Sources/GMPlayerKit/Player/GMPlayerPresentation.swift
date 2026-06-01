//
//  GMPlayerPresentation.swift
//  The *policy* that drives how the native player is hosted on each platform.
//
//  SwiftUI view rendering, tvOS focus, and Siri-remote input can't be asserted
//  in a unit test (no render server, no focus engine off-device). So the
//  decisions that actually cause the two reported tvOS bugs -- (1) the native
//  transport controls never appearing because the player isn't a focusable,
//  control-bearing container, and (2) the video not filling the screen because
//  only the bottom safe-area edge was ignored -- are pulled out of the views
//  and into this pure, platform-parameterized value type. The views consume it;
//  the tests pin it for all three platforms regardless of the host OS.
//

import Foundation

/// The Apple platform a build targets. Explicit (not just `#if`) so tests can
/// evaluate the presentation policy for every platform on any host.
public enum GMPlatform: String, CaseIterable, Sendable {
    case macOS
    case iOS
    case tvOS

    /// The platform this binary is running on.
    public static var current: GMPlatform {
        #if os(macOS)
            .macOS
        #elseif os(tvOS)
            .tvOS
        #else
            .iOS
        #endif
    }
}

/// How the video image scales within the player's bounds. Mirrors
/// `AVLayerVideoGravity` but stays dependency-free so it's trivially testable.
public enum GMVideoGravity: String, Sendable {
    /// Preserve aspect ratio, letterbox to fit. Correct default for a player:
    /// fills the available area without distorting or cropping.
    case resizeAspect
    /// Preserve aspect ratio, crop to fill.
    case resizeAspectFill
    /// Stretch to fill, ignoring aspect ratio.
    case resize
}

/// The screen edges a player view extends under (i.e. ignores the safe area on).
public struct GMSafeAreaEdges: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let top = GMSafeAreaEdges(rawValue: 1 << 0)
    public static let leading = GMSafeAreaEdges(rawValue: 1 << 1)
    public static let bottom = GMSafeAreaEdges(rawValue: 1 << 2)
    public static let trailing = GMSafeAreaEdges(rawValue: 1 << 3)

    public static let none: GMSafeAreaEdges = []
    public static let all: GMSafeAreaEdges = [.top, .leading, .bottom, .trailing]
}

/// The resolved hosting policy for the native player on a given platform.
public struct GMPlayerPresentation: Equatable, Sendable {
    /// AVKit draws its own native transport UI (the system player chrome:
    /// scrubber, play/pause, subtitle + audio selection). On tvOS this UI only
    /// appears when the player is a focusable container receiving remote input,
    /// which is exactly what `requiresFocusableContainer` guarantees.
    public var usesNativeTransportControls: Bool

    /// The app draws its own auxiliary overlay (info / tracks / close buttons).
    /// Off on tvOS: the native focus-driven UI owns the experience there, and a
    /// non-focusable SwiftUI overlay layered on top would only fight the remote.
    public var usesCustomOverlay: Bool

    /// How the video scales within the player bounds.
    public var videoGravity: GMVideoGravity

    /// Which edges the player view extends under. A full-screen player must
    /// ignore the safe area entirely on tvOS, where the title-safe inset is
    /// large on every edge and otherwise shrinks the video into a centered box.
    public var ignoredSafeAreaEdges: GMSafeAreaEdges

    /// The player container must be focusable so the Siri Remote can reveal and
    /// drive the native transport bar (tvOS). False where focus isn't a concept
    /// (pointer-driven macOS, touch-driven iOS).
    public var requiresFocusableContainer: Bool

    public init(
        usesNativeTransportControls: Bool,
        usesCustomOverlay: Bool,
        videoGravity: GMVideoGravity,
        ignoredSafeAreaEdges: GMSafeAreaEdges,
        requiresFocusableContainer: Bool
    ) {
        self.usesNativeTransportControls = usesNativeTransportControls
        self.usesCustomOverlay = usesCustomOverlay
        self.videoGravity = videoGravity
        self.ignoredSafeAreaEdges = ignoredSafeAreaEdges
        self.requiresFocusableContainer = requiresFocusableContainer
    }

    /// Resolve the hosting policy for a platform.
    public static func resolve(for platform: GMPlatform) -> GMPlayerPresentation {
        switch platform {
        case .macOS:
            // AVPlayerView (NSView) with floating transport controls. Pointer
            // driven; the app also shows a mouse-activity overlay. Full-bleed:
            // the video extends under the transparent titlebar for the QuickTime
            // immersive look (the title + traffic lights fade in on pointer
            // activity). AVKit floats its transport bar within the safe area, and
            // our custom top bar reserves its own clearance, so nothing is clipped.
            GMPlayerPresentation(
                usesNativeTransportControls: true,
                usesCustomOverlay: true,
                videoGravity: .resizeAspect,
                ignoredSafeAreaEdges: .all,
                requiresFocusableContainer: false
            )
        case .iOS:
            // The native AVPlayerViewController owns the experience: it auto-enters
            // full screen when playback begins (entersFullScreenWhenPlaybackBegins),
            // and its native collapse (X) button is the way back to the landing
            // screen. We do NOT layer a custom overlay here, on iOS it would sit
            // BEHIND the native full-screen presentation and compete with the native
            // controls for taps (the cause of the "no way back" report). This mirrors
            // tvOS: let the first-party player own a full-screen video surface.
            GMPlayerPresentation(
                usesNativeTransportControls: true,
                usesCustomOverlay: false,
                videoGravity: .resizeAspect,
                ignoredSafeAreaEdges: .all,
                requiresFocusableContainer: false
            )
        case .tvOS:
            // The native focus-driven player owns the whole screen. No custom
            // overlay (it would only steal focus from the remote), full-bleed
            // video, and a focusable container so the transport bar appears.
            GMPlayerPresentation(
                usesNativeTransportControls: true,
                usesCustomOverlay: false,
                videoGravity: .resizeAspect,
                ignoredSafeAreaEdges: .all,
                requiresFocusableContainer: true
            )
        }
    }

    /// The policy for the platform this build runs on.
    public static var current: GMPlayerPresentation {
        resolve(for: .current)
    }
}
