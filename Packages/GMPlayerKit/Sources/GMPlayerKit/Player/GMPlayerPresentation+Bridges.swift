//
//  GMPlayerPresentation+Bridges.swift
//  Maps the pure presentation policy onto the framework types the views need:
//  SwiftUI's Edge.Set and AVFoundation's AVLayerVideoGravity. Kept separate
//  from the pure policy so GMPlayerPresentation itself stays dependency-free
//  and trivially testable.
//

import AVFoundation
import SwiftUI

public extension GMVideoGravity {
    /// The AVFoundation gravity constant for this policy value.
    var avLayerVideoGravity: AVLayerVideoGravity {
        switch self {
        case .resizeAspect: .resizeAspect
        case .resizeAspectFill: .resizeAspectFill
        case .resize: .resize
        }
    }
}

public extension GMSafeAreaEdges {
    /// The SwiftUI edge set this policy value corresponds to.
    var swiftUIEdges: Edge.Set {
        var set: Edge.Set = []
        if contains(.top) { set.insert(.top) }
        if contains(.leading) { set.insert(.leading) }
        if contains(.bottom) { set.insert(.bottom) }
        if contains(.trailing) { set.insert(.trailing) }
        return set
    }
}

public extension View {
    /// Apply the player's safe-area policy: ignore the configured edges, or
    /// none. Centralized so PlayerScreen doesn't hand-roll `#if os(tvOS)`.
    @ViewBuilder
    func ignoresSafeArea(_ edges: GMSafeAreaEdges) -> some View {
        if edges.isEmpty {
            self
        } else {
            ignoresSafeArea(edges: edges.swiftUIEdges)
        }
    }
}
