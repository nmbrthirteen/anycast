import CryptoKit
import Foundation

// AnyCast downloads its own ffmpeg, ffprobe and yt-dlp so nobody needs Homebrew.
// ffmpeg builds are pinned by checksum. yt-dlp follows its latest release, checked against the release's own checksums,
// because sites change and old copies stop finding videos.
@MainActor
final class ToolStatus: ObservableObject {
    static let shared = ToolStatus()

    enum State: Equatable {
        case ready
        case downloading(step: String, done: Int64, total: Int64)
        case failed(String)
    }

    @Published var state: State = ToolInstaller.isComplete ? .ready : .downloading(step: "Getting ready", done: 0, total: 0)

    var summary: String {
        switch state {
        case .ready: "Installed"
        case .failed: "Download failed"
        case .downloading(_, let done, let total) where total > 0: "Downloading, \(Int(Double(done) / Double(total) * 100))%"
        case .downloading: "Downloading"
        }
    }

    // Background yt-dlp updates also report progress; those stay silent once the tools are ready.
    func progress(_ next: State) {
        if state != .ready { state = next }
    }

    func retry() {
        Task { try? await ToolInstaller.shared.ensureInstalled() }
    }
}

actor ToolInstaller {
    static let shared = ToolInstaller()
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AnyCast/bin")

    private struct Pinned { let name: String; let url: String; let sha256: String }
    private static let ffmpegBuilds = [
        Pinned(name: "ffmpeg", url: "https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip",
               sha256: "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924"),
        Pinned(name: "ffprobe", url: "https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffprobe.zip",
               sha256: "fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6"),
    ]
    private static let ytdlpRelease = "https://github.com/yt-dlp/yt-dlp/releases"
    private static let ytdlpVersionKey = "ytdlpVersion"
    private static let ytdlpCheckedKey = "ytdlpChecked"

    private var installing: Task<Void, Error>?

    static var isComplete: Bool { Tools.ffmpeg != nil && Tools.ffprobe != nil && Tools.ytdlp != nil }

    func ensureInstalled() async throws {
        if Self.isComplete {
            await Self.report(.ready)
            return
        }
        if let installing { return try await installing.value }
        let task = Task { try await Self.installMissing() }
        installing = task
        defer { installing = nil }
        do {
            try await task.value
            await Self.report(.ready)
        } catch {
            await Self.report(.failed(error.localizedDescription))
            throw error
        }
    }

    private static func report(_ state: ToolStatus.State) async {
        await MainActor.run { ToolStatus.shared.state = state }
    }

    func updateYtdlpIfDue() async {
        guard Tools.ytdlp == Tools.managedPath("yt-dlp") else { return }
        let last = UserDefaults.standard.object(forKey: Self.ytdlpCheckedKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86400 else { return }
        do {
            try await Self.installYtdlp()
            UserDefaults.standard.set(Date(), forKey: Self.ytdlpCheckedKey)
        } catch {
            Log.write("yt-dlp update failed: \(error.localizedDescription)")
        }
    }

    private static func installMissing() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            for build in ffmpegBuilds where Tools.find(build.name) == nil {
                let zip = try await download(build.url, step: "Downloading \(build.name)")
                guard sha256(of: zip) == build.sha256 else { throw Tools.Failure(message: "\(build.name) download was damaged") }
                try unzip(zip, to: directory.appendingPathComponent(build.name), keepFolder: false)
                Log.write("installed \(build.name)")
            }
            if Tools.ytdlp == nil {
                try await installYtdlp()
                UserDefaults.standard.set(Date(), forKey: ytdlpCheckedKey)
            }
        } catch let error as Tools.Failure {
            throw error
        } catch {
            Log.write("tool install failed: \(error.localizedDescription)")
            throw Tools.Failure(message: "AnyCast couldn't download its video tools. Check your internet connection and try again.")
        }
    }

    private static func installYtdlp() async throws {
        let latest = try await latestYtdlpTag()
        if latest == UserDefaults.standard.string(forKey: ytdlpVersionKey), Tools.ytdlp != nil { return }
        let sums = String(decoding: try Data(contentsOf: try await download("\(ytdlpRelease)/download/\(latest)/SHA2-256SUMS", step: nil)), as: UTF8.self)
        guard let expected = sums.split(separator: "\n").first(where: { $0.hasSuffix(" yt-dlp_macos.zip") })?.split(separator: " ").first else {
            throw Tools.Failure(message: "yt-dlp release has no checksum")
        }
        let zip = try await download("\(ytdlpRelease)/download/\(latest)/yt-dlp_macos.zip", step: "Downloading yt-dlp")
        guard sha256(of: zip) == String(expected) else { throw Tools.Failure(message: "yt-dlp download was damaged") }
        let target = directory.appendingPathComponent("yt-dlp")
        try unzip(zip, to: target, keepFolder: true)
        UserDefaults.standard.set(latest, forKey: ytdlpVersionKey)
        Log.write("installed yt-dlp \(latest)")
        // macOS scans new code on first launch, which can take a minute; doing it now keeps the first cast fast.
        await MainActor.run { ToolStatus.shared.progress(.downloading(step: "Checking yt-dlp", done: 0, total: 0)) }
        _ = try? await Tools.run(target.appendingPathComponent("yt-dlp_macos").path, ["--version"])
    }

    private static func latestYtdlpTag() async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let tag = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["tag_name"] as? String else {
            throw Tools.Failure(message: "Couldn't find the latest yt-dlp")
        }
        return tag
    }

    // A nil step downloads quietly. The file is moved out of URLSession's temporary spot before the handler returns.
    private static func download(_ url: String, step: String?) async throws -> URL {
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("anycast-download-\(UUID().uuidString)")
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: URLRequest(url: URL(string: url)!, timeoutInterval: 60)) { file, response, error in
                if let error { return continuation.resume(throwing: error) }
                guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else { return continuation.resume(throwing: URLError(.badServerResponse)) }
                do {
                    try FileManager.default.moveItem(at: file, to: saved)
                    continuation.resume(returning: saved)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            if let step {
                observation = task.progress.observe(\.completedUnitCount, options: [.initial]) { progress, _ in
                    let state = ToolStatus.State.downloading(step: step, done: progress.completedUnitCount, total: max(progress.totalUnitCount, 0))
                    Task { @MainActor in ToolStatus.shared.progress(state) }
                }
            }
            task.resume()
        }
    }

    private static func sha256(of file: URL) -> String {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Unpacks next to the target first, so a half-finished download never replaces a working copy.
    private static func unzip(_ zip: URL, to target: URL, keepFolder: Bool) throws {
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, staging.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw Tools.Failure(message: "Couldn't unpack \(target.lastPathComponent)") }
        let unpacked = keepFolder ? staging : staging.appendingPathComponent(target.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: unpacked, to: target)
    }
}
