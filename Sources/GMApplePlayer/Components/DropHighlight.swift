//
//  DropHighlight.swift
//  Dashed border shown while a file is dragged over a drop target.
//

import SwiftUI

struct DropHighlight: View {
    let active: Bool

    var body: some View {
        if active {
            RoundedRectangle(cornerRadius: GMRadius.card)
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [7]))
                .padding(GMSpace.md)
                .transition(.opacity)
        }
    }
}
