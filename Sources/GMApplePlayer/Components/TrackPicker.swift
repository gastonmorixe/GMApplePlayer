//
//  TrackPicker.swift
//  Lets the user override the auto-selected video / audio track. Useful when the
//  auto heuristic picks a track you don't want (e.g. a Dolby "companion" AC-3
//  track vs the E-AC-3 feature track). Re-remuxes on apply.
//

import GMPlayerKit
import SwiftUI

struct TrackPicker: View {
    let probe: GMProbeResult
    let initialVideo: Int
    let initialAudio: Int
    let onApply: (Int, Int) -> Void
    @Environment(\.dismiss) private var dismiss

    // Local editable selection, seeded from the model's current choice. (A bound
    // `.constant` here would silently ignore every change the user makes.)
    @State private var video: Int
    @State private var audio: Int

    init(
        probe: GMProbeResult,
        initialVideo: Int,
        initialAudio: Int,
        onApply: @escaping (Int, Int) -> Void
    ) {
        self.probe = probe
        self.initialVideo = initialVideo
        self.initialAudio = initialAudio
        self.onApply = onApply
        _video = State(initialValue: initialVideo)
        _audio = State(initialValue: initialAudio)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GMSpace.xl) {
            Text("Tracks").font(.title2).bold()

            if !probe.videoStreams.isEmpty {
                VStack(alignment: .leading, spacing: GMSpace.sm) {
                    Text("Video").font(.headline)
                    Picker("Video", selection: $video) {
                        Text("Auto").tag(-1)
                        ForEach(probe.videoStreams) { s in
                            Text(s.displayLabel).tag(s.id)
                        }
                    }
                    .labelsHidden()
                    #if !os(tvOS)
                        .pickerStyle(.menu)
                    #endif
                }
            }

            VStack(alignment: .leading, spacing: GMSpace.sm) {
                Text("Audio").font(.headline)
                Picker("Audio", selection: $audio) {
                    Text("Auto").tag(-1)
                    ForEach(probe.audioStreams) { s in
                        Text(s.avfCompatible ? s.displayLabel : "\(s.displayLabel), unsupported")
                            .tag(s.id)
                    }
                }
                .labelsHidden()
                #if !os(tvOS)
                    .pickerStyle(.menu)
                #endif
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .gmCancelAction()
                    .gmSecondaryButton()
                Spacer()
                Button("Apply & Reload") {
                    onApply(video, audio)
                    dismiss()
                }
                .gmDefaultAction()
                .gmPrimaryButton()
            }
        }
        .padding(GMSpace.xxl)
        #if os(macOS)
            .frame(width: 460)
        #endif
            .gmCompactSheet()
    }
}
