import Darwin
import Foundation

enum SSDP {
    private static let searchTargets = [
        "urn:schemas-upnp-org:device:MediaRenderer:1",
        "urn:schemas-upnp-org:service:AVTransport:1",
    ]

    static func search(timeout: TimeInterval = 4) -> [URL] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &dest.sin_addr)

        func sendSearches() {
            for target in searchTargets {
                let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(target)\r\n\r\n"
                let bytes = Array(message.utf8)
                withUnsafePointer(to: &dest) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var locations: [URL] = []
        let deadline = Date().addingTimeInterval(timeout)
        var lastSend = Date.distantPast
        var buffer = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline {
            if Date().timeIntervalSince(lastSend) > 1.2 {
                sendSearches()
                lastSend = Date()
            }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0, let text = String(bytes: buffer[0..<count], encoding: .utf8) else { continue }
            if let location = header("location", in: text), let url = URL(string: location), !locations.contains(url) {
                locations.append(url)
            }
        }
        return locations
    }

    private static func header(_ name: String, in response: String) -> String? {
        for line in response.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
