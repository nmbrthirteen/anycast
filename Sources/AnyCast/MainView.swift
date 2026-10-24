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
    @AppStorage(Pref.sidebar) private var selection: SidebarItem = .link
    @AppStorage(Pref.onboarded) private var onboarded = false
    @State private var dropTargeted = false

    var body: some View {
        TabView(selection: $selection) {
            TabSection("Browsers") {
                ForEach(controller.browsers) { browser in
                    Tab(value: SidebarItem.browser(browser.name)) {
                        page { TabsView(browser: browser) }
                    } label: {
                        Label { Text(browser.name) } icon: { Image(nsImage: browser.icon) }
                    }
                    .badge(browser.tabs.count)
                }
            }
            TabSection("More ways to cast") {
                Tab("Video link", systemImage: "link", value: SidebarItem.link) { page { LinkView() } }
                Tab("Files", systemImage: "folder", value: SidebarItem.files) { page { FilesView() } }
                Tab("Mirror", systemImage: "rectangle.on.rectangle", value: SidebarItem.mirror) { page { MirrorView() } }
            }
            TabSection("AnyCast") {
                Tab("Settings", systemImage: "gearshape", value: SidebarItem.settings) { page { SettingsView() } }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
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
        .onAppear(perform: controller.refreshTabs)
        .onChange(of: controller.browsers.map(\.name)) { _, names in
            if case .browser(let name) = selection, !names.contains(name) { selection = names.first.map(SidebarItem.browser) ?? .link }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controller.refreshTabs() }
    }

    private func page(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { StatusBanner() }
            .safeAreaInset(edge: .bottom) { NowPlayingBar() }
    }
}

struct MainToolbar: ToolbarContent {
    @EnvironmentObject private var controller: CastController
    @Binding var selection: SidebarItem

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
