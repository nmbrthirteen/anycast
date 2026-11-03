import AppKit
import CoreAudio

struct PlayingApp: Equatable {
    let name: String
    let bundleID: String
    let pid: pid_t
}

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsiblePID(_ pid: pid_t) -> pid_t

@MainActor
final class MediaDetector {
    private static let videoPlayers: Set<String> = [
        "com.colliderli.iina", "org.videolan.vlc", "com.apple.QuickTimePlayerX", "io.mpv",
        "com.firecore.infuse", "com.apple.TV", "tv.plex.desktop", "com.netflix.Netflix",
    ]
    // Paused videos and ad gaps stop the audio stream, so an app counts as playing for a while after its last sound.
    private static let grace: TimeInterval = 180
    private var lastHeard: [pid_t: Date] = [:]
    private var audible: Set<pid_t> = []
    var onChange: (() -> Void)?

    private var processListListener: AudioObjectPropertyListenerBlock?
    private var outputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var expiryTask: Task<Void, Never>?

    // CoreAudio reports processes appearing and starting or stopping output, and NSWorkspace reports launches and quits.
    func start() {
        guard processListListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.processListChanged() }
        }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr else {
            return Log.write("media detector: could not watch audio processes")
        }
        processListListener = listener
        watchOutput(of: Self.processObjects())
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
        }
    }

    func stop() {
        if let processListListener {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, processListListener)
        }
        processListListener = nil
        watchOutput(of: [])
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        expiryTask?.cancel()
    }

    private func processListChanged() {
        watchOutput(of: Self.processObjects())
        onChange?()
    }

    private func watchOutput(of ids: [AudioObjectID]) {
        var address = Self.address(kAudioProcessPropertyIsRunningOutput)
        for (id, block) in outputListeners where !ids.contains(id) {
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
            outputListeners[id] = nil
        }
        for id in ids where outputListeners[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
            if AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr { outputListeners[id] = block }
        }
    }

    func scan() -> (playing: [PlayingApp], others: [PlayingApp]) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
        let now = Date()
        let heard = Set(Self.audioProcesses().filter(\.isPlaying).compactMap { Self.owner(of: $0, in: apps)?.processIdentifier })
        // Scans only run on changes, so an app that was audible at the last scan played until now.
        for pid in heard.union(audible) { lastHeard[pid] = now }
        audible = heard
        lastHeard = lastHeard.filter { pid, date in now.timeIntervalSince(date) < Self.grace && apps.contains { $0.processIdentifier == pid } }
        expireQuietApps(now)

        let playing = apps.filter { lastHeard[$0.processIdentifier] != nil }
        let others = apps.filter { app in
            guard let id = app.bundleIdentifier, lastHeard[app.processIdentifier] == nil else { return false }
            return Self.videoPlayers.contains(id) || BrowserWatcher.name(forBundleID: id) != nil
        }
        return (playing.compactMap(Self.playingApp), others.compactMap(Self.playingApp))
    }

    private static func playingApp(_ app: NSRunningApplication) -> PlayingApp? {
        guard let id = app.bundleIdentifier else { return nil }
        return PlayingApp(name: app.localizedName ?? id, bundleID: id, pid: app.processIdentifier)
    }

    // Browsers and WebKit apps play sound from helper processes, which macOS attributes to the app that launched them.
    private static func owner(of process: AudioProcess, in apps: [NSRunningApplication]) -> NSRunningApplication? {
        let responsible = responsiblePID(process.pid)
        return apps.first { $0.processIdentifier == process.pid || $0.processIdentifier == responsible }
            ?? apps.first { app in app.bundleIdentifier.map { process.bundleID.hasPrefix($0 + ".") } ?? false }
    }

    private struct AudioProcess {
        let pid: pid_t
        let bundleID: String
        let isPlaying: Bool
    }

    // No event marks the end of the grace period, so one timer fires when the oldest quiet app should drop out.
    private func expireQuietApps(_ now: Date) {
        expiryTask?.cancel()
        guard let oldest = lastHeard.filter({ !audible.contains($0.key) }).values.min() else { return }
        let delay = max(1, Self.grace - now.timeIntervalSince(oldest))
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func audioProcesses() -> [AudioProcess] {
        processObjects().map { id in
            AudioProcess(pid: pid_t(bitPattern: uint32(id, kAudioProcessPropertyPID)),
                         bundleID: string(id, kAudioProcessPropertyBundleID) ?? "",
                         isPlaying: uint32(id, kAudioProcessPropertyIsRunningOutput) != 0)
        }
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = Self.address(selector)
        var result: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr ? result : 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }
}
