//
//  RecentMediaStore.swift
//  The "Open Recent" backing store (macOS). A plain WindowGroup app is NOT
//  document-based, so AppKit never auto-builds the File ▸ Open Recent submenu and
//  never records opens. This wraps the system recents list
//  (NSDocumentController.recentDocumentURLs) so we still get the native behavior:
//  the list persists across launches, is shared with the Dock's "Recent Items",
//  and honors the system "Recent items" count in General settings.
//
//  We use the system controller rather than our own UserDefaults list so the
//  experience matches every other Mac app (and so "Clear Menu" clears the same
//  list the Dock shows). macOS-only: iOS/tvOS have no menu bar.
//

#if os(macOS)
    import AppKit
    import Combine

    @MainActor
    final class RecentMediaStore: ObservableObject {
        static let shared = RecentMediaStore()

        /// Mirror of NSDocumentController.recentDocumentURLs, published so the
        /// File ▸ Open Recent menu rebuilds when an open is recorded or cleared.
        @Published private(set) var urls: [URL] = []

        private init() {
            refresh()
        }

        /// Record a freshly opened file in the system recents. Only file URLs go in
        /// the recents list (that's what "Recently Opened" means and what the Dock
        /// shows); remote stream URLs are skipped.
        func record(_ url: URL) {
            guard url.isFileURL else { return }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            refresh()
        }

        /// Clear the menu (and the Dock's Recent Items, since it's the same list).
        func clear() {
            NSDocumentController.shared.clearRecentDocuments(nil)
            refresh()
        }

        /// Pull the current list back from the system controller.
        func refresh() {
            urls = NSDocumentController.shared.recentDocumentURLs
        }
    }
#endif
