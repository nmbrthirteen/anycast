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

    // Full screen windows can't be moved, and macOS puts a window back where it was when full screen ends,
    // so every step waits until macOS reports it finished before the next one starts.
    static func moveFrontWindow(of pid: pid_t, to bounds: CGRect) async -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activate()
        let app = AXUIElementCreateApplication(pid)
        guard let window = frontWindow(of: app) else {
            Log.write("move: no window found for pid \(pid)")
            return false
        }
        if bool(window, "AXFullScreen") {
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
            guard await waitUntil({ !bool(window, "AXFullScreen") }) else {
                Log.write("move: window stayed full screen")
                return false
            }
            try? await Task.sleep(for: .milliseconds(800))
        }
        if bool(window, kAXMinimizedAttribute) {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            try? await Task.sleep(for: .milliseconds(500))
        }

        var landed = false
        for attempt in 1...4 where !landed {
            var origin = CGPoint(x: bounds.minX + 40, y: bounds.minY + 40)
            var size = CGSize(width: bounds.width - 80, height: bounds.height - 80)
            if let position = AXValueCreate(.cgPoint, &origin), let dimensions = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
            }
            try? await Task.sleep(for: .milliseconds(500))
            landed = isInside(window, bounds)
            Log.write("move: attempt \(attempt) landed=\(landed) at \(framePosition(window).map { "\($0)" } ?? "?")")
        }
        guard landed else { return false }

        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
        _ = await waitUntil({ bool(window, "AXFullScreen") })
        try? await Task.sleep(for: .milliseconds(800))
        let stayed = isInside(window, bounds)
        Log.write("move: full screen on tv=\(stayed)")
        if !stayed {
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
            _ = await waitUntil({ !bool(window, "AXFullScreen") })
            try? await Task.sleep(for: .milliseconds(800))
            var origin = CGPoint(x: bounds.minX, y: bounds.minY)
            var size = bounds.size
            if let position = AXValueCreate(.cgPoint, &origin), let dimensions = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
            }
            return isInside(window, bounds)
        }
        return true
    }

    private static func waitUntil(_ condition: () -> Bool, timeout: Double = 4) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return condition()
    }

    private static func isInside(_ window: AXUIElement, _ bounds: CGRect) -> Bool {
        framePosition(window).map { bounds.insetBy(dx: -8, dy: -8).contains($0) } ?? false
    }

    // Brings the app back on top. If its window left the TV screen (the lid closed and macOS rearranged things), it moves back.
    static func restore(_ pid: pid_t, on bounds: CGRect) async {
        NSRunningApplication(processIdentifier: pid)?.activate()
        let app = AXUIElementCreateApplication(pid)
        guard let window = frontWindow(of: app) else { return }
        let onTV = framePosition(window).map { bounds.insetBy(dx: -8, dy: -8).contains($0) } ?? false
        if onTV {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            if !bool(window, "AXFullScreen") { AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue) }
        } else {
            _ = await moveFrontWindow(of: pid, to: bounds)
        }
        Log.write("restored pid \(pid) on tv screen (was on tv: \(onTV))")
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
