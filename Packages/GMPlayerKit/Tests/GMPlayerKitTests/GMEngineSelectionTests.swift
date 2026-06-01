import Foundation
import XCTest
@testable import GMPlayerKit

/// Verifies the engine-selection policy: loopback (HLS) is the default for every
/// input (it starts instantly and seeks cleanly even on 40-80 GB REMUX MKVs, where
/// the single-file resource loader hangs), the explicit user Preference is honored,
/// and the GM_PLAYER_ENGINE env override still wins for tests/debugging.
final class GMEngineSelectionTests: XCTestCase {
    /// Whether GM_PLAYER_ENGINE is set in this process (it overrides resolveKind, so
    /// the preference-based assertions below would be masked). The harness leaves it
    /// unset; guard so a developer running with it set doesn't see spurious failures.
    private var envOverridden: Bool {
        ProcessInfo.processInfo.environment["GM_PLAYER_ENGINE"] != nil
    }

    func testDefaultEngineIsLoopback() {
        XCTAssertEqual(GMStreamingEngine.defaultKind, .loopback)
    }

    func testAutoPreferenceResolvesToLoopback() throws {
        try XCTSkipIf(envOverridden, "GM_PLAYER_ENGINE override is active")
        XCTAssertEqual(GMStreamingEngine.resolveKind(preference: .auto), .loopback)
        // nil preference behaves like .auto.
        XCTAssertEqual(GMStreamingEngine.resolveKind(preference: nil), .loopback)
        // selectedKind (no preference) is the default too.
        XCTAssertEqual(GMStreamingEngine.selectedKind, .loopback)
    }

    func testExplicitPreferenceIsHonored() throws {
        try XCTSkipIf(envOverridden, "GM_PLAYER_ENGINE override is active")
        XCTAssertEqual(GMStreamingEngine.resolveKind(preference: .loopback), .loopback)
        XCTAssertEqual(GMStreamingEngine.resolveKind(preference: .resourceLoader), .resourceLoader)
    }

    func testPreferenceRawValuesAreStableForAppStorage() {
        // The app persists these raw strings via @AppStorage; they must not drift.
        XCTAssertEqual(GMStreamingEngine.Preference.auto.rawValue, "auto")
        XCTAssertEqual(GMStreamingEngine.Preference.loopback.rawValue, "loopback")
        XCTAssertEqual(GMStreamingEngine.Preference.resourceLoader.rawValue, "resourceLoader")
        // round-trips.
        for p in GMStreamingEngine.Preference.allCases {
            XCTAssertEqual(GMStreamingEngine.Preference(rawValue: p.rawValue), p)
        }
    }

    func testEveryPreferenceHasANonEmptyLabel() {
        for p in GMStreamingEngine.Preference.allCases {
            XCTAssertFalse(p.label.isEmpty)
        }
    }
}
