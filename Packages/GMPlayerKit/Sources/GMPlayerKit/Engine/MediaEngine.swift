//
//  MediaEngine.swift
//  Protocol seams (Dependency Inversion). The player model depends on these
//  abstractions, not on the concrete FFmpeg-backed implementation. This makes
//  the orchestration unit-testable with fakes and lets us swap the engine
//  (e.g. a future direct-AVIO engine) without touching the UI/model layer.
//

import Foundation

/// Probes a media source and reports its streams.
public protocol MediaProbing: Sendable {
    func probe(_ input: String) async throws -> GMProbeResult
}

/// Remuxes a source into an AVFoundation-playable file (stream copy).
public protocol Remuxing: Sendable {
    /// - Parameters:
    ///   - input: local path or http(s) URL.
    ///   - outputURL: destination (a fragmented/faststart MP4).
    ///   - videoStream/audioStream: source indices, or -1 to auto-select.
    ///   - progress: 0...1 fractions; return false to cancel.
    func remux(
        input: String,
        outputURL: URL,
        videoStream: Int32,
        audioStream: Int32,
        progress: ((Double) -> Bool)?
    ) async throws
}

/// A media engine is both a prober and a remuxer, plus identifies its backend.
public protocol MediaEngine: MediaProbing, Remuxing {
    var backendVersion: String { get }
}

/// The default engine, backed by the FFmpeg C core (GMRemuxer).
public struct FFmpegMediaEngine: MediaEngine {
    public init() {}

    public var backendVersion: String {
        "FFmpeg \(GMRemuxer.ffmpegVersion)"
    }

    public func probe(_ input: String) async throws -> GMProbeResult {
        try await GMRemuxer.probe(input)
    }

    public func remux(
        input: String,
        outputURL: URL,
        videoStream: Int32 = -1,
        audioStream: Int32 = -1,
        progress: ((Double) -> Bool)? = nil
    ) async throws {
        try await GMRemuxer.remux(
            input: input,
            outputURL: outputURL,
            videoStream: videoStream,
            audioStream: audioStream,
            progress: progress
        )
    }
}
