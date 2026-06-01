//
//  GMStreamInfo.swift
//  Swift value types describing a probed media source.
//

import Foundation

public enum GMStreamKind: Int, Sendable {
    case unknown = 0
    case video = 1
    case audio = 2
    case subtitle = 3
}

public struct GMStreamInfo: Identifiable, Sendable {
    public let id: Int // source stream index
    public let kind: GMStreamKind
    public let codecName: String
    public let profile: String
    public let language: String
    public let title: String
    public let width: Int
    public let height: Int
    public let channels: Int
    public let isDefault: Bool
    public let avfCompatible: Bool
    public let isDolbyVision: Bool
    public let doviProfile: Int

    /// Human label for UI, e.g. "HEVC 3840×2160 (HDR10) [eng]".
    public var displayLabel: String {
        switch kind {
        case .video:
            var s = "\(codecName.uppercased()) \(width)×\(height)"
            if isDolbyVision { s += " DoVi P\(doviProfile)" }
            return s
        case .audio:
            var s = "\(codecName.uppercased()) \(channels)ch"
            if !title.isEmpty { s += " \"\(title)\"" }
            if !language.isEmpty { s += " [\(language)]" }
            return s
        case .subtitle:
            return "Subtitle \(codecName) [\(language)]"
        case .unknown:
            return codecName
        }
    }
}

public struct GMProbeResult: Sendable {
    public let streams: [GMStreamInfo]
    public let durationSeconds: Double
    public let formatName: String

    public var videoStreams: [GMStreamInfo] {
        streams.filter { $0.kind == .video }
    }

    public var audioStreams: [GMStreamInfo] {
        streams.filter { $0.kind == .audio }
    }

    /// True if at least one stream of each present type is AVFoundation-playable.
    public var hasPlayableVideo: Bool {
        videoStreams.contains { $0.avfCompatible }
    }

    public var hasPlayableAudio: Bool {
        audioStreams.contains { $0.avfCompatible }
    }
}

public enum GMRemuxError: Error, LocalizedError {
    case probeFailed(String)
    case remuxFailed(String)
    case noCompatibleStreams
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .probeFailed(m): "Probe failed: \(m)"
        case let .remuxFailed(m): "Remux failed: \(m)"
        case .noCompatibleStreams: "No AVFoundation-compatible streams found."
        case .cancelled: "Cancelled."
        }
    }
}
