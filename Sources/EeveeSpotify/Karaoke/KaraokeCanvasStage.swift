import UIKit
import AVFoundation
import CoreImage
import Combine

@available(iOS 15.0, *)
final class KaraokeCanvasAmbient: ObservableObject {
    static let shared = KaraokeCanvasAmbient()
    @Published private(set) var image: UIImage?
    func update(_ image: UIImage?) {
        self.image = image
        if let source = image ?? KaraokeBackgroundView.lastImage {
            KaraokeBackgroundRenderer.shared?.setAlbumArt(source)
        }
    }
}

/// Canvas Stage from the fork, adapted to native video-only decoding. No audio player,
/// audio-session changes, playback commands, or Connect activation are involved.
@available(iOS 15.0, *)
final class KaraokeCanvasStageView: UIView {
    var visibilityChanged: ((Bool) -> Void)?
    private var track: String?
    private var mediaURL: URL?
    private var generation = UUID()
    private var lookup: URLSessionDataTask?
    private var download: URLSessionDataTask?
    private var lookedUp = false
    private var playing = false
    private var decoder: KaraokeCanvasDecoder?
    private var observers: [NSObjectProtocol] = []
    private let deliveryLock = NSLock()
    private var deliveryPending = false
    private let shade = CAGradientLayer()
    private static let cache: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.countLimit = 6; cache.totalCostLimit = 20 * 1024 * 1024
        return cache
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; isHidden = true
        layer.contentsGravity = .resizeAspectFill; clipsToBounds = true; layer.cornerRadius = 10
        shade.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.15).cgColor, UIColor.black.withAlphaComponent(0.85).cgColor]
        shade.locations = [0, 0.45, 1]; layer.addSublayer(shade)
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.decoder?.setPlaying(false)
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.update() })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); shade.frame = bounds }

    func update() {
        guard let window, window.bounds.width > window.bounds.height, UserDefaults.karaokeOptions.landscapeCanvas,
              let id = KaraokePlaybackTracker.shared.canvasSnapshot().track else { stop(); return }
        let state = KaraokePlaybackTracker.shared.canvasSnapshot()
        if track != id { stop(); track = id }
        playing = state.playing && UIApplication.shared.applicationState == .active
        decoder?.setPlaying(playing)
        if let url = state.url, mediaURL != url { load(url); return }
        guard !lookedUp, mediaURL == nil, let token = spotifyAccessToken else { return }
        lookedUp = true
        let key = generation
        let uri = Data("spotify:track:\(id)".utf8)
        guard uri.count < 126 else { return }
        var request = URLRequest(url: URL(string: "https://spclient.wg.spotify.com/canvaz-cache/v0/canvases")!)
        request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data([10, UInt8(uri.count + 2), 10, UInt8(uri.count)]) + uri
        lookup = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let canvas = CanvasWire.fields(data, number: 1).first,
                  let bytes = CanvasWire.fields(canvas, number: 2).first,
                  let string = String(data: bytes, encoding: .utf8), let url = URL(string: string), url.scheme == "https" else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == key else { return }
                if self.mediaURL == nil { self.load(url) }
            }
        }
        lookup?.resume()
    }

    private func load(_ url: URL) {
        guard url.scheme == "https" else { return }
        generation = UUID()
        download?.cancel(); decoder?.stop(); decoder = nil
        layer.contents = nil; isHidden = true; visibilityChanged?(false)
        mediaURL = url
        let key = generation
        if let data = Self.cache.object(forKey: url as NSURL) { start(data as Data, generation: key); return }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        download = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data, !data.isEmpty, data.count <= 20 * 1024 * 1024 else { return }
            Self.cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
            DispatchQueue.main.async {
                guard let self, self.generation == key, self.mediaURL == url else { return }
                self.start(data, generation: key)
            }
        }
        download?.resume()
    }

    private func start(_ data: Data, generation key: UUID) {
        decoder = KaraokeCanvasDecoder(data: data, frame: { [weak self] frame, ambient in
            guard let self else { return }
            self.deliveryLock.lock()
            if self.deliveryPending { self.deliveryLock.unlock(); return }
            self.deliveryPending = true; self.deliveryLock.unlock()
            DispatchQueue.main.async {
                defer { self.deliveryLock.lock(); self.deliveryPending = false; self.deliveryLock.unlock() }
                guard self.generation == key else { return }
                self.layer.contents = frame
                if self.isHidden { self.isHidden = false; self.visibilityChanged?(true) }
                if let ambient { KaraokeCanvasAmbient.shared.update(ambient) }
            }
        }, failed: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.generation == key else { return }
                    self.decoder?.stop(); self.decoder = nil
                    self.layer.contents = nil; self.isHidden = true; self.visibilityChanged?(false)
                    KaraokeCanvasAmbient.shared.update(nil)
                }
        })
        decoder?.setPlaying(playing)
    }

    func stop() {
        generation = UUID(); lookup?.cancel(); download?.cancel()
        lookup = nil; download = nil; decoder?.stop(); decoder = nil
        track = nil; mediaURL = nil; lookedUp = false
        layer.contents = nil; isHidden = true; visibilityChanged?(false)
        if KaraokeCanvasAmbient.shared.image != nil { KaraokeCanvasAmbient.shared.update(nil) }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { stop() } }
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        lookup?.cancel(); download?.cancel(); decoder?.stop()
    }
}

