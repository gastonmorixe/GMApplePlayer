//
//  GlassStyle.swift
//  Liquid Glass styling helpers, with graceful fallback on OSes that predate it.
//  Liquid Glass (`.glassEffect`) is iOS 26 / macOS 26 / tvOS 26. On older OSes we
//  fall back to a translucent material card so the UI still looks modern.
//

import SwiftUI

extension View {
    /// A rounded "card" surface: Liquid Glass on OS 26+, else .ultraThinMaterial.
    @ViewBuilder
    func gmGlassCard(cornerRadius: CGFloat = GMRadius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            padding(GMSpace.lg).glassEffect(.regular, in: shape)
        } else {
            padding(GMSpace.lg)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
    }

    /// A glassy capsule for buttons / chips.
    ///
    /// IMPORTANT: do NOT use `.regular.interactive()` here. `.interactive()`
    /// registers the glass shape for per-frame hit-testing/animation readiness,
    /// which forces a main-thread SDFLayer recompute on every CoreAnimation
    /// commit. When such a capsule is overlaid on the 24fps 4K video player, the
    /// CA commit blows past the ~42ms frame deadline and CAImageQueue evicts
    /// ~half the video frames at present time (measured: ~48% IQ-CA drops, zero
    /// decoder drops), i.e. choppy video while audio stays smooth. `.regular`
    /// computes the glass once and caches it. (Verified by profiling vs QuickTime.)
    @ViewBuilder
    func gmGlassCapsule() -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.ultraThinMaterial, in: Capsule())
        }
    }
}

extension View {
    /// The single primary action button.
    ///
    /// tvOS is its own case on purpose: the system there is a focus-driven 10-foot
    /// UI, and the glass/prominent styles render as flat tinted pills that don't
    /// take the focus highlight (the "weird coloured button" the user saw). The
    /// native tvOS affordance is `.bordered`, which the focus engine lifts, scales,
    /// and brightens when the Siri Remote lands on it. On iOS/macOS keep Liquid
    /// Glass prominent (OS 26+) with a borderedProminent fallback.
    @ViewBuilder
    func gmPrimaryButton() -> some View {
        #if os(tvOS)
            buttonStyle(.bordered)
        #else
            if #available(iOS 26.0, macOS 26.0, *) {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.borderedProminent)
            }
        #endif
    }

    /// The secondary action button. tvOS uses the same native `.bordered` focusable
    /// style as primary (hierarchy on tvOS comes from focus, not tint); iOS/macOS
    /// use plain Liquid Glass on OS 26+ with a bordered fallback.
    @ViewBuilder
    func gmSecondaryButton() -> some View {
        #if os(tvOS)
            buttonStyle(.bordered)
        #else
            if #available(iOS 26.0, macOS 26.0, *) {
                buttonStyle(.glass)
            } else {
                buttonStyle(.bordered)
            }
        #endif
    }
}

extension View {
    /// Bind a button to Return (the default action). No-op on tvOS, which has no
    /// hardware keyboard concept for `keyboardShortcut`.
    @ViewBuilder
    func gmDefaultAction() -> some View {
        #if os(tvOS)
            self
        #else
            keyboardShortcut(.defaultAction)
        #endif
    }

    /// Bind a button to Escape (the cancel action). No-op on tvOS.
    @ViewBuilder
    func gmCancelAction() -> some View {
        #if os(tvOS)
            self
        #else
            keyboardShortcut(.cancelAction)
        #endif
    }

    /// Present a compact sheet on iPhone: a medium detent + drag indicator, the
    /// native pattern for a short form. No-op below iOS 16 and on other platforms.
    @ViewBuilder
    func gmCompactSheet() -> some View {
        #if os(iOS)
            if #available(iOS 16.0, *) {
                presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            } else {
                self
            }
        #else
            self
        #endif
    }
}

extension Color {
    /// The app canvas. Pure black on every platform: this is a media player, so it
    /// commits to a dark, cinematic surface end-to-end (the landing screen and the
    /// player read as one continuous black stage, like QuickTime / TV). The app
    /// also pins the dark color scheme (see ContentView) so system text + control
    /// colors resolve light-on-dark against this.
    static var gmCanvas: Color {
        .black
    }
}
