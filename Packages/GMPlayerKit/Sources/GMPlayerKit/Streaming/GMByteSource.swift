//
//  GMByteSource.swift
//  The INPUT byte source the C streaming engine (CGMStream) reads through. Two
//  implementations behind one protocol so local files and remote http(s) URLs use
//  the SAME engine path, differing only here:
//
//    • GMFileByteSource  , a local .mkv via FileHandle pread (instant seeks).
//    • GMHTTPByteSource  , a remote URL via ONE streaming open-ended HTTP GET,
//                           consumed incrementally as bytes arrive (mpv/ffmpeg-style).
//                           Seeks reopen at the new offset. No full-body buffering.
//
//  The engine calls these synchronously on its own worker queue, so a blocking
//  range GET (semaphore) is the right model here.
//

import CGMStream
import Foundation

/// A random-access byte source over the input media.
public protocol GMByteSource: AnyObject {
    /// Total size in bytes, or -1 if unknown.
    var totalSize: Int64 { get }
    /// Read up to `count` bytes at absolute `offset`. Return bytes read (0 = EOF)
    /// or a negative value on error. Called synchronously by the engine.
    func read(at offset: Int64, into buffer: UnsafeMutablePointer<UInt8>, count: Int32) -> Int32

    /// Optional liveness hook for the OPEN/probe phase: called as input bytes are
    /// delivered, with the cumulative bytes read so far and a smoothed throughput
    /// (bytes/sec). Lets the UI show a moving "inspecting… N MB · R/s" label during
    /// the otherwise-opaque `gm_stream_open`. Fired on a background thread, throttled.
    /// Local file sources never fire it (their reads are instant).
    var onProgress: ((_ bytesRead: Int64, _ bytesPerSec: Double) -> Void)? { get set }
}

/// Local file source: one file descriptor, positioned reads (thread-confined to
/// the engine's serial queue, which is how CGMStream calls it).
public final class GMFileByteSource: GMByteSource {
    private let fd: Int32
    public let totalSize: Int64
    /// Local reads are instant; nothing to report. Stored only to satisfy the protocol.
    public var onProgress: ((Int64, Double) -> Void)?

    public init?(path: String) {
        let f = open(path, O_RDONLY)
        guard f >= 0 else { return nil }
        self.fd = f
        let sz = lseek(f, 0, SEEK_END)
        self.totalSize = sz >= 0 ? Int64(sz) : -1
    }

    deinit { close(fd) }

    public func read(at offset: Int64, into buffer: UnsafeMutablePointer<UInt8>, count: Int32) -> Int32 {
        let n = pread(fd, buffer, Int(count), off_t(offset))
        return Int32(truncatingIfNeeded: n)
    }
}

/// Remote source: a single STREAMING open-ended HTTP GET against an http(s) URL,
/// consumed incrementally as bytes arrive, exactly how mpv/ffmpeg read. This is the
/// critical difference from a per-read ranged-GET design:
///
///   • One open-ended `Range: bytes=<pos>-` connection is opened and read as a flow;
///     a `read()` blocks only until ITS bytes have streamed in, not until a whole
///     chunk/body finishes. So playback starts in ~1s even on a slow (≈250 KB/s),
///     range-honoring CDN origin.
///   • A backward seek, or a forward jump past the look-ahead window, cancels the
///     connection and reopens at the new offset (one round-trip), like ffmpeg.
///   • A 200 (server ignored Range and is streaming the whole file from 0) is handled
///     as a sequential stream from byte 0, never buffered to completion. The previous
///     design called `dataTask(completionHandler:)`, which only returns after the
///     ENTIRE body arrives; on a CDN MISS that 200-streams a 924 MB file, that meant
///     waiting ~65 min at 250 KB/s before yielding byte 0 (the "inspecting… forever"
///     hang). We never wait for a full body again.
///
/// Memory is bounded: consumed bytes are trimmed off the front of the buffer, and a
/// far-ahead read reopens rather than buffering the gap.
public final class GMHTTPByteSource: NSObject, GMByteSource, URLSessionDataDelegate {
    private let url: URL
    private let timeout: TimeInterval
    public let totalSize: Int64

