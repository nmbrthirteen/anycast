import Foundation

struct GitHubRelease {
    let tag: String
    let assets: [String: URL]

    static func latest(repo: String) async throws -> GitHubRelease {
        let request = Self.request(URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!, accept: "application/vnd.github+json")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        struct Payload: Decodable {
            struct Asset: Decodable { let name: String; let url: URL }
            let tag_name: String
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return GitHubRelease(tag: payload.tag_name, assets: Dictionary(payload.assets.map { ($0.name, $0.url) }) { first, _ in first })
    }

    static func download(_ asset: URL, to destination: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(for: request(asset, accept: "application/octet-stream"))
        try check(response)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    private static func request(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    private static func check(_ response: URLResponse) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode, status != 200 else { return }
        throw Tools.Failure(message: status == 404 ? "No releases found on GitHub" : "GitHub returned \(status)")
    }
}
