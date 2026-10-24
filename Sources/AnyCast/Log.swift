import Foundation

enum Log {
    static func rotate() {
        for name in ["AnyCast.log", "AnyCast-ffmpeg.log"] {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(name)")
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > 2_000_000 { try? Data().write(to: url) }
        }
    }

    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AnyCast.log")
    private static let queue = DispatchQueue(label: "anycast.log")

    static func ffmpegHandle() -> FileHandle {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AnyCast-ffmpeg.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return .nullDevice }
        handle.seekToEndOfFile()
        return handle
    }

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
