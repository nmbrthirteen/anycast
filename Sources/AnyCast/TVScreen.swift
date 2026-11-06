import AppKit
import ApplicationServices
import VirtualDisplayKit

@MainActor
final class TVScreen {
    private var display: AnyCastVirtualDisplay?
    var displayID: CGDirectDisplayID? { display?.displayID }

    // A fixed identity keeps macOS from piling up a new color profile and arrangement for every session.
    func turnOn() async throws -> CGDirectDisplayID {
        if let id = displayID { return id }
        homeFrames = Self.visibleWindows()
        turnedOnAt = Date()
        let display = try AnyCastVirtualDisplay(name: "AnyCast TV", width: 1920, height: 1080, refreshRate: 60, productID: 0x7A01)
        self.display = display
        for attempt in 0..<120 where !Self.isOnline(display.displayID) {
            if attempt == 10 { _ = await DisplayPrompt.chooseExtended(for: display.displayID) }
            do { try await Task.sleep(for: .milliseconds(100)) } catch {
                turnOff()
                throw error
            }
        }
        guard Self.isOnline(display.displayID) else {
            turnOff()
            throw Tools.Failure(message: "macOS didn't switch on the TV screen. Try again, or restart your Mac if it keeps happening.")
        }
        Log.write("tv screen on as display \(display.displayID)")
        Self.unmirror(display.displayID)
        keepExtended()
        // A new screen first appears in a default spot and macOS then moves it, so windows sent too early miss it.
        var placed = CGDisplayBounds(display.displayID)
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(200))
            let now = CGDisplayBounds(display.displayID)
            if now == placed { break }
            placed = now
        }
        return display.displayID
    }

    // If someone picks "Entire Screen" in the macOS prompt, the TV screen becomes a mirror and the Mac rescales to 1080p. Undo that.
    private func keepExtended() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let id = self?.displayID { Self.unmirror(id) }
            }
        }
    }

    private var screenObserver: NSObjectProtocol?

    private static func unmirror(_ id: CGDirectDisplayID) {
        guard CGDisplayIsInMirrorSet(id) != 0 else { return }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
        CGCompleteDisplayConfiguration(config, .forSession)
        Log.write("tv screen was mirrored, switched back to extended")
    }

    // Adding a screen, and macOS briefly mirroring it, can shuffle other windows onto it. Where every window was just before
    // the TV screen came on is kept for a short while, so windows that land on it by accident can be put back.
    private var homeFrames: [CGWindowID: (pid: pid_t, frame: CGRect)] = [:]
    private var turnedOnAt = Date.distantPast

    func strayWindows() -> [(pid: pid_t, frame: CGRect, home: CGRect)] {
        guard let bounds, Date().timeIntervalSince(turnedOnAt) < 20 else { return [] }
        let tv = { (frame: CGRect) in bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        return Self.visibleWindows().compactMap { id, now in
            guard tv(now.frame), let home = homeFrames[id], !tv(home.frame) else { return nil }
            return (now.pid, now.frame, home.frame)
        }
    }

    private static func visibleWindows() -> [CGWindowID: (pid: pid_t, frame: CGRect)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var windows: [CGWindowID: (pid: pid_t, frame: CGRect)] = [:]
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID, let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let frame = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  frame.height > 50 else { continue }
            windows[id] = (pid, frame)
        }
        return windows
    }

    func turnOff() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        display?.destroy()
        display = nil
    }

    var bounds: CGRect? { displayID.map(CGDisplayBounds) }
    var isOnline: Bool { displayID.map(Self.isOnline) ?? false }

    private static func isOnline(_ id: CGDirectDisplayID) -> Bool {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).contains(id)
    }
}

struct SentWindow {
    let pid: pid_t
    let element: AXUIElement
    let fullScreen: Bool
}

enum WindowMover {
    static var isAllowed: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    // Full screen windows can't be moved, and macOS puts a window back where it was when full screen ends,
    // so every step waits until macOS reports it finished before the next one starts.
    static func frontWindow(of pid: pid_t) -> AXUIElement? {
        let window = frontWindow(of: AXUIElementCreateApplication(pid))
        if window == nil { Log.write("move: no window found for pid \(pid)") }
        return window
    }

