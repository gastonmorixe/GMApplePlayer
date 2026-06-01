//
//  OpenURLSheet.swift
//  Remote-URL entry sheet. Owns only its text field state; hands a validated
//  URL back to the caller via `onOpen`.
//

import SwiftUI

struct OpenURLSheet: View {
    let onOpen: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: GMSpace.lg) {
            VStack(alignment: .leading, spacing: GMSpace.xs) {
                Text("Open Remote URL").font(.title2).bold()
                Text("An http(s) URL to an MKV or MP4. Byte-range support on the server gives smooth seeking.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            urlField

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .gmCancelAction()
                    .gmSecondaryButton()
                Spacer()
                Button("Play", action: submit)
                    .gmDefaultAction()
                    .gmPrimaryButton()
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(GMSpace.xxl)
        #if os(macOS)
            .frame(width: 460)
        #elseif os(tvOS)
            // Center a readable column on the big screen and give the modal a solid
            // surface; without it the sheet was a washed-out full-white panel.
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.thinMaterial)
            .ignoresSafeArea()
        #endif
            .gmCompactSheet()
            .onAppear { fieldFocused = true }
    }

    /// The URL entry field. tvOS gets an explicit, high-contrast container: the
    /// system `TextField` there is borderless and invisible against the sheet until
    /// focused (the "white field you can't see anything in"). The focus engine
    /// brightens the container when the Siri Remote lands on it.
    @ViewBuilder
    private var urlField: some View {
        #if os(tvOS)
            TextField("https://example.com/movie.mkv", text: $urlText)
                .focused($fieldFocused)
                .onSubmit(submit)
                .textContentType(.URL)
                .padding(.horizontal, GMSpace.lg)
                .padding(.vertical, GMSpace.md)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: GMRadius.control))
                .overlay(
                    RoundedRectangle(cornerRadius: GMRadius.control)
                        .strokeBorder(.secondary.opacity(0.35), lineWidth: 1)
                )
        #else
            TextField("https://example.com/movie.mkv", text: $urlText)
                .focused($fieldFocused)
                .onSubmit(submit)
                .textFieldStyle(.roundedBorder)
            #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            #endif
        #endif
    }

    private var trimmed: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard let url = URL(string: trimmed), !trimmed.isEmpty else { return }
        dismiss()
        onOpen(url)
    }
}
