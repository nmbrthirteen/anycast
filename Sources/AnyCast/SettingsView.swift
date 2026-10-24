import ServiceManagement
import SwiftUI

struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general = "General", quality = "Quality", mirroring = "Mirroring", power = "Power", permissions = "Permissions", about = "About"
        var id: String { rawValue }
    }

    @AppStorage("settingsSection") private var section = Section.general

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560)
            .padding(.top, 16)
            .padding(.bottom, 4)

            Group {
                switch section {
                case .general: GeneralSettings()
                case .quality: QualitySettings()
                case .mirroring: MirroringSettings()
                case .power: PowerSettings()
                case .permissions: PermissionSettings()
                case .about: AboutSettings()
                }
            }
            .frame(maxWidth: 640, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("Settings")
    }
}

private struct GeneralSettings: View {
    @AppStorage(Pref.showMenuBar) private var showMenuBar = true
    @AppStorage(Pref.pauseBrowser) private var pauseBrowser = true
    @AppStorage(Pref.resumePosition) private var resumePosition = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Show in menu bar", isOn: $showMenuBar)
                Button("Show welcome guide") { UserDefaults.standard.set(false, forKey: "onboarded") }
            }
            Section {
                Toggle("Pause the video in the browser when casting", isOn: $pauseBrowser)
                Toggle("Start on the TV where you left off", isOn: $resumePosition)
                    .disabled(!pauseBrowser)
            } header: {
                Text("Browser videos")
            } footer: {
                Text("Reading the play position needs \"Allow JavaScript from Apple Events\" in your browser's developer menu. Casting works without it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("1. Open", value: "chrome://extensions")
                LabeledContent("2. Turn on", value: "Developer mode")
                LabeledContent("3. Click", value: "Load unpacked, then pick the folder")
                Button("Show extension folder", action: Extension.revealFolder)
            } header: {
                Text("Browser extension")
            } footer: {
                Text("Works in Chrome and Helium. Click its icon on any tab to send that tab's video and sound to the TV. It keeps playing when you switch desktops.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Allow moving windows to the TV screen", action: WindowMover.requestPermission)
                    .disabled(WindowMover.isAllowed)
            } header: {
                Text("TV screen")
            } footer: {
                Text("Lets Send to TV move the playing window onto the TV screen for you. Uses Accessibility permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keyboard") {
                LabeledContent("Play or pause", value: "Space")
                LabeledContent("Cast front browser tab", value: "Menu bar icon")
            }
        }
        .formStyle(.grouped)
    }
}

private struct QualitySettings: View {
    @EnvironmentObject private var controller: CastController
    @AppStorage(Pref.maxHeight) private var maxHeight = 1080
    @AppStorage(Pref.playsHEVC) private var playsHEVC = false