/// Minimal length-delimited protobuf reader for Spotify's Canvaz response envelope.
private enum CanvasWire {
    static func fields(_ data: Data, number: UInt64) -> [Data] {
        let bytes = [UInt8](data); var index = 0; var result = [Data]()
        func varint() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) {
                guard index < bytes.count else { return nil }
                let byte = bytes[index]; index += 1
                if shift == 63, byte > 1 { return nil }
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
            }
            return nil
        }
        while index < bytes.count {
            guard let tag = varint(), tag >> 3 != 0 else { return [] }
            switch tag & 7 {
            case 0: guard varint() != nil else { return [] }
            case 1: index += 8
            case 5: index += 4
            case 2:
                guard let count = varint(), count <= UInt64(bytes.count - index) else { return [] }
                let end = index + Int(count)
                if tag >> 3 == number { result.append(Data(bytes[index..<end])) }
                index = end
            default: return []
            }
            guard index <= bytes.count else { return [] }
        }
        return result
    }
}

/// Decode one video frame ahead, on a private queue, and loop against a monotonic clock.
/// AVAssetReader reads only the video track and never activates an audio session.
@available(iOS 15.0, *)
private final class KaraokeCanvasDecoder {
    private let queue = DispatchQueue(label: "com.eevee.canvas.decode", qos: .userInitiated)
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("eevee-canvas-\(UUID()).mp4")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var asset: AVURLAsset?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var next: CMSampleBuffer?
    private var timer: DispatchSourceTimer?
    private var transform = CGAffineTransform.identity
    private var duration = 0.0, elapsed = 0.0, stamp = CACurrentMediaTime(), lastClock = -1.0, lastAmbient = -1.0
    private var playing = false, rendered = false, stopped = false
    private let frame: (CGImage, UIImage?) -> Void
    private let failed: () -> Void

    init(data: Data, frame: @escaping (CGImage, UIImage?) -> Void, failed: @escaping () -> Void) {
        self.frame = frame; self.failed = failed
        queue.async { [self] in
            do {
                try data.write(to: file, options: .atomic)
                let asset = AVURLAsset(url: file); self.asset = asset
                duration = CMTimeGetSeconds(asset.duration)
                guard duration.isFinite, duration > 0, duration <= 30 else { throw CocoaError(.fileReadCorruptFile) }
                try resetReader()
                let timer = DispatchSource.makeTimerSource(queue: queue); self.timer = timer
                timer.schedule(deadline: .now(), repeating: 1.0 / 30)
                timer.setEventHandler { [weak self] in self?.tick() }; timer.resume()
            } catch { failed() }
        }
    }
    func setPlaying(_ value: Bool) {
        queue.async { [self] in
            guard playing != value else { return }
            let now = CACurrentMediaTime()
            if playing { elapsed += now - stamp }
            stamp = now; playing = value
        }
    }
    private func resetReader() throws {
        reader?.cancelReading()
        guard let asset, let track = asset.tracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        transform = track.preferredTransform
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        self.reader = reader; self.output = output; next = output.copyNextSampleBuffer()
    }
    private func tick() {
        guard !stopped, playing || !rendered else { return }
        autoreleasepool {
            let now = CACurrentMediaTime()
            let clock = (elapsed + (playing ? now - stamp : 0)).truncatingRemainder(dividingBy: duration)
            do { if clock < lastClock { try resetReader() } } catch { stopOnQueue(); failed(); return }
            lastClock = clock
            var sample: CMSampleBuffer?
            while let candidate = next, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(candidate)) <= clock {
                sample = candidate; next = output?.copyNextSampleBuffer()
            }
            if reader?.status == .failed { stopOnQueue(); failed(); return }
            guard let sample, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
            let image = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
            guard image.extent.width > 0, image.extent.height > 0 else { return }
            let scale = min(1, 640 / max(image.extent.width, image.extent.height))
            let fitted = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let renderedImage = context.createCGImage(fitted, from: fitted.extent) else { return }
            var ambient: UIImage?
            if now - lastAmbient >= 0.2 {
                lastAmbient = now
                let tiny = image.transformed(by: CGAffineTransform(scaleX: 80 / image.extent.width, y: 80 / image.extent.width))
                if let cg = context.createCGImage(tiny, from: tiny.extent) { ambient = UIImage(cgImage: cg) }
            }
            rendered = true; frame(renderedImage, ambient)
        }
    }
    private func stopOnQueue() { stopped = true; timer?.cancel(); timer = nil; reader?.cancelReading(); next = nil }
    func stop() { queue.async { [self] in stopOnQueue() } }
    deinit { timer?.cancel(); reader?.cancelReading(); try? FileManager.default.removeItem(at: file) }
}
