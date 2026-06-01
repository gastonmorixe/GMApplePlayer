//
//  ControlsVisibilityModel.swift
//  The auto-hide behavior for the player's custom overlay: reveal on pointer
//  activity, hide (and hide the pointer) after an idle timeout, in sync with
//  AVKit's floating controls. This is behavior/logic, kept out of the views.
//

import Combine
import Foundation
import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

@MainActor
final class ControlsVisibilityModel: ObservableObject {
    @Published private(set) var isVisible = true

    private var hideWorkItem: DispatchWorkItem?
    private let idleInterval: TimeInterval

    /// Matches the gentle fade of AVKit's own floating transport chrome.
    private let fade: Animation = .easeInOut(duration: 0.25)

    init(idleInterval: TimeInterval = 3) {
        self.idleInterval = idleInterval
    }

    /// Pointer moved / user tapped: show controls, un-hide the pointer, restart
    /// the idle countdown.
    func registerActivity() {
        if !isVisible { withAnimation(fade) { isVisible = true } }
        #if os(macOS)
            NSCursor.unhide()
        #endif
        scheduleHide()
    }

    /// Explicit toggle (used by tap on touch platforms).
    func toggle() {
        if isVisible {
            withAnimation(fade) { isVisible = false }
        } else {
            registerActivity()
        }
    }

    /// Hide immediately, cancelling any pending idle countdown. Used on macOS when
    /// the pointer leaves the window entirely (QuickTime fades its chrome on exit,
    /// not only after the idle timeout). We do NOT force-hide the cursor here: it
    /// has already left our window, so its visibility isn't ours to manage.
    func hideNow() {
        hideWorkItem?.cancel()
        guard isVisible else { return }
        withAnimation(fade) { isVisible = false }
    }

    /// Pin the chrome visible and CANCEL any pending hide (no reschedule). Used on
    /// macOS while the pointer sits in the titlebar strip / over the traffic-light
    /// buttons: those buttons live above our content, so the idle timer must not
    /// fade them out from under the user reaching to click ([BUG #19ab09]). Normal
    /// idle scheduling resumes as soon as the pointer moves back over the video.
    func keepVisible() {
        hideWorkItem?.cancel()
        #if os(macOS)
            NSCursor.unhide()
        #endif
        if !isVisible { withAnimation(fade) { isVisible = true } }
    }

    func begin() {
        scheduleHide()
    }

    func cancel() {
        hideWorkItem?.cancel()
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(fade) { self.isVisible = false }
            #if os(macOS)
                NSCursor.setHiddenUntilMouseMoves(true)
            #endif
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleInterval, execute: work)
    }
}
