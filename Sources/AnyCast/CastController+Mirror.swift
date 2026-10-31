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
        guard var window = try await ScreenMirror.frontWindow(of: app.pid) else {
            if ScreenMirror.hasWindowOnOtherDesktop(app.pid) { throw Tools.Failure(message: Self.otherDesktopMessage(app.name)) }
            return try await mirrorWithPicker()
        }
        if let browserName = BrowserWatcher.name(forBundleID: app.bundleID) {
            window.crop = await browser.videoFrame(inFrontTabOf: browserName)
        }
        Log.write("mirroring playing app \(app.name) crop=\(window.crop.map { "\($0)" } ?? "none")")
        try await mirrorCast(window)
    }

    func mirrorWithPicker() async throws {
        let filter = try await ScreenMirror.pickWithSystemPicker()
        try Task.checkCancellation()
        try await mirror.start(filter: filter, settings: mirrorSettings)
        try await castMirror(title: "Screen mirroring")
    }

    // Display changes (like the macOS "show on AnyCast TV" prompt) can stop capture, and macOS sometimes removes the
    // TV screen altogether. Capture restarts on the same screen, or on a new one when the old one is gone.
    func mirrorStopped(_ error: Error?) {
        Log.write("capture stopped: \(error?.localizedDescription ?? "no error") tv screen online=\(tvScreen.isOnline)")
        guard plan?.mode == .mirror else { return }
        guard tvScreenOn, tvScreen.displayID != nil else { return stop() }
        captureRestarts += 1
        guard captureRestarts <= 3 else {
            message = "macOS kept stopping the TV screen. Turn it on again."
            return stop()
        }
        restartTask?.cancel()
        restartTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, plan?.mode == .mirror else { return }
            do {
                if !tvScreen.isOnline {
                    tvScreen.turnOff()
                    _ = try await tvScreen.turnOn()
                }
                guard !Task.isCancelled, let id = tvScreen.displayID else { return }
                try await mirror.start(tvScreenTarget(id), settings: mirror.settings)
                Log.write("capture restarted on tv screen \(id)")
                if let sentWindow, let bounds = tvScreen.bounds { await WindowMover.restore(sentWindow, on: bounds) }
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
                stop()
            }
        }
    }

    // Closing the lid turns off the built-in screen and macOS shuffles windows; put the video back once things settle.
    func screensChanged() {
        guard tvScreenOn, let sentWindow else { return }
        restoreTask?.cancel()
        restoreTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, tvScreenOn, tvScreen.isOnline, let bounds = tvScreen.bounds else { return }
            await WindowMover.restore(sentWindow, on: bounds)
        }
    }

    func tuneMirrorLatency(tvPosition: Double) {
        if let id = mirror.windowID, !ScreenMirror.isOnScreen(id), message == nil, let title = plan?.title {
            message = Self.otherDesktopMessage(String(title.split(separator: ":").first ?? "The"))
        }
        let buffered = mirror.streamSeconds - tvPosition
        if lowLatency {
            if buffered > 5.2 { mirror.speed = 0.7 } else if buffered < 4.6 { mirror.speed = 1 }
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
    }

    private func sendToTVScreen(_ app: PlayingApp) async throws {
        _ = try await tvScreen.turnOn()
        tvScreenOn = true
        guard let bounds = tvScreen.bounds, let window = WindowMover.frontWindow(of: app.pid),
              await WindowMover.move(window, of: app.pid, to: bounds) else {
            try await showTVScreen()
            throw Tools.Failure(message: "Couldn't move \(app.name)'s window. Drag it onto the TV screen, off the right edge of your display.")
        }
        Log.write("moved \(app.name) onto the tv screen")
        sentWindow = SentWindow(pid: app.pid, element: window)
        try await showTVScreen()
        if BrowserWatcher.name(forBundleID: app.bundleID) != nil, let id = tvScreen.displayID {
            await VideoFullscreen.restore(on: id, in: app.pid)
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
