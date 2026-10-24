import AppKit
import CoreMedia
import ScreenCaptureKit

struct MirrorTarget: Identifiable, Hashable {
    enum Kind: Hashable { case display(CGDirectDisplayID), window(CGWindowID) }
    let kind: Kind
    let title: String
    var pid: pid_t = 0
    var crop: CGRect?
    var id: Kind { kind }
}

struct MirrorSettings {
    var fps: Int
    var bitrateMbps: Int
    var maxHeight: Int
    var showsCursor: Bool
    var capturesAudio: Bool
}

final class ScreenMirror: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let sampleRate = 48_000

    private let lock = NSLock()
    private var stream: SCStream?
    private var latestFrame: Data?
    private var audio: [Float] = []
    private(set) var encoderStarted: Date?
    private var streamClock = StreamClock()
    var speed: Double {
        get { streamClock.speed }
        set { streamClock.speed = newValue }
    }
    var streamSeconds: Double { streamClock.now() }
    private(set) var audioPeak: Float = 0
    private var stats = (frames: 0, newFrames: 0, padded: 0, dropped: 0, captured: 0, received: 0, consumed: 0)

    func takeStats() -> String {
        lock.lock()
        defer { stats = (0, 0, 0, 0, 0, 0, 0); lock.unlock() }
        return "audio in \(stats.received) out \(stats.consumed) | captured \(stats.captured) frames, wrote \(stats.frames) (\(stats.newFrames) new), audio padded \(stats.padded) dropped \(stats.dropped) samples, ring \(audio.count / 2)"
    }
    private(set) var width = 0
    private(set) var height = 0
    private(set) var settings = MirrorSettings(fps: 30, bitrateMbps: 12, maxHeight: 1080, showsCursor: true, capturesAudio: true)
    var onStopped: ((Error?) -> Void)?

    static func targets() async throws -> [MirrorTarget] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displays = content.displays.enumerated().map { index, display in
            MirrorTarget(kind: .display(display.displayID), title: content.displays.count > 1 ? "Entire screen \(index + 1)" : "Entire screen")
        }
        let windows = content.windows
            .filter { ($0.windowLayer == 0 || isPictureInPicture($0.title)) && $0.frame.width > 200 && $0.frame.height > 150 && $0.owningApplication?.processID != ownPID }
            .compactMap { window -> MirrorTarget? in
                guard let app = window.owningApplication?.applicationName, !app.isEmpty else { return nil }
                let title = (window.title ?? "").isEmpty ? app : "\(app): \(window.title!)"
                return MirrorTarget(kind: .window(window.windowID), title: String(title.prefix(70)), pid: window.owningApplication?.processID ?? 0)
            }
        return displays + windows
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func filter(for target: MirrorTarget) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        switch target.kind {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw Tools.Failure(message: "Screen not found") }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw Tools.Failure(message: "That window is gone") }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    static func thumbnail(for target: MirrorTarget) async -> NSImage? {
        guard let filter = try? await filter(for: target) else { return nil }
        let config = SCStreamConfiguration()
        let scale = 360 / max(filter.contentRect.width, 1)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    @MainActor
    static func pickWithSystemPicker() async throws -> SCContentFilter {
        try await SystemPicker.shared.pick()
    }

    static func isOnScreen(_ windowID: CGWindowID) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }
    }

    static func hasWindowOnOtherDesktop(_ pid: pid_t) -> Bool {
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return all.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
                && ($0[kCGWindowIsOnscreen as String] as? Bool) != true
                && (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0) > 200
        }
    }

    static func frontWindow(of pid: pid_t) async throws -> MirrorTarget? {
        let ordered = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let windows = try await targets().filter { $0.pid == pid }
        let candidates = ordered.compactMap { number in windows.first { $0.kind == .window(number) } }
        return candidates.first { isPictureInPicture($0.title) } ?? candidates.first
    }

    // Picture in picture floats on every desktop, so it keeps rendering after you switch away.
    static func isPictureInPicture(_ title: String?) -> Bool {
        guard let title = title?.lowercased() else { return false }
        return title.contains("picture in picture") || title.contains("picture-in-picture")
    }

    private(set) var windowID: CGWindowID?

    func start(_ target: MirrorTarget, settings: MirrorSettings) async throws {
        if case .window(let id) = target.kind { windowID = id } else { windowID = nil }
        try await start(filter: Self.filter(for: target), settings: settings, crop: target.crop)
    }

    func start(filter: SCContentFilter, settings: MirrorSettings, crop: CGRect? = nil) async throws {
        stop()
        self.settings = settings
        let region = crop.map { $0.intersection(CGRect(origin: .zero, size: filter.contentRect.size)) }.flatMap { $0.width > 100 && $0.height > 60 ? $0 : nil }
        let points = region?.size ?? filter.contentRect.size
        let size = CGSize(width: points.width * CGFloat(filter.pointPixelScale), height: points.height * CGFloat(filter.pointPixelScale))

        let fit = min(1, Double(settings.maxHeight) / size.height, Double(settings.maxHeight) * 16 / 9 / size.width)
        width = Int(size.width * fit) & ~1
        height = Int(size.height * fit) & ~1

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        config.queueDepth = 6
        config.showsCursor = settings.showsCursor
        config.scalesToFit = true
        if let region { config.sourceRect = region }
        config.capturesAudio = settings.capturesAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Self.sampleRate
        config.channelCount = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "anycast.video"))
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "anycast.audio"))
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        lock.lock()
        latestFrame = nil
        audio.removeAll()
        lock.unlock()
    }

    func makeProducer() -> StreamProducer { MirrorEncoder(mirror: self) }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStopped?(error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }
        switch type {
        case .screen: storeFrame(buffer)
        case .audio: storeAudio(buffer)
        default: break
        }
    }

    private func storeFrame(_ buffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = buffer.imageBuffer
        else { return }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let w = CVPixelBufferGetWidth(pixels)
        let h = CVPixelBufferGetHeight(pixels)
        guard w == width, h == height else { return }

        var frame = Data(capacity: w * h * 3 / 2)
        for (plane, rows) in [(0, h), (1, h / 2)] {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, plane) else { return }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane)
            for row in 0..<rows { frame.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: w) }
        }
        lock.lock()
        latestFrame = frame
        frameIsNew = true
        stats.captured += 1
        lock.unlock()
    }

    private func storeAudio(_ buffer: CMSampleBuffer) {
        try? buffer.withAudioBufferList { list, _ in
            let frames = buffer.numSamples
            var interleaved = [Float](repeating: 0, count: frames * 2)
            if list.count >= 2 {
                for channel in 0..<2 {
                    guard let samples = list[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<frames { interleaved[i * 2 + channel] = samples[i] }
                }
            } else if let samples = list.first?.mData?.assumingMemoryBound(to: Float.self) {
                let channels = Int(list[0].mNumberChannels)
                for i in 0..<frames {
                    interleaved[i * 2] = samples[i * channels]
                    interleaved[i * 2 + 1] = samples[i * channels + (channels > 1 ? 1 : 0)]
                }
            }
            let peak = interleaved.reduce(0) { max($0, abs($1)) }
            lock.lock()
            audioPeak = max(audioPeak * 0.9, peak)
            stats.received += frames
            audio.append(contentsOf: interleaved)
            let cap = Self.sampleRate * 2 * 2
            if audio.count > cap {
                stats.dropped += (audio.count - cap) / 2
                audio.removeFirst(audio.count - cap)
            }
            lock.unlock()
        }
    }

    private var frameIsNew = false

    fileprivate func currentFrame(count: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let latestFrame else { return nil }
        stats.frames += count
        if frameIsNew { stats.newFrames += 1 }
        frameIsNew = false
        return latestFrame
    }

    fileprivate func markEncoderStart(_ date: Date) -> StreamClock {
        encoderStarted = date
        streamClock = StreamClock()
        return streamClock
    }

    fileprivate func takeAudio(frames: Int) -> [Float] {
        lock.lock()
        // Keep only a small cushion so sound stays in step with the picture.
        let maxBacklog = Self.sampleRate * 2 * 3 / 10
        if audio.count > maxBacklog {
            let excess = audio.count - Self.sampleRate * 2 / 10
            stats.dropped += excess / 2
            audio.removeFirst(excess)
        }
        let wanted = frames * 2
        let available = min(wanted, audio.count)
        stats.consumed += frames
        var chunk = Array(audio.prefix(available))
        audio.removeFirst(available)
        lock.unlock()
        if chunk.count < wanted {
            lock.withLock { stats.padded += (wanted - chunk.count) / 2 }
            chunk += [Float](repeating: 0, count: wanted - chunk.count)
        }
        return chunk
    }

    fileprivate func clearAudio() {
        lock.lock()
        audio.removeAll()
        lock.unlock()
    }
}

