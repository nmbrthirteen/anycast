import AppKit
import SwiftUI

@MainActor
final class Updater: ObservableObject {
    static let repo = "nmbrthirteen/anycast"

    enum State: Equatable {
        case idle, checking, upToDate, downloading(String), ready(String), failed(String)
    }

    @Published var state = State.idle
    @AppStorage(Pref.autoUpdate) var autoUpdate = true
    var canInstallNow: () -> Bool = { true }

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
        guard let requirement = CodeSignature.ownRequirement() else {
            return state = .failed("This build isn't signed, so it can't verify updates. Build it with ./build.sh to update.")
        }
        state = .checking
        do {
            let release = try await GitHubRelease.latest(repo: Self.repo)
            let version = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
            guard Self.isNewer(version, than: Self.currentVersion) else { return state = .upToDate }
            guard let asset = release.assets["AnyCast.zip"] else { throw Tools.Failure(message: "The latest release has no AnyCast.zip") }

            state = .downloading(version)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("anycast-update-\(version)")
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let zip = try await GitHubRelease.download(asset, to: folder.appendingPathComponent("AnyCast.zip"))
            _ = try await Tools.run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
            let app = folder.appendingPathComponent("AnyCast.app")
            guard CodeSignature.satisfies(app, requirement) else {
                throw Tools.Failure(message: "The update isn't signed by the same developer, so it was skipped")
            }

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
