import AppKit

@MainActor
final class RecentApps {
    private var order: [pid_t] = []
    private var observer: NSObjectProtocol?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated {
                self?.order.removeAll { $0 == pid }
                self?.order.insert(pid, at: 0)
            }
        }
    }

    func rank(_ pid: pid_t) -> Int { order.firstIndex(of: pid) ?? .max }
}
