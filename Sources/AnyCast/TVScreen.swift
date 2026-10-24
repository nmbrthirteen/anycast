import AppKit
import ApplicationServices
import VirtualDisplayKit

@MainActor
final class TVScreen {
    private var display: AnyCastVirtualDisplay?
    var displayID: CGDirectDisplayID? { display?.displayID }
    var isOn: Bool { display != nil }

    // A fixed identity keeps macOS from piling up a new color profile and arrangement for every session.
    func turnOn() async throws -> CGDirectDisplayID {
        if let id = displayID { return id }
        let display = try AnyCastVirtualDisplay(name: "AnyCast TV", width: 1920, height: 1080, refreshRate: 60, productID: 0x7A01)
        self.display = display
        for _ in 0..<30 where !Self.isOnline(display.displayID) {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard Self.isOnline(display.displayID) else {
            turnOff()
            throw Tools.Failure(message: "macOS didn't switch on the TV screen. Try again, or restart your Mac if it keeps happening.")
        }
        Log.write("tv screen on as display \(display.displayID)")
        return display.displayID
    }

    func turnOff() {
        display?.destroy()
        display = nil
    }

    var bounds: CGRect? { displayID.map(CGDisplayBounds) }

    private static func isOnline(_ id: CGDirectDisplayID) -> Bool {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).contains(id)
    }
}

enum WindowMover {
    static var isAllowed: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    // Accessibility moves the app's front window onto the TV screen and sizes it to fill it.
    static func moveFrontWindow(of pid: pid_t, to bounds: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let window: AXUIElement
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success, let focused = value {
            window = focused as! AXUIElement
        } else if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement], let first = windows.first {
            window = first
        } else {
            return false
        }
        var origin = bounds.origin
        var size = bounds.size
        guard let position = AXValueCreate(.cgPoint, &origin), let dimensions = AXValueCreate(.cgSize, &size) else { return false }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success
    }
}
