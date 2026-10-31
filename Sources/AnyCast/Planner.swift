import Foundation
import ImageIO
import UniformTypeIdentifiers

struct TVProfile {
    var maxHeight: Int
    var playsHEVC: Bool

    func canPlay(video codec: String?, height: Int) -> Bool {
        guard let codec else { return true }
        let codecs = playsHEVC ? ["h264", "avc1", "hevc", "hev1", "hvc1"] : ["h264", "avc1"]
        let fits = maxHeight == 0 || height <= maxHeight
        return fits && codecs.contains { codec.hasPrefix($0) }
    }

    func canPlay(audio codec: String?) -> Bool {
        guard let codec else { return true }
        return ["aac", "mp4a", "mp3", "ac3", "ac-3", "eac3", "ec-3"].contains { codec.hasPrefix($0) }
    }
}

struct CastPlan {
    enum Source {
        case remote(URL, mime: String)
        case file(URL, mime: String)
        case pipeline(mime: String, ext: String, arguments: (Double) -> [String])
        case mirror(make: () -> StreamProducer)

        var needsFFmpeg: Bool {
            switch self {
            case .pipeline, .mirror: true
            case .remote, .file: false
            }
        }
    }

    enum Mode: String {
        case direct = "TV plays the original stream itself. Your Mac can sleep."
        case original = "Original quality, streamed from your Mac."
        case remux = "Original quality, repackaged for the TV by your Mac."
        case converted = "Converted for your TV at high bitrate."
        case mirror = "Mirroring with sound."
        case tab = "Streaming this tab from the AnyCast extension. It keeps playing on any desktop."

        var label: String {
            switch self {
            case .direct: "Direct from web"
            case .original: "Original file"
            case .remux: "Original quality"
            case .converted: "Converted"
            case .mirror: "Mirroring"
            case .tab: "Browser tab"
            }
        }
    }

    let title: String
    let kind: MediaItem.Kind
    let duration: Double
    var mode: Mode
    var source: Source
    var fallback: (mode: Mode, source: Source)?
    var startAt: Double = 0

    var seeksByRestart: Bool { if case .pipeline = source { return true } else { return false } }
}

enum Planner {
    static func plan(file url: URL, profile: TVProfile) async throws -> CastPlan {
        let title = url.deletingPathExtension().lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let mime = type?.preferredMIMEType ?? "application/octet-stream"

        if type?.conforms(to: .image) == true {
            if ["image/jpeg", "image/png"].contains(mime) {
                return CastPlan(title: title, kind: .image, duration: 0, mode: .original, source: .file(url, mime: mime))
            }
            return CastPlan(title: title, kind: .image, duration: 0, mode: .converted, source: .file(try jpegCopy(of: url), mime: "image/jpeg"))
        }

        let probe = await ProbeResult.probe(url.path)
        let duration = probe?.duration ?? 0

        if probe?.videoCodec == nil, type?.conforms(to: .audio) == true || probe?.audioCodec != nil {
            let direct = ["mp3", "aac", "flac", "pcm_s16le", "pcm_s24le"].contains { probe?.audioCodec?.hasPrefix($0) ?? true }
            if direct && ["mp3", "m4a", "aac", "flac", "wav"].contains(url.pathExtension.lowercased()) {
                return CastPlan(title: title, kind: .audio, duration: duration, mode: .original, source: .file(url, mime: mime))
            }
            let source = CastPlan.Source.pipeline(mime: "audio/mpeg", ext: "mp3") { offset in
                ["-ss", String(offset), "-i", url.path, "-vn", "-c:a", "libmp3lame", "-b:a", "320k", "-f", "mp3", "pipe:1"]
            }
            return CastPlan(title: title, kind: .audio, duration: duration, mode: .converted, source: source)
        }

        guard let probe else {
            if Tools.ffprobe == nil {
                throw Tools.Failure(message: "AnyCast needs ffmpeg to check this video. Install it in Terminal with: brew install ffmpeg")
            }
            return CastPlan(title: title, kind: .video, duration: 0, mode: .original, source: .file(url, mime: mime))
        }

        let videoOK = profile.canPlay(video: probe.videoCodec, height: probe.height)
        let audioOK = profile.canPlay(audio: probe.audioCodec)
        let mp4Family = probe.formatName.contains("mp4") || probe.formatName.contains("mov")

        if videoOK && audioOK && mp4Family {
            var plan = CastPlan(title: title, kind: .video, duration: duration, mode: .original, source: .file(url, mime: mime == "video/quicktime" ? "video/mp4" : mime))
            plan.fallback = (.remux, transportStream(inputs: [.init(url: url.path)], probe: probe, profile: profile))
            return plan
        }
        return CastPlan(
            title: title, kind: .video, duration: duration,
            mode: videoOK ? .remux : .converted,
            source: transportStream(inputs: [.init(url: url.path)], probe: probe, profile: profile)
        )
    }

