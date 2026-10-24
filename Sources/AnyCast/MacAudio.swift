import Foundation

enum MacAudio {
    private static var mutedByUs = false

    static func mute() {
        guard !mutedByUs, osascript("output muted of (get volume settings)") == "false" else { return }
        _ = osascript("set volume output muted true")
        mutedByUs = true
    }

    static func restore() {
        guard mutedByUs else { return }
        _ = osascript("set volume output muted false")
        mutedByUs = false
    }

    private static func osascript(_ source: String) -> String {
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
