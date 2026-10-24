import AppKit

enum Extension {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AnyCast/Extension")

    // Chrome loads unpacked extensions from a fixed folder, so the bundled copy is mirrored there on every launch.
    static func install() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("Extension"),
              FileManager.default.fileExists(atPath: bundled.path) else { return }
        try? FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.copyItem(at: bundled, to: folder)
    }

    static func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
