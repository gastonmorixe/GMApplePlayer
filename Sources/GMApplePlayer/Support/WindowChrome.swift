//
//  WindowChrome.swift
//  Per-screen macOS window styling. The player runs "immersive" like QuickTime:
//  the video fills the whole window (content extends under a transparent
//  titlebar), the native title is hidden, and the traffic-light buttons fade
//  out on pointer idle and back in on movement, driven by the same visibility
//  state that reveals/hides the custom overlay. The landing screen restores the
//  ordinary chrome so it reads as a normal document window.
//
//  Cross-platform: the public modifiers are no-ops off macOS, so screens call
//  them unconditionally and stay declarative.
//

import SwiftUI

#if os(macOS)
    import AppKit

    extension View {
        /// QuickTime-style window: full-bleed content, transparent titlebar, the
        /// native title hidden (we draw our own), and traffic lights that fade with
        /// `chromeVisible`. `title` is still set on the window for the Window menu
        /// and the ⌘-click proxy path.
        func gmImmersiveWindow(chromeVisible: Bool, title: String) -> some View {
            background(ImmersiveWindowChrome(chromeVisible: chromeVisible, title: title))
        }

        /// Restore the standard document-window chrome (used by the landing screen
        /// and whenever we leave the immersive player).
        func gmStandardWindow() -> some View {
            background(StandardWindowChrome())
        }
    }

    /// Styles the hosting window for immersive playback and animates the traffic
    /// lights to match `chromeVisible`. The heavy one-time styling is applied once
    /// per window; only the button alpha tracks the binding after that.
    private struct ImmersiveWindowChrome: NSViewRepresentable {
        var chromeVisible: Bool
        var title: String

        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: .zero)
            // The window isn't attached yet inside make; resolve it next runloop.
            DispatchQueue.main.async { apply(around: view, context: context) }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            apply(around: nsView, context: context)
        }

        private func apply(around view: NSView, context: Context) {
            guard let window = view.window else {
                // Still detached (first layout pass): retry once attached.
                DispatchQueue.main.async {
                    if let window = view.window { configure(window, context: context) }
                }
                return
            }
            configure(window, context: context)
        }

        private func configure(_ window: NSWindow, context: Context) {
            let coordinator = context.coordinator
            if !coordinator.didStyle {
                coordinator.didStyle = true
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isMovableByWindowBackground = true
                window.backgroundColor = .black
                window.isOpaque = true
                window.toolbar = nil
                if #available(macOS 11.0, *) {
                    window.titlebarSeparatorStyle = .none
                }
            }
            if window.title != title { window.title = title }
            fadeTrafficLights(in: window, visible: chromeVisible, animated: coordinator.didInitialApply)
            coordinator.didInitialApply = true
        }

        private func fadeTrafficLights(in window: NSWindow, visible: Bool, animated: Bool) {
            // Fade every titlebar button, not just the traffic lights, so nothing
            // lingers over the video: close/miniaturize/zoom plus the full-screen
            // and document-icon buttons (the latter two appear in some window
            // configs). Matches FOTWindow's QuickTime-style enter/exit fade set.
            let types: [NSWindow.ButtonType] = [
                .closeButton, .miniaturizeButton, .zoomButton,
                .fullScreenButton, .documentIconButton,
            ]
            let buttons: [NSButton] = types.compactMap { window.standardWindowButton($0) }
            guard !buttons.isEmpty else { return }
            let target: CGFloat = visible ? 1 : 0
            guard animated else {
                buttons.forEach { $0.alphaValue = target }
                return
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                buttons.forEach { $0.animator().alphaValue = target }
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        final class Coordinator {
            var didStyle = false
            var didInitialApply = false
        }
    }

    /// The non-immersive (landing) window treatment. The scene already opts into
    /// `.hiddenTitleBar`, so there is NO gray titlebar strip to "restore", doing
    /// so would reintroduce exactly the gray bar we want gone. Instead we keep the
    /// titlebar transparent + full-size (content edge-to-edge) and simply make the
    /// traffic lights fully visible again, since the landing screen isn't an
    /// auto-hiding immersive surface. Background switches back to the adaptive
    /// window color so the landing canvas isn't forced black.
    private struct StandardWindowChrome: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: .zero)
            DispatchQueue.main.async { restore(view.window) }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            restore(nsView.window)
        }

        private func restore(_ window: NSWindow?) {
            guard let window else { return }
            // Keep the chromeless titlebar (no gray strip), just non-immersive.
            // Black backing (matching the immersive player and the black canvas) so
            // there's no gray flash behind the SwiftUI content on launch / resize,
            // so the landing screen and the player read as one continuous black stage.
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
            window.isOpaque = true
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }
            // Traffic lights always visible on the landing screen (not immersive).
            let types: [NSWindow.ButtonType] = [
                .closeButton, .miniaturizeButton, .zoomButton,
                .fullScreenButton, .documentIconButton,
            ]
            for type in types {
                window.standardWindowButton(type)?.alphaValue = 1
            }
            window.title = "GMApplePlayer"
        }
    }

#else

    extension View {
        /// No-op off macOS (no window chrome to manage).
        func gmImmersiveWindow(chromeVisible _: Bool, title _: String) -> some View {
            self
        }

        /// No-op off macOS.
        func gmStandardWindow() -> some View {
            self
        }
    }

#endif
