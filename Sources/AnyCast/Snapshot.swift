import AppKit
import ScreenCaptureKit

enum Snapshot {
    static func captureOwnWindows(to directory: String) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let pid = ProcessInfo.processInfo.processIdentifier
            let own = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.height > 100 }
            Log.write("snapshot windows \(own.map { "\($0.windowID) \($0.frame) onscreen=\($0.isOnScreen)" }) of \(content.windows.count)")
            for (index, window) in own.enumerated() {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width * 2)
                config.height = Int(window.frame.height * 2)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(directory)/window-\(index).png"))
            }
            Log.write("snapshot saved to \(directory)")
        } catch {
            Log.write("snapshot failed: \(error.localizedDescription)")
        }
    }
}
