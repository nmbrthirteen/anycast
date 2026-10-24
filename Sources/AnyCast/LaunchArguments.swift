import Foundation

extension CastController {
    func handleLaunchArguments() {
        guard !handledLaunchArguments, renderer != nil else { return }
        handledLaunchArguments = true
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        if let target = value(after: "--cast") {
            target.hasPrefix("http") ? castLink(target) : castFile(URL(fileURLWithPath: target))
        } else if let name = value(after: "--send") {
            refreshPlaying()
            sendToTV(playingApps.first { $0.name == name })
        } else if args.contains("--tv-screen") {
            startTVScreen()
        } else if args.contains("--cast-tab") {
            castCurrentTab()
        } else if args.contains("--mirror") {
            refreshPlaying()
            if playingApps.isEmpty {
                Task { if let screen = try? await ScreenMirror.targets().first { startMirror(screen) } }
            } else {
                sendToTV(nil)
            }
        }
    }
}