    /// A forward read this far past what we've buffered triggers a reopen at the new
    /// offset instead of streaming through (and discarding) the gap. Small forward
    /// skips (the demuxer's normal ±MiB hops) stay on the live connection.
    private let maxForwardSkip: Int64 = 8 * 1024 * 1024
    /// Trim the in-memory buffer down to roughly this much already-delivered history.
    private let keepBehind: Int64 = 256 * 1024

    private let cond = NSCondition()
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var buffer = Data() // bytes currently held
    private var bufStart: Int64 = -1 // absolute file offset of buffer[0]; -1 = no data yet
    private var streamPos: Int64 = 0 // absolute offset just past the last received byte
    private var requestedStart: Int64 = 0 // offset the live request asked for
    private var gotResponse = false // first response header for the live task seen
    private var ignoresRange = false // server answered 200 (whole file from 0)
    private var finished = false // live connection closed (its EOF)
    private var failed = false // live connection errored (permanent, after retries)
    private var reopenAttempts = 0 // consecutive transient reopen attempts at one offset
    private let maxReopen = 4 // ride through flaky CDN 5xx/resets like mpv

    /// Liveness hook (see protocol). Fired off the network thread, throttled.
    public var onProgress: ((Int64, Double) -> Void)?
    /// Cumulative bytes actually delivered over the wire (across reopens), for the
    /// "inspecting… N MB" readout. Distinct from streamPos, which jumps on seek.
    private var totalDelivered: Int64 = 0
    /// EWMA throughput (bytes/sec) and the bookkeeping to compute it.
    private var emaBytesPerSec: Double = 0
    private var lastProgressAt: CFAbsoluteTime = 0
    private var lastDeliveredAt: CFAbsoluteTime = 0
    /// Throttle UI callbacks to ~12/sec; cheaper than every data chunk.
    private let progressMinInterval: CFAbsoluteTime = 1.0 / 12.0

    /// Probes Content-Length with a HEAD. The streaming reads use a separate
    /// delegate-driven session created below.
    public init?(url: URL, timeout: TimeInterval = 60) {
        self.url = url
        self.timeout = timeout
        let probe = Self.probeSize(url: url, timeout: timeout)
        self.totalSize = probe
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        // Idle timeout BETWEEN bytes. A slow CDN (0.4 MB/s, bursty) can pause many
        // seconds between data callbacks; too small a value kills the stream mid-play
        // with "request timed out". Generous here; we cancel+reopen ourselves on seek.
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = 0 // no overall cap (we stream for minutes)
        cfg.waitsForConnectivity = true // ride through brief connectivity gaps
        cfg.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    deinit {
        task?.cancel()
        session.invalidateAndCancel()
    }

    /// Resolve total size with a one-byte ranged GET, trusting only a real 206's
    /// `Content-Range: .../TOTAL` (or a 200's Content-Length). A flaky CDN's 5xx error
    /// page must NOT be mistaken for the file size (that made OPEN read a tiny garbage
    /// "file"). Retries a few times on transient failures, like mpv. Returns -1 if
    /// unknown (reads then use open-ended ranges). Bug #1958b5.
    private static func probeSize(url: URL, timeout: TimeInterval) -> Int64 {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        let s = URLSession(configuration: cfg)
        defer { s.finishTasksAndInvalidate() }
        let debug = ProcessInfo.processInfo.environment["GM_HTTP_DEBUG"] != nil
        for attempt in 0 ..< 4 {
            var req = URLRequest(url: url, timeoutInterval: timeout)
            req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            var size: Int64 = -1
            var status = -1
            let sem = DispatchSemaphore(value: 0)
            s.dataTask(with: req) { _, resp, _ in
                if let http = resp as? HTTPURLResponse {
                    status = http.statusCode
                    if http.statusCode == 206,
                       let cr = http.value(forHTTPHeaderField: "Content-Range"),
                       let slash = cr.lastIndex(of: "/"),
                       let total = Int64(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces))
                    {
                        size = total
                    } else if http.statusCode == 200, http.expectedContentLength > 0 {
                        size = http.expectedContentLength
                    }
                }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + timeout)
            if debug {
                FileHandle.standardError.write(Data("[http] probeSize try\(attempt) status=\(status) size=\(size)\n".utf8))
            }
            if size > 0 { return size }
            if attempt < 3 { Thread.sleep(forTimeInterval: min(0.2 * pow(2.0, Double(attempt)), 1.5)) }
        }
        return -1
    }

    // MARK: - Read (engine thread)

