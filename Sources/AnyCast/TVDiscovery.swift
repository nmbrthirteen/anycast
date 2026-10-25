import Foundation
import Network

enum TVDiscovery {
    private static let knownKey = "knownTVs"

    // Some TVs only answer multicast searches intermittently, so the last description URLs are retried directly.
    static func find() async -> [Renderer] {
        var locations = await Task.detached { SSDP.search() }.value
        let known = (UserDefaults.standard.string(forKey: knownKey) ?? "").split(separator: " ").compactMap { URL(string: String($0)) }
        locations += known.filter { !locations.contains($0) }

        var found: [Renderer] = []
        await withTaskGroup(of: Renderer?.self) { group in
            for location in locations { group.addTask { try? await DeviceDescription.load(location) } }
            for await renderer in group {
                if let renderer, !found.contains(where: { $0.avTransport == renderer.avTransport }) { found.append(renderer) }
            }
        }
        if !found.isEmpty { UserDefaults.standard.set(found.map(\.id).joined(separator: " "), forKey: knownKey) }
        return found.sorted { $0.name < $1.name }
    }

    // A refused connection means the TV is on the network but its casting service has stopped, which a power cycle fixes.
    static func knownTVIsStuck() async -> Bool {
        let known = (UserDefaults.standard.string(forKey: knownKey) ?? "").split(separator: " ").compactMap { URL(string: String($0)) }
        for url in known {
            guard let host = url.host, let port = url.port.flatMap({ NWEndpoint.Port(rawValue: UInt16($0)) }) else { continue }
            if await refuses(NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)) { return true }
        }
        return false
    }

    private static func refuses(_ endpoint: NWEndpoint) async -> Bool {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once()
            let finish: @Sendable (Bool) -> Void = { value in
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(false)
                case .waiting(let error), .failed(let error): finish(error == .posix(.ECONNREFUSED))
                default: break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish(false) }
        }
        connection.cancel()
        return result
    }
}

// Every callback runs on the main queue, so the flag needs no lock.
private final class Once: @unchecked Sendable {
    var done = false
}