    static func move(_ window: AXUIElement, of pid: pid_t, to bounds: CGRect) async -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activate()
        if AX.bool(window, "AXFullScreen") {
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
            guard await waitUntil({ !AX.bool(window, "AXFullScreen") }) else {
                Log.write("move: window stayed full screen")
                return false
            }
            try? await Task.sleep(for: .milliseconds(800))
        }
        if AX.bool(window, kAXMinimizedAttribute) {
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
            Log.write("move: attempt \(attempt) landed=\(landed) at \(AX.point(window).map { "\($0)" } ?? "?")")
        }
        guard landed else { return false }

        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
        _ = await waitUntil({ AX.bool(window, "AXFullScreen") })
        try? await Task.sleep(for: .milliseconds(800))
        let stayed = isInside(window, bounds)
        Log.write("move: full screen on tv=\(stayed)")
        if !stayed {
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
            _ = await waitUntil({ !AX.bool(window, "AXFullScreen") })
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
        AX.point(window).map { bounds.insetBy(dx: -8, dy: -8).contains($0) } ?? false
    }

    // Closing the lid makes macOS recreate the TV screen: the video's full screen desktop is lost and the laptop's
    // windows land on top. A window still showing full size on the TV is left alone so focus on the laptop isn't taken.
    // Returns true when the window had to be moved, which also ends a web page's own full screen.
    static func restore(_ sent: SentWindow, on bounds: CGRect) async -> Bool {
        guard AX.point(sent.element) != nil else { return false }
        let inPlace = isInside(sent.element, bounds) && isFullScreen(sent.element) == sent.fullScreen
        if inPlace && frontmostOwner(on: bounds) == sent.pid { return false }
        if inPlace {
            NSRunningApplication(processIdentifier: sent.pid)?.activate()
            AXUIElementPerformAction(sent.element, kAXRaiseAction as CFString)
            try? await Task.sleep(for: .seconds(1))
            if frontmostOwner(on: bounds) == sent.pid {
                Log.write("raised pid \(sent.pid) on the tv screen")
                return false
            }
        }
        let moved = await move(sent.element, of: sent.pid, to: bounds)
        Log.write("moved pid \(sent.pid) back onto the tv screen: \(moved)")
        return moved
    }

    static func sendHome(_ strays: [(pid: pid_t, frame: CGRect, home: CGRect)], except sent: SentWindow?) {
        for stray in strays where stray.pid != sent?.pid {
            let windows = AX.children(AXUIElementCreateApplication(stray.pid), kAXWindowsAttribute)
            guard let window = windows.first(where: { window in
                guard let point = AX.point(window), let size = AX.size(window) else { return false }
                return abs(point.x - stray.frame.minX) < 3 && abs(point.y - stray.frame.minY) < 3 && abs(size.width - stray.frame.width) < 3
            }), !isFullScreen(window) else { continue }
            var origin = stray.home.origin
            var size = stray.home.size
            if let position = AXValueCreate(.cgPoint, &origin), let dimensions = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
            }
            Log.write("put pid \(stray.pid)'s window back where it was, off the tv screen")
        }
    }

    static func isFullScreen(_ window: AXUIElement) -> Bool { AX.bool(window, "AXFullScreen") }

    private static func frontmostOwner(on bounds: CGRect) -> pid_t? {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.first { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let frame = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return false }
            return frame.contains(center)
        }?[kCGWindowOwnerPID as String] as? pid_t
    }

    private static func frontWindow(of app: AXUIElement) -> AXUIElement? {
        AX.element(app, kAXFocusedWindowAttribute) ?? AX.element(app, kAXMainWindowAttribute)
            ?? AX.children(app, kAXWindowsAttribute).max { area($0) < area($1) }
    }

    private static func area(_ element: AXUIElement) -> CGFloat {
        AX.size(element).map { $0.width * $0.height } ?? 0
    }
}
