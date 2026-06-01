//
//  ContentView.swift
//  Thin window root: owns the per-window models and routes between the landing
//  screen and the player screen. All file/URL logic lives in
//  MediaImportCoordinator; all view content lives in Screens/ and Components/.
//

import GMPlayerKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = GMPlayerModel()
    @State private var showURLSheet = false
    @State private var showSettingsSheet = false
    /// Persisted streaming-engine choice (see EngineSettingsSheet). Copied into the
    /// model before every open so the user's pick (Automatic / loopback / single-file)
    /// drives playback. Defaults to Automatic (HLS loopback: instant on huge files).
    @AppStorage(EnginePreferenceStore.key) private var enginePreference = EnginePreferenceStore.defaultValue
    /// Persisted "loop the movie" toggle. Applied to the model live, so flipping it in
    /// Settings during playback takes effect immediately (and persists for next time).
    @AppStorage(PlaybackPrefs.loopKey) private var loopPlayback = false

    var body: some View {
        Group {
            if case .readyToPlay = model.state {
                PlayerScreen(model: model, showURLSheet: $showURLSheet)
            } else {
                LandingScreen(
                    model: model,
                    importer: importer,
                    showURLSheet: $showURLSheet,
                    showSettingsSheet: $showSettingsSheet
                )
            }
        }
        #if os(macOS)
        .frame(minWidth: 820, minHeight: 540)
        #endif
        // A media player commits to a dark, cinematic look. Pinning dark means the
        // black canvas (Color.gmCanvas) is correct in every system appearance, and
        // system semantic colors (.primary/.secondary, glass button styles) resolve
        // light-on-dark instead of black-on-black in Light Mode. Sheets inherit it.
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showURLSheet) {
            OpenURLSheet { url in importer.open(remoteURL: url) }
        }
        .sheet(isPresented: $showSettingsSheet) {
            EngineSettingsSheet()
        }
        .onAppear {
            applyEnginePreference()
            model.loops = loopPlayback
            importer.consumeLaunchArgumentsIfFirstWindow()
        }
        .onChange(of: enginePreference) { _ in applyEnginePreference() }
        .onChange(of: loopPlayback) { model.loops = $0 }
        #if os(macOS)
            .focusedSceneValue(\.playerCommands, PlayerCommandActions(
                openFile: { importer.presentOpenPanel() },
                openURL: { showURLSheet = true },
                openSettings: { showSettingsSheet = true },
                openRecent: { importer.open(fileURL: $0) }
            ))
        #endif
    }

    /// Push the persisted engine preference into the model. Cheap; safe to call often.
    private func applyEnginePreference() {
        model.enginePreference = EnginePreferenceStore.preference(from: enginePreference)
    }

    /// Stateless helper bound to this window's model (cheap to build on demand;
    /// holds only a model reference plus a process-wide launch-arg latch).
    private var importer: MediaImportCoordinator {
        MediaImportCoordinator(model: model)
    }
}
