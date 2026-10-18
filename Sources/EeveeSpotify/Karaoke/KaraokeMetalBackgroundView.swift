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
    private var transitionStart: CFTimeInterval = 0
    private let transitionDuration: CFTimeInterval = 0.9
    private static let imageContext = CIContext()
    private let startTime = CACurrentMediaTime()

    var warpIntensity: Float = 0.8

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
        if sourceImage === image { pendingImage = nil; return }
        guard let original = image.cgImage else { return }
        if albumTexture != nil, CACurrentMediaTime() - transitionStart < transitionDuration {
            pendingImage = image
            return
        }
        let input = CIImage(cgImage: original)
        let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: Double(original.width) * 0.08
        ]).cropped(to: input.extent)
        let cgImage = Self.imageContext.createCGImage(blurred, from: input.extent) ?? original
        let loader = MTKTextureLoader(device: device)
        guard let next = try? loader.newTexture(cgImage: cgImage, options: [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        ]) else {
            writeDebugLog("[Karaoke][background] texture upload failed; keeping previous artwork")
            return
        }
        previousTexture = albumTexture
        albumTexture = next
        sourceImage = image
        transitionStart = previousTexture == nil ? CACurrentMediaTime() - transitionDuration : CACurrentMediaTime()
        writeDebugLog("[Karaoke][background] animated artwork blend started")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let albumTexture = albumTexture,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        let blend = Float(min(1, max(0, (CACurrentMediaTime() - transitionStart) / transitionDuration)))
        var params = KaraokeBgParamsMirror(
            time: Float(CACurrentMediaTime() - startTime),
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
            previousTexture = nil
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
    let albumArt: UIImage

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.preferredFramesPerSecond = 30 // matches the lyrics TimelineView's rate; no need to run faster
        view.enableSetNeedsDisplay = false
        view.isPaused = false

        guard let renderer = KaraokeBackgroundRenderer.shared else {
            writeDebugLog("[Karaoke][background] animated bitmap fallback active")
            return view
        }
        view.device = renderer.device
        renderer.setAlbumArt(albumArt)
        view.delegate = renderer
        context.coordinator.renderer = renderer
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.setAlbumArt(albumArt)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: KaraokeBackgroundRenderer?
    }
}
