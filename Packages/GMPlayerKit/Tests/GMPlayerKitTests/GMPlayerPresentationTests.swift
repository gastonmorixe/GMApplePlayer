//
//  GMPlayerPresentationTests.swift
//  Pins the per-platform player hosting policy that drives the native controls
//  and full-screen framing. These are pure value tests: they evaluate
//  GMPlayerPresentation.resolve(for:) for EVERY platform, so they assert the
//  tvOS behavior even when the suite runs on a macOS host. SwiftUI rendering and
//  the tvOS focus engine can't be exercised off-device, so the contract that
//  *causes* correct rendering is what we lock down here.
//
//  Maps directly to the two reported tvOS bugs:
//    Bug 1 - "no native controls; the remote does nothing"
//            -> tvOS must request native transport controls AND a focusable
//               container (the focusable container is what lets the Siri Remote
//               reveal/drive the transport bar).
//    Bug 2 - "video doesn't fill the screen"
//            -> tvOS must ignore the FULL safe area (not just .bottom), so the
//               player isn't inset into the title-safe box.
//

import AVFoundation
import SwiftUI
import XCTest
@testable import GMPlayerKit

final class GMPlayerPresentationTests: XCTestCase {
    // MARK: - Bug 1: native transport controls on every platform

    func testNativeTransportControlsEnabledOnAllPlatforms() {
        for platform in GMPlatform.allCases {
            let p = GMPlayerPresentation.resolve(for: platform)
            XCTAssertTrue(
                p.usesNativeTransportControls,
                "\(platform) must use the native AVKit transport controls"
            )
        }
    }

    // MARK: - Bug 1: the actual tvOS fix is the focusable container

    func testTVOSRequiresFocusableContainerForRemoteDrivenControls() {
        let tv = GMPlayerPresentation.resolve(for: .tvOS)
        XCTAssertTrue(
            tv.requiresFocusableContainer,
            "tvOS controls only appear when the player is a focusable container the Siri Remote can drive"
        )
    }

    func testFocusIsNotRequiredWhereThereIsNoFocusEngine() {
        // macOS is pointer-driven, iOS is touch-driven: neither has a focus
        // concept for the player, so requesting focus would be wrong.
        XCTAssertFalse(GMPlayerPresentation.resolve(for: .macOS).requiresFocusableContainer)
        XCTAssertFalse(GMPlayerPresentation.resolve(for: .iOS).requiresFocusableContainer)
    }

    // MARK: - Bug 1: tvOS must NOT stack a custom overlay over the native UI

    func testTVOSDoesNotUseCustomOverlay() {
        // A non-focusable SwiftUI overlay layered on the player would compete
        // with the remote for focus and is why the native UI must own tvOS.
        XCTAssertFalse(
            GMPlayerPresentation.resolve(for: .tvOS).usesCustomOverlay,
            "tvOS must let the native focus-driven player own the screen"
        )
    }

    func testOnlyDesktopKeepsTheCustomOverlay() {
        // macOS uses the QuickTime-style immersive overlay (title + glass cluster).
        XCTAssertTrue(GMPlayerPresentation.resolve(for: .macOS).usesCustomOverlay)
        // iOS and tvOS let the native full-screen player own the screen: iOS
        // auto-enters full screen and its X is the back action, so a custom overlay
        // would only compete with the native controls.
        XCTAssertFalse(GMPlayerPresentation.resolve(for: .iOS).usesCustomOverlay)
        XCTAssertFalse(GMPlayerPresentation.resolve(for: .tvOS).usesCustomOverlay)
    }

    // MARK: - Bug 2: full-screen framing via the safe-area policy

    func testTVOSIgnoresFullSafeAreaSoVideoFillsScreen() {
        let tv = GMPlayerPresentation.resolve(for: .tvOS)
        XCTAssertEqual(
            tv.ignoredSafeAreaEdges, .all,
            "tvOS must ignore the full safe area; insetting any edge shrinks the video into the title-safe box"
        )
    }

    func testDesktopAndPhoneIgnoreFullSafeAreaForImmersivePlayback() {
        // Immersive, edge-to-edge video like the system players: macOS extends the
        // video under the transparent titlebar (QuickTime look), iOS fills the
        // screen under the notch / Dynamic Island. AVKit's transport controls and
        // our custom top bar still float within the safe area via their own insets,
        // so the chrome is never clipped.
        XCTAssertEqual(GMPlayerPresentation.resolve(for: .macOS).ignoredSafeAreaEdges, .all)
        XCTAssertEqual(GMPlayerPresentation.resolve(for: .iOS).ignoredSafeAreaEdges, .all)
    }

