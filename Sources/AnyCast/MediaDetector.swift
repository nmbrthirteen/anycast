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

    func scan() -> (playing: [PlayingApp], others: [PlayingApp]) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
        let now = Date()
        for process in Self.audioProcesses() where process.isPlaying {
            if let app = Self.owner(of: process, in: apps) { lastHeard[app.processIdentifier] = now }
        }
        lastHeard = lastHeard.filter { pid, date in now.timeIntervalSince(date) < Self.grace && apps.contains { $0.processIdentifier == pid } }

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

    private static func audioProcesses() -> [AudioProcess] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.map { id in
            AudioProcess(pid: pid_t(bitPattern: uint32(id, kAudioProcessPropertyPID)),
                         bundleID: string(id, kAudioProcessPropertyBundleID) ?? "",
                         isPlaying: uint32(id, kAudioProcessPropertyIsRunningOutput) != 0)
        }
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var result: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr ? result : 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }
}
