import CoreAudio
import Foundation

@MainActor
enum MacAudio {
    private enum Muted { case device(AudioObjectID), script(Task<Bool, Never>) }
    private static var muted: Muted? {
        didSet { UserDefaults.standard.set(muted != nil, forKey: Pref.mutedByAnyCast) }
    }

    // A crash or force quit skips restore(), so the next launch unmutes what AnyCast muted.
    static func restoreAfterCrash() {
        guard muted == nil, UserDefaults.standard.bool(forKey: Pref.mutedByAnyCast) else { return }
        UserDefaults.standard.set(false, forKey: Pref.mutedByAnyCast)
        if let device = defaultOutput(), canMute(device) {
            _ = setMute(device, false)
        } else {
            Task.detached { _ = osascript("set volume output muted false") }
        }
    }

    static func mute() {
        guard muted == nil else { return }
        if let device = defaultOutput(), canMute(device) {
            guard muteState(device) == false, setMute(device, true) else { return }
            muted = .device(device)
        } else {
            // Some outputs have no mute control of their own; AppleScript still mutes them through the system volume.
            muted = .script(Task.detached {
                guard osascript("output muted of (get volume settings)") == "false" else { return false }
                _ = osascript("set volume output muted true")
                return true
            })
        }
    }

    static func restore() {
        switch muted {
        case .device(let device): _ = setMute(device, false)
        case .script(let muting):
            Task.detached { if await muting.value { _ = osascript("set volume output muted false") } }
        case nil: break
        }
        muted = nil
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioObjectID? {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func canMute(_ device: AudioObjectID) -> Bool {
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address) && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func muteState(_ device: AudioObjectID) -> Bool? {
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMute(_ device: AudioObjectID, _ mute: Bool) -> Bool {
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var value: UInt32 = mute ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private nonisolated static func osascript(_ source: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        process.standardOutput = out
        try? process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
