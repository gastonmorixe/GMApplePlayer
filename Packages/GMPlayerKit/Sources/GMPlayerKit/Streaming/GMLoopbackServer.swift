//
//  GMLoopbackServer.swift
//  A minimal HTTP/1.1 server bound to 127.0.0.1 on an ephemeral port, used ONLY
//  to vend our on-demand HLS to the in-process AVPlayer.
//
//  WHY a server at all (the hard constraint we proved):
//    AVAssetResourceLoaderDelegate is NOT allowed to vend HLS media-segment bytes.
//    Apple requires AVFoundation to fetch segment bytes itself (for bitrate
//    adaptation); a resource-loader may only return playlists, keys, or REDIRECTS
//    for segments. Returning segment data via respond(with:) is rejected with
//    AVPlayerItem error -12881 ("custom url not redirect"), for .ts and fMP4 alike.
//    Verified: the same segment bytes that fail through the loader play perfectly
//    when fetched over HTTP. So the documented path (used by Infuse, VLCKit,
//    KTVHTTPCache, etc.) is a loopback HTTP server.
//
//  This is NOT an exposed service: it binds to 127.0.0.1 only, on an OS-assigned
//  ephemeral port, lives and dies with the player, and is reachable only from
//  inside this process. No other device or app can connect.
//
//  It serves three resource kinds from a GMStreamSession, generated on demand:
//    GET /index.m3u8  -> the VOD media playlist
//    GET /init.mp4    -> the fMP4 init segment (ftyp+moov)
//    GET /segN.m4s    -> media segment N (moof+mdat), muxed on demand
//  Range requests are honored (AVFoundation issues them for segments).
//

import Foundation
import Network

public final class GMLoopbackServer {
    private let session: GMStreamSession
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.gm.appleplayer.httpd", qos: .userInitiated)
    private var connections = Set<ObjectIdentifier>()
    private let lock = NSLock()
    private let debug = ProcessInfo.processInfo.environment["GM_LOADER_DEBUG"] != nil

    public private(set) var port: UInt16 = 0

    /// Diagnostics: how many distinct media-segment (segN.m4s) GET requests we have
    /// answered. For tests/harness: proves the loopback engine fetches segments
    /// lazily as the playhead advances instead of pulling the whole movie up front.
    private var servedSegmentsLock = NSLock()
    private var _servedSegments = 0
    public var servedSegments: Int {
        servedSegmentsLock.lock()
        defer { servedSegmentsLock.unlock() }
        return _servedSegments
    }

    public init(session: GMStreamSession) throws {
        self.session = session
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback // 127.0.0.1 only
        self.listener = try NWListener(using: params, on: .any)
    }

    /// Start listening and return the base URL (http://127.0.0.1:<port>/).
    public func start() throws -> URL {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let p = self?.listener.port?.rawValue {
                self?.port = p
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw GMStreamError.openFailed("loopback server failed to start")
        }
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    public func stop() {
        listener.cancel()
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(on: conn, buffer: Data())
    }

    /// Read until we have a full request head ("\r\n\r\n"), then dispatch.
    private func receive(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let chunk, !chunk.isEmpty { buf.append(chunk) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = buf.subdata(in: buf.startIndex ..< range.lowerBound)
                handle(head: head, on: conn)
                return
            }
            if error != nil || isComplete { conn.cancel()
                return
            }
            if buf.count > 1 << 20 { conn.cancel()
                return
            } // runaway head guard
            receive(on: conn, buffer: buf)
        }
    }

