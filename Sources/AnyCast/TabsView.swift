import SwiftUI

struct TabsView: View {
    @EnvironmentObject private var controller: CastController
    let browser: Browser

    private var windows: [(number: Int, tabs: [BrowserTab])] {
        Dictionary(grouping: browser.tabs, by: \.window).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        if browser.tabs.isEmpty {
            ContentUnavailableView {
                Label("No tabs to show", systemImage: "rectangle.stack")
            } description: {
                Text("Open a video in \(browser.name), or allow AnyCast to read its tabs in System Settings, Privacy & Security, Automation.")
            } actions: {
                Button("Refresh", action: controller.refreshTabs).buttonStyle(.glass)
            }
        } else {
            List {
                ForEach(windows, id: \.number) { window in
                    Section(windows.count > 1 ? "Window \(window.number)" : browser.tabs.count == 1 ? "1 tab" : "\(browser.tabs.count) tabs") {
                        ForEach(window.tabs) { tab in TabRow(tab: tab) }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .navigationTitle(browser.name)
            .navigationSubtitle("Double-click a tab to play its video on your TV")
        }
    }
}

struct TabRow: View {
    @EnvironmentObject private var controller: CastController
    let tab: BrowserTab
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Favicon(host: tab.url.host)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title).lineLimit(1)
                Text(tab.url.host?.replacingOccurrences(of: "www.", with: "") ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if tab.isActive {
                Text("Active")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.3)), in: .capsule)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .trailing) {
            if hovering {
                Button("Cast", systemImage: "play.tv.fill") { controller.cast(tab: tab) }
                    .buttonStyle(.glassProminent)
            }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { controller.cast(tab: tab) }
    }
}

struct Favicon: View {
    let host: String?

    var body: some View {
        AsyncImage(url: host.flatMap { URL(string: "https://\($0)/favicon.ico") }) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high)
            } else {
                Image(systemName: "globe").foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .padding(6)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
    }
}
