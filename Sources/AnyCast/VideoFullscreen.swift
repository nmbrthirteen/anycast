import AppKit
import ScreenCaptureKit

// Moving a window off its full screen desktop also ends the page's video full screen, and pages only re-enter it from a real click or key.
// Most web players (YouTube, Vimeo, Plyr, video.js, Chrome's own controls) treat a double-click on the video as full screen, many also use F.
enum VideoFullscreen {
    private static let gridWidth = 160, gridHeight = 90

    static func restore(on displayID: CGDirectDisplayID) async {
        let screen = CGDisplayBounds(displayID)
        guard let video = await movingRegion(on: displayID, in: screen) else {
            return Log.write("video full screen: no playing video found")
        }
        Log.write("video full screen: video at \(video) on \(screen)")
        if fillsScreen(video, screen) { return Log.write("video full screen: already full screen") }

        doubleClick(at: CGPoint(x: video.midX, y: video.midY))
        if await isFullScreen(on: displayID, in: screen) { return Log.write("video full screen: restored with double-click") }
        pressF()
        let done = await isFullScreen(on: displayID, in: screen)
        Log.write("video full screen: \(done ? "restored with F" : "page didn't respond")")
    }

    private static func isFullScreen(on displayID: CGDirectDisplayID, in screen: CGRect) async -> Bool {
        try? await Task.sleep(for: .milliseconds(1200))
        let region = await movingRegion(on: displayID, in: screen)
        Log.write("video full screen: now \(region.map { "\($0)" } ?? "nothing moving")")
        return region.map { fillsScreen($0, screen) } ?? false
    }

    private static func fillsScreen(_ video: CGRect, _ screen: CGRect) -> Bool {
        video.width >= screen.width * 0.9 || video.height >= screen.height * 0.9
    }

    // Diffs a few small screenshots and returns the bounds of the largest area that keeps changing.
    private static func movingRegion(on displayID: CGDirectDisplayID, in screen: CGRect) async -> CGRect? {
        guard let filter = try? await ScreenMirror.filter(for: MirrorTarget(kind: .display(displayID), title: "")) else { return nil }
        let config = SCStreamConfiguration()
        config.width = gridWidth
        config.height = gridHeight
        config.showsCursor = false
        var changed = [Bool](repeating: false, count: gridWidth * gridHeight)
        var previous: [UInt8]?
        for attempt in 0..<12 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(250)) }
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
                  let pixels = gray(image) else { continue }
            if let previous {
                for i in pixels.indices where abs(Int(pixels[i]) - Int(previous[i])) > 10 { changed[i] = true }
            }
            previous = pixels
            if attempt >= 3, let box = largestRegion(dilate(changed)), box.width * box.height > gridWidth * gridHeight / 25 {
                let scaleX = screen.width / CGFloat(gridWidth), scaleY = screen.height / CGFloat(gridHeight)
                return CGRect(x: screen.minX + CGFloat(box.minX) * scaleX, y: screen.minY + CGFloat(box.minY) * scaleY,
                              width: CGFloat(box.width) * scaleX, height: CGFloat(box.height) * scaleY)
            }
        }
        return nil
    }

    private static func gray(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        guard let context = CGContext(data: &pixels, width: gridWidth, height: gridHeight, bitsPerComponent: 8, bytesPerRow: gridWidth,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight))
        return pixels
    }

    private static func dilate(_ mask: [Bool]) -> [Bool] {
        var result = mask
        for y in 0..<gridHeight {
            for x in 0..<gridWidth where mask[y * gridWidth + x] {
                for dy in -2...2 {
                    for dx in -2...2 {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0, ny >= 0, nx < gridWidth, ny < gridHeight { result[ny * gridWidth + nx] = true }
                    }
                }
            }
        }
        return result
    }

    private struct Box { var minX, minY, maxX, maxY: Int; var width: Int { maxX - minX + 1 }; var height: Int { maxY - minY + 1 } }

    private static func largestRegion(_ mask: [Bool]) -> Box? {
        var seen = [Bool](repeating: false, count: mask.count)
        var best: (count: Int, box: Box)?
        for start in mask.indices where mask[start] && !seen[start] {
            var stack = [start], count = 0
            var box = Box(minX: .max, minY: .max, maxX: 0, maxY: 0)
            seen[start] = true
            while let i = stack.popLast() {
                count += 1
                let x = i % gridWidth, y = i / gridWidth
                box = Box(minX: min(box.minX, x), minY: min(box.minY, y), maxX: max(box.maxX, x), maxY: max(box.maxY, y))
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < gridWidth && ny < gridHeight {
                    let n = ny * gridWidth + nx
                    if mask[n] && !seen[n] { seen[n] = true; stack.append(n) }
                }
            }
            if count > best?.count ?? 0 { best = (count, box) }
        }
        return best?.box
    }

    private static func doubleClick(at point: CGPoint) {
        let original = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(100_000)
        for click in 1...2 {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                event?.post(tap: .cghidEventTap)
            }
            usleep(60_000)
        }
        if let original { CGWarpMouseCursorPosition(original) }
    }

    private static func pressF() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] { CGEvent(keyboardEventSource: source, virtualKey: 3, keyDown: down)?.post(tap: .cghidEventTap) }
    }
}
