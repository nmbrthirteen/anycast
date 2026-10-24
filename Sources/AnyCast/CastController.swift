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
    @Published var loadingTabs = false
    @Published var recentFiles: [URL] = (UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []).map { URL(fileURLWithPath: $0) }

    @AppStorage(Pref.maxHeight) var maxHeight = 1080
    @AppStorage(Pref.playsHEVC) var playsHEVC = false
    @AppStorage(Pref.mirrorFPS) var mirrorFPS = 30
    @AppStorage(Pref.mirrorBitrate) var mirrorBitrate = 12
    @AppStorage(Pref.mirrorCursor) var mirrorCursor = true
    @AppStorage(Pref.mirrorAudio) var mirrorAudio = true
    @AppStorage(Pref.lidClosed) var lidClosed = false
    @AppStorage(Pref.pauseBrowser) var pauseBrowser = true
    @AppStorage(Pref.resumePosition) var resumePosition = true
    @AppStorage(Pref.lowLatency) var lowLatency = true
    @AppStorage(Pref.muteMac) var muteMac = true

    private let server = MediaServer()
    private let mirror = ScreenMirror()
    private let browser = BrowserWatcher()
    private let power = Power()
    private var offset = 0.0
    private var hasPlayed = false
    private var castStarted = Date()
    private var pollTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?

    var browserName: String? { browser.lastBrowser }
    var renderer: Renderer? { renderers.first { $0.id == selectedID } ?? renderers.first }
    var isPlaying: Bool { tvState == "PLAYING" || tvState == "TRANSITIONING" }
    var canSeek: Bool { plan.map { $0.duration > 0 && $0.kind != .image } ?? false }
    private var client: DLNAClient? { renderer.map(DLNAClient.init) }
    private var profile: TVProfile { TVProfile(maxHeight: maxHeight, playsHEVC: playsHEVC) }

    init() {
        selectedID = UserDefaults.standard.string(forKey: "selectedTV")
        try? server.start()
        mirror.onStopped = { [weak self] _ in Task { @MainActor in self?.stop() } }
        scan()
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            var locations = await Task.detached { SSDP.search() }.value
            if let known = UserDefaults.standard.string(forKey: "knownTVs").map({ $0.split(separator: " ").compactMap { URL(string: String($0)) } }) {
                locations += known.filter { !locations.contains($0) }
            }
            var found: [Renderer] = []
            await withTaskGroup(of: Renderer?.self) { group in
                for location in locations { group.addTask { try? await DeviceDescription.load(location) } }
                for await renderer in group { if let renderer, !found.contains(where: { $0.avTransport == renderer.avTransport }) { found.append(renderer) } }
            }
            renderers = found.sorted { $0.name < $1.name }
            if !renderers.isEmpty { UserDefaults.standard.set(renderers.map(\.id).joined(separator: " "), forKey: "knownTVs") }
            if renderer == nil || !renderers.contains(where: { $0.id == selectedID }) {
                selectedID = renderers.first(where: { $0.name == UserDefaults.standard.string(forKey: "selectedTVName") })?.id ?? renderers.first?.id
            }
            if let name = renderer?.name { UserDefaults.standard.set(name, forKey: "selectedTVName") }
            scanning = false
            if renderers.isEmpty && emptyScans < 3 {
                emptyScans += 1
                try? await Task.sleep(for: .seconds(3))
                scanning = false
                return scan()
            }
            emptyScans = 0
            if renderers.isEmpty { message = "No TV found. Check the TV is on and on the same Wi-Fi, then scan again." }
            else if message?.hasPrefix("No TV") == true { message = nil }
            Log.write("scan found \(renderers.map { "\($0.name) \($0.id)" })")
            if let client { volume = Double((try? await client.volume()) ?? 0) }
            handleLaunchArguments()
        }
    }

    private var handledLaunchArguments = false
    private var emptyScans = 0

    private func handleLaunchArguments() {
        guard !handledLaunchArguments, renderer != nil else { return }
        handledLaunchArguments = true
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--cast"), index + 1 < args.count {
            let target = args[index + 1]
            target.hasPrefix("http") ? castLink(target) : castFile(URL(fileURLWithPath: target))
        } else if args.contains("--cast-tab") {
            castCurrentTab()
        } else if args.contains("--mirror") {
            refreshPlaying()
            if playingApps.isEmpty {
                Task { if let screen = try? await ScreenMirror.targets().first { startMirror(screen) } }
            } else {
                mirrorPlayingMedia()
            }
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
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID(of: tab.browser)).first {
                try await mirrorWindow(of: PlayingApp(name: tab.browser, bundleID: bundleID(of: tab.browser), pid: app.processIdentifier))
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

    private func bundleID(of browserName: String) -> String {
        BrowserWatcher.bundleID(forName: browserName) ?? ""
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

    func loadMirrorTargets() {
        guard ScreenMirror.hasPermission else { return }
        Task {
            mirrorTargets = (try? await ScreenMirror.targets()) ?? []
            for target in mirrorTargets {
                if let image = await ScreenMirror.thumbnail(for: target) { thumbnails[target.id] = image }
            }
        }
    }

    func startMirror(_ target: MirrorTarget) {
        run("Starting mirroring") { [self] in try await mirrorCast(target) }
    }

    func refreshPlaying() {
        playingApps = MediaDetector.appsPlayingAudio()
    }

    func mirrorPlayingMedia() {
        run("Finding what's playing") { [self] in
            refreshPlaying()
            guard let app = playingApps.first else {
                throw Tools.Failure(message: "Nothing is playing sound right now. Start the video, then try again.")
            }
            try await mirrorWindow(of: app)
        }
    }

    private func mirrorWindow(of app: PlayingApp) async throws {
        guard ScreenMirror.hasPermission else { return try await mirrorWithPicker() }
        guard var window = try await ScreenMirror.frontWindow(of: app.pid) else {
            if ScreenMirror.hasWindowOnOtherDesktop(app.pid) { throw Tools.Failure(message: Self.otherDesktopMessage(app.name)) }
            return try await mirrorWithPicker()
        }
        if let browser = BrowserWatcher.name(forBundleID: app.bundleID) {
            window.crop = await self.browser.videoFrame(inFrontTabOf: browser)
        }
        Log.write("mirroring playing app \(app.name) crop=\(window.crop.map { "\($0)" } ?? "none")")
        try await mirrorCast(window)
    }

    func startMirrorWithPicker() {
        run("Choose what to mirror") { [self] in
            do {
                try await mirrorWithPicker()
            } catch is CancellationError {
            } catch let error as SCStreamError where error.code == .userDeclined {
                throw Tools.Failure(message: "macOS blocked screen capture. Allow AnyCast in System Settings, Privacy & Security, Screen & System Audio Recording.")
            }
        }
    }

    private var mirrorSettings: MirrorSettings {
        MirrorSettings(fps: mirrorFPS, bitrateMbps: mirrorBitrate, maxHeight: min(maxHeight == 0 ? 1080 : maxHeight, 1080),
                       showsCursor: mirrorCursor, capturesAudio: mirrorAudio)
    }

    private func mirrorCast(_ target: MirrorTarget) async throws {
        guard ScreenMirror.hasPermission else { return try await mirrorWithPicker() }
        do {
            try await mirror.start(target, settings: mirrorSettings)
        } catch let error as SCStreamError where error.code == .userDeclined {
            return try await mirrorWithPicker()
        }
        try await castMirror(title: target.title)
    }

    private func mirrorWithPicker() async throws {
        let filter = try await ScreenMirror.pickWithSystemPicker()
        try await mirror.start(filter: filter, settings: mirrorSettings)
        try await castMirror(title: "Screen mirroring")
    }

    private func castMirror(title: String) async throws {
        if muteMac && mirrorAudio { MacAudio.mute() }
        let mirror = self.mirror
        try await cast(CastPlan(title: title, kind: .video, duration: 0, mode: .mirror, source: .mirror(make: { mirror.makeProducer() })))
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
        guard let client else { return }
        let playing = isPlaying
        tvState = playing ? "PAUSED_PLAYBACK" : "PLAYING"
        Task {
            do { playing ? try await client.pause() : try await client.play() } catch { message = error.localizedDescription }
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
            Task { do { try await client.seek(to: seconds) } catch { message = error.localizedDescription } }
        }
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
        pollTask?.cancel()
        let client = client
        Task { try? await client?.stop() }
        endSession()
    }

    func shutdown() {
        MacAudio.restore()
        server.clear()
        mirror.stop()
        power.allowSleep()
    }

    private func endSession() {
        pollTask?.cancel()
        MacAudio.restore()
        mirror.speed = 1
        server.clear()
        mirror.stop()
        power.allowSleep()
        plan = nil
        tvState = ""
        position = 0
    }

    private func run(_ status: String, _ work: @escaping () async throws -> Void) {
        guard renderer != nil else {
            message = "No TV selected. Scan for your TV first."
            return
        }
        working = status
        message = nil
        Task {
            do { try await work() } catch {
                Log.write("error: \(error.localizedDescription)")
                message = error.localizedDescription
                if plan == nil { endSession() }
            }
            working = nil
        }
    }

    private func cast(_ plan: CastPlan) async throws {
        guard let renderer, let client else { return }
        pollTask?.cancel()
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

        if case .remote = plan.source { power.allowSleep() } else { power.keepAwake(lidClosed: lidClosed) }

        working = "Starting on \(renderer.name)"
        Log.write("cast \(plan.title) mode=\(plan.mode) url=\(item.url.absoluteString.prefix(120)) start=\(plan.startAt)")
        try await client.load(item)
        self.plan = plan
        duration = plan.duration
        position = 0
        hasPlayed = false
        castStarted = Date()
        tvState = "TRANSITIONING"
        if !plan.seeksByRestart && plan.startAt > 5 { startSeekWhenReady(client, to: plan.startAt) }
        startPolling(client)
    }

    private static func otherDesktopMessage(_ app: String) -> String {
        "\(app)'s video is on another desktop, and macOS doesn't draw windows there, so the TV would show black. Keep it on the desktop you're using, or pop the video out with picture in picture."
    }

    private func tuneMirrorLatency(tvPosition: Double) {
        if let id = mirror.windowID, !ScreenMirror.isOnScreen(id), message == nil, let title = plan?.title {
            message = Self.otherDesktopMessage(String(title.split(separator: ":").first ?? "The"))
        }
        let buffered = mirror.streamSeconds - tvPosition
        if lowLatency {
            if buffered > 5.2 { mirror.speed = 0.7 } else if buffered < 4.6 { mirror.speed = 1 }
        }
        Log.write(String(format: "mirror buffered %.1fs speed %.1f | ", buffered, mirror.speed) + mirror.takeStats())
    }

    private func startSeekWhenReady(_ client: DLNAClient, to seconds: Double) {
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if (try? await client.transportState()) == "PLAYING" {
                    try? await client.seek(to: seconds)
                    return
                }
            }
        }
    }

    private func startPolling(_ client: DLNAClient) {
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, plan != nil else { return }
                guard let state = try? await client.transportState() else { continue }
                if state != tvState { Log.write("tv state \(state) at \(Int(currentTime))s") }
                tvState = state
                if let info = try? await client.position() {
                    position = info.position
                    if case .mirror = plan?.source, info.position > 0 { tuneMirrorLatency(tvPosition: info.position) }
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
