//
//  GMStreamSession+Tracks.swift
//  The value types GMStreamSession surfaces to the player: ColorInfo (HDR/color
//  characteristics of the selected video stream) and Track (one source track for
//  the native picker), plus the audioRenditions list. Split out of
//  GMStreamSession.swift to keep that file within the project's file-size limit.
//

import Foundation

public extension GMStreamSession {
    /// Color characteristics of the selected video stream, read from the input codec
    /// parameters at open (independent of the playback transport). The HLS loopback
    /// transport does not surface per-track color info to AVFoundation, so the app
    /// reads HDR state from here instead of from the AVAssetTrack's format descriptions.
    struct ColorInfo: Sendable, Equatable {
        public var transfer: Int // AVColorTransferCharacteristic (16=PQ, 18=HLG)
        public var primaries: Int // AVColorPrimaries (9=BT.2020)
        public var matrix: Int // AVColorSpace (9=BT.2020nc)
        public var range: Int // AVColorRange (1=limited, 2=full)
        public var dolbyVision = false // a Dolby Vision configuration record is present
        public var doviProfile = 0 // 5 / 7 / 8 / ...
        public var hasMastering = false // static mastering-display metadata (HDR10)
        public var hasHDR10Plus = false // dynamic ST 2094-40 metadata (HDR10+)

        /// True if the transfer function is an HDR one (PQ/ST-2084 or HLG).
        public var isHDR: Bool {
            transfer == 16 || transfer == 18 || dolbyVision
        }

        /// True if the transfer is HLG (ARIB STD-B67), which uses VIDEO-RANGE=HLG.
        public var isHLG: Bool {
            transfer == 18
        }

        /// A short transfer-function name (matches CoreMedia's vocabulary).
        public var transferName: String {
            switch transfer {
            case 16: "SMPTE ST 2084 (PQ)"
            case 18: "HLG"
            case 1: "BT.709"
            default: transfer >= 0 ? "transfer \(transfer)" : "unknown"
            }
        }

        /// The specific HDR format, for a UI tag. Dolby Vision wins (it's layered on
        /// PQ); then dynamic HDR10+; then static HDR10; then HLG; else SDR.
        public enum Format: String, Sendable {
            case dolbyVision = "Dolby Vision"
            case hdr10Plus = "HDR10+"
            case hdr10 = "HDR10"
            case hlg = "HLG"
            case hdrPQ = "HDR (PQ)" // PQ transfer without mastering metadata
            case sdr = "SDR"
        }

        public var format: Format {
            if dolbyVision { return .dolbyVision }
            if transfer == 18 { return .hlg }
            if transfer == 16 { return hasHDR10Plus ? .hdr10Plus : (hasMastering ? .hdr10 : .hdrPQ) }
            return .sdr
        }
    }

    /// One source track (video/audio/subtitle), surfaced so the player can list every
    /// track in the native picker. The engine still plays one video + one audio by
    /// default; a non-default rendition's segments are muxed only when actually selected.
    struct Track: Sendable, Equatable, Identifiable {
        public enum Kind: Int, Sendable { case video = 1, audio = 2, subtitle = 3 }
        public var id: Int {
            sourceIndex
        }

        public var sourceIndex: Int
        public var kind: Kind
        public var codec: String
        public var language: String // ISO 639, or ""
        public var title: String
        public var channels: Int
        public var width = 0
        public var height = 0
        public var fpsNum = 0
        public var fpsDen = 0
        public var isDefault: Bool

        /// Frame rate (frames per second), or nil if the source didn't report it.
        public var frameRate: Double? {
            (fpsNum > 0 && fpsDen > 0) ? Double(fpsNum) / Double(fpsDen) : nil
        }

        public var avfCompatible: Bool
        public var isTextSubtitle: Bool // subtitle convertible to WebVTT (vs image PGS)

        /// A friendly display name for the picker, e.g. "English 5.1 (AC-3)".
        public var displayName: String {
            var parts: [String] = []
            if !title.isEmpty { parts.append(title) }
            else if !language.isEmpty { parts.append(Self.languageName(language)) }
            if kind == .audio, channels > 0 { parts.append(Self.channelLabel(channels)) }
            if !codec.isEmpty { parts.append("(\(Self.codecLabel(codec)))") }
            return parts.isEmpty ? "Track \(sourceIndex)" : parts.joined(separator: " ")
        }

        static func channelLabel(_ ch: Int) -> String {
            switch ch { case 1: "Mono"
            case 2: "Stereo"
            case 6: "5.1"
            case 8: "7.1"
            default: "\(ch)ch" }
        }

        static func codecLabel(_ c: String) -> String {
            switch c {
            case "ac3": "AC-3"
            case "eac3": "E-AC-3"
            case "aac": "AAC"
            case "truehd": "TrueHD"
            case "dts": "DTS"
            case "mp3": "MP3"
            case "subrip": "SRT"
            case "ass", "ssa": "ASS"
            case "mov_text": "Text"
            case "hdmv_pgs_subtitle": "PGS"
            case "dvd_subtitle": "VobSub"
            default: c.uppercased()
            }
        }

        static func languageName(_ code: String) -> String {
            Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
        }

        /// HLS/RFC5646 wants the shortest language subtag (ISO 639-1 "en" over the
        /// 639-2 "eng" that MKV stores). Map the common 3-letter codes to 2-letter;
        /// fall back to the original (already valid for languages without a 639-1 code).
        public var bcp47Language: String {
            guard !language.isEmpty else { return "" }
            let lc = language.lowercased()
            if lc.count == 2 { return lc }
            // Map the common ISO 639-2 (3-letter) codes MKV stores to 639-1 (2-letter),
            // which HLS/RFC5646 prefers. Unknown codes pass through (valid for languages
            // that have no 639-1 form).
            let m = [
                "eng": "en",
                "ita": "it",
                "spa": "es",
                "fra": "fr",
                "fre": "fr",
                "ger": "de",
                "deu": "de",
                "jpn": "ja",
                "chi": "zh",
                "zho": "zh",
                "rus": "ru",
                "por": "pt",
                "kor": "ko",
                "dut": "nl",
                "nld": "nl",
                "swe": "sv",
                "nor": "no",
                "dan": "da",
                "fin": "fi",
                "pol": "pl",
                "ara": "ar",
                "hin": "hi",
                "tur": "tr",
                "ces": "cs",
                "cze": "cs",
                "ell": "el",
                "gre": "el",
                "heb": "he",
                "tha": "th",
                "vie": "vi",
                "ukr": "uk",
            ]
            return m[lc] ?? lc
        }

        /// The HLS CODECS token for this audio track (ac-3 / ec-3 / mp4a.40.2 / ...).
        var hlsAudioCodec: String {
            switch codec {
            case "ac3": "ac-3"
            case "eac3": "ec-3"
            case "aac": "mp4a.40.2"
            case "mp3": "mp4a.40.34"
            case "alac": "alac"
            default: "mp4a.40.2"
            }
        }
    }

    /// Audio renditions the native picker should offer: AVFoundation-playable audio
    /// tracks only. Order preserved; the default-selected one is marked DEFAULT=YES.
    var audioRenditions: [Track] {
        tracks.filter { $0.kind == .audio && $0.avfCompatible }
    }

    /// Subtitle renditions carried as WebVTT: TEXT subs only (subrip/ass/mov_text). Image
    /// subs (PGS/VobSub) can't become WebVTT, so they're excluded from the picker.
    var subtitleRenditions: [Track] {
        tracks.filter { $0.kind == .subtitle && $0.isTextSubtitle }
    }
}
