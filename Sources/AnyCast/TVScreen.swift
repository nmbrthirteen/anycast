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
        keepExtended()
        return display.displayID
    }

    // If someone picks "Entire Screen" in the macOS prompt, the TV screen becomes a mirror and the Mac rescales to 1080p. Undo that.
    private func keepExtended() {
        extendTask?.cancel()
        extendTask = Task { [weak self] in
            while !Task.isCancelled, let id = self?.displayID {
                if CGDisplayIsInMirrorSet(id) != 0 {
                    var config: CGDisplayConfigRef?
                    CGBeginDisplayConfiguration(&config)
                    CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
                    CGCompleteDisplayConfiguration(config, .forSession)
                    Log.write("tv screen was mirrored, switched back to extended")
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var extendTask: Task<Void, Never>?

    func turnOff() {
        extendTask?.cancel()
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

    // Full screen windows can't be moved, so they leave full screen, move, then go full screen again on the TV screen.
    static func moveFrontWindow(of pid: pid_t, to bounds: CGRect) async -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let window = frontWindow(of: app) else {
            Log.write("move: no window found for pid \(pid)")
            return false
        }
        let wasFullScreen = bool(window, "AXFullScreen")
        if wasFullScreen {
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
            try? await Task.sleep(for: .milliseconds(900))
        }
        if bool(window, kAXMinimizedAttribute) {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            try? await Task.sleep(for: .milliseconds(400))
        }
        var origin = CGPoint(x: bounds.minX + 40, y: bounds.minY + 40)
        var size = CGSize(width: bounds.width - 80, height: bounds.height - 80)
        guard let position = AXValueCreate(.cgPoint, &origin), let dimensions = AXValueCreate(.cgSize, &size) else { return false }
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        let resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        try? await Task.sleep(for: .milliseconds(300))
        let landed = framePosition(window).map { bounds.insetBy(dx: -8, dy: -8).contains($0) } ?? false
        Log.write("move: fullscreen=\(wasFullScreen) move=\(moved.rawValue) resize=\(resized.rawValue) landed=\(landed)")
        guard landed else { return false }
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
        return true
    }

    private static func frontWindow(of app: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success, let value {
                return (value as! AXUIElement)
            }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.max { area($0) < area($1) }
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    private static func framePosition(_ element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        var point = CGPoint.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func area(_ element: AXUIElement) -> CGFloat {
        var value: CFTypeRef?
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let value, AXValueGetValue(value as! AXValue, .cgSize, &size) else { return 0 }
        return size.width * size.height
    }
}
