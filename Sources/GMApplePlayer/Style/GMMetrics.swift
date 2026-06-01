//
//  GMMetrics.swift
//  Shared spacing + corner-radius scale so the app reads as one consistent,
//  well-spaced surface instead of ad-hoc magic numbers per view. Plain values,
//  no custom colors or fonts, those stay system-native.
//

import CoreGraphics

/// An 8pt-based spacing rhythm (with a 4pt half-step) used app-wide. tvOS is a
/// 10-foot UI rendered on a 1080p/4K canvas, so it gets a larger rhythm: the same
/// 8pt steps read as a cramped little box from across the room.
enum GMSpace {
    #if os(tvOS)
        static let xs: CGFloat = 8
        static let sm: CGFloat = 16
        static let md: CGFloat = 24
        static let lg: CGFloat = 32
        static let xl: CGFloat = 48
        static let xxl: CGFloat = 64
        static let edge: CGFloat = 90 // overscan-safe horizontal inset
    #else
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let edge: CGFloat = 40 // screen horizontal inset
    #endif

    /// Max width of the centered landing content column. On tvOS the old 520pt
    /// cap shrank everything into a tiny square in the middle of a huge screen;
    /// a much wider column fills the title-safe area the way a TV app should.
    static var landingColumnWidth: CGFloat {
        #if os(tvOS)
            960
        #else
            520
        #endif
    }
}

/// A small, consistent corner-radius set for glass surfaces and controls.
enum GMRadius {
    static let control: CGFloat = 14
    static let card: CGFloat = 20
}
