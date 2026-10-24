import SwiftUI

@main
struct AnyCastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = CastController()
    @StateObject private var updater = Updater()
    @AppStorage(Pref.showMenuBar) private var showMenuBar = true

    var body: some Scene {
        Window("AnyCast", id: "main") {
            MainView()
                .environmentObject(controller)
                .environmentObject(updater)
                .task {
                    updater.canInstallNow = { [weak controller] in controller?.plan == nil }
                    updater.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in controller.shutdown() }
        }
        .defaultSize(width: 920, height: 620)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appSettings) { OpenSettingsButton().keyboardShortcut(",") }
        }

        MenuBarExtra("AnyCast", systemImage: controller.plan == nil ? "tv" : "tv.inset.filled", isInserted: $showMenuBar) {
            MenuBarContent().environmentObject(controller).environmentObject(updater)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        Log.rotate()
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--probe"), index + 2 < args.count {
            let (app, directory) = (args[index + 1], args[index + 2])
            Task { await Snapshot.probeWindows(of: app, to: directory) }
        }
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            let directory = args[index + 1]
            Task {
                try? await Task.sleep(for: .seconds(UserDefaults.standard.double(forKey: Pref.snapshotDelay).nonZero ?? 5))
                await Snapshot.captureOwnWindows(to: directory)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuBarContent: View {
    @EnvironmentObject private var controller: CastController
    @EnvironmentObject private var updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Cast front browser tab", action: controller.castCurrentTab)
        Menu("Send playing video to TV") {
            ForEach(controller.playingApps, id: \.pid) { app in
                Button(app.name) { controller.sendToTV(app) }
            }
            if controller.playingApps.isEmpty { Text("Nothing is playing") }
        }
        .onAppear(perform: controller.refreshPlaying)
        Button(controller.tvScreenOn ? "Turn off TV screen" : "Turn on TV screen") {
            controller.tvScreenOn ? controller.stop() : controller.startTVScreen()
        }
        Button("Mirror a window", action: controller.startMirrorWithPicker)
        if controller.plan != nil {
            Divider()
            Button(controller.isPlaying ? "Pause" : "Play", action: controller.togglePause)
            Button("Stop casting", action: controller.stop)
        }
        Divider()
        Button("Open AnyCast") {
            openWindow(id: "main")
            NSApp.activate()
        }
        OpenSettingsButton()
        if case .ready(let version) = updater.state {
            Button("Restart to update to \(version)", action: updater.install)
        } else {
            Button("Check for updates") { Task { await updater.check(installAutomatically: false) } }
        }
        Divider()
        Button("Quit AnyCast") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct OpenSettingsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            UserDefaults.standard.set(SidebarItem.settings.rawValue, forKey: Pref.sidebar)
            openWindow(id: "main")
            NSApp.activate()
        }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
