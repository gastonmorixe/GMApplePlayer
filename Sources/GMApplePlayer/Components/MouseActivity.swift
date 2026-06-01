//
//  MouseActivity.swift
//  Deterministic pointer-movement detection for the player overlay's auto-hide.
//
//  SwiftUI's onContinuousHover only reliably reports enter/leave, so the custom
//  HUD ended up hiding only when the pointer left the window. This uses an
//  AppKit NSTrackingArea (the same mechanism AVKit/QuickTime use) to fire on
//  every pointer move, so we can hide the HUD + pointer after an idle timeout
//  and reveal them on the next movement.
//
//  It also reports when the pointer LEAVES the window (mouseExited), so the
//  chrome can hide the instant the mouse is out of the app, the way QuickTime
//  fades its floating titlebar + controls on exit, not just on idle.
//

#if os(macOS)
    import AppKit
    import SwiftUI

    struct MouseActivityView: NSViewRepresentable {
        /// Pointer entered the window or moved within it (reveal chrome).
        let onActivity: () -> Void
        /// Pointer left the window (hide chrome immediately, QuickTime-style).
        var onExit: () -> Void = {}

        func makeNSView(context: Context) -> NSView {
            TrackingView(onActivity: onActivity, onExit: onExit)
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            guard let view = nsView as? TrackingView else { return }
            view.onActivity = onActivity
            view.onExit = onExit
        }

        final class TrackingView: NSView {
            var onActivity: () -> Void
            var onExit: () -> Void

            init(onActivity: @escaping () -> Void, onExit: @escaping () -> Void) {
                self.onActivity = onActivity
                self.onExit = onExit
                super.init(frame: .zero)
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) {
                fatalError()
            }

            override func updateTrackingAreas() {
                super.updateTrackingAreas()
                for area in trackingAreas {
                    removeTrackingArea(area)
                }
                addTrackingArea(NSTrackingArea(
                    rect: bounds,
                    options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                    owner: self,
                    userInfo: nil
                ))
            }

            override func mouseMoved(with event: NSEvent) {
                onActivity()
            }

            override func mouseEntered(with event: NSEvent) {
                onActivity()
            }

            /// Pointer left the tracking area. With `.fullSizeContentView` our view
            /// extends UNDER the titlebar, where the traffic-light buttons live as
            /// sibling views above us. Moving onto one of those buttons makes this
            /// area report `mouseExited` even though the pointer is still inside the
            /// window, and hiding here would fade out the very button the user is
            /// reaching for ([BUG #19ab09]). So only treat it as a real exit when
            /// the pointer has actually left the window's frame; otherwise it's just
            /// hovering the titlebar, which should KEEP the chrome up.
            override func mouseExited(with event: NSEvent) {
                guard let window else { onExit()
                    return
                }
                if window.frame.contains(NSEvent.mouseLocation) {
                    onActivity() // still inside (e.g. over the traffic lights): keep visible
                } else {
                    onExit() // genuinely left the window: hide, QuickTime-style
                }
            }

            /// Transparent to clicks/drags so the AVKit transport controls underneath
            /// still receive all mouse events; we only observe movement.
            override func hitTest(_ point: NSPoint) -> NSView? {
                nil
            }
        }
    }
#endif
