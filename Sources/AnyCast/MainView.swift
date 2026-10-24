import SwiftUI

enum SidebarItem: Hashable, RawRepresentable {
    case browser(String)
    case link
    case files
    case mirror
    case settings

    init?(rawValue: String) {
        switch rawValue {
        case "link": self = .link
        case "files": self = .files
        case "mirror": self = .mirror
        case "settings": self = .settings
        default:
            guard rawValue.hasPrefix("browser:") else { return nil }
            self = .browser(String(rawValue.dropFirst(8)))
        }
    }

    var rawValue: String {
        switch self {
        case .browser(let name): "browser:\(name)"
        case .link: "link"
        case .files: "files"
        case .mirror: "mirror"
        case .settings: "settings"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var controller: CastController
    @AppStorage("sidebar") private var selection: SidebarItem?
    @State private var dropTargeted = false
    @AppStorage("onboarded") private var onboarded = false

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { StatusBanner() }
                .safeAreaInset(edge: .bottom) { NowPlayingBar() }
        }
        .toolbar { MainToolbar(selection: $selection) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in controller.castFile(url) } }
            }
            return true
        }
        .overlay { if dropTargeted { DropOverlay() } }
        .frame(minWidth: 820, minHeight: 540)
        .sheet(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) {
            OnboardingView().environmentObject(controller).interactiveDismissDisabled()
        }
        .onAppear {
            controller.refreshTabs()
        }
        .onChange(of: controller.browsers.map(\.name)) { _, names in
            if selection == nil, let first = names.first { selection = .browser(first) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controller.refreshTabs() }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .browser(let name):
            if let browser = controller.browsers.first(where: { $0.name == name }) {
                TabsView(browser: browser)
            } else {
                ContentUnavailableView("\(name) is closed", systemImage: "safari", description: Text("Open it to see its tabs here."))
            }
        case .files: FilesView()
        case .mirror: MirrorView()
        case .settings: SettingsView()
        case .link, nil: LinkView()
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var controller: CastController
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("TV") { TVRow() }
            Section("Browsers") {
                ForEach(controller.browsers) { browser in
                    Label {
                        Text(browser.name)
                    } icon: {
                        Image(nsImage: browser.icon).resizable().frame(width: 18, height: 18)
                    }
                    .badge(browser.tabs.count)
                    .tag(SidebarItem.browser(browser.name))
                }
                if controller.browsers.isEmpty && !controller.loadingTabs {
                    Text("No browser open").foregroundStyle(.secondary)
                }
            }
            Section("More ways to cast") {
                Label("Video link", systemImage: "link").tag(SidebarItem.link)
                Label("Files", systemImage: "folder").tag(SidebarItem.files)
                Label("Mirror", systemImage: "rectangle.on.rectangle").tag(SidebarItem.mirror)
            }
            Section {
                Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
    }
}

struct MainToolbar: ToolbarContent {
    @EnvironmentObject private var controller: CastController
    @Binding var selection: SidebarItem?

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            TVMenu()
        }
        ToolbarItem {
            Button(action: controller.refreshTabs) { Label("Refresh tabs", systemImage: "arrow.clockwise") }
                .help("Refresh browser tabs")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button { selection = .settings } label: { Label("Settings", systemImage: "gearshape") }
                .help("Settings")
        }
    }
}

struct TVMenu: View {
    @EnvironmentObject private var controller: CastController

    var body: some View {
        Menu {
            if controller.renderers.isEmpty {
                Text(controller.scanning ? "Looking for TVs" : "No TV found")
            }
            Picker("TV", selection: Binding(get: { controller.renderer?.id }, set: { controller.selectedID = $0 })) {
                ForEach(controller.renderers) { tv in
                    Text(tv.name).tag(Optional(tv.id))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Scan again", systemImage: "antenna.radiowaves.left.and.right", action: controller.scan)
        } label: {
            Label {
                Text(controller.renderer?.name ?? (controller.scanning ? "Looking for TV" : "No TV"))
            } icon: {
                Image(systemName: controller.renderer == nil ? "tv.slash" : "tv")
                    .foregroundStyle(controller.renderer == nil ? Color.secondary : Color.green)
            }
            .labelStyle(.titleAndIcon)
        }
        .menuIndicator(.visible)
        .fixedSize()
    }
}

struct TVRow: View {
    @EnvironmentObject private var controller: CastController

    private var status: String {
        if let plan = controller.plan { return controller.isPlaying ? "Playing \(plan.title)" : "Paused" }
        if controller.renderer != nil { return "Ready" }
        return controller.scanning ? "Looking on your Wi-Fi" : "Not found"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.renderer == nil ? "tv.slash" : "tv")
                .foregroundStyle(controller.renderer == nil ? Color.secondary : Color.green)
                .frame(width: 30, height: 30)
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.renderer?.name ?? "No TV").fontWeight(.medium).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if controller.scanning { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 2)
        .contextMenu {
            ForEach(controller.renderers) { tv in
                Button(tv.name) { controller.selectedID = tv.id }
            }
            Button("Scan again", action: controller.scan)
        }
    }
}

struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(.clear)
            .glassEffect(.regular.tint(.accentColor.opacity(0.25)), in: .rect(cornerRadius: 24))
            .overlay {
                Label("Drop to cast", systemImage: "arrow.down.to.line")
                    .font(.title2.weight(.semibold))
            }
            .padding(24)
            .allowsHitTesting(false)
    }
}
