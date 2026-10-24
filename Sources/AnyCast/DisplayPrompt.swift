import AppKit
import ApplicationServices

// macOS 27 keeps every new display dark until "Extended Display" is picked from Control Center's Screen Mirroring menu.
enum DisplayPrompt {
    static func chooseExtended(for displayID: CGDirectDisplayID) async -> Bool {
        guard AXIsProcessTrusted(), let menuItem = screenMirroringMenuItem() else { return false }
        AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
        let deviceID = "screen-mirroring-device-Display:\(displayID)"
        guard let chooseContent = await waitFor({ controlCenterElements().first { AX.string($0, kAXRoleAttribute) == kAXButtonRole && AX.string($0, kAXIdentifierAttribute) == deviceID } }) else {
            Log.write("display prompt: no Choose Content button")
            return false
        }
        AXUIElementPerformAction(chooseContent, kAXPressAction as CFString)
        // Buttons are Entire Screen, Window or App, Extended Display, Cancel, Start. Matched by position so other languages work.
        guard let buttons = await waitFor({ pickerButtons().count == 5 ? pickerButtons() : nil }) else {
            Log.write("display prompt: picker didn't open")
            return false
        }
        AXUIElementPerformAction(buttons[2], kAXPressAction as CFString)
        try? await Task.sleep(for: .milliseconds(300))
        AXUIElementPerformAction(buttons[4], kAXPressAction as CFString)
        Log.write("display prompt: chose extended display")
        return true
    }

    private static func pickerButtons() -> [AXUIElement] {
        helperPIDs().flatMap { AX.children(AXUIElementCreateApplication($0), kAXWindowsAttribute) }
            .map { AX.descendants($0, depth: 3).filter { AX.string($0, kAXRoleAttribute) == kAXButtonRole } }
            .first { $0.count == 5 } ?? []
    }

    private static func helperPIDs() -> [pid_t] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return Array(Set(windows.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t })).filter { pid in
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            return proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path).hasSuffix("/ControlCenterHelper")
        }
    }

    private static func screenMirroringMenuItem() -> AXUIElement? {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first,
              let bar = AX.element(AXUIElementCreateApplication(agent.processIdentifier), kAXExtrasMenuBarAttribute) else { return nil }
        return AX.descendants(bar, depth: 2).first { AX.string($0, kAXIdentifierAttribute) == "com.apple.menuextra.screen-mirroring" }
    }

    private static func controlCenterElements() -> [AXUIElement] {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first?.processIdentifier else { return [] }
        return AX.children(AXUIElementCreateApplication(pid), kAXWindowsAttribute).flatMap { AX.descendants($0, depth: 8) }
    }

    private static func waitFor<T>(_ find: () -> T?) async -> T? {
        for _ in 0..<20 {
            if let found = find() { return found }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }
}

enum AX {
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func children(_ element: AXUIElement, _ attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    static func descendants(_ element: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        return children(element).flatMap { [$0] + descendants($0, depth: depth - 1) }
    }
}