    static func plan(web page: URL, profile: TVProfile) async throws -> CastPlan {
        let height = profile.maxHeight > 0 ? "[height<=\(profile.maxHeight)]" : ""
        let video = profile.playsHEVC ? "[vcodec~='^(avc|h264|hev|hvc|hevc)']" : "[vcodec~='^(avc|h264)']"
        let audio = "[acodec~='^(mp4a|aac|mp3|ac-3|ec-3)']"
        let format = "bv*\(video)\(height)+ba\(audio)/b\(video)\(height)/bv*\(video)\(height)+ba/bv*\(height)+ba/b\(height)/b"

        let data: Data
        do {
            data = try await Tools.run(Tools.ytdlp, ["-J", "--no-playlist", "--no-warnings", "-f", format, page.absoluteString])
        } catch let failure as Tools.Failure {
            throw Tools.Failure(message: Self.friendly(failure.message))
        }
        guard let info = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Tools.Failure(message: "Could not read video info")
        }
        let title = info["title"] as? String ?? page.host ?? "Video"
        let duration = info["duration"] as? Double ?? 0
        let formats = (info["requested_formats"] as? [[String: Any]]) ?? [info]
        let inputs = formats.compactMap(Input.init(format:))
        guard !inputs.isEmpty else { throw Tools.Failure(message: "No playable stream found on this page") }

        let videoFormat = formats.first { ($0["vcodec"] as? String ?? "none") != "none" } ?? formats[0]
        let audioFormat = formats.first { ($0["acodec"] as? String ?? "none") != "none" }
        var probe = ProbeResult()
        probe.videoCodec = (videoFormat["vcodec"] as? String).flatMap { $0 == "none" ? nil : $0 }
        probe.audioCodec = (audioFormat?["acodec"] as? String).flatMap { $0 == "none" ? nil : $0 }
        probe.height = videoFormat["height"] as? Int ?? 0
        probe.videoBitrate = Int((videoFormat["tbr"] as? Double ?? 0) * 1000)
        probe.duration = duration

        let videoOK = profile.canPlay(video: probe.videoCodec, height: probe.height)
        let relay = transportStream(inputs: inputs, probe: probe, profile: profile)
        let relayMode: CastPlan.Mode = videoOK && profile.canPlay(audio: probe.audioCodec) ? .remux : .converted

        let single = formats.count == 1 ? formats[0] : nil
        let isProgressive = (single?["protocol"] as? String).map { $0 == "https" || $0 == "http" } ?? false
        let isMP4 = (single?["ext"] as? String) == "mp4"
        let needsCookies = (single?["http_headers"] as? [String: String])?["Cookie"] != nil
        if let single, isProgressive, isMP4, !needsCookies, relayMode == .remux,
           let urlString = single["url"] as? String, let url = URL(string: urlString) {
            var plan = CastPlan(title: title, kind: .video, duration: duration, mode: .direct, source: .remote(url, mime: "video/mp4"))
            plan.fallback = (.remux, relay)
            return plan
        }
        return CastPlan(title: title, kind: .video, duration: duration, mode: relayMode, source: relay)
    }

    private static func friendly(_ ytdlpError: String) -> String {
        let text = ytdlpError.lowercased()
        if text.contains("unsupported url") || text.contains("no video") || text.contains("unable to download webpage") {
            return "AnyCast couldn't find a video on this page."
        }
        if text.contains("sign in") || text.contains("login") || text.contains("private") {
            return "This video needs you to be signed in, so AnyCast can't fetch it."
        }
        if text.contains("drm") { return "This video is copy-protected, so it can't be cast." }
        return ytdlpError.replacingOccurrences(of: "ERROR: ", with: "")
    }

    struct Input {
        var url: String
        var headers: String?

        init(url: String, headers: String? = nil) {
            self.url = url
            self.headers = headers
        }

        init?(format: [String: Any]) {
            guard let url = format["url"] as? String else { return nil }
            self.url = url
            let headers = format["http_headers"] as? [String: String] ?? [:]
            self.headers = headers.isEmpty ? nil : headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        }
    }

    static func transportStream(inputs: [Input], probe: ProbeResult, profile: TVProfile) -> CastPlan.Source {
        let videoOK = profile.canPlay(video: probe.videoCodec, height: probe.height)
        let audioOK = profile.canPlay(audio: probe.audioCodec)
        let targetHeight = profile.maxHeight > 0 ? min(probe.height, profile.maxHeight) : probe.height
        let bitrate = max(probe.videoBitrate * 3 / 2, targetHeight > 1080 ? 40_000_000 : 20_000_000)

        return .pipeline(mime: "video/mpeg", ext: "ts") { offset in
            var args: [String] = []
            for input in inputs {
                if input.url.hasPrefix("http") {
                    args += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
                }
                if let headers = input.headers { args += ["-headers", headers] }
                if offset > 0 { args += ["-ss", String(format: "%.2f", offset)] }
                args += ["-i", input.url]
            }
            if inputs.count > 1 {
                args += ["-map", "0:v:0", "-map", "1:a:0"]
            } else {
                args += ["-map", "0:v:0?", "-map", "0:a:0?"]
            }
            if videoOK {
                args += ["-c:v", "copy"]
            } else {
                var filters = ["format=nv12"]
                if profile.maxHeight > 0 && probe.height > profile.maxHeight { filters.insert("scale=-2:\(profile.maxHeight)", at: 0) }
                args += ["-vf", filters.joined(separator: ","), "-c:v", "h264_videotoolbox", "-profile:v", "high",
                         "-b:v", String(bitrate), "-maxrate", String(bitrate * 3 / 2), "-bufsize", String(bitrate * 2), "-g", "60"]
            }
            args += audioOK ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "320k", "-ac", "2"]
            args += ["-f", "mpegts", "-mpegts_flags", "+resend_headers", "-muxdelay", "0", "pipe:1"]
            return args
        }
    }

    private static func jpegCopy(of url: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Tools.Failure(message: "Could not read image") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("anycast-images")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent(UUID().uuidString + ".jpg")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Tools.Failure(message: "Could not convert image")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.97] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output
    }
}
