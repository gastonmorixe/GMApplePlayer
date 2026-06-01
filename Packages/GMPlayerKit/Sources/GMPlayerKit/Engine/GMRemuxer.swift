//
//  GMRemuxer.swift
//  Swift bridge over the CFFmpeg remux engine.
//
//  Probes a source and remuxes (stream-copy, no transcode) the
//  AVFoundation-compatible streams into a fragmented MP4 playable by AVPlayer.
//

import CFFmpeg
import Foundation

public enum GMRemuxer {
    /// FFmpeg version compiled into the app (e.g. "8.1.1").
    public static var ffmpegVersion: String {
        String(cString: gm_ffmpeg_version())
    }

    // MARK: - Probe

    /// Probe a local file URL or an http(s) URL. Runs synchronously; call off
    /// the main thread (the async wrapper below does that for you).
    public static func probeSync(_ input: String) throws -> GMProbeResult {
        gm_init()
        var result = CFFmpeg.GMProbeResult()
        var errbuf = [CChar](repeating: 0, count: 512)
        let rc = gm_probe(input, &result, &errbuf, 512)
        guard rc == 0 else {
            throw GMRemuxError.probeFailed(String(cString: errbuf))
        }

        var streams: [GMStreamInfo] = []
        let count = Int(result.stream_count)
        withUnsafeBytes(of: &result.streams) { _ in } // keep tuple alive
        // The C array is a fixed C tuple; iterate by binding to a pointer.
        let mirror = Mirror(reflecting: result.streams)
        for (i, child) in mirror.children.enumerated() where i < count {
            guard var d = child.value as? CFFmpeg.GMStreamDesc else { continue }
            streams.append(Self.makeStreamInfo(&d))
        }

        return GMProbeResult(
            streams: streams,
            durationSeconds: result.duration_seconds,
            formatName: Self.cString(&result.format_name)
        )
    }

    /// Async probe (off the main actor).
    public static func probe(_ input: String) async throws -> GMProbeResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try cont.resume(returning: probeSync(input))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Remux

    /// Remux to a fragmented MP4 at `outputURL`. `videoStream`/`audioStream` are
    /// source indices; nil = auto-select, .some(-2 via .omit) drops that type.
    /// `progress` is called with 0...1 fractions on a background queue.
    public static func remuxSync(
        input: String,
        outputURL: URL,
        videoStream: Int32 = -1,
        audioStream: Int32 = -1,
        progress: ((Double) -> Bool)? = nil
    ) throws {
        gm_init()
        var errbuf = [CChar](repeating: 0, count: 512)

        // Bridge the Swift progress closure into a C function pointer via a box.
        final class Box { let cb: ((Double) -> Bool)?
            init(_ cb: ((Double) -> Bool)?) {
                self.cb = cb
            }
        }
        let box = Box(progress)
        let ctx = Unmanaged.passUnretained(box).toOpaque()

        let cProgress: gm_progress_cb? = (progress == nil) ? nil : { fraction, ctx in
            guard let ctx else { return 0 }
            let box = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
            let keepGoing = box.cb?(fraction) ?? true
            return keepGoing ? 0 : 1 // non-zero requests cancel
        }

        let rc = gm_remux_to_fmp4(
            input,
            outputURL.path,
            videoStream,
            audioStream,
            cProgress,
            ctx,
            &errbuf,
            512
        )
        withExtendedLifetime(box) {}
        guard rc == 0 else {
            let msg = String(cString: errbuf)
            if rc == -255 || msg.isEmpty { throw GMRemuxError.cancelled }
            throw GMRemuxError.remuxFailed(msg.isEmpty ? "code \(rc)" : msg)
        }
    }

    /// Async remux (off the main actor).
    public static func remux(
        input: String,
        outputURL: URL,
        videoStream: Int32 = -1,
        audioStream: Int32 = -1,
        progress: ((Double) -> Bool)? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try remuxSync(
                        input: input,
                        outputURL: outputURL,
                        videoStream: videoStream,
                        audioStream: audioStream,
                        progress: progress
                    )
                    cont.resume()
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: - C struct bridging

    private static func makeStreamInfo(_ d: inout CFFmpeg.GMStreamDesc) -> GMStreamInfo {
        GMStreamInfo(
            id: Int(d.index),
            kind: GMStreamKind(rawValue: Int(d.kind.rawValue)) ?? .unknown,
            codecName: cString(&d.codec_name),
            profile: cString(&d.profile),
            language: cString(&d.language),
            title: cString(&d.title),
            width: Int(d.width),
            height: Int(d.height),
            channels: Int(d.channels),
            isDefault: d.is_default != 0,
            avfCompatible: d.avf_compatible,
            isDolbyVision: d.is_dolby_vision,
            doviProfile: Int(d.dovi_profile)
        )
    }

    /// Read a fixed-size C char tuple into a Swift String.
    private static func cString(_ tuple: inout some Any) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
    }
}
