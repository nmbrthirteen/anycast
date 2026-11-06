import Foundation
import Network

final class TabCastServer: @unchecked Sendable {
    static let port: UInt16 = 47801
    // Derived from the "key" in Extension/manifest.json, so every unpacked install gets this ID.
    static let extensionOrigin = "chrome-extension://khjccglcnoeigpocpbmeeajnmjjplinl"
    private let queue = DispatchQueue(label: "anycast.tabcast")
    private var listener: NWListener?
    var onSession: ((TabSession) -> Void)?

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 32 << 20
        // Any web page or other extension can reach localhost, so only the AnyCast extension may send a stream.
        websocket.setClientRequestHandler(queue) { _, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value ?? ""
            return NWProtocolWebSocket.Response(status: origin == Self.extensionOrigin ? .accept : .reject, subprotocol: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        guard let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!) else {
            Log.write("tab cast server could not start on port \(Self.port), retrying")
            return queue.asyncAfter(deadline: .now() + 3) { self.start() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        // The port can still be held right after a relaunch, so keep trying instead of leaving the extension without a server.
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .failed(let error) = state, let self else { return }
            Log.write("tab cast server failed: \(error), retrying")
            listener?.cancel()
            self.queue.asyncAfter(deadline: .now() + 3) { self.start() }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, session: nil)
    }

    private func receive(_ connection: NWConnection, session: TabSession?) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close {
                session?.close()
                return connection.cancel()
            }
            var session = session
            if let data, !data.isEmpty {
                if metadata?.opcode == .text, session == nil {
                    let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
                    let started = TabSession(title: info["title"] ?? "Browser tab", mimeType: info["mimeType"] ?? "") { connection.cancel() }
                    do {
                        try started.start()
                        session = started
                        Log.write("tab cast started: \(started.title) \(started.mimeType)")
                        self.onSession?(started)
                    } catch {
                        Log.write("tab cast failed to start: \(error.localizedDescription)")
                        return connection.cancel()
                    }
                } else if metadata?.opcode == .binary {
                    session?.write(data)
                }
            }
            self.receive(connection, session: session)
        }
    }
}

final class TabSession: @unchecked Sendable {
    let title: String
    let mimeType: String
    var onEnded: (() -> Void)?
    private let disconnect: () -> Void
    private let process = Process()
    private let input = Pipe()
    private let lock = NSLock()
    private var consumer: FileHandle?
    private var closed = false

    init(title: String, mimeType: String, disconnect: @escaping () -> Void) {
        self.title = title
        self.mimeType = mimeType
        self.disconnect = disconnect
    }

    func start() throws {
        guard let ffmpeg = Tools.ffmpeg else { throw Tools.Failure(message: "ffmpeg not found") }
        let video = mimeType.contains("h264")
            ? ["-c:v", "copy"]
            : ["-c:v", "h264_videotoolbox", "-realtime", "1", "-profile:v", "high", "-b:v", "12000000", "-g", "60"]
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-hide_banner", "-loglevel", "warning", "-fflags", "+genpts+nobuffer", "-i", "pipe:0",
                             "-map", "0:v:0", "-map", "0:a:0?"] + video + [
                             "-c:a", "aac", "-b:a", "256k", "-ar", "48000",
                             "-f", "mpegts", "-muxrate", "20000000", "-pcr_period", "20",
                             "-flush_packets", "1", "-muxdelay", "0", "-muxpreload", "0", "pipe:1"]
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Log.ffmpegHandle()
        try process.run()

        Thread.detachNewThread { [self] in
            let reader = output.fileHandleForReading
            // Writes hold the lock so a handle is never closed, and its descriptor reused, mid-write.
            while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
                lock.withLock {
                    guard let target = consumer, (try? target.write(contentsOf: chunk)) == nil else { return }
                    try? target.close()
                    consumer = nil
                }
            }
            close()
        }
    }

    func write(_ data: Data) {
        if (try? input.fileHandleForWriting.write(contentsOf: data)) == nil { close() }
    }

    fileprivate func setConsumer(_ handle: FileHandle?) {
        lock.withLock {
            if consumer !== handle { try? consumer?.close() }
            consumer = handle
        }
    }

    fileprivate func release(_ handle: FileHandle) {
        lock.withLock {
            if consumer === handle { consumer = nil }
            try? handle.close()
        }
    }

    func makeProducer() -> StreamProducer { TabProducer(session: self) }

    func close() {
        lock.lock()
        guard !closed else { return lock.unlock() }
        closed = true
        lock.unlock()
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        setConsumer(nil)
        disconnect()
        Log.write("tab cast ended: \(title)")
        onEnded?()
    }
}

// Each TV request gets a fresh pipe fed from the one running encoder; MPEG-TS can be joined mid-stream.
private final class TabProducer: StreamProducer {
    private let session: TabSession
    private var pipe: Pipe?

    init(session: TabSession) { self.session = session }

    func start() throws -> FileHandle {
        let pipe = Pipe()
        self.pipe = pipe
        session.setConsumer(pipe.fileHandleForWriting)
        return pipe.fileHandleForReading
    }

    func stop() {
        guard let pipe else { return }
        // Closing the read end first fails a write blocked on a full pipe, which would otherwise hold the session lock.
        try? pipe.fileHandleForReading.close()
        session.release(pipe.fileHandleForWriting)
    }
}
