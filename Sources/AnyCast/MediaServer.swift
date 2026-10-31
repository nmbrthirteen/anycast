import Darwin
import Foundation
import Network

protocol StreamProducer: AnyObject {
    func start() throws -> FileHandle
    func stop()
}

final class MediaServer: @unchecked Sendable {
    enum Content {
        case file(URL, mime: String)
        case stream(mime: String, live: Bool = false, make: () -> StreamProducer)
    }

    private let queue = DispatchQueue(label: "anycast.server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var routes: [String: Content] = [:]
    private var activeProducer: StreamProducer?
    private(set) var port: UInt16 = 0

    func start() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
        self.listener = listener
    }

    func publish(_ content: Content, ext: String, for host: String) -> URL {
        let token = UUID().uuidString.prefix(8).lowercased()
        lock.lock()
        routes = ["/\(token).\(ext)": content]
        lock.unlock()
        let ip = Self.localAddress(toward: host) ?? "127.0.0.1"
        return URL(string: "http://\(ip):\(port)/\(token).\(ext)")!
    }

    func clear() {
        lock.lock()
        routes.removeAll()
        let producer = activeProducer
        activeProducer = nil
        lock.unlock()
        producer?.stop()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || done || buffer.count > 65536 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return connection.cancel() }
        let method = String(parts[0])
        let path = String(parts[1]).components(separatedBy: "?")[0]
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        lock.lock()
        let content = routes[path]
        lock.unlock()
        Log.write("tv requested \(method) \(path) range=\(headers["range"] ?? "-") found=\(content != nil)")