    private func handle(head: Data, on conn: NWConnection) {
        guard let text = String(data: head, encoding: .utf8),
              let requestLine = text.split(separator: "\r\n").first
        else {
            respond(conn, status: 400, headers: [:], body: Data(), close: true)
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { respond(conn, status: 400, headers: [:], body: Data(), close: true)
            return
        }
        let method = String(parts[0])
        let path = String(parts[1])
        let range = Self.parseRange(in: text)
        if debug {
            FileHandle.standardError
                .write(Data("[httpd] \(method) \(path) range=\(range.map { "\($0.0)-\($0.1 ?? -1)" } ?? "none")\n".utf8))
        }

        // Resolve the resource. Path components route between the multivariant
        // renditions; anything we can't build is a 404. The leading "/" yields an empty
        // first component, so drop empties.
        let host = "127.0.0.1:\(port)"
        let comps = path.split(separator: "?").first.map(String.init).map { p in
            p.split(separator: "/").map(String.init)
        } ?? []
        let name = comps.last ?? ""
        let m3u = "application/vnd.apple.mpegurl"
        do {
            let body: Data
            let contentType: String
            switch comps.first {
            case nil, "master.m3u8", "index.m3u8": // base URL or master/legacy media
                if comps.first == "index.m3u8" {
                    body = Data(session.playlist(scheme: "http", host: host).utf8) // legacy single-variant
                } else {
                    body = Data(session.masterPlaylist(scheme: "http", host: host).utf8)
                }
                contentType = m3u
            case "video":
                (body, contentType) = try renditionResource(
                    leaf: name,
                    host: host,
                    playlist: { self.session.videoPlaylist(scheme: "http", host: $0) },
                    initSeg: { try self.session.videoInit() },
                    segment: { try self.session.videoSegment($0) }
                )
            case "audio":
                guard comps.count >= 3, let src = Int(comps[1]) else {
                    respond(conn, status: 404, headers: [:], body: Data(), close: true)
                    return
                }
                (body, contentType) = try renditionResource(
                    leaf: name,
                    host: host,
                    playlist: { self.session.audioPlaylist(source: src, scheme: "http", host: $0) },
                    initSeg: { try self.session.audioInit(source: src) },
                    segment: { try self.session.audioSegment(source: src, $0) }
                )
            case "subs":
                // WebVTT subtitle rendition: /subs/<src>/index.m3u8 or /subs/<src>/segN.vtt
                guard comps.count >= 3, let src = Int(comps[1]),
                      let resolved = try subtitleResource(leaf: name, source: src, host: host)
                else {
                    respond(conn, status: 404, headers: [:], body: Data(), close: true)
                    return
                }
                (body, contentType) = resolved
            case "init.mp4": // legacy single-variant init
                body = try session.initSegment()
                contentType = "video/mp4"
            default:
                if let idx = Self.segmentIndex(from: name) { // legacy single-variant segment
                    body = try session.segment(idx)
                    contentType = "video/mp4"
                    servedSegmentsLock.lock()
                    _servedSegments += 1
                    servedSegmentsLock.unlock()
                } else {
                    respond(conn, status: 404, headers: [:], body: Data(), close: true)
                    return
                }
            }
            serve(conn, body: body, contentType: contentType, range: range, headOnly: method == "HEAD")
        } catch {
            if debug { FileHandle.standardError.write(Data("[httpd] 500 \(name): \(error.localizedDescription)\n".utf8)) }
            respond(conn, status: 500, headers: [:], body: Data(), close: true)
        }
    }

    /// Resolve a subtitle rendition leaf ("index.m3u8" or "segN.vtt") for `source` to
    /// (body, type), or nil for an unknown leaf (caller 404s).
    private func subtitleResource(leaf: String, source: Int, host: String) throws -> (Data, String)? {
        if leaf == "index.m3u8" {
            return (
                Data(session.subtitlePlaylist(source: source, scheme: "http", host: host).utf8),
                "application/vnd.apple.mpegurl"
            )
        }
        if let idx = Self.vttIndex(from: leaf) {
            return try (session.subtitleSegment(source: source, idx), "text/vtt")
        }
        return nil
    }

    /// Resolve a rendition leaf ("index.m3u8" / "init.mp4" / "segN.m4s") to (body, type)
    /// via the rendition-specific closures. Increments servedSegments for a media segment.
    private func renditionResource(
        leaf: String,
        host: String,
        playlist: (String) -> String,
        initSeg: () throws -> Data,
        segment: (Int) throws -> Data
    ) throws -> (Data, String) {
        if leaf == "index.m3u8" {
            return (Data(playlist(host).utf8), "application/vnd.apple.mpegurl")
        }
        if leaf == "init.mp4" {
            return try (initSeg(), "video/mp4")
        }
        if let idx = Self.segmentIndex(from: leaf) {
            let data = try segment(idx)
            servedSegmentsLock.lock()
            _servedSegments += 1
            servedSegmentsLock.unlock()
            return (data, "video/mp4")
        }
        throw GMStreamError.segmentFailed("unknown rendition leaf \(leaf)")
    }

    /// Serve a body with optional byte-range (206) support.
    private func serve(
        _ conn: NWConnection,
        body: Data,
        contentType: String,
        range: (Int, Int?)?,
        headOnly: Bool
    ) {
        var headers = [
            "Content-Type": contentType,
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
        ]
        var status = 200
        var slice = body
        if let (start, endOpt) = range, start < body.count {
            let end = min(endOpt ?? (body.count - 1), body.count - 1)
            if start <= end {
                slice = body.subdata(in: start ..< (end + 1))
                status = 206
                headers["Content-Range"] = "bytes \(start)-\(end)/\(body.count)"
            }
        }
        headers["Content-Length"] = String(slice.count)
        respond(conn, status: status, headers: headers, body: headOnly ? Data() : slice, close: true)
    }

    private func respond(
        _ conn: NWConnection,
        status: Int,
        headers: [String: String],
        body: Data,
        close: Bool
    ) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (k, v) in headers {
            head += "\(k): \(v)\r\n"
        }
        if headers["Content-Length"] == nil { head += "Content-Length: \(body.count)\r\n" }
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            if close { conn.cancel() }
        })
    }

    // MARK: - Parsing helpers

    /// "Range: bytes=START-END" -> (start, end?) ; end nil = open-ended.
    static func parseRange(in head: String) -> (Int, Int?)? {
        for line in head.split(separator: "\r\n") {
            let l = line.lowercased()
            guard l.hasPrefix("range:"), let eq = line.firstIndex(of: "=") else { continue }
            let spec = line[line.index(after: eq)...]
            let nums = spec.split(separator: "-", omittingEmptySubsequences: false)
            guard let start = Int(nums.first ?? "") else { return nil }
            if nums.count > 1, let end = Int(nums[1]) { return (start, end) }
            return (start, nil)
        }
        return nil
    }

    static func segmentIndex(from name: String) -> Int? {
        guard name.hasPrefix("seg"), name.hasSuffix(".m4s") else { return nil }
        return Int(name.dropFirst(3).dropLast(4))
    }

    static func vttIndex(from name: String) -> Int? {
        guard name.hasPrefix("seg"), name.hasSuffix(".vtt") else { return nil }
        return Int(name.dropFirst(3).dropLast(4))
    }

    private static func reason(_ s: Int) -> String {
        switch s {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }
}