    public func read(at offset: Int64, into out: UnsafeMutablePointer<UInt8>, count: Int32) -> Int32 {
        guard count > 0 else { return 0 }
        if totalSize >= 0, offset >= totalSize { return 0 } // clean EOF past end

        cond.lock()
        defer { cond.unlock() }

        // Decide whether the live connection can serve `offset`, else (re)open.
        if task == nil { openConnection(at: offset) }

        while true {
            if failed { return -1 }

            // Serve from buffer if offset is inside what we hold.
            if bufStart >= 0, offset >= bufStart, offset < bufStart + Int64(buffer.count) {
                let rel = Int(offset - bufStart)
                let n = min(Int(count), buffer.count - rel)
                buffer.withUnsafeBytes { raw in
                    out.update(from: raw.baseAddress!.advanced(by: rel).assumingMemoryBound(to: UInt8.self), count: n)
                }
                trimFront(upTo: offset - keepBehind)
                return Int32(n)
            }

            // Backward seek (before our buffer): reopen at offset.
            if bufStart >= 0, offset < bufStart {
                openConnection(at: offset)
                continue
            }

            // Offset is at/after the end of what we hold.
            let haveEnd = bufStart >= 0 ? bufStart + Int64(buffer.count) : streamPos
            if offset >= haveEnd {
                if finished {
                    // Connection ended before reaching offset. If that's real EOF, done;
                    // otherwise reopen at offset to fetch the rest (transient: bounded
                    // retries with backoff so a flaky CDN doesn't surface as a hard
                    // failure, matching mpv's resilience).
                    if totalSize >= 0, offset >= totalSize { return 0 }
                    reopenAttempts += 1
                    if reopenAttempts > maxReopen { failed = true
                        return -1
                    }
                    if reopenAttempts > 1 {
                        let delay = min(0.2 * pow(2.0, Double(reopenAttempts - 1)), 1.5)
                        cond.unlock()
                        Thread.sleep(forTimeInterval: delay)
                        cond.lock()
                    }
                    openConnection(at: offset)
                    continue
                }
                // Far forward jump on a range-honoring server: reopen (cheap) instead
                // of streaming through the gap. If the server ignores Range (200), we
                // can't reopen usefully, so we stream forward and discard.
                if !ignoresRange, offset > haveEnd + maxForwardSkip {
                    openConnection(at: offset)
                    continue
                }
                // Cap memory while we wait: drop bytes well behind the cursor.
                trimFront(upTo: offset - keepBehind)
                cond.wait() // delegate signals on data / completion / error
                continue
            }

            // bufStart < 0 and we have nothing yet: wait for first bytes.
            cond.wait()
        }
    }

    /// Drop buffered bytes before `floor` (absolute offset) to bound memory.
    private func trimFront(upTo floor: Int64) {
        guard bufStart >= 0, floor > bufStart else { return }
        let drop = Int(min(floor - bufStart, Int64(buffer.count)))
        if drop > 0 {
            buffer.removeFirst(drop)
            bufStart += Int64(drop)
        }
    }

    /// Cancel any live connection and start a fresh open-ended GET at `off`.
    /// Caller holds `cond`.
    private func openConnection(at off: Int64) {
        task?.cancel()
        task = nil
        // Reassign rather than removeAll(keepingCapacity:true). The latter mutates the
        // backing store IN PLACE; if `buffer` shares storage with a delegate-delivered
        // Data chunk (URLSession hands us NSData/dispatch_data-backed Data, and append
        // can adopt that backing), an in-place clear corrupts the still-referenced store
        // and traps in Data._Representation.replaceSubrange (observed crash on the
        // stream queue under loopback seek/prefetch churn). A fresh value can't race.
        buffer = Data()
        bufStart = -1
        streamPos = off
        requestedStart = off
        gotResponse = false
        ignoresRange = false
        finished = false
        failed = false

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("bytes=\(off)-", forHTTPHeaderField: "Range")
        let t = session.dataTask(with: req)
        task = t
        t.resume()
    }

