import AppKit
import ScreenCaptureKit
import SwiftUI

@MainActor
final class CastController: ObservableObject {
    @Published var renderers: [Renderer] = []
    @Published var selectedID: String? { didSet { UserDefaults.standard.set(selectedID, forKey: "selectedTV") } }
    @Published var scanning = false
    @Published var working: String?
    @Published var message: String?
    @Published var plan: CastPlan?
    @Published var tvState = ""
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var volume = 0.0
    @Published var mirrorTargets: [MirrorTarget] = []
    @Published var thumbnails: [MirrorTarget.ID: NSImage] = [:]
    @Published var browsers: [Browser] = []
    @Published var playingApps: [PlayingApp] = []
    @Published var otherApps: [PlayingApp] = []
    @Published var tvScreenOn = false
    @Published var loadingTabs = false
    @Published var recentFiles: [URL] = (UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []).map { URL(fileURLWithPath: $0) }

    @AppStorage(Pref.maxHeight) var maxHeight = 1080
    @AppStorage(Pref.playsHEVC) var playsHEVC = false
    @AppStorage(Pref.mirrorFPS) var mirrorFPS = 30
    @AppStorage(Pref.mirrorBitrate) var mirrorBitrate = 8
    @AppStorage(Pref.mirrorCursor) var mirrorCursor = true
    @AppStorage(Pref.mirrorAudio) var mirrorAudio = true
    @AppStorage(Pref.lidClosed) var lidClosed = false
    @AppStorage(Pref.pauseBrowser) var pauseBrowser = true
    @AppStorage(Pref.resumePosition) var resumePosition = true
    @AppStorage(Pref.lowLatency) var lowLatency = true
    @AppStorage(Pref.muteMac) var muteMac = true

    let mirror = ScreenMirror()
    let browser = BrowserWatcher()
    let tvScreen = TVScreen()
    let recentApps = RecentApps()
    let media = MediaDetector()
    var sentWindow: SentWindow?
    var restoreTask: Task<Void, Never>?
    var restartTask: Task<Void, Never>?
    var captureRestarts = 0
    var handledLaunchArguments = false
    private let server = MediaServer()
    private let power = Power()
    private let tabServer = TabCastServer()
    private var screenObserver: NSObjectProtocol?
    private var emptyScans = 0
    private var offset = 0.0
    private var hasPlayed = false
    private var castStarted = Date()
    private var pollTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?

    var renderer: Renderer? { renderers.first { $0.id == selectedID } ?? renderers.first }
    var isPlaying: Bool { tvState == "PLAYING" || tvState == "TRANSITIONING" }
    var canSeek: Bool { plan.map { $0.duration > 0 && $0.kind != .image } ?? false }
    var canPause: Bool { plan.map { $0.mode != .mirror && $0.mode != .tab } ?? false }
    private var client: DLNAClient? { renderer.map(DLNAClient.init) }
    private var profile: TVProfile { TVProfile(maxHeight: maxHeight, playsHEVC: playsHEVC) }

    init() {
        selectedID = UserDefaults.standard.string(forKey: "selectedTV")
        try? server.start()
        mirror.onStopped = { [weak self] error in Task { @MainActor in self?.mirrorStopped(error) } }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        tabServer.onSession = { [weak self] session in Task { @MainActor in self?.castTabStream(session) } }
        tabServer.start()
        Extension.install()
        if Tools.ffmpeg == nil {
            message = "AnyCast needs ffmpeg to stream from your Mac. Install it in Terminal with: brew install ffmpeg yt-dlp"
        }
        scan()
        Task { [weak self] in
            while let self {
                refreshPlaying()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            renderers = await TVDiscovery.find()
            if !renderers.contains(where: { $0.id == selectedID }) {
                selectedID = renderers.first(where: { $0.name == UserDefaults.standard.string(forKey: "selectedTVName") })?.id ?? renderers.first?.id
            }
            if let name = renderer?.name { UserDefaults.standard.set(name, forKey: "selectedTVName") }
            scanning = false
            if renderers.isEmpty && emptyScans < 3 {
                emptyScans += 1
                try? await Task.sleep(for: .seconds(3))
                return scan()
            }
            emptyScans = 0
            if renderers.isEmpty {
                message = await TVDiscovery.knownTVIsStuck()
                    ? "No TV found. Your TV is on the network but stopped accepting casts. Unplug it for 10 seconds, then scan again."
                    : "No TV found. Check the TV is on and on the same Wi-Fi, then scan again."
            }
            else if message?.hasPrefix("No TV") == true { message = nil }
            Log.write("scan found \(renderers.map { "\($0.name) \($0.id)" })")
            if let client { volume = Double((try? await client.volume()) ?? 0) }
            handleLaunchArguments()
        }
    }

    func refreshTabs() {
        guard !loadingTabs else { return }
        loadingTabs = true
        Task {
            browsers = await browser.browsers()
            loadingTabs = false
        }
    }

    func castCurrentTab() {
        run("Getting the video from your browser") { [self] in try await castTabNow(try await browser.activeTab()) }
    }

    func cast(tab: BrowserTab) {
        run("Getting the video from \(tab.url.host ?? "the tab")") { [self] in try await castTabNow(tab) }
    }

    private func castTabNow(_ tab: BrowserTab) async throws {
        let plan: CastPlan
        do {
            plan = try await Planner.plan(web: tab.url, profile: profile)
        } catch {
            Log.write("extract failed (\(error.localizedDescription)), mirroring \(tab.browser)")
            await browser.bringToFront(tab)
            let bundleID = BrowserWatcher.bundleID(forName: tab.browser) ?? ""
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                try await mirrorWindow(of: PlayingApp(name: tab.browser, bundleID: bundleID, pid: app.processIdentifier))
            } else {
                try await mirrorWithPicker()
            }
            message = "This site locks its video, so AnyCast is mirroring the \(tab.browser) window. Make the video full screen for the best picture."
            return
        }
        var resumed = plan
        let position = pauseBrowser ? await browser.pauseVideo(in: tab) : nil
        resumed.startAt = resumePosition ? position ?? 0 : 0
        try await cast(resumed)
    }

