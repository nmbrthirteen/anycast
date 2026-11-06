import AppKit
import ScreenCaptureKit

extension CastController {
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
        let found = media.scan()
        let byRecent = { (a: PlayingApp, b: PlayingApp) in self.recentApps.rank(a.pid) < self.recentApps.rank(b.pid) }
        let playing = found.playing.sorted(by: byRecent), others = found.others.sorted(by: byRecent)
        if playing != playingApps {
            Log.write("playing apps: \(playing.map(\.name))")
            playingApps = playing
        }
        if others != otherApps { otherApps = others }
    }

    func sendToTV(_ chosen: PlayingApp?) {
        run("Finding what's playing") { [self] in
            refreshPlaying()
            guard let app = chosen ?? playingApps.first else {
                throw Tools.Failure(message: "Nothing has played sound in the last few minutes. Start the video, or pick the app from the menu.")
            }
            if WindowMover.isAllowed {
                try await sendToTVScreen(app)
            } else {
                WindowMover.requestPermission()
                try await mirrorWindow(of: app)
                message = "Allow AnyCast in Accessibility settings so it can move videos onto the TV screen. That keeps them playing on any desktop."
            }
        }
    }

    func startTVScreen() {
        run("Turning on the TV screen") { [self] in try await showTVScreen() }
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

    func mirrorWindow(of app: PlayingApp) async throws {
        guard ScreenMirror.hasPermission else { return try await mirrorWithPicker() }
        var found = try await windowTarget(of: app)
        if found == nil { found = await showDesktop(of: app) }
        guard let window = found else {
            if ScreenMirror.hasWindowOnOtherDesktop(app.pid) { throw Tools.Failure(message: Self.otherDesktopMessage(app.name)) }
            return try await mirrorWithPicker()
        }
        Log.write("mirroring playing app \(app.name) crop=\(window.crop.map { "\($0)" } ?? "none")")
        try await mirrorCast(window)
    }

    // macOS only draws the visible desktop, so a video on another desktop (often a full screen one) is brought into view first.
    private func showDesktop(of app: PlayingApp) async -> MirrorTarget? {
        guard ScreenMirror.hasWindowOnOtherDesktop(app.pid) else { return nil }
        NSRunningApplication(processIdentifier: app.pid)?.activate()
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(300))
            if let window = try? await windowTarget(of: app) { return window }
        }
        return nil
    }

    private func windowTarget(of app: PlayingApp) async throws -> MirrorTarget? {
        guard var window = try await ScreenMirror.frontWindow(of: app.pid) else { return nil }
        if let browserName = BrowserWatcher.name(forBundleID: app.bundleID) {
            window.crop = await browser.videoFrame(inFrontTabOf: browserName)
        }
        return window
    }

    func mirrorWithPicker() async throws {
        let filter = try await ScreenMirror.pickWithSystemPicker()
        try Task.checkCancellation()
        try await mirror.start(filter: filter, settings: mirrorSettings)
        try await castMirror(title: "Screen mirroring")
    }

    // Display changes (like the macOS "show on AnyCast TV" prompt or closing the lid) can stop capture, and macOS sometimes
    // removes the TV screen altogether. Capture restarts on the same target, or on a new TV screen when the old one is gone.
    func mirrorStopped(_ error: Error?) {
        Log.write("capture stopped: \(error?.localizedDescription ?? "no error") tv screen online=\(tvScreen.isOnline)")
        guard plan?.mode == .mirror else { return }
        lastDisplayChange = Date()
        guard tvScreenOn else { return stop() }
        captureRestarts = captureRestarts.filter { Date().timeIntervalSince($0) < 60 } + [Date()]
        guard captureRestarts.count <= 3 else {
            message = "macOS kept stopping the capture. Start casting again."
            return stop()
        }
        restartTask?.cancel()
        restartTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, plan?.mode == .mirror else { return }
            do {
                try await restartCapture()
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
                stop()
            }
        }
    }

    private func restartCapture() async throws {
        let target: MirrorTarget
        if tvScreenOn {
            if !tvScreen.isOnline {
                tvScreen.turnOff()
                _ = try await tvScreen.turnOn()
            }
            guard let id = tvScreen.displayID else { return }
            target = tvScreenTarget(id)
        } else {
            return
        }
        try Task.checkCancellation()
        let size = (mirror.width, mirror.height)
        try await mirror.start(target, settings: mirror.settings)
        try Task.checkCancellation()
        Log.write("capture restarted on \(target.title)")
        if size != (mirror.width, mirror.height), let plan { reconnect(plan) }
        scheduleRestore()
    }

    func screensChanged() {
        scheduleRestore()
    }

    // Waits for macOS to finish rearranging screens, then puts the video back on the TV screen if it was knocked off.
    private func scheduleRestore() {
        guard tvScreenOn else { return }
        let previous = restoreTask
        previous?.cancel()
        restoreTask = Task {
            await previous?.value
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, tvScreenOn else { return }
            sendStraysHome()
            guard working == nil, let sentWindow, tvScreen.isOnline, let id = tvScreen.displayID,
                  await WindowMover.restore(sentWindow, on: CGDisplayBounds(id)) else { return }
            if Self.isBrowser(sentWindow.pid) { await VideoFullscreen.restore(on: id, in: sentWindow.pid) }
        }
    }

    private func sendStraysHome() {
        guard WindowMover.isAllowed else { return }
        WindowMover.sendHome(tvScreen.strayWindows(), except: sentWindow)
    }

    private static func isBrowser(_ pid: pid_t) -> Bool {
        BrowserWatcher.name(forBundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "") != nil
    }

    func leaveTVScreen() {
        restoreTask?.cancel()
        tvScreen.turnOff()
        tvScreenOn = false
        sentWindow = nil
    }

    func tuneMirrorLatency(tvPosition: Double) {
        if let id = mirror.windowID, !ScreenMirror.isOnScreen(id), message == nil, let title = plan?.title {
            message = Self.otherDesktopMessage(String(title.split(separator: ":").first ?? "The"))
        }
        let buffered = mirror.streamSeconds - tvPosition
        // The TV reports whole seconds, so a position that holds for several polls means it ran dry and is rebuffering.
        tvPositionRepeats = tvPosition == lastTVPosition ? tvPositionRepeats + 1 : 0
        lastTVPosition = tvPosition
        if tvPositionRepeats >= 3 {
            tvPositionRepeats = 0
            latencyTarget = min(latencyTarget + 0.5, 5)
            Log.write("tv stalled, keeping \(latencyTarget)s buffered from now on")
        }
        if lowLatency {
            if buffered > latencyTarget + 0.6 { mirror.speed = 0.8 } else if buffered < latencyTarget { mirror.speed = 1 }
        }
        Log.write(String(format: "mirror buffered %.1fs speed %.1f | ", buffered, mirror.speed) + mirror.takeStats())
    }

    func castTabStream(_ session: TabSession) {
        session.onEnded = { [weak self] in
            Task { @MainActor in if self?.plan?.mode == .tab { self?.stop() } }
        }
        run("Sending \(session.title) to the TV") { [self] in
            try await cast(CastPlan(title: session.title, kind: .video, duration: 0, mode: .tab, source: .mirror(make: { session.makeProducer() })))
        }
    }

    private var mirrorSettings: MirrorSettings {
        MirrorSettings(fps: mirrorFPS, bitrateMbps: mirrorBitrate, maxHeight: min(maxHeight == 0 ? 1080 : maxHeight, 1080),
                       showsCursor: mirrorCursor, capturesAudio: mirrorAudio)
    }

    private func tvScreenTarget(_ id: CGDirectDisplayID) -> MirrorTarget {
        MirrorTarget(kind: .display(id), title: "TV screen")
    }

    private func showTVScreen() async throws {
        let id = try await tvScreen.turnOn()
        tvScreenOn = true
        if plan?.mode == .mirror, mirror.displayID == id { return }
        try Task.checkCancellation()
        try await mirror.start(tvScreenTarget(id), settings: mirrorSettings)
        try await castMirror(title: "TV screen")
        Task {
            try? await Task.sleep(for: .seconds(2))
            sendStraysHome()
        }
    }

    // The TV takes several seconds to start playing, so it loads while the window moves over.
    private func sendToTVScreen(_ app: PlayingApp) async throws {
        let id = try await tvScreen.turnOn()
        tvScreenOn = true
        async let casting: Void = showTVScreen()
        var moved = false
        if let window = WindowMover.frontWindow(of: app.pid) {
            sentWindow = SentWindow(pid: app.pid, element: window, fullScreen: false)
            moved = await WindowMover.move(window, of: app.pid, to: CGDisplayBounds(id))
            sentWindow = moved ? SentWindow(pid: app.pid, element: window, fullScreen: WindowMover.isFullScreen(window)) : nil
        }
        if moved {
            try Task.checkCancellation()
            Log.write("moved \(app.name) onto the tv screen")
            if Self.isBrowser(app.pid) { await VideoFullscreen.restore(on: id, in: app.pid) }
        }
        try await casting
        guard moved else {
            throw Tools.Failure(message: "Couldn't move \(app.name)'s window. Drag it onto the TV screen, off the right edge of your display.")
        }
    }

    private func mirrorCast(_ target: MirrorTarget) async throws {
        guard ScreenMirror.hasPermission else { return try await mirrorWithPicker() }
        do {
            try Task.checkCancellation()
            try await mirror.start(target, settings: mirrorSettings)
        } catch let error as SCStreamError where error.code == .userDeclined {
            return try await mirrorWithPicker()
        }
        try await castMirror(title: target.title)
    }

    private func castMirror(title: String) async throws {
        if muteMac && mirrorAudio { MacAudio.mute() }
        let mirror = self.mirror
        try await cast(CastPlan(title: title, kind: .video, duration: 0, mode: .mirror, source: .mirror(make: { mirror.makeProducer() })))
    }

    private static func otherDesktopMessage(_ app: String) -> String {
        "\(app)'s video is on another desktop, and macOS doesn't draw windows there, so the TV would show black. Keep it on the desktop you're using, or pop the video out with picture in picture."
    }
}