    // MARK: - URLSessionDataDelegate (network thread)

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        cond.lock()
        defer { cond.unlock() }
        guard dataTask == task else { completionHandler(.cancel)
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 416 || status == 204 {
            finished = true
            cond.signal()
            completionHandler(.cancel)
            return
        }
        if status == 200 {
            // Server ignored Range: body streams from byte 0.
            ignoresRange = true
            streamPos = 0
        } else if status != 206 {
            // Transient (5xx error page, etc.): mark the connection finished so read()
            // reopens at the same offset (bounded), instead of a permanent failure.
            // A flaky CDN blips 502/520/530; mpv rides through by retrying.
            finished = true
            cond.signal()
            completionHandler(.cancel)
            return
        }
        gotResponse = true
        reopenAttempts = 0 // a good response clears the transient-retry budget
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        cond.lock()
        guard dataTask == task else { cond.unlock()
            return
        }
        if bufStart < 0 { bufStart = streamPos }
        // Append a COPY of the delivered bytes into our own storage. A plain
        // buffer.append(data) can make `buffer` adopt the URLSession-owned Data backing
        // (NSData/dispatch_data) by reference; a later in-place mutation (removeAll /
        // removeFirst) on that shared store then traps. Copying via the raw bytes keeps
        // `buffer` the sole owner of contiguous storage it is always safe to mutate.
        data.withUnsafeBytes { raw in
            buffer.append(contentsOf: raw.bindMemory(to: UInt8.self))
        }
        streamPos += Int64(data.count)
        reopenAttempts = 0 // any forward progress clears the transient-retry budget
        let report = noteDeliveredLocked(data.count)
        cond.signal()
        cond.unlock()
        // Fire OUTSIDE the lock: the closure hops to the main actor and we must not
        // hold `cond` across it (read() waits on cond on the engine thread).
        if let report { onProgress?(report.0, report.1) }
    }

    /// Accumulate delivered bytes, update the EWMA throughput, and decide whether to
    /// emit a (throttled) progress sample. Returns `(totalDelivered, bytesPerSec)` when
    /// a sample should fire, else nil. Caller holds `cond`.
    private func noteDeliveredLocked(_ n: Int) -> (Int64, Double)? {
        let now = CFAbsoluteTimeGetCurrent()
        totalDelivered += Int64(n)
        if lastDeliveredAt > 0 {
            let dt = now - lastDeliveredAt
            if dt > 0 {
                let inst = Double(n) / dt
                // EWMA: smooth bursty CDN delivery into a steady-reading rate.
                emaBytesPerSec = emaBytesPerSec == 0 ? inst : emaBytesPerSec * 0.8 + inst * 0.2
            }
        }
        lastDeliveredAt = now
        guard now - lastProgressAt >= progressMinInterval else { return nil }
        lastProgressAt = now
        return (totalDelivered, emaBytesPerSec)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        cond.lock()
        defer { cond.unlock() }
        guard task == self.task else { return }
        // A connection error (timeout, reset, dropped mid-stream) is TRANSIENT, not
        // fatal: mark the connection finished so read() reopens at the current offset
        // with bounded retries (same as a 5xx). Permanently failing here turned one
        // slow-CDN blip into AVPlayer item failure. We only have what we've buffered;
        // read() will reopen for the rest. (NSURLErrorCancelled is our own reopen.)
        if let error, (error as NSError).code != NSURLErrorCancelled {
            let code = (error as NSError).code
            if debugHTTP {
                FileHandle.standardError.write(Data("[http] completion error code=\(code) at streamPos=\(streamPos) -> reopen\n".utf8))
            }
        }
        finished = true
        cond.signal()
    }

    private var debugHTTP: Bool {
        ProcessInfo.processInfo.environment["GM_HTTP_DEBUG"] != nil
    }
}

// MARK: - C bridge

/// Retains a GMByteSource and exposes it to C via the `gm_source` callback struct.
/// Keep this alive for the lifetime of the gm_stream that uses it.
final class GMSourceBridge {
    let source: GMByteSource
    init(_ source: GMByteSource) {
        self.source = source
    }

    /// Build the C `gm_source`. The ctx is THIS bridge (unretained: caller keeps it).
    func cSource() -> gm_source {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        return gm_source(
            ctx: ctx,
            size: { ctx in
                guard let ctx else { return -1 }
                return Unmanaged<GMSourceBridge>.fromOpaque(ctx).takeUnretainedValue().source.totalSize
            },
            read: { ctx, offset, buf, n in
                guard let ctx, let buf else { return -1 }
                let bridge = Unmanaged<GMSourceBridge>.fromOpaque(ctx).takeUnretainedValue()
                return bridge.source.read(at: offset, into: buf, count: n)
            }
        )
    }
}
