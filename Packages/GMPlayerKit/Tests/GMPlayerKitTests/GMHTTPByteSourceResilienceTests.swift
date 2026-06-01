import Foundation
import Network
import XCTest
@testable import GMPlayerKit

/// Regression guard for BUG #1958b5 (slow/flaky origin): a connection that drops or
/// times out MID-STREAM must be recoverable (reopen at the current offset), not a
/// permanent failure. Before the fix, a URLSession completion error (e.g. -1005
/// "network connection lost", the same class as the CDN's mid-stream timeout) set
/// `failed = true` and every subsequent read() returned -1, so AVPlayer's item failed
/// and the UI showed "request timed out" ~10s into playback. mpv/VLC just reopen the
/// range; now GMHTTPByteSource does too.
///
/// The test serves a known byte pattern from an in-process loopback HTTP server that
/// CLOSES the socket once, mid-body, on the first large ranged GET. The byte source
/// must transparently reopen and still deliver every byte correctly.
final class GMHTTPByteSourceResilienceTests: XCTestCase {
    /// A tiny loopback HTTP/1.1 server that honors `Range` and, on the first response
    /// whose length exceeds `dropAfter`, writes `dropAfter` bytes then closes the
    /// connection (simulating a CDN dropping mid-stream). Later requests succeed.
    private final class DropOnceServer {
        let total: Int
        let dropAfter: Int
        private let listener: NWListener
        private let queue = DispatchQueue(label: "drop.server")
        private let lock = NSLock()
        private var dropped = false
        private(set) var port: UInt16 = 0

        init(total: Int, dropAfter: Int) throws {
            self.total = total
            self.dropAfter = dropAfter
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            self.listener = try NWListener(using: params, on: .any)
        }

        /// byte i has value UInt8(i % 251), a deterministic, position-checkable pattern.
        static func byte(at i: Int) -> UInt8 {
            UInt8(i % 251)
        }

        func start() throws -> UInt16 {
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { [weak self] st in
                if case .ready = st, let p = self?.listener.port?.rawValue { self?.port = p
                    ready.signal()
                }
            }
            listener.newConnectionHandler = { [weak self] c in self?.handle(c) }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 5)
            return port
        }

        func stop() {
            listener.cancel()
        }

        private func handle(_ conn: NWConnection) {
            conn.start(queue: queue)
            receive(conn, buffer: Data())
        }

        private func receive(_ conn: NWConnection, buffer: Data) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, done, _ in
                guard let self else { return }
                var buf = buffer
                if let chunk { buf.append(chunk) }
                if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buf[buf.startIndex ..< r.lowerBound], as: UTF8.self)
                    respond(conn, head: head)
                } else if done {
                    conn.cancel()
                } else {
                    receive(conn, buffer: buf)
                }
            }
        }

        private func respond(_ conn: NWConnection, head: String) {
            // Parse "Range: bytes=START-END"
            var start = 0
            var end = total - 1
            for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("range:") {
                if let eq = line.firstIndex(of: "=") {
                    let spec = line[line.index(after: eq)...].split(separator: "-", omittingEmptySubsequences: false)
                    if let s = Int(spec.first ?? "") { start = s }
                    if spec.count > 1, let e = Int(spec[1]) { end = e }
                }
            }
            let length = max(0, end - start + 1)
            var dropHere = false
            lock.lock()
            if !dropped, length > dropAfter { dropped = true
                dropHere = true
            }
            lock.unlock()
            let sendLen = dropHere ? dropAfter : length

            var header = "HTTP/1.1 206 Partial Content\r\n"
            header += "Content-Range: bytes \(start)-\(end)/\(total)\r\n"
            header += "Content-Length: \(length)\r\n"
            header += "Accept-Ranges: bytes\r\n"
            header += "Connection: close\r\n\r\n"
            var out = Data(header.utf8)
            out.reserveCapacity(out.count + sendLen)
            for i in start ..< (start + sendLen) {
                out.append(Self.byte(at: i))
            }

            conn.send(content: out, completion: .contentProcessed { _ in
                // On a drop, close immediately AFTER fewer bytes than promised (the
                // client sees a truncated body -> connection-lost error mid-stream).
                conn.cancel()
            })
        }
    }

    func testRecoversFromMidStreamDrop() throws {
        let total = 8 * 1024 * 1024 // 8 MB
        let server = try DropOnceServer(total: total, dropAfter: 2 * 1024 * 1024)
        let port = try server.start()
        defer { server.stop() }

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/pattern.bin"))
        let src = try XCTUnwrap(GMHTTPByteSource(url: url, timeout: 10))
        XCTAssertEqual(src.totalSize, Int64(total), "probe should learn total size from Content-Range")

        // Read the whole resource sequentially in 256 KB reads. The server drops the
        // first big body mid-way; the source must reopen and still return every byte.
        let chunk = 256 * 1024
        var offset = 0
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        var mismatches = 0
        while offset < total {
            let want = Int32(min(chunk, total - offset))
            let n = src.read(at: Int64(offset), into: buf, count: want)
            XCTAssertGreaterThan(n, 0, "read returned \(n) at offset \(offset), byte source gave up (no reopen)")
            if n <= 0 { break }
            // Verify the bytes match the known pattern (no corruption across the reopen).
            for k in 0 ..< Int(n) where buf[k] != DropOnceServer.byte(at: offset + k) {
                mismatches += 1
                if mismatches == 1 {
                    XCTFail("byte mismatch at \(offset + k): got \(buf[k]) expected \(DropOnceServer.byte(at: offset + k))")
                }
            }
            offset += Int(n)
        }
        XCTAssertEqual(offset, total, "did not read the whole resource through the mid-stream drop")
        XCTAssertEqual(mismatches, 0, "data corrupted across the reopen")
    }
}
