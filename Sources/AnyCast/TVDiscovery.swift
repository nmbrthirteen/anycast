import Foundation

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
}
