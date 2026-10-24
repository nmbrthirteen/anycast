import AppKit
import CoreGraphics

enum Permissions {
    enum State { case allowed, denied, notAsked, unavailable, checking }

    static var screenRecording: State { CGPreflightScreenCaptureAccess() ? .allowed : .notAsked }

    // AEDeterminePermissionToAutomateTarget can block for a long time on a busy browser, so it never runs on the main thread.
    static func automationAsync(bundleID: String) async -> State {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            DispatchQueue.global().async { once.resume(automation(bundleID: bundleID)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.resume(.notAsked) }
        }
    }

    private final class Once: @unchecked Sendable {
        private var continuation: CheckedContinuation<State, Never>?
        private let lock = NSLock()
        init(_ continuation: CheckedContinuation<State, Never>) { self.continuation = continuation }
        func resume(_ state: State) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: state)
        }
    }

    private static func automation(bundleID: String) -> State {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else { return .unavailable }
        var target = AEAddressDesc()
        let id = Array(bundleID.utf8)
        AECreateDesc(typeApplicationBundleID, id, id.count, &target)
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false) {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notAsked
        }
    }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() { openScreenRecordingSettings() }
    }

    static func openScreenRecordingSettings() { open("Privacy_ScreenCapture") }
    static func openAutomationSettings() { open("Privacy_Automation") }
    static func openLocalNetworkSettings() { open("Privacy_LocalNetwork") }

    private static func open(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}
