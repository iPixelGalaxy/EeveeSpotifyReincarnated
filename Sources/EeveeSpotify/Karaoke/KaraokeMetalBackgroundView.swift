import SwiftUI
import MetalKit
import CoreImage
import EeveeSpotifyC

/// Renders the album-art domain-warp background using the Metal shader in
/// KaraokeBackgroundShader.metal — the native equivalent of the real
/// extension's Kawarp (WebGL Kawase blur + simplex domain warp).
///
/// Returns nil from init if Metal setup fails for any reason (e.g.
/// simulator without Metal support, shader compile issue) — callers
/// should fall back to the placeholder gradient rather than crash.
final class KaraokeBackgroundRenderer: NSObject, MTKViewDelegate {
    static let shared: KaraokeBackgroundRenderer? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return KaraokeBackgroundRenderer(device: device)
    }()
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var albumTexture: MTLTexture?
    private var sourceImage: UIImage?
    private var previousTexture: MTLTexture?
    private var pendingImage: UIImage?
    private var loadingImage: UIImage?
    private var loadingToken = UUID()
    private static let textureQueue = DispatchQueue(label: "com.eevee.karaoke.texture", qos: .userInitiated)
    private var transitionElapsed: CFTimeInterval = 0
    private var lastFrameStamp: CFTimeInterval?
    private var loggedTransitionMidpoint = false
    private let transitionDuration: CFTimeInterval = 1.6
    private static let imageContext = CIContext()
    private let startTime = CACurrentMediaTime()

    var warpIntensity: Float = 1.0

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        // The injected resource bundle travels with both sideloaded and jailbreak builds.
        let resourceBundle = Bundle.main.url(forResource: "EeveeSpotify", withExtension: "bundle")
            .flatMap { Bundle(url: $0) }
        let metallibPath = resourceBundle?.path(forResource: "KaraokeBackgroundShader", ofType: "metallib")
            ?? EeveeJBRootPath("/Library/Application Support/EeveeSpotify.bundle/KaraokeBackgroundShader.metallib")
        guard let library = try? device.makeLibrary(filepath: metallibPath),
              let vertexFn = library.makeFunction(name: "karaoke_bg_vertex"),
              let fragmentFn = library.makeFunction(name: "karaoke_bg_fragment") else {
            writeDebugLog("[Karaoke] Metal shader library not found at \(metallibPath) — falling back to placeholder background")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            writeDebugLog("[Karaoke] Metal pipeline state creation failed — falling back to placeholder background")
            return nil
        }
        self.pipelineState = pipeline
        super.init()
    }

    func setAlbumArt(_ image: UIImage) {
        if sourceImage === image {
            pendingImage = nil; loadingImage = nil; loadingToken = UUID()
            return
        }
        guard let original = image.cgImage, loadingImage !== image, pendingImage !== image else { return }
        if previousTexture != nil, transitionElapsed < transitionDuration {
            pendingImage = image
            return
        }
        // The first view is prepared before presentation; subsequent uploads leave its flow running.
        if albumTexture == nil {
            if let texture = Self.prepareTexture(original, device: device) { install(texture, image: image) }
            return
        }
        let token = UUID(), device = device
        loadingToken = token; loadingImage = image
        Self.textureQueue.async { [weak self] in
            let texture = Self.prepareTexture(original, device: device)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadingToken == token else { return }
                self.loadingImage = nil
                if let texture { self.install(texture, image: image) }
                else { writeDebugLog("[Karaoke][background] texture upload failed; keeping previous artwork") }
            }
        }
    }

    private static func prepareTexture(_ original: CGImage, device: MTLDevice) -> MTLTexture? {
        let input = CIImage(cgImage: original)
        let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: Double(original.width) * 0.08
        ]).cropped(to: input.extent)
        let image = imageContext.createCGImage(blurred, from: input.extent) ?? original
        return try? MTKTextureLoader(device: device).newTexture(cgImage: image, options: [
            .SRGB: false, .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
        ])
    }

    private func install(_ texture: MTLTexture, image: UIImage) {
        previousTexture = albumTexture
        albumTexture = texture
        sourceImage = image
        transitionElapsed = previousTexture == nil ? transitionDuration : 0
        lastFrameStamp = nil
        loggedTransitionMidpoint = false
        writeDebugLog("[Karaoke][background] artwork ready; fade from previous=\(previousTexture != nil) duration=\(transitionDuration)")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func isVisible(_ view: MTKView) -> Bool {
        guard let window = view.window, view.convert(view.bounds, to: window).intersects(window.bounds) else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha <= 0.01 { return false }
            ancestor = current.superview
        }
        return true
    }

    func draw(in view: MTKView) {
        guard isVisible(view), let albumTexture = albumTexture,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        let now = CACurrentMediaTime()
        if previousTexture != nil {
            // Start on the first drawable frame. A hidden or stalled view must not consume the fade.
            if let lastFrameStamp { transitionElapsed += min(1.0 / 15.0, max(0, now - lastFrameStamp)) }
            lastFrameStamp = now
        }
        let blend = Float(min(1, max(0, transitionElapsed / transitionDuration)))
        if previousTexture != nil, blend >= 0.5, !loggedTransitionMidpoint {
            loggedTransitionMidpoint = true
            writeDebugLog("[Karaoke][background] rendering artwork fade midpoint")
        }
        var params = KaraokeBgParamsMirror(
            time: Float((CACurrentMediaTime() - startTime) * 0.1),
            warpIntensity: warpIntensity,
            blurRadius: 0.018,
            blendProgress: blend
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(albumTexture, index: 0)
        encoder.setFragmentTexture(previousTexture ?? albumTexture, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<KaraokeBgParamsMirror>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        if blend >= 1 {
            if previousTexture != nil { writeDebugLog("[Karaoke][background] artwork fade complete") }
            previousTexture = nil
            lastFrameStamp = nil
            if let pending = pendingImage {
                pendingImage = nil
                setAlbumArt(pending)
            }
        }
    }
}

/// Mirrors the Metal shader's KaraokeBgParams struct layout exactly — field
/// order and types must match the .metal file's struct for setFragmentBytes
/// to interpret the raw bytes correctly.
private struct KaraokeBgParamsMirror {
    var time: Float
    var warpIntensity: Float
    var blurRadius: Float
    var blendProgress: Float
}

/// SwiftUI wrapper around the MTKView + renderer.
struct KaraokeMetalBackgroundView: UIViewRepresentable {

    func makeUIView(context: Context) -> MTKView {
        let view = KaraokeMetalCanvas()
        view.preferredFramesPerSecond = 30 // matches the lyrics TimelineView's rate; no need to run faster
        view.autoResizeDrawable = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false

        guard let renderer = KaraokeBackgroundRenderer.shared else {
            writeDebugLog("[Karaoke][background] animated bitmap fallback active")
            return view
        }
        view.device = renderer.device
        view.delegate = renderer
        context.coordinator.renderer = renderer
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: KaraokeBackgroundRenderer?
    }
}

// Flowing blur needs a small render target; preserve GPU time for lyric frames.
private final class KaraokeMetalCanvas: MTKView {
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let width = min(384, bounds.width)
        let size = CGSize(width: width, height: max(1, (width * bounds.height / bounds.width).rounded()))
        if drawableSize != size { drawableSize = size }
    }
}
