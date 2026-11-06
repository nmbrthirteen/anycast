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
            if sendMode == .keepOnMac && !Lid.isClosed {
                try await keepOnMac(app)
            } else if WindowMover.isAllowed {
                try await sendToTVScreen(app)
                if sendMode == .keepOnMac {
                    mirroredApp = app
                    followedLidClosed = true
                }
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
        guard let window = try await windowTarget(of: app) else {
            if ScreenMirror.hasWindowOnOtherDesktop(app.pid) { throw Tools.Failure(message: Self.otherDesktopMessage(app.name)) }
            return try await mirrorWithPicker()
        }
        Log.write("mirroring playing app \(app.name) crop=\(window.crop.map { "\($0)" } ?? "none")")
        try await mirrorCast(window)
    }

    private func windowTarget(of app: PlayingApp) async throws -> MirrorTarget? {
        guard var window = try await ScreenMirror.frontWindow(of: app.pid) else { return nil }
        if let browserName = BrowserWatcher.name(forBundleID: app.bundleID) {
            window.crop = await browser.videoFrame(inFrontTabOf: browserName)
        }
        return window
    }

    private func keepOnMac(_ app: PlayingApp) async throws {
        try await mirrorWindow(of: app)
        guard mirror.windowID != nil else { return }
        mirroredApp = app
        followedLidClosed = false
        if lidClosed && !WindowMover.isAllowed {
            WindowMover.requestPermission()
            message = "Allow AnyCast in Accessibility settings so the video can move to the TV screen when you close the lid."
        }
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
        guard !isHandingOff else { return }
        if lidMayHaveChanged() { return }
        guard tvScreenOn || mirroredApp != nil else { return stop() }
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
        } else if let app = mirroredApp, let window = try await windowTarget(of: app) {
            target = window
        } else {
            throw Tools.Failure(message: "The video's window closed, so mirroring stopped.")
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
        lidMayHaveChanged()
        scheduleRestore()
    }

    // Waits for macOS to finish rearranging screens, then puts the video back on the TV screen if it was knocked off.
    private func scheduleRestore() {
        guard tvScreenOn, sentWindow != nil else { return }
        let previous = restoreTask
        previous?.cancel()
        restoreTask = Task {
            await previous?.value
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !isHandingOff, tvScreenOn, let sentWindow, tvScreen.isOnline, let id = tvScreen.displayID,
                  await WindowMover.restore(sentWindow, on: CGDisplayBounds(id)) else { return }
            if Self.isBrowser(sentWindow.pid) { await VideoFullscreen.restore(on: id, in: sentWindow.pid) }
        }
    }

    @discardableResult
    func lidMayHaveChanged() -> Bool {
        let closed = Lid.isClosed
        if closed != lidIsClosed {
            lidIsClosed = closed
            Log.write("lid \(closed ? "closed" : "opened")")
        }
        return followLid()
    }

    // A closed lid leaves no screen to draw a window kept on the Mac, so it moves to the TV screen until the lid opens.
    // Each lid change is acted on once, so a failed move isn't retried on every poll.
    private func followLid() -> Bool {
        guard let app = mirroredApp, plan?.mode == .mirror, lidIsClosed != followedLidClosed,
              renderer != nil, ToolInstaller.isComplete, working == nil, !isHandingOff else { return false }
        if lidIsClosed && !WindowMover.isAllowed { return false }
        followedLidClosed = lidIsClosed
        if lidIsClosed {
            handOff("Moving the video to the TV screen") { [self] in try await sendToTVScreen(app) }
        } else {
            handOff("Moving the video back to your Mac") { [self] in try await returnToMac(app) }
        }
        return true
    }

    private func handOff(_ status: String, _ work: @escaping () async throws -> Void) {
        Log.write(status)
        let restart = restartTask
        restart?.cancel()
        restoreTask?.cancel()
        isHandingOff = true
        run(status, continuing: true) { [self] in
            defer {
                isHandingOff = false
                if !Task.isCancelled, plan?.mode == .mirror, !mirror.isCapturing { mirrorStopped(nil) }
            }
            await restart?.value
            try await work()
        }
    }

    private func returnToMac(_ app: PlayingApp) async throws {
        var screen: CGDirectDisplayID?
        for _ in 0..<20 {
            screen = Lid.builtInDisplay
            if screen != nil { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let screen, let element = sentWindow?.element ?? WindowMover.frontWindow(of: app.pid) else {
            mirroredApp = nil
            throw Tools.Failure(message: "Couldn't bring \(app.name) back to your Mac, so it stays on the TV screen.")
        }
        let moved = await WindowMover.move(element, of: app.pid, to: CGDisplayBounds(screen))
        try Task.checkCancellation()
        Log.write("moved \(app.name) back to the mac: \(moved)")
        var window: MirrorTarget?
        for _ in 0..<8 where moved && window == nil {
            window = try await windowTarget(of: app)
            if window == nil { try await Task.sleep(for: .milliseconds(250)) }
        }
        guard let window else {
            mirroredApp = nil
            throw Tools.Failure(message: "Couldn't bring \(app.name) back to your Mac, so it stays on the TV screen.")
        }
        sentWindow = nil
        tvScreenOn = false
        defer { tvScreen.turnOff() }
        do {
            try await mirrorCast(window)
        } catch {
            stop()
            throw error
        }
        if Self.isBrowser(app.pid) { await VideoFullscreen.restore(on: screen, in: app.pid) }
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
            try Task.checkCancellation()
            try await showTVScreen()
            throw Tools.Failure(message: "Couldn't move \(app.name)'s window. Drag it onto the TV screen, off the right edge of your display.")
        }
        try Task.checkCancellation()
        Log.write("moved \(app.name) onto the tv screen")
        sentWindow = SentWindow(pid: app.pid, element: window, fullScreen: WindowMover.isFullScreen(window))
        try await showTVScreen()
        if Self.isBrowser(app.pid), let id = tvScreen.displayID {
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
