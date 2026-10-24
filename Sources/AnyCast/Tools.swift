import Foundation

enum Tools {
    static let ffmpeg = find("ffmpeg")
    static let ffprobe = find("ffprobe")
    static let ytdlp = find("yt-dlp")

    static func find(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", NSHomeDirectory() + "/.local/bin"]
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(_ path: String?, _ arguments: [String]) async throws -> Data {
        guard let path else { throw Failure(message: "Missing tool. Install with: brew install ffmpeg yt-dlp") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                var errors = Data()
                let errorReader = Thread { errors = err.fileHandleForReading.readDataToEndOfFile() }
                errorReader.start()
                let output = out.fileHandleForReading.readDataToEndOfFile()
                while !errorReader.isFinished { usleep(1000) }
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let message = String(decoding: errors, as: UTF8.self)
                    let lastLine = message.split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)"
                    continuation.resume(throwing: Failure(message: lastLine))
                }
            }
        }
    }
}

final class FFmpegProducer: StreamProducer {
    private let arguments: [String]
    private var process: Process?
    var onStart: ((Process) -> Void)?

    init(arguments: [String]) { self.arguments = arguments }

    func start() throws -> FileHandle {
        guard let path = Tools.ffmpeg else { throw Tools.Failure(message: "ffmpeg not found") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-hide_banner", "-loglevel", "warning", "-nostdin"] + arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Log.ffmpegHandle()
        if arguments.contains("pipe:0") {
            process.standardInput = Pipe()
            process.arguments?.removeAll { $0 == "-nostdin" }
        }
        try process.run()
        self.process = process
        onStart?(process)
        return out.fileHandleForReading
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

struct ProbeResult {
    var videoCodec: String?
    var audioCodec: String?
    var height: Int = 0
    var duration: Double = 0
    var formatName = ""
    var videoBitrate = 0

    static func probe(_ input: String) async -> ProbeResult? {
        var args = ["-v", "error", "-show_entries", "stream=codec_type,codec_name,height,bit_rate:format=duration,format_name,bit_rate", "-of", "json"]
        args.append(input)
        guard let data = try? await Tools.run(Tools.ffprobe, args),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var result = ProbeResult()
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            let codec = stream["codec_name"] as? String
            switch stream["codec_type"] as? String {
            case "video" where result.videoCodec == nil && codec != "mjpeg" && codec != "png":
                result.videoCodec = codec
                result.height = stream["height"] as? Int ?? 0
                result.videoBitrate = Int(stream["bit_rate"] as? String ?? "") ?? 0
            case "audio" where result.audioCodec == nil:
                result.audioCodec = codec
            default: break
            }
        }
        let format = json["format"] as? [String: Any] ?? [:]
        result.duration = Double(format["duration"] as? String ?? "") ?? 0
        result.formatName = format["format_name"] as? String ?? ""
        if result.videoBitrate == 0 { result.videoBitrate = Int(format["bit_rate"] as? String ?? "") ?? 0 }
        return result
    }
}
