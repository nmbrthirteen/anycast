import CoreGraphics
import IOKit

enum Lid {
    static var isClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (state as? Bool) ?? false
    }

    static var builtInDisplay: CGDirectDisplayID? {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}
