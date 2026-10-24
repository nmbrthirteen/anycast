import Foundation
import Network

// Receives a tab stream from the AnyCast browser extension over a local WebSocket.
final class TabCastServer: @unchecked Sendable {
    static let port: UInt16 = 47801
    private let queue = DispatchQueue(label: "anycast.tabcast")
    private var listener: NWListener?
    var onSession: ((TabSession) -> Void)?

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 32 << 20
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        guard let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!) else {
            return Log.write("tab cast server could not start on port \(Self.port)")
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
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
                    if (try? started.start()) != nil {
                        session = started
                        Log.write("tab cast started: \(started.title) \(started.mimeType)")
                        self.onSession?(started)
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
            while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
                lock.lock()
                let target = consumer
                lock.unlock()
                if let target, (try? target.write(contentsOf: chunk)) == nil { setConsumer(nil) }
            }
            close()
        }
    }

    func write(_ data: Data) {
        if (try? input.fileHandleForWriting.write(contentsOf: data)) == nil { close() }
    }

    fileprivate func setConsumer(_ handle: FileHandle?) {
        lock.lock()
        let previous = consumer
        consumer = handle
        lock.unlock()
        if previous !== handle { try? previous?.close() }
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
        if let pipe { try? pipe.fileHandleForWriting.close() }
    }
}
