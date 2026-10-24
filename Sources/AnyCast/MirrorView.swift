import SwiftUI

struct MirrorView: View {
    @EnvironmentObject private var controller: CastController
    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 18)]

    var body: some View {
        Group {
            if ScreenMirror.hasPermission {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        TVScreenCard()
                        NowPlayingCard()
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(sortedTargets) { target in
                                MirrorCard(target: target, thumbnail: controller.thumbnails[target.id],
                                           isPlaying: controller.playingApps.contains { $0.pid == target.pid })
                            }
                        }
                    }
                    .padding(24)
                }
            } else {
                ContentUnavailableView {
                    Label("Pick what to mirror", systemImage: "rectangle.on.rectangle")
                } description: {
                    Text("Use the macOS picker to choose a window or screen. It needs no extra permission. Allow Screen Recording to see live previews of every window here.")
                } actions: {
                    Button("Choose window or screen", action: controller.startMirrorWithPicker).buttonStyle(.glassProminent)
                    Button("Allow previews") { Permissions.openScreenRecordingSettings() }.buttonStyle(.glass)
                }
            }
        }
        .navigationTitle("Mirror")
        .navigationSubtitle("Sound is included, at up to 1080p.")
        .toolbar {
            ToolbarItem {
                Button("macOS picker", systemImage: "macwindow.on.rectangle", action: controller.startMirrorWithPicker)
                    .help("Choose with the macOS picker")
            }
        }
        .onAppear(perform: controller.loadMirrorTargets)
        .task {
            while !Task.isCancelled {
                controller.refreshPlaying()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

extension MirrorView {
    private var sortedTargets: [MirrorTarget] {
        let playing = Set(controller.playingApps.map(\.pid))
        return controller.mirrorTargets.enumerated()
            .sorted { (playing.contains($0.element.pid) ? 0 : 1, $0.offset) < (playing.contains($1.element.pid) ? 0 : 1, $1.offset) }
            .map(\.element)
    }
}

struct TVScreenCard: View {
    @EnvironmentObject private var controller: CastController

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: controller.tvScreenOn ? "tv.inset.filled" : "tv")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("TV screen").font(.headline)
                Text(controller.tvScreenOn
                     ? "On, to the right of your display. Anything you move there shows on the TV, on any desktop."
                     : "A second screen that shows on your TV. Windows on it keep playing when you switch desktops.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if controller.tvScreenOn {
                Button("Turn off", action: controller.stop).buttonStyle(.glass).controlSize(.large)
            } else {
                Button("Turn on", systemImage: "rectangle.portrait.and.arrow.right", action: controller.startTVScreen)
                    .buttonStyle(.glassProminent).controlSize(.large)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

struct NowPlayingCard: View {
    @EnvironmentObject private var controller: CastController

    var body: some View {
        HStack(spacing: 14) {
            if let app = controller.playingApps.first,
               let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
                Image(nsImage: icon).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.playingApps.count > 1
                         ? controller.playingApps.map(\.name).joined(separator: " and ") + " are playing"
                         : "\(app.name) is playing").font(.headline)
                    Text("Moves its window onto the TV screen so it keeps playing on any desktop.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "speaker.slash").font(.title2).foregroundStyle(.secondary).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nothing is playing").font(.headline)
                    Text("Start a video and it shows up here.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if controller.playingApps.count > 1 {
                Menu {
                    ForEach(controller.playingApps, id: \.pid) { app in
                        Button(app.name) { controller.sendToTV(app) }
                    }
                } label: {
                    Label("Send to TV", systemImage: "play.rectangle.on.rectangle.fill")
                }
                .menuStyle(.button)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .fixedSize()
            } else {
                Button("Send to TV", systemImage: "play.rectangle.on.rectangle.fill", action: { controller.sendToTV(nil) })
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(controller.playingApps.isEmpty)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

struct MirrorCard: View {
    @EnvironmentObject private var controller: CastController
    let target: MirrorTarget
    let thumbnail: NSImage?
    let isPlaying: Bool
    @State private var hovering = false

    var body: some View {
        Button { controller.startMirror(target) } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit().clipShape(.rect(cornerRadius: 10))
                    } else {
                        Image(systemName: isScreen ? "display" : "macwindow").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if isPlaying {
                        Label("Playing", systemImage: "speaker.wave.2.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .glassEffect(.regular.tint(.green.opacity(0.4)), in: .capsule)
                            .padding(8)
                    }
                }
                Label(target.title, systemImage: isScreen ? "display" : "macwindow")
                    .lineLimit(1)
                    .font(.callout)
            }
            .padding(10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive().tint(hovering ? .accentColor.opacity(0.2) : nil), in: .rect(cornerRadius: 18))
        .onHover { hovering = $0 }
    }

    private var isScreen: Bool { if case .display = target.kind { true } else { false } }
}
