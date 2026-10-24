import Foundation

struct Renderer: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let model: String
    let host: String
    let avTransport: URL
    let renderingControl: URL?
}

struct UPnPError: LocalizedError {
    let code: Int
    let detail: String
    var errorDescription: String? { "TV error \(code): \(detail)" }
}

enum DeviceDescription {
    static func load(_ location: URL) async throws -> Renderer? {
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: location, timeoutInterval: 4))
        let parser = DescriptionParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()

        let base = parser.urlBase.flatMap(URL.init(string:)) ?? location
        func resolve(_ path: String) -> URL? { URL(string: path, relativeTo: base)?.absoluteURL }

        guard let transport = parser.services.first(where: { $0.type.contains(":AVTransport:") }),
              let transportURL = resolve(transport.controlURL)
        else { return nil }
        let rendering = parser.services.first(where: { $0.type.contains(":RenderingControl:") })

        return Renderer(
            id: location.absoluteString,
            name: parser.friendlyName ?? location.host ?? "TV",
            model: [parser.manufacturer, parser.modelName].compactMap { $0 }.joined(separator: " "),
            host: location.host ?? "",
            avTransport: transportURL,
            renderingControl: rendering.flatMap { resolve($0.controlURL) }
        )
    }
}

private final class DescriptionParser: NSObject, XMLParserDelegate {
    struct Service { var type = ""; var controlURL = "" }

    var friendlyName: String?
    var manufacturer: String?
    var modelName: String?
    var urlBase: String?
    var services: [Service] = []

    private var current: Service?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if localName(name) == "service" { current = Service() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch localName(name) {
        case "friendlyName" where friendlyName == nil: friendlyName = value
        case "manufacturer" where manufacturer == nil: manufacturer = value
        case "modelName" where modelName == nil: modelName = value
        case "URLBase": urlBase = value
        case "serviceType": current?.type = value
        case "controlURL": current?.controlURL = value
        case "service":
            if let current { services.append(current) }
            current = nil
        default: break
        }
        text = ""
    }

    private func localName(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }
}

struct MediaItem {
    enum Kind { case video, audio, image }
    let url: URL
    let title: String
    let mime: String
    let kind: Kind
    let isLive: Bool
}

struct DLNAClient {
    let renderer: Renderer

    private static let transport = "urn:schemas-upnp-org:service:AVTransport:1"
    private static let rendering = "urn:schemas-upnp-org:service:RenderingControl:1"

    func load(_ item: MediaItem) async throws {
        _ = try? await call(Self.transport, "Stop")
        do {
            try await setURI(item, mime: item.mime)
        } catch is UPnPError where item.mime == "video/mpeg" {
            try await setURI(item, mime: "video/mp2t")
        }
        var lastError: Error?
        for _ in 0..<6 {
            do {
                try await play()
                return
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(800))
            }
        }
        if let lastError { throw lastError }
    }

    func play() async throws { try await call(Self.transport, "Play", [("Speed", "1")]) }
    func pause() async throws { try await call(Self.transport, "Pause") }
    func stop() async throws { try await call(Self.transport, "Stop") }

    func seek(to seconds: Double) async throws {
        try await call(Self.transport, "Seek", [("Unit", "REL_TIME"), ("Target", Self.format(seconds))])
    }

    func transportState() async throws -> String {
        let xml = try await call(Self.transport, "GetTransportInfo")
        return Self.value("CurrentTransportState", in: xml) ?? "UNKNOWN"
    }

    func position() async throws -> (position: Double, duration: Double) {
        let xml = try await call(Self.transport, "GetPositionInfo")
        return (Self.parse(Self.value("RelTime", in: xml)), Self.parse(Self.value("TrackDuration", in: xml)))
    }

    func volume() async throws -> Int {
        guard renderer.renderingControl != nil else { return 0 }
        let xml = try await call(Self.rendering, "GetVolume", [("Channel", "Master")])
        return Int(Self.value("CurrentVolume", in: xml) ?? "") ?? 0
    }

    func setVolume(_ volume: Int) async throws {
        guard renderer.renderingControl != nil else { return }
        try await call(Self.rendering, "SetVolume", [("Channel", "Master"), ("DesiredVolume", String(volume))])
    }

    private func setURI(_ item: MediaItem, mime: String) async throws {
        try await call(Self.transport, "SetAVTransportURI", [
            ("CurrentURI", item.url.absoluteString),
            ("CurrentURIMetaData", Self.didl(item, mime: mime)),
        ])
    }

    @discardableResult
    private func call(_ service: String, _ action: String, _ arguments: [(String, String)] = []) async throws -> String {
        guard let endpoint = service == Self.rendering ? renderer.renderingControl : renderer.avTransport else { return "" }
        let args = ([("InstanceID", "0")] + arguments).map { "<\($0.0)>\(Self.escape($0.1))</\($0.0)>" }.joined()
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="\(service)">\(args)</u:\(action)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let xml = String(decoding: data, as: UTF8.self)
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            throw UPnPError(
                code: Int(Self.value("errorCode", in: xml) ?? "") ?? http.statusCode,
                detail: Self.value("errorDescription", in: xml) ?? "\(action) failed"
            )
        }
        return xml
    }

    static func protocolInfo(mime: String, live: Bool) -> String {
        let flags = live ? "DLNA.ORG_OP=00;DLNA.ORG_CI=1;DLNA.ORG_FLAGS=01700000000000000000000000000000"
                         : "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
        return "http-get:*:\(mime):\(flags)"
    }

    private static func didl(_ item: MediaItem, mime: String) -> String {
        let upnpClass: String
        switch item.kind {
        case .video: upnpClass = "object.item.videoItem"
        case .audio: upnpClass = "object.item.audioItem.musicTrack"
        case .image: upnpClass = "object.item.imageItem.photo"
        }
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">\
        <item id="0" parentID="-1" restricted="1"><dc:title>\(escape(item.title))</dc:title><upnp:class>\(upnpClass)</upnp:class>\
        <res protocolInfo="\(protocolInfo(mime: mime, live: item.isLive))">\(escape(item.url.absoluteString))</res></item></DIDL-Lite>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func value(_ tag: String, in xml: String) -> String? {
        let pattern = "<(?:\\w+:)?\(tag)[^>]*>(.*?)</(?:\\w+:)?\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml)
        else { return nil }
        return String(xml[range])
    }

    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    private static func parse(_ time: String?) -> Double {
        guard let time, !time.contains("NOT_IMPLEMENTED") else { return 0 }
        let parts = time.split(separator: ".").first?.split(separator: ":").compactMap { Double($0) } ?? []
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
