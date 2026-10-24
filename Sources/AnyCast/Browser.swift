import AppKit

struct BrowserTab: Identifiable, Hashable {
    let browser: String
    let window: Int
    let index: Int
    let url: URL
    let title: String
    let isActive: Bool
    var id: String { "\(browser)-\(window)-\(index)-\(url.absoluteString)" }
}

struct Browser: Identifiable {
    let name: String
    let icon: NSImage
    var tabs: [BrowserTab]
    var id: String { name }
}

@MainActor
final class BrowserWatcher {
    private static let known: [(bundleID: String, name: String)] = [
        ("com.apple.Safari", "Safari"),
        ("com.google.Chrome", "Google Chrome"),
        ("net.imput.helium", "Helium"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.brave.Browser", "Brave Browser"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("com.vivaldi.Vivaldi", "Vivaldi"),
        ("com.operasoftware.Opera", "Opera"),
    ]

    private(set) var lastBrowser: String?
    private var observer: NSObjectProtocol?

    init() {
        lastBrowser = running().first?.name
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard let name = Self.known.first(where: { $0.bundleID == id })?.name else { return }
            MainActor.assumeIsolated { self?.lastBrowser = name }
        }
    }

    private func running() -> [(name: String, app: NSRunningApplication)] {
        let apps = NSWorkspace.shared.runningApplications
        return Self.known.compactMap { entry in
            apps.first { $0.bundleIdentifier == entry.bundleID }.map { (entry.name, $0) }
        }
    }

    func browsers() async -> [Browser] {
        var result: [Browser] = []
        for (name, app) in running() {
            let icon = app.icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!
            let tabs = (try? await Self.tabs(of: name)) ?? []
            result.append(Browser(name: name, icon: icon, tabs: tabs))
        }
        if let last = lastBrowser, let index = result.firstIndex(where: { $0.name == last }) {
            result.insert(result.remove(at: index), at: 0)
        }
        return result
    }

    func activeTab() async throws -> BrowserTab {
        guard let browser = lastBrowser else { throw Tools.Failure(message: "Open the video in your browser first") }
        let tabs = try await Self.tabs(of: browser)
        guard let tab = tabs.first(where: { $0.isActive && $0.window == 1 }) ?? tabs.first else {
            throw Tools.Failure(message: "\(browser) has no open tabs")
        }
        return tab
    }

    func pauseVideo(in tab: BrowserTab) async -> Double? {
        let js = "(function(){var v=Array.from(document.querySelectorAll('video')).sort(function(a,b){return b.clientWidth*b.clientHeight-a.clientWidth*a.clientHeight})[0];if(!v)return '';v.pause();return String(v.currentTime);})()"
        return (try? await Self.javascript(js, in: tab.browser, tab: (tab.window, tab.index))).flatMap(Double.init)
    }

    static func name(forBundleID id: String) -> String? { known.first { $0.bundleID == id }?.name }
    static func bundleID(forName name: String) -> String? { known.first { $0.name == name }?.bundleID }

    // Returns the playing video's frame in window points, or nil when the page hides it in a cross-site frame or JavaScript from Apple Events is off.
    func videoFrame(inFrontTabOf browser: String) async -> CGRect? {
        let js = "(function(){var v=Array.from(document.querySelectorAll('video')).filter(function(x){return x.currentTime>0}).sort(function(a,b){return b.clientWidth*b.clientHeight-a.clientWidth*a.clientHeight})[0];if(!v)return '';var r=v.getBoundingClientRect();return [r.left,r.top,r.width,r.height,innerWidth,innerHeight,outerWidth,outerHeight].join(',');})()"
        guard let result = try? await Self.javascript(js, in: browser, tab: nil) else { return nil }
        let n = result.split(separator: ",").compactMap { Double($0) }
        guard n.count == 8 else { return nil }
        return CGRect(x: (n[6] - n[4]) / 2 + n[0], y: n[7] - n[5] + n[1], width: n[2], height: n[3])
    }

    func bringToFront(_ tab: BrowserTab) async {
        let script = tab.browser == "Safari"
            ? "tell application \"Safari\" to set current tab of window \(tab.window) to tab \(tab.index) of window \(tab.window)"
            : "tell application \"\(tab.browser)\" to set active tab index of window \(tab.window) to \(tab.index)"
        _ = try? await Self.run(script)
    }

    private static func tabs(of browser: String) async throws -> [BrowserTab] {
        let safari = browser == "Safari"
        let titleKey = safari ? "name" : "title"
        let activeIndex = safari ? "index of current tab of window w" : "active tab index of window w"
        let script = """
        set sep to character id 9
        tell application "\(browser)"
            set out to ""
            repeat with w from 1 to count of windows
                set activeIndex to \(activeIndex)
                set i to 1
                repeat with t in tabs of window w
                    set out to out & w & sep & i & sep & activeIndex & sep & (URL of t) & sep & (\(titleKey) of t) & linefeed
                    set i to i + 1
                end repeat
            end repeat
            return out
        end tell
        """
        return try await run(script).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5, let window = Int(parts[0]), let index = Int(parts[1]),
                  let url = URL(string: parts[3]), url.scheme?.hasPrefix("http") == true
            else { return nil }
            return BrowserTab(browser: browser, window: window, index: index, url: url,
                              title: parts[4].isEmpty ? url.host ?? parts[3] : parts[4], isActive: parts[2] == parts[1])
        }
    }

    private static func javascript(_ js: String, in browser: String, tab: (window: Int, index: Int)?) async throws -> String {
        let quoted = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let target = tab.map { "tab \($0.index) of window \($0.window)" } ?? (browser == "Safari" ? "current tab of front window" : "active tab of front window")
        let script = browser == "Safari"
            ? "tell application \"Safari\" to do JavaScript \"\(quoted)\" in \(target)"
            : "tell application \"\(browser)\" to execute \(target) javascript \"\(quoted)\""
        return try await run(script)
    }

    private static func run(_ source: String) async throws -> String {
        do {
            let data = try await Tools.run("/usr/bin/osascript", ["-e", source])
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        } catch let failure as Tools.Failure where failure.message.contains("-1743") {
            throw Tools.Failure(message: "AnyCast isn't allowed to read your browser tabs. Turn it on in System Settings, Privacy & Security, Automation.")
        }
    }
}