@MainActor
private final class SystemPicker: NSObject, SCContentSharingPickerObserver {
    static let shared = SystemPicker()
    private var continuation: CheckedContinuation<SCContentFilter, Error>?

    func pick() async throws -> SCContentFilter {
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow, .singleDisplay, .singleApplication]
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation?.resume(throwing: CancellationError())
            self.continuation = continuation
            picker.present()
        }
    }

    private func finish(_ result: Result<SCContentFilter, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in finish(.failure(CancellationError())) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in finish(.success(filter)) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in finish(.failure(error)) }
    }
}

// Both inputs are fed on a wall clock, padding with repeated frames and silence, so ffmpeg sees constant-rate streams that stay in sync.
private final class MirrorEncoder: StreamProducer {
    private let mirror: ScreenMirror
    private let fifo = FileManager.default.temporaryDirectory.appendingPathComponent("anycast-audio-\(UUID().uuidString)").path
    private let ffmpeg: FFmpegProducer
    private var running = false

    init(mirror: ScreenMirror) {
        self.mirror = mirror
        let s = mirror.settings
        let bitrate = s.bitrateMbps * 1_000_000
        ffmpeg = FFmpegProducer(arguments: [
            // Color tags go on the input; on the output they force a software color conversion of every frame.
            "-f", "rawvideo", "-pix_fmt", "nv12", "-s", "\(mirror.width)x\(mirror.height)", "-framerate", String(s.fps),
            "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-i", "pipe:0",
            "-f", "f32le", "-ar", String(ScreenMirror.sampleRate), "-ac", "2", "-i", fifo,
            "-c:v", "h264_videotoolbox", "-realtime", "1", "-profile:v", "high", "-bf", "0",
            "-b:v", String(bitrate), "-maxrate", String(bitrate * 5 / 4), "-bufsize", String(bitrate),
            "-g", String(s.fps),
            "-c:a", "aac", "-b:a", "256k",
            // Constant mux rate pads still screens with null packets so the TV's byte-sized buffer fills in under a second.
            "-f", "mpegts", "-muxrate", String(bitrate * 3 / 2 + 512_000), "-pcr_period", "20",
            "-flush_packets", "1", "-muxdelay", "0", "-muxpreload", "0", "pipe:1",
        ])
    }

