//
//  GMAudioSession.swift
//  Configures the audio session so playback (and Picture-in-Picture) behave
//  correctly. PiP on iOS requires an active `.playback` AVAudioSession and the
//  "audio" UIBackgroundMode (set in Info.plist); without it PiP will not start.
//  No-op on macOS/tvOS (no AVAudioSession to configure the same way).
//

import Foundation

#if os(iOS)
    import AVFoundation

    enum GMAudioSession {
        /// Activate a playback audio session. Safe to call repeatedly.
        static func activatePlayback() {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
            } catch {
                // Non-fatal: playback still works inline; only PiP/background needs this.
                NSLog("GMAudioSession: failed to activate playback session: \(error.localizedDescription)")
            }
        }
    }
#else
    enum GMAudioSession {
        static func activatePlayback() {}
    }
#endif
