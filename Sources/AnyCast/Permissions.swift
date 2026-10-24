import AppKit
import CoreGraphics

enum Permissions {
    enum State { case allowed, denied, notAsked, unavailable, checking }

    static var screenRecording: State { CGPreflightScreenCaptureAccess() ? .allowed : .notAsked }

    static func automation(bundleID: String) -> State {
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
