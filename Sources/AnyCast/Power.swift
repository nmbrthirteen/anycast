import Foundation
import IOKit.pwr_mgt

@MainActor
final class Power {
    private static let rulePath = "/etc/sudoers.d/anycast-pmset"
    private var assertion: IOPMAssertionID = 0
    private var sleepDisabled = false

    init() {
        if UserDefaults.standard.bool(forKey: Pref.sleepDisabledByAnyCast) { Self.pmset(disable: false) }
    }

    func keepAwake(lidClosed: Bool) {
        if assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "AnyCast is streaming to your TV" as CFString, &assertion)
        }
        guard lidClosed, !sleepDisabled else { return }
        if !Self.pmset(disable: true) {
            installRule()
            guard Self.pmset(disable: true) else { return }
        }
        sleepDisabled = true
        UserDefaults.standard.set(true, forKey: Pref.sleepDisabledByAnyCast)
        Self.restoreWhenAppExits()
    }

    func allowSleep() {
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        guard sleepDisabled else { return }
        Self.pmset(disable: false)
        sleepDisabled = false
        UserDefaults.standard.set(false, forKey: Pref.sleepDisabledByAnyCast)
    }

    // One admin prompt installs a rule that lets AnyCast toggle only this pmset setting without a password from then on.
    private func installRule() {
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("anycast-pmset").path
        try? (rule + "\n").write(toFile: temp, atomically: true, encoding: .utf8)
        let shell = "/usr/sbin/visudo -cf '\(temp)' && /usr/bin/install -m 0440 -o root -g wheel '\(temp)' \(Self.rulePath)"
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(shell)\" with administrator privileges")?.executeAndReturnError(&error)
        try? FileManager.default.removeItem(atPath: temp)
    }

    @discardableResult
    private static func pmset(disable: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disable ? "1" : "0"]
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static var watching = false

    private static func restoreWhenAppExits() {
        guard !watching else { return }
        watching = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 5; done; /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0"]
        try? process.run()
    }
}