    var body: some View {
        Form {
            Section {
                Picker("Highest resolution", selection: $maxHeight) {
                    Text("720p").tag(720)
                    Text("1080p").tag(1080)
                    Text("4K").tag(2160)
                    Text("No limit").tag(0)
                }
                .pickerStyle(.segmented)
                Toggle("TV can play HEVC (H.265)", isOn: $playsHEVC)
            } footer: {
                Text("AnyCast always sends the original stream when your TV supports it. Anything it can't play is converted to H.264 at 20 Mbps or more, and the sound to AAC at 320 kbps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let tv = controller.renderer {
                Section("Your TV") {
                    LabeledContent("Name", value: tv.name)
                    LabeledContent("Model", value: tv.model.isEmpty ? "Unknown" : tv.model)
                    LabeledContent("Address", value: tv.host)
                    LabeledContent("Tested", value: "1080p at 60 fps, H.264, AAC")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct MirroringSettings: View {
    @AppStorage(Pref.mirrorFPS) private var fps = 30
    @AppStorage(Pref.mirrorBitrate) private var bitrate = 12
    @AppStorage(Pref.mirrorCursor) private var cursor = true
    @AppStorage(Pref.mirrorAudio) private var audio = true
    @AppStorage(Pref.muteMac) private var muteMac = true
    @AppStorage(Pref.lowLatency) private var lowLatency = true

    var body: some View {
        Form {
            Section {
                Toggle("Low delay", isOn: $lowLatency)
            } footer: {
                Text("Your TV holds about 6 seconds of video before it plays. Low delay briefly speeds up the start so the TV catches up to about 4 seconds, the lowest it can hold without stuttering.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Frame rate", selection: $fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)
                LabeledContent("Bitrate") {
                    HStack {
                        Slider(value: Binding(get: { Double(bitrate) }, set: { bitrate = Int($0) }), in: 4...40, step: 2)
                        Text("\(bitrate) Mbps").monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
            } footer: {
                Text("Higher bitrate looks sharper but needs a strong Wi-Fi signal at the TV. Lower it if the picture stutters.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Send sound to the TV", isOn: $audio)
                Toggle("Mute this Mac while mirroring", isOn: $muteMac).disabled(!audio)
                Toggle("Show the mouse pointer", isOn: $cursor)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PowerSettings: View {
    @AppStorage(Pref.lidClosed) private var lidClosed = false

    var body: some View {
        Form {
            Section {
                Toggle("Keep casting with the lid closed", isOn: $lidClosed)
            } footer: {
                Text("Asks for your password once, the first time. Normal sleep comes back when casting stops or AnyCast quits. Keep your Mac plugged in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("How sleep works") {
                LabeledContent("Direct from web", value: "Mac can sleep")
                LabeledContent("Files and relayed videos", value: "Mac stays awake")
                LabeledContent("Mirroring", value: "Needs the lid open")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionSettings: View {
    @EnvironmentObject private var controller: CastController
    @State private var refresh = 0
    @State private var automation: [String: Permissions.State] = [:]

    var body: some View {
        Form {
            Section {
                PermissionRow(title: "Local network", detail: "Finds your TV and streams to it",
                              state: controller.scanning ? .checking : controller.renderers.isEmpty ? .notAsked : .allowed,
                              action: Permissions.openLocalNetworkSettings)
                PermissionRow(title: "Screen recording", detail: "Window previews and mirroring",
                              state: Permissions.screenRecording,
                              action: Permissions.requestScreenRecording)
                ForEach(controller.browsers) { browser in
                    PermissionRow(title: browser.name, detail: "Reads tabs and pauses the video",
                                  state: automation[browser.name] ?? .checking,
                                  action: Permissions.openAutomationSettings)
                }
            } footer: {
                Text("macOS remembers these choices. You only answer each one once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .id(refresh)
        .task(id: refresh) {
            for browser in controller.browsers {
                automation[browser.name] = await Permissions.automationAsync(bundleID: BrowserWatcher.bundleID(forName: browser.name) ?? "")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh += 1 }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let state: Permissions.State
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .allowed:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .unavailable:
                Text("Not running").foregroundStyle(.secondary)
            case .checking:
                ProgressView().controlSize(.small)
            case .denied, .notAsked:
                Button(state == .denied ? "Open settings" : "Allow", action: action).buttonStyle(.glass)
            }
        }
    }
}

private struct AboutSettings: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AnyCast").font(.title2.weight(.semibold))
                        Text("Version \(version)").foregroundStyle(.secondary)
                        Text("Plays web videos, files, and your screen on any DLNA TV, at the best quality the TV supports.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            UpdateSection()
            Section("Helpers") {
                LabeledContent("ffmpeg", value: Tools.ffmpeg == nil ? "Missing: brew install ffmpeg" : "Installed")
                LabeledContent("yt-dlp", value: Tools.ytdlp == nil ? "Missing: brew install yt-dlp" : "Installed")
            }
            Section {
                Button("Show log") {
                    NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AnyCast.log")])
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdateSection: View {
    @EnvironmentObject private var updater: Updater

    private var status: String {
        switch updater.state {
        case .idle: "Checks at launch and every 6 hours"
        case .checking: "Checking"
        case .upToDate: "You have the latest version"
        case .downloading(let version): "Downloading \(version)"
        case .ready(let version): "Version \(version) is ready"
        case .failed(let message): message
        }
    }

    var body: some View {
        Section("Updates") {
            Toggle("Install updates automatically", isOn: $updater.autoUpdate)
            LabeledContent("Status") {
                HStack {
                    Text(status).foregroundStyle(.secondary).lineLimit(2)
                    if case .ready = updater.state {
                        Button("Restart to update", action: updater.install).buttonStyle(.glassProminent)
                    } else {
                        Button("Check now") { Task { await updater.check(installAutomatically: false) } }
                            .disabled(updater.state == .checking)
                    }
                }
            }
        }
    }
}