    // MARK: - Video fills (not distorts): gravity is aspect-fit everywhere

    func testVideoGravityIsResizeAspectEverywhere() {
        for platform in GMPlatform.allCases {
            XCTAssertEqual(
                GMPlayerPresentation.resolve(for: platform).videoGravity, .resizeAspect,
                "\(platform) should aspect-fit (fill available area without distortion or crop)"
            )
        }
    }

    // MARK: - resolve is total + current matches the running host

    func testResolveIsTotalOverAllPlatforms() {
        // CaseIterable + a value return means every platform resolves; this guards
        // against a future platform being added without a policy.
        for platform in GMPlatform.allCases {
            _ = GMPlayerPresentation.resolve(for: platform)
        }
        XCTAssertEqual(GMPlatform.allCases.count, 3)
    }

    func testCurrentMatchesHostPlatform() {
        #if os(macOS)
            XCTAssertEqual(GMPlatform.current, .macOS)
        #elseif os(tvOS)
            XCTAssertEqual(GMPlatform.current, .tvOS)
        #else
            XCTAssertEqual(GMPlatform.current, .iOS)
        #endif
        XCTAssertEqual(GMPlayerPresentation.current, GMPlayerPresentation.resolve(for: .current))
    }

    // MARK: - Bridges: policy -> framework types

    func testSafeAreaEdgesMapToSwiftUIEdges() {
        XCTAssertEqual(GMSafeAreaEdges.all.swiftUIEdges, Edge.Set.all)
        XCTAssertEqual(GMSafeAreaEdges.bottom.swiftUIEdges, Edge.Set.bottom)
        XCTAssertEqual(GMSafeAreaEdges.none.swiftUIEdges, Edge.Set())

        let topLeading: GMSafeAreaEdges = [.top, .leading]
        XCTAssertEqual(topLeading.swiftUIEdges, [Edge.Set.top, Edge.Set.leading])
    }

    func testSafeAreaOptionSetMembership() {
        XCTAssertTrue(GMSafeAreaEdges.all.contains(.top))
        XCTAssertTrue(GMSafeAreaEdges.all.contains(.leading))
        XCTAssertTrue(GMSafeAreaEdges.all.contains(.bottom))
        XCTAssertTrue(GMSafeAreaEdges.all.contains(.trailing))
        XCTAssertTrue(GMSafeAreaEdges.none.isEmpty)
        XCTAssertFalse(GMSafeAreaEdges.bottom.contains(.top))
    }

    func testVideoGravityMapsToAVLayerVideoGravity() {
        XCTAssertEqual(GMVideoGravity.resizeAspect.avLayerVideoGravity, .resizeAspect)
        XCTAssertEqual(GMVideoGravity.resizeAspectFill.avLayerVideoGravity, .resizeAspectFill)
        XCTAssertEqual(GMVideoGravity.resize.avLayerVideoGravity, .resize)
    }

    // MARK: - Regression guards for the two original bugs (explicit, by name)

    func testRegression_tvOSControlsReachableByRemote() {
        // The original code embedded a bare AVPlayerViewController in a ZStack,
        // which never became the focused environment -> remote did nothing.
        // The policy now demands BOTH native controls and a focusable container.
        let tv = GMPlayerPresentation.resolve(for: .tvOS)
        XCTAssertTrue(tv.usesNativeTransportControls && tv.requiresFocusableContainer)
    }

    func testRegression_tvOSVideoNotInsetByTitleSafeArea() {
        // The original code applied only .ignoresSafeArea(edges: .bottom),
        // leaving top/leading/trailing insets that shrank the video.
        let tv = GMPlayerPresentation.resolve(for: .tvOS)
        XCTAssertTrue(tv.ignoredSafeAreaEdges.contains(.top))
        XCTAssertTrue(tv.ignoredSafeAreaEdges.contains(.leading))
        XCTAssertTrue(tv.ignoredSafeAreaEdges.contains(.trailing))
        XCTAssertTrue(tv.ignoredSafeAreaEdges.contains(.bottom))
    }
}
