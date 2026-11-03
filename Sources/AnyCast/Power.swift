import Foundation
import IOKit.pwr_mgt

@MainActor
final class Power {
    private static let rulePath = "/etc/sudoers.d/anycast-pmset"
    private var assertions: [IOPMAssertionID] = []
    private var sleepDisabled = false

    init() {
        if UserDefaults.standard.bool(forKey: Pref.sleepDisabledByAnyCast) { Task { await Self.pmset(disable: false) } }
    }

    // System sleep prevention only holds on AC power, so idle sleep is blocked too for casting on battery.
    func keepAwake(lidClosed: Bool) async throws {
        if assertions.isEmpty {
            for type in [kIOPMAssertionTypePreventSystemSleep, kIOPMAssertionTypePreventUserIdleSystemSleep] {
                var id: IOPMAssertionID = 0
                if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "AnyCast is streaming to your TV" as CFString, &id) == kIOReturnSuccess {
                    assertions.append(id)
                }
            }
        }
        guard lidClosed, !sleepDisabled else { return }
        if await !Self.pmset(disable: true) {
            try await Self.installRule()
            guard await Self.pmset(disable: true) else {
                throw Tools.Failure(message: "AnyCast couldn't keep your Mac awake with the lid closed. Keep the lid open while casting.")
            }
        }
        sleepDisabled = true
        UserDefaults.standard.set(true, forKey: Pref.sleepDisabledByAnyCast)
        Self.restoreWhenAppExits()
    }

    func allowSleep() {
        assertions.forEach { IOPMAssertionRelease($0) }
        assertions.removeAll()
        guard sleepDisabled else { return }
        Task { await Self.pmset(disable: false) }
        sleepDisabled = false
        UserDefaults.standard.set(false, forKey: Pref.sleepDisabledByAnyCast)
    }

    // Turning the lid setting off takes the sudoers rule back out, after normal sleep is restored while the rule still works.
    func removeRule() async throws {
        if sleepDisabled {
            await Self.pmset(disable: false)
            sleepDisabled = false
            UserDefaults.standard.set(false, forKey: Pref.sleepDisabledByAnyCast)
        }
        guard FileManager.default.fileExists(atPath: Self.rulePath) else { return }
        try await Self.runAsAdmin("/bin/rm -f \(Self.rulePath)")
    }

    // One admin prompt installs a rule that lets AnyCast toggle only this pmset setting without a password from then on.
    // The rule file is created by root inside the privileged script, so no other process can swap it before install.
    private static func installRule() async throws {
        let user = NSUserName()
        guard !user.isEmpty, user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw Tools.Failure(message: "AnyCast can't add a sleep rule for the user name \"\(user)\". Keep the lid open while casting.")
        }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
        try await runAsAdmin("""
            f=$(/usr/bin/mktemp) || exit 1; \
            printf '%s\\n' '\(rule)' > "$f" && /usr/sbin/visudo -cf "$f" && /usr/bin/install -m 0440 -o root -g wheel "$f" \(rulePath); \
            s=$?; /bin/rm -f "$f"; exit $s
            """)
    }

    private static func runAsAdmin(_ shell: String) async throws {
        let quoted = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        do {
            _ = try await Tools.run("/usr/bin/osascript", ["-e", "do shell script \"\(quoted)\" with administrator privileges"])
        } catch let error as Tools.Failure where error.message.contains("-128") {
            throw Tools.Failure(message: "AnyCast needs your password to keep your Mac awake with the lid closed. Keep the lid open, or try again.")
        } catch {
            Log.write("admin script failed: \(error.localizedDescription)")
            throw Tools.Failure(message: "AnyCast couldn't change the sleep setting: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private nonisolated static func pmset(disable: Bool) async -> Bool {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disable ? "1" : "0"]
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
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