    func castLink(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else {
            message = "That doesn't look like a web link"
            return
        }
        run("Getting the video from the link") { [self] in try await cast(try await Planner.plan(web: url, profile: profile)) }
    }

    func castFile(_ url: URL) {
        recentFiles = Array(([url] + recentFiles.filter { $0 != url }).prefix(8))
        UserDefaults.standard.set(recentFiles.map(\.path), forKey: "recentFiles")
        run("Preparing \(url.lastPathComponent)") { [self] in try await cast(try await Planner.plan(file: url, profile: profile)) }
    }

    func useFallback() {
        guard var plan, let fallback = plan.fallback else { return }
        plan.mode = fallback.mode
        plan.source = fallback.source
        plan.fallback = nil
        plan.startAt = max(plan.startAt, currentTime)
        run("Retrying through your Mac") { [self] in try await cast(plan) }
    }

    var currentTime: Double { (plan?.seeksByRestart == true ? offset : 0) + position }

    func togglePause() {
        guard canPause, let client else { return }
        let playing = isPlaying
        tvState = playing ? "PAUSED_PLAYBACK" : "PLAYING"
        Task {
            do { playing ? try await client.pause() : try await client.play() } catch { transportFailed(error) }
        }
    }

    func seek(to seconds: Double) {
        guard let plan, let client else { return }
        if plan.seeksByRestart {
            var restarted = plan
            restarted.startAt = seconds
            run("Jumping to \(DLNAClient.format(seconds))") { [self] in try await cast(restarted) }
        } else {
            position = seconds
            Task { do { try await client.seek(to: seconds) } catch { transportFailed(error) } }
        }
    }

    private func transportFailed(_ error: Error) {
        Log.write("transport error: \(error.localizedDescription)")
        guard (error as? UPnPError)?.code == 716, var plan else {
            message = error.localizedDescription
            return
        }
        plan.startAt = currentTime
        run("Reconnecting to the TV") { [self] in try await cast(plan) }
    }

    func setVolume(_ value: Double) {
        volume = value
        volumeTask?.cancel()
        volumeTask = Task { [client] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            try? await client?.setVolume(Int(value))
        }
    }

    func stop() {
        runTask?.cancel()
        working = nil
        pollTask?.cancel()
        let client = client
        Task { try? await client?.stop() }
        endSession()
    }

    func shutdown() {
        tvScreen.turnOff()
        MacAudio.restore()
        server.clear()
        mirror.stop()
        power.allowSleep()
    }

    private func endSession() {
        pollTask?.cancel()
        seekTask?.cancel()
        tvScreen.turnOff()
        tvScreenOn = false
        sentWindow = nil
        restartTask?.cancel()
        captureRestarts = 0
        MacAudio.restore()
        mirror.speed = 1
        server.clear()
        mirror.stop()
        power.allowSleep()
        plan = nil
        tvState = ""
        position = 0
    }

