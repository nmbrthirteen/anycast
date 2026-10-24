import AppKit
import SwiftUI

@MainActor
final class Updater: ObservableObject {
    static let repo = "nmbrthirteen/anycast"
    // Only builds signed by the same local certificate as this copy may replace it.
    private static let requirement = "=identifier \"local.anycast.app\" and certificate leaf = H\"c70d195c4c3187d4a81b4a6b07f4e7205d65bf42\""

    enum State: Equatable {
        case idle, checking, upToDate, downloading(String), ready(String), failed(String)
    }

    @Published var state = State.idle
    @AppStorage(Pref.autoUpdate) var autoUpdate = true
    var canInstallNow: () -> Bool = { true }

    private let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    private var staged: URL?
    private var timer: Timer?

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func start() {
        Task { await check(installAutomatically: autoUpdate) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoUpdate else { return }
                await self.check(installAutomatically: true)
            }
        }
    }

    func check(installAutomatically: Bool) async {
        guard let gh else { return state = .failed("Install the GitHub CLI to get updates: brew install gh") }
        state = .checking
        do {
            let data = try await Tools.run(gh, ["api", "repos/\(Self.repo)/releases/latest", "--jq", ".tag_name"])
            let tag = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard Self.isNewer(version, than: Self.currentVersion) else { return state = .upToDate }

            state = .downloading(version)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("anycast-update-\(version)")
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = try await Tools.run(gh, ["release", "download", tag, "-R", Self.repo, "-p", "AnyCast.zip", "-D", folder.path])
            _ = try await Tools.run("/usr/bin/ditto", ["-x", "-k", folder.appendingPathComponent("AnyCast.zip").path, folder.path])
            let app = folder.appendingPathComponent("AnyCast.app")
            _ = try await Tools.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", Self.requirement, app.path])

            staged = app
            state = .ready(version)
            Log.write("update \(version) downloaded and verified")
            if installAutomatically { installWhenIdle() }
        } catch {
            state = .failed(error.localizedDescription)
            Log.write("update check failed: \(error.localizedDescription)")
        }
    }

    func installWhenIdle() {
        guard staged != nil else { return }
        if canInstallNow() { return install() }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.installWhenIdle() }
        }
    }

    func install() {
        guard let staged else { return }
        let target = Bundle.main.bundleURL.path
        let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.5; done; rm -rf '\(target)' && /usr/bin/ditto '\(staged.path)' '\(target)' && open '\(target)'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        Log.write("installing update over \(target)")
        NSApp.terminate(nil)
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
