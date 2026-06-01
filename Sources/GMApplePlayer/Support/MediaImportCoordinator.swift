//
//  MediaImportCoordinator.swift
//  App-layer business logic for getting media INTO the player: file picking,
//  security-scoped access, drag-and-drop decoding, and launch-argument parsing.
//
//  This type contains NO SwiftUI views. Views call its intents; it drives the
//  engine-facing GMPlayerModel. Keeping it separate is the UI<->logic boundary:
//  screens stay declarative and free of AppKit/file-system code.
//

import Foundation
import GMPlayerKit
import UniformTypeIdentifiers

#if canImport(AppKit)
    import AppKit
#endif

@MainActor
final class MediaImportCoordinator {
    let model: GMPlayerModel

    init(model: GMPlayerModel) {
        self.model = model
    }

    /// Container formats we offer in pickers / accept via drop.
    static let supportedTypes: [UTType] = {
        var types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        for ext in ["mkv", "ts", "m2ts", "webm"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }()

    // MARK: Intents

    func open(fileURL: URL) {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        model.open(fileURL: fileURL)
        #if os(macOS)
            // Record in the system recents so File ▸ Open Recent (and the Dock's
            // Recent Items) lists it. Every file path funnels through here, open
            // panel, file importer, drag-drop, and launch args, so this one call
            // covers them all.
            RecentMediaStore.shared.record(fileURL)
        #endif
        if scoped {
            // Release shortly after; the engine reads the bytes synchronously
            // via libavformat during the remux that open() kicks off.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
    }

    func open(remoteURL: URL) {
        model.open(remoteURL: remoteURL)
    }

    /// Resolve a SwiftUI `.fileImporter` result.
    func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            open(fileURL: url)
        case let .failure(error):
            model.openFailed(error.localizedDescription)
        }
    }

    /// Decode a drag-and-drop payload into a file URL and open it.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
            guard let url else { return }
            DispatchQueue.main.async { self?.open(fileURL: url) }
        }
        return true
    }

    #if os(macOS)
        /// Present the native open panel (macOS). iOS/tvOS use `.fileImporter`.
        func presentOpenPanel() {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.allowedContentTypes = Self.supportedTypes
            if panel.runModal() == .OK, let url = panel.url {
                open(fileURL: url)
            }
        }
    #endif

    // MARK: Launch arguments (first window only)

    private static var didConsumeLaunchOpen = false

    /// Open whatever was passed via `--open <path|url>`, a bare path argument,
    /// or the `GM_OPEN` env var. Only the first window consumes it, so ⌘N opens
    /// a blank window.
    func consumeLaunchArgumentsIfFirstWindow() {
        guard model.state == .idle, !Self.didConsumeLaunchOpen else { return }
        Self.didConsumeLaunchOpen = true

        var target: String?
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            target = args[i + 1]
        } else if args.count == 2, !args[1].hasPrefix("-") {
            target = args[1]
        } else if let env = ProcessInfo.processInfo.environment["GM_OPEN"], !env.isEmpty {
            target = env
        }
        guard let t = target else { return }

        if let url = URL(string: t), url.scheme == "http" || url.scheme == "https" {
            open(remoteURL: url)
        } else {
            open(fileURL: URL(fileURLWithPath: (t as NSString).expandingTildeInPath))
        }
    }
}
