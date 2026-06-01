//
//  EngineSettingsSheet.swift
//  Playback settings: choose the streaming engine. The default (Automatic) uses the
//  HLS loopback server, which starts instantly and seeks cleanly even on 40-80 GB
//  REMUX MKVs. The single-file resource loader is kept as an experimental option
//  (best for small/medium files; it can stall to "loading forever" on huge ones).
//
//  The choice is persisted in UserDefaults via @AppStorage("enginePreference") and
//  read back by ContentView, which copies it into GMPlayerModel.enginePreference
//  before each open. Takes effect on the next movie opened.
//

import GMPlayerKit
import SwiftUI

/// The persisted key + raw values are shared between this sheet and ContentView.
/// Keep the raw strings in sync with GMStreamingEngine.Preference.rawValue.
enum EnginePreferenceStore {
    static let key = "enginePreference"
    static let defaultValue = GMStreamingEngine.Preference.auto.rawValue

    /// Map a stored raw string back to the engine preference (tolerant of bad data).
    static func preference(from raw: String) -> GMStreamingEngine.Preference {
        GMStreamingEngine.Preference(rawValue: raw) ?? .auto
    }
}

/// Persisted playback options shared between the sheet and ContentView.
enum PlaybackPrefs {
    static let loopKey = "loopPlayback"
}

struct EngineSettingsSheet: View {
    @AppStorage(EnginePreferenceStore.key) private var enginePreference = EnginePreferenceStore.defaultValue
    @AppStorage(PlaybackPrefs.loopKey) private var loopPlayback = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: GMSpace.lg) {
            VStack(alignment: .leading, spacing: GMSpace.xs) {
                Text("Playback Settings").font(.title2).bold()
                Text("How movies are streamed to the player. Applies to the next movie you open.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: GMSpace.sm) {
                Text("Streaming Engine").font(.headline)
                Picker("Streaming Engine", selection: $enginePreference) {
                    ForEach(GMStreamingEngine.Preference.allCases, id: \.rawValue) { pref in
                        Text(pref.label).tag(pref.rawValue)
                    }
                }
                #if os(tvOS)
                .pickerStyle(.inline)
                #else
                .pickerStyle(.menu)
                #endif
                .labelsHidden()

                Text(detail(for: EnginePreferenceStore.preference(from: enginePreference)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: GMSpace.sm) {
                Text("Playback").font(.headline)
                Toggle(isOn: $loopPlayback) {
                    Label("Loop", systemImage: "repeat")
                }
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
                Text("Restart the movie from the beginning when it reaches the end.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Done", action: { dismiss() })
                    .gmDefaultAction()
                    .gmPrimaryButton()
            }
        }
        .padding(GMSpace.xxl)
        #if os(macOS)
            .frame(width: 460)
        #elseif os(tvOS)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.thinMaterial)
            .ignoresSafeArea()
        #endif
            .gmCompactSheet()
    }

    private func detail(for pref: GMStreamingEngine.Preference) -> String {
        switch pref {
        case .auto:
            "Recommended. Uses the HLS loopback server: instant start and smooth seeking on any size file, including 40-80 GB 4K REMUX movies."
        case .loopback:
            "Always use the HLS loopback server. Same as Automatic today."
        case .resourceLoader:
            "Experimental single-file engine. Good for small or medium files, but can stall on very large many-fragment movies."
        }
    }
}