    func start() throws -> FileHandle {
        mkfifo(fifo, 0o600)
        var videoInput: FileHandle?
        ffmpeg.onStart = { process in videoInput = (process.standardInput as? Pipe)?.fileHandleForWriting }
        let output = try ffmpeg.start()
        guard let videoInput else { throw Tools.Failure(message: "Encoder did not start") }
        running = true
        mirror.clearAudio()
        let clock = mirror.markEncoderStart(Date())
        let fps = mirror.settings.fps

        Thread.detachNewThread { [self] in
            // Every due frame is written, black until capture starts, so video time never falls behind the audio.
            let black = Data(repeating: 16, count: mirror.width * mirror.height) + Data(repeating: 128, count: mirror.width * mirror.height / 2)
            var written = 0
            while running {
                let due = Int(clock.now() * Double(fps)) - written
                if due > 0 {
                    let frame = mirror.currentFrame(count: due) ?? black
                    for _ in 0..<due where running {
                        guard (try? videoInput.write(contentsOf: frame)) != nil else { running = false; break }
                        written += 1
                    }
                }
                Thread.sleep(forTimeInterval: 0.5 / Double(fps))
            }
            try? videoInput.close()
        }

        Thread.detachNewThread { [self] in
            // O_RDWR never blocks on a FIFO, which lets ffmpeg's blocking open for reading complete.
            let fd = open(fifo, O_RDWR | O_NONBLOCK)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var written = 0
            while running {
                let due = Int(clock.now() * Double(ScreenMirror.sampleRate)) - written
                if due > 0 {
                    let samples = mirror.takeAudio(frames: due)
                    samples.withUnsafeBytes { bytes in
                        var offset = 0
                        while running && offset < bytes.count {
                            let result = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                            if result > 0 { offset += result } else { Thread.sleep(forTimeInterval: 0.005) }
                        }
                    }
                    written += due
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        return output
    }

    func stop() {
        running = false
        ffmpeg.stop()
        let path = fifo
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { unlink(path) }
    }
}

// Stream time can run slower than wall time, which drains the TV's playback buffer and cuts the delay.
final class StreamClock: @unchecked Sendable {
    private let lock = NSLock()
    private var lastWall = Date()
    private var stream = 0.0
    private var rate = 1.0

    var speed: Double {
        get { lock.withLock { rate } }
        set { lock.withLock { advance(); rate = newValue } }
    }

    func now() -> Double { lock.withLock { advance(); return stream } }

    private func advance() {
        let wall = Date()
        stream += wall.timeIntervalSince(lastWall) * rate
        lastWall = wall
    }
}