    func run(_ status: String, _ work: @escaping () async throws -> Void) {
        guard renderer != nil else {
            message = "No TV selected. Scan for your TV first."
            return
        }
        working = status
        message = nil
        runTask?.cancel()
        runTask = Task {
            do { try await work() } catch {
                guard !Task.isCancelled else { return }
                Log.write("error: \(error.localizedDescription)")
                message = error.localizedDescription
                if plan == nil { endSession() }
            }
            if !Task.isCancelled { working = nil }
        }
    }

    func cast(_ plan: CastPlan) async throws {
        guard let renderer, let client else { return }
        try Task.checkCancellation()
        if Tools.ffmpeg == nil, plan.source.needsFFmpeg {
            throw Tools.Failure(message: "AnyCast needs ffmpeg to stream from your Mac. Install it in Terminal with: brew install ffmpeg")
        }
        pollTask?.cancel()
        seekTask?.cancel()
        restartTask?.cancel()
        server.clear()
        if case .mirror = plan.source {} else { mirror.stop() }

        offset = plan.seeksByRestart ? plan.startAt : 0
        let item: MediaItem
        switch plan.source {
        case .remote(let url, let mime):
            item = MediaItem(url: url, title: plan.title, mime: mime, kind: plan.kind, isLive: false)
        case .file(let url, let mime):
            let served = server.publish(.file(url, mime: mime), ext: url.pathExtension.lowercased(), for: renderer.host)
            item = MediaItem(url: served, title: plan.title, mime: mime, kind: plan.kind, isLive: false)
        case .pipeline(let mime, let ext, let arguments):
            let start = offset
            let served = server.publish(.stream(mime: mime, make: { FFmpegProducer(arguments: arguments(start)) }), ext: ext, for: renderer.host)
            item = MediaItem(url: served, title: plan.title, mime: mime, kind: plan.kind, isLive: true)
        case .mirror(let make):
            let served = server.publish(.stream(mime: "video/mpeg", live: true, make: make), ext: "ts", for: renderer.host)
            item = MediaItem(url: served, title: plan.title, mime: "video/mpeg", kind: .video, isLive: true)
        }

        if case .remote = plan.source { power.allowSleep() } else { await power.keepAwake(lidClosed: lidClosed) }

        working = "Starting on \(renderer.name)"
        Log.write("cast \(plan.title) mode=\(plan.mode) url=\(item.url.absoluteString.prefix(120)) start=\(plan.startAt)")
        do {
            try await client.load(item)
            try Task.checkCancellation()
        } catch {
            if !Task.isCancelled { endSession() }
            throw error
        }
        self.plan = plan
        captureRestarts = 0
        duration = plan.duration
        position = 0
        hasPlayed = false
        castStarted = Date()
        tvState = "TRANSITIONING"
        if !plan.seeksByRestart && plan.startAt > 5 { startSeekWhenReady(client, to: plan.startAt) }
        startPolling(client)
    }

    private func startSeekWhenReady(_ client: DLNAClient, to seconds: Double) {
        seekTask?.cancel()
        seekTask = Task {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                if (try? await client.transportState()) == "PLAYING" {
                    try? await client.seek(to: seconds)
                    return
                }
            }
        }
    }

    private func startPolling(_ client: DLNAClient) {
        pollTask?.cancel()
        pollTask = Task {
            var lastAnswer = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, plan != nil else { return }
                guard let state = try? await client.transportState() else {
                    guard !Task.isCancelled else { return }
                    if Date().timeIntervalSince(lastAnswer) > 20 {
                        Log.write("tv stopped answering")
                        message = "Lost the connection to \(client.renderer.name). Check the TV is on, then cast again."
                        endSession()
                        return
                    }
                    continue
                }
                guard !Task.isCancelled else { return }
                lastAnswer = Date()
                if state != tvState { Log.write("tv state \(state) at \(Int(currentTime))s") }
                tvState = state
                let info = try? await client.position()
                guard !Task.isCancelled else { return }
                if let info {
                    position = info.position
                    if plan?.mode == .mirror, info.position > 0 { tuneMirrorLatency(tvPosition: info.position) }
                    if duration == 0, info.duration > 0 { duration = info.duration }
                    if state == "PLAYING" && info.position > 0 { hasPlayed = true }
                }
                guard state == "STOPPED" || state == "NO_MEDIA_PRESENT" else { continue }
                if hasPlayed {
                    endSession()
                    return
                }
                if Date().timeIntervalSince(castStarted) > 8, plan?.kind != .image {
                    if plan?.fallback != nil {
                        message = "The TV couldn't play it directly. Retrying through your Mac."
                        useFallback()
                    } else {
                        message = "The TV couldn't play this. Try a lower max resolution in Settings."
                        endSession()
                    }
                    return
                }
            }
        }
    }
}
