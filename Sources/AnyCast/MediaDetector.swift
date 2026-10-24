import AppKit
import CoreAudio

struct PlayingApp {
    let name: String
    let bundleID: String
    let pid: pid_t
}

enum MediaDetector {
    // Browsers play sound from helper processes (com.google.Chrome.helper), so match them back to the parent app by bundle ID prefix.
    static func appsPlayingAudio() -> [PlayingApp] {
        let ownBundle = Bundle.main.bundleIdentifier ?? ""
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var result: [PlayingApp] = []
        for process in audioProcesses() where process.isPlaying {
            guard let app = apps.first(where: { app in
                guard let id = app.bundleIdentifier else { return false }
                return app.processIdentifier == process.pid || process.bundleID == id || process.bundleID.hasPrefix(id + ".")
            }), let id = app.bundleIdentifier, id != ownBundle, !result.contains(where: { $0.bundleID == id })
            else { continue }
            result.append(PlayingApp(name: app.localizedName ?? id, bundleID: id, pid: app.processIdentifier))
        }
        return result
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
