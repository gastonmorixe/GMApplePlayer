//
//  LandingScreen.swift
//  Minimalist "open a movie" screen: quiet canvas, one mark, one primary
//  action, status-in-place. Pure presentation; all actions are delegated to the
//  injected MediaImportCoordinator.
//

import GMPlayerKit
import SwiftUI

struct LandingScreen: View {
    @ObservedObject var model: GMPlayerModel
    let importer: MediaImportCoordinator
    @Binding var showURLSheet: Bool
    @Binding var showSettingsSheet: Bool

    @State private var dropTargeted = false
    @State private var showFileImporter = false

    var body: some View {
        ZStack {
            Color.gmCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                header
                actionOrStatus
                if case let .failed(msg) = model.state {
                    StreamDiagnostics(message: msg, probe: model.probe)
                        .padding(.top, GMSpace.md)
                }
                Spacer()
                footer
            }
            .padding(.horizontal, GMSpace.edge)
            .frame(maxWidth: GMSpace.landingColumnWidth)
        }
        // Returning here from the immersive player restores the ordinary
        // document-window chrome (opaque titlebar, visible title, full-alpha
        // traffic lights). No-op off macOS.
        .gmStandardWindow()
        #if !os(tvOS)
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: MediaImportCoordinator.supportedTypes,
                allowsMultipleSelection: false
            ) { importer.handleImport($0) }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { importer.handleDrop($0) }
            .overlay { DropHighlight(active: dropTargeted) }
        #endif
    }

    private var header: some View {
        VStack(spacing: 0) {
            Image(systemName: "film.stack")
                .font(.system(size: headerGlyphSize, weight: .light))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text("GMApplePlayer")
                .font(.largeTitle).bold()
                .padding(.top, GMSpace.lg)
            Text("Open a movie to play")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.top, GMSpace.xs)
        }
    }

    /// The app mark scales up on tvOS so it reads from across the room.
    private var headerGlyphSize: CGFloat {
        #if os(tvOS)
            96
        #else
            46
        #endif
    }

    private var actionOrStatus: some View {
        Group {
            if model.isBusy {
                LandingStatusView(state: model.state, sourceName: model.sourceName)
            } else {
                LandingActions(
                    openFile: {
                        #if os(macOS)
                            importer.presentOpenPanel()
                        #else
                            showFileImporter = true
                        #endif
                    },
                    openURL: { showURLSheet = true }
                )
            }
        }
        .frame(minHeight: 96)
        .padding(.top, GMSpace.xxl)
    }

    private var footer: some View {
        HStack(spacing: GMSpace.sm) {
            Text("FFmpeg \(GMRemuxer.ffmpegVersion) · remux, no transcode")
                .font(.caption).foregroundStyle(.tertiary)
            Button { showSettingsSheet = true } label: {
                Image(systemName: "gearshape")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Playback settings")
            .accessibilityLabel("Playback settings")
        }
        .padding(.bottom, GMSpace.lg)
    }
}
