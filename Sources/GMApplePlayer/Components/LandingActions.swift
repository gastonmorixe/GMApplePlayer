//
//  LandingActions.swift
//  The landing screen's primary/secondary actions. Dumb view: emits intents
//  via closures, holds no state and no file logic.
//

import SwiftUI

struct LandingActions: View {
    let openFile: () -> Void
    let openURL: () -> Void

    var body: some View {
        VStack(spacing: GMSpace.md) {
            #if !os(tvOS)
                Button(action: openFile) {
                    Text("Open File…").frame(maxWidth: 220)
                }
                .controlSize(.large)
                .gmPrimaryButton()

                Button(action: openURL) {
                    Text("Open URL…").frame(maxWidth: 220)
                }
                .controlSize(.large)
                .gmSecondaryButton()

                Text("or drag a file here")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, GMSpace.xs)
            #else
                Button("Open URL…", action: openURL)
                    .controlSize(.large)
                    .gmPrimaryButton()
            #endif
        }
    }
}
