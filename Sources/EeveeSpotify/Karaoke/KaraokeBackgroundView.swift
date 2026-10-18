import SwiftUI
import MetalKit

/// Refresh artwork after player changes: media metadata and cover views can arrive later than lyrics.
@available(iOS 15.0, *)
struct KaraokeBackgroundView: View {
    let trackId: String?
    private static var lastImage: UIImage?
    private static var lastFingerprint: Data?

    init(trackId: String?) {
        self.trackId = trackId
        _albumArtImage = State(initialValue: Self.lastImage)
        _fingerprint = State(initialValue: Self.lastFingerprint)
    }
    @State private var albumArtImage: UIImage?
    @State private var colors = Self.placeholderColors
    @State private var fingerprint: Data?
    @State private var generation = UUID()
    @State private var refreshWork: DispatchWorkItem?

    private static let placeholderColors: [Color] = [Color(white: 0.08), Color(white: 0.04), Color(white: 0.02)]
    private static let metalRendererSupported = KaraokeBackgroundRenderer.shared != nil

    var body: some View {
        Group {
            if let image = albumArtImage, Self.metalRendererSupported {
                KaraokeMetalBackgroundView().ignoresSafeArea().transition(.opacity)
            } else if let image = albumArtImage {
                TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { timeline in
                    GeometryReader { geometry in
                        let time = timeline.date.timeIntervalSinceReferenceDate
                        ZStack {
                            Color(white: 0.04)
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .scaleEffect(1.35 + 0.03 * sin(time * 0.13))
                                .rotationEffect(.degrees(6 * sin(time * 0.11)))
                                .offset(x: 35 * sin(time * 0.17), y: 35 * cos(time * 0.14))
                                .blur(radius: 45)
                                .id(fingerprint).transition(.opacity)
                        }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                }.ignoresSafeArea()
            } else {
                TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    RadialGradient(colors: colors,
                        center: UnitPoint(x: 0.5 + 0.3 * sin(time * 0.13), y: 0.5 + 0.3 * cos(time * 0.09)),
                        startRadius: 20, endRadius: 500)
                        .ignoresSafeArea().background(Color.black)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { restart() }
        .onChange(of: trackId) { _ in restart() }
        .onDisappear { refreshWork?.cancel(); refreshWork = nil; generation = UUID() }
    }

    private func restart() {
        refreshWork?.cancel()
        generation = UUID()
        writeDebugLog("[Karaoke][background] refresh for track=\(trackId ?? "nil")")
        refresh(token: generation, attempt: 0)
    }

    private func refresh(token: UUID, attempt: Int) {
        guard token == generation else { return }
        let playing = KaraokePlaybackTracker.shared.playerReportedTrackId() ?? KaraokePlaybackTracker.shared.currentTrackId()
        guard playing == trackId else {
            refreshWork = nil
            return
        }
        if let image = AlbumArtLocator.currentAlbumArt(forTrackId: trackId),
           let signature = Self.signature(image), signature != fingerprint {
            Self.lastImage = image
            Self.lastFingerprint = signature
            if Self.metalRendererSupported { KaraokeBackgroundRenderer.shared?.setAlbumArt(image) }
            withAnimation(.easeInOut(duration: 1.6)) {
                fingerprint = signature
                albumArtImage = image
            }
            writeDebugLog("[Karaoke][background] updated artwork for track=\(trackId ?? "nil") attempt=\(attempt)")
            // Keep a slow refresh after startup: delayed artwork can replace an earlier cached image.
            if !Self.metalRendererSupported {
                DispatchQueue.global(qos: .userInitiated).async {
                    let extracted = AlbumArtColorExtractor.dominantColors(from: image, count: 3)
                    DispatchQueue.main.async {
                        guard token == generation, fingerprint == signature, extracted.count >= 2 else { return }
                        colors = extracted.map { Color($0) }
                    }
                }
            }
        }
        let work = DispatchWorkItem { refresh(token: token, attempt: attempt + 1) }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt < 10 ? 0.3 : 2), execute: work)
    }

    private static func signature(_ image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 8, height: 8, bitsPerComponent: 8,
                bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            return true
        }
        return rendered ? Data(bytes) : nil
    }
}