        switch content {
        case .file(let url, let mime):
            serveFile(connection, url: url, mime: mime, method: method, range: headers["range"])
        case .stream(let mime, let live, let make):
            serveStream(connection, mime: mime, live: live, make: make)
        case nil:
            send(connection, status: "404 Not Found", headers: ["Content-Length": "0"], thenClose: true)
        }
    }

    private func serveFile(_ connection: NWConnection, url: URL, mime: String, method: String, range: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        else { return send(connection, status: "404 Not Found", headers: ["Content-Length": "0"], thenClose: true) }

        var start = 0
        var end = size - 1
        var status = "200 OK"
        if let range, range.hasPrefix("bytes=") {
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if bounds.count == 2 {
                if let first = Int(bounds[0]) {
                    start = first
                    if let last = Int(bounds[1]) { end = min(last, size - 1) }
                } else if let suffix = Int(bounds[1]) {
                    start = max(0, size - suffix)
                }
                status = "206 Partial Content"
            }
        }
        guard start <= end else {
            try? handle.close()
            return send(connection, status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(size)", "Content-Length": "0"], thenClose: true)
        }

        var headers = dlnaHeaders(mime: mime, live: false)
        headers["Content-Length"] = String(end - start + 1)
        headers["Accept-Ranges"] = "bytes"
        if status.hasPrefix("206") { headers["Content-Range"] = "bytes \(start)-\(end)/\(size)" }

        guard method != "HEAD" else {
            try? handle.close()
            return send(connection, status: status, headers: headers, thenClose: true)
        }
        send(connection, status: status, headers: headers, thenClose: false)
        try? handle.seek(toOffset: UInt64(start))
        pump(connection, handle: handle, remaining: end - start + 1)
    }

    private func pump(_ connection: NWConnection, handle: FileHandle, remaining: Int) {
        guard remaining > 0, let chunk = try? handle.read(upToCount: min(remaining, 1 << 20)), !chunk.isEmpty else {
            try? handle.close()
            return connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil else { try? handle.close(); return connection.cancel() }
            self?.queue.async { self?.pump(connection, handle: handle, remaining: remaining - chunk.count) }
        })
    }

    private func serveStream(_ connection: NWConnection, mime: String, live: Bool, make: () -> StreamProducer) {
        var headers = dlnaHeaders(mime: mime, live: true)
        headers["Cache-Control"] = "no-cache"
        // MStar renderers stall after a bodiless HEAD on a live stream, so HEAD gets the stream too.
        let producer = make()
        lock.lock()
        let previous = activeProducer
        activeProducer = producer
        lock.unlock()
        previous?.stop()

        let output: FileHandle
        do { output = try producer.start() } catch {
            Log.write("stream failed to start: \(error.localizedDescription)")
            return send(connection, status: "500 Internal Server Error", headers: ["Content-Length": "0"], thenClose: true)
        }
        send(connection, status: "200 OK", headers: headers, thenClose: false)

        // Live encoders must never wait on the TV, which reads in bursts, or capture backs up and audio drops out.
        let queue = ChunkQueue()
        if live {
            Thread.detachNewThread {
                while let chunk = try? output.read(upToCount: 64 * 1024), !chunk.isEmpty, queue.push(chunk) {}
                queue.finish()
            }
        }

        Thread.detachNewThread {
            let sent = DispatchSemaphore(value: 0)
            var failed = false
            var sentBytes = 0
            var windowStart = Date()
            while !failed, let chunk = live ? queue.pop() : (try? output.read(upToCount: 256 * 1024)).flatMap({ $0.isEmpty ? nil : $0 }) {
                sentBytes += chunk.count
                if Date().timeIntervalSince(windowStart) >= 5 {
                    Log.write(String(format: "stream sent %.1f Mbps, queued %d KB", Double(sentBytes) * 8 / Date().timeIntervalSince(windowStart) / 1_000_000, queue.bytes / 1024))
                    sentBytes = 0
                    windowStart = Date()
                }
                connection.send(content: chunk, completion: .contentProcessed { error in
                    failed = error != nil
                    sent.signal()
                })
                sent.wait()
            }
            Log.write("stream ended failed=\(failed)")
            queue.finish()
            producer.stop()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func dlnaHeaders(mime: String, live: Bool) -> [String: String] {
        let features = DLNAClient.protocolInfo(mime: mime, live: live).components(separatedBy: ":").last ?? ""
        return [
            "Content-Type": mime,
            "transferMode.dlna.org": mime.hasPrefix("image/") ? "Interactive" : "Streaming",
            "contentFeatures.dlna.org": features,
            "Server": "AnyCast/1.0 UPnP/1.0 DLNADOC/1.50",
        ]
    }

    private func send(_ connection: NWConnection, status: String, headers: [String: String], thenClose: Bool) {
        var head = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
            if thenClose { connection.cancel() }
        })
    }

    static func localAddress(toward host: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var remote = sockaddr_in()
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = UInt16(9).bigEndian
        guard inet_pton(AF_INET, host, &remote.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &local.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}

private final class ChunkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var chunks: [Data] = []
    private var finished = false
    private(set) var bytes = 0
    private let limit = 64 << 20

    // When the TV falls far behind, the oldest video is dropped so it catches up to live.
    // The skipped amount stays a multiple of 188 bytes so the TV stays aligned to MPEG-TS packets.
    func push(_ chunk: Data) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !finished else { return false }
        chunks.append(chunk)
        bytes += chunk.count
        if bytes > limit {
            var dropped = 0
            while bytes > limit / 2, chunks.count > 1 {
                dropped += chunks[0].count
                bytes -= chunks.removeFirst().count
            }
            var extra = (188 - dropped % 188) % 188
            while extra > 0, !chunks.isEmpty {
                let cut = min(extra, chunks[0].count)
                chunks[0].removeFirst(cut)
                bytes -= cut
                extra -= cut
                if chunks[0].isEmpty { chunks.removeFirst() }
            }
            Log.write("stream: tv fell behind, skipped \(dropped / 1024) KB to catch up")
        }
        condition.signal()
        return true
    }

    func pop() -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while chunks.isEmpty && !finished { condition.wait() }
        guard !chunks.isEmpty else { return nil }
        let chunk = chunks.removeFirst()
        bytes -= chunk.count
        var merged = chunk
        while merged.count < 256 * 1024, !chunks.isEmpty {
            let next = chunks.removeFirst()
            bytes -= next.count
            merged.append(next)
        }
        return merged
    }

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }
}
