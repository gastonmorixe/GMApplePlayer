//
//  GMApplePlayerApp.swift
//  Entry point. One app, three platforms (macOS / iOS / tvOS).
//
//  Multi-window on macOS: WindowGroup gives a fresh ContentView (and a fresh,
//  idle GMPlayerModel) per window, so ⌘N opens a blank player ready to pick a
//  new file. The CLI/--open auto-load only fires for the very first window
//  (see ContentView.autoOpenIfRequested), so new windows are never duplicates.
//

import SwiftUI

@main
struct GMApplePlayerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .commands { PlayerMenuCommands() }
        // Hide the title bar at the SCENE level so the window never paints the
        // gray titlebar strip, content goes edge-to-edge and the traffic lights
        // float over it (QuickTime-style). This is more reliable than toggling
        // NSWindow.styleMask after the fact: SwiftUI applies it at window
        // creation, before any content draws, so there's no gray flash and no
        // race with the AppKit styling pass. WindowChrome then only animates the
        // traffic-light alpha (the one thing SwiftUI can't express).
        .windowStyle(.hiddenTitleBar)
        // If a toolbar ever appears (none today), keep it compact + unified
        // instead of the tall separated style. Harmless with no toolbar present.
        .windowToolbarStyle(.unifiedCompact)
        #endif
    }
}

#if os(macOS)
    /// Per-window menu actions the focused player window publishes, so File-menu
    /// commands route to the window the user is actually looking at.
    struct PlayerCommandActions {
        var openFile: () -> Void
        var openURL: () -> Void
        var openSettings: () -> Void
        var openRecent: (URL) -> Void
    }

    private struct PlayerCommandActionsKey: FocusedValueKey {
        typealias Value = PlayerCommandActions
    }

    extension FocusedValues {
        var playerCommands: PlayerCommandActions? {
            get { self[PlayerCommandActionsKey.self] }
            set { self[PlayerCommandActionsKey.self] = newValue }
        }
    }

    /// File-menu items: New Window (kept from the default), Open File…, Open URL…,
    /// and an Open Recent submenu (built manually, since a non-document WindowGroup
    /// app gets none automatically).
    struct PlayerMenuCommands: Commands {
        @FocusedValue(\.playerCommands) private var actions
        @ObservedObject private var recents = RecentMediaStore.shared

        var body: some Commands {
            // Keep the system "New Window" (⌘N) and add Open items right after it.
            CommandGroup(after: .newItem) {
                Divider()
                Button("Open File…") { actions?.openFile() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(actions == nil)
                Button("Open URL…") { actions?.openURL() }
                    .keyboardShortcut("u", modifiers: .command)
                    .disabled(actions == nil)
                openRecentMenu
            }
            // Standard macOS Settings… (⌘,) in the app menu.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { actions?.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(actions == nil)
            }
        }

        /// The File ▸ Open Recent submenu, rebuilt whenever the system recents list
        /// changes. Each item reopens the file in the focused window; "Clear Menu"
        /// empties the shared system list (also clearing the Dock's Recent Items).
        private var openRecentMenu: some View {
            Menu("Open Recent") {
                ForEach(recents.urls, id: \.self) { url in
                    Button(url.lastPathComponent) { actions?.openRecent(url) }
                }
                if !recents.urls.isEmpty {
                    Divider()
                    Button("Clear Menu") { recents.clear() }
                }
            }
            .disabled(actions == nil || recents.urls.isEmpty)
        }
    }
#endif
