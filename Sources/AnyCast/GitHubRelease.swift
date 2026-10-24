import Foundation

struct GitHubRelease {
    let tag: String
    let assets: [String: URL]

    static func latest(repo: String) async throws -> GitHubRelease {
        let request = try await authorized(URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!, accept: "application/vnd.github+json")
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
        let (file, response) = try await URLSession.shared.download(for: try await authorized(asset, accept: "application/octet-stream"))
        try check(response)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    // Private forks need a token; the gh CLI login is reused when it's installed.
    private static func authorized(_ url: URL, accept: String) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let token = await token() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private static func token() async -> String? {
        if let env = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !env.isEmpty { return env }
        guard let gh = Tools.find("gh"), let data = try? await Tools.run(gh, ["auth", "token"]) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private static func check(_ response: URLResponse) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode, status != 200 else { return }
        throw Tools.Failure(message: status == 404 ? "No releases found on GitHub" : "GitHub returned \(status)")
    }
}
