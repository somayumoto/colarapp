#if os(iOS)
import CoreVideo
import MetalKit
import SwiftUI
import UIKit

/// One drawable and one render pass compare the same camera frame in both panels.
struct CameraMetalView: UIViewRepresentable {
    let frames: LatestFrameStore
    var mode: ColorMode
    var intensity: Float
    var demo: Bool
    var fill: Bool = true
    var onFailure: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(frames: frames, onFailure: onFailure)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0.025, 0.03, 0.045, 1)
        view.isOpaque = true
        view.layer.isOpaque = true
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        context.coordinator.configure(view)
        context.coordinator.update(mode: mode, intensity: intensity, demo: demo, fill: fill)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.onFailure = onFailure
        context.coordinator.update(mode: mode, intensity: intensity, demo: demo, fill: fill)
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.detach()
        uiView.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private let frames: LatestFrameStore
        private weak var view: MTKView?
        private var commandQueue: (any MTLCommandQueue)?
        private var pipeline: (any MTLRenderPipelineState)?
        private var textureCache: CVMetalTextureCache?
        private var dummyLuma: (any MTLTexture)?
        private var dummyChroma: (any MTLTexture)?
        private var redraw: DrawRequest?
        private let capacity = GPUCapacity()
        private var mode: ColorMode = .redAsBlue
        private var intensity: Float = 1
        private var demo = false
        private var fill = true
        private var invalidated = true
        private var lastFrameID: UInt64?
        private var lastRotation: Int32 = -1
        private var reportedFailure = false
        var onFailure: ((String) -> Void)?

        init(frames: LatestFrameStore, onFailure: ((String) -> Void)?) {
            self.frames = frames
            self.onFailure = onFailure
        }

        func configure(_ view: MTKView) {
            self.view = view
            let request = DrawRequest { [weak self, weak view] in
                guard self != nil else { return }
                view?.setNeedsDisplay()
            }
            redraw = request
            frames.setOnFrame { [weak request] in request?.request() }
            view.delegate = self

            do {
                guard let device = view.device,
                      let queue = device.makeCommandQueue(),
                      let library = device.makeDefaultLibrary(),
                      let vertex = library.makeFunction(name: "comparisonVertex"),
                      let fragment = library.makeFunction(name: "comparisonFragment") else {
                    throw RendererError.setup
                }
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertex
                descriptor.fragmentFunction = fragment
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                commandQueue = queue
                var cache: CVMetalTextureCache?
                guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
                      let cache else { throw RendererError.setup }
                textureCache = cache
                dummyLuma = Self.makeDummyTexture(device: device, format: .r8Unorm)
                dummyChroma = Self.makeDummyTexture(device: device, format: .rg8Unorm)
                guard dummyLuma != nil, dummyChroma != nil else { throw RendererError.setup }
            } catch {
                fail("映像表示を準備できませんでした。Metalに対応した端末で開き直してください。")
            }
            request.request()
        }

        func update(mode: ColorMode, intensity: Float, demo: Bool, fill: Bool) {
            let clamped = min(max(intensity, 0), 1)
            guard self.mode != mode || self.intensity != clamped || self.demo != demo || self.fill != fill || invalidated else { return }
            self.mode = mode
            self.intensity = clamped
            self.demo = demo
            self.fill = fill
            invalidated = true
            redraw?.request()
        }

        func detach() {
            frames.setOnFrame(nil)
            redraw?.invalidate()
            redraw = nil
            view = nil
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            invalidated = true
            redraw?.request()
        }

        func draw(in view: MTKView) {
            guard let pipeline, let commandQueue else { return }
            let frame = demo ? nil : frames.snapshot()
            let rotation = demo ? 0 : Self.rotation(for: view.window?.windowScene?.interfaceOrientation)
            guard invalidated || frame?.id != lastFrameID || rotation != lastRotation else { return }
            guard capacity.acquire() else { return }
            var submitted = false
            defer { if !submitted { _ = capacity.release() } }

            guard view.drawableSize.width > 0, view.drawableSize.height > 0,
                  let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let command = commandQueue.makeCommandBuffer() else { return }

            let textures: CameraTextures?
            if let frame {
                do { textures = try makeTextures(frame) }
                catch {
                    fail("カメラ映像の形式を表示できませんでした。画質を変更するか、アプリを開き直してください。")
                    return
                }
            } else {
                textures = nil
            }

            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            command.label = "Same-frame color comparison"
            encoder.label = "YCbCr conversion + color mapping + split preview"
            if demo || textures != nil {
                var uniforms = Self.uniforms(
                    pixelBuffer: frame?.pixelBuffer,
                    viewport: view.drawableSize,
                    mode: mode,
                    intensity: intensity,
                    rotation: rotation,
                    demo: demo,
                    fill: fill
                )
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ComparisonUniforms>.stride, index: 0)
                encoder.setFragmentTexture(textures?.luma ?? dummyLuma, index: 0)
                encoder.setFragmentTexture(textures?.chroma ?? dummyChroma, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            encoder.endEncoding()
            command.present(drawable)

            let capacity = self.capacity
            let request = redraw
            // CVMetalTexture wrappers and their source buffer must outlive GPU sampling.
            command.addCompletedHandler { [textures, capacity, request, weak self] completed in
                withExtendedLifetime(textures) {}
                if capacity.release() { request?.request() }
                if completed.status == .error {
                    DispatchQueue.main.async { [weak self] in
                        self?.fail("映像の描画中にエラーが発生しました。アプリを開き直してください。")
                    }
                }
            }
            command.commit()
            submitted = true
            invalidated = false
            lastFrameID = frame?.id
            lastRotation = rotation
        }

        private func makeTextures(_ frame: CameraFrame) throws -> CameraTextures {
            guard let textureCache else { throw RendererError.setup }
            let buffer = frame.pixelBuffer
            let format = CVPixelBufferGetPixelFormatType(buffer)
            guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                  CVPixelBufferGetPlaneCount(buffer) == 2 else { throw RendererError.pixelFormat }
            var luma: CVMetalTexture?
            var chroma: CVMetalTexture?
            let yResult = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, buffer, nil, .r8Unorm,
                CVPixelBufferGetWidthOfPlane(buffer, 0), CVPixelBufferGetHeightOfPlane(buffer, 0), 0, &luma
            )
            let cResult = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, buffer, nil, .rg8Unorm,
                CVPixelBufferGetWidthOfPlane(buffer, 1), CVPixelBufferGetHeightOfPlane(buffer, 1), 1, &chroma
            )
            guard yResult == kCVReturnSuccess, cResult == kCVReturnSuccess,
                  let luma, let chroma,
                  let yTexture = CVMetalTextureGetTexture(luma),
                  let cTexture = CVMetalTextureGetTexture(chroma) else { throw RendererError.pixelFormat }
            return CameraTextures(pixelBuffer: buffer, lumaWrapper: luma, chromaWrapper: chroma, luma: yTexture, chroma: cTexture)
        }

        private static func makeDummyTexture(device: any MTLDevice, format: MTLPixelFormat) -> (any MTLTexture)? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            let bytes: [UInt8] = [0, 128]
            bytes.withUnsafeBytes { data in
                texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: data.baseAddress!, bytesPerRow: format == .r8Unorm ? 1 : 2)
            }
            return texture
        }

        private static func rotation(for orientation: UIInterfaceOrientation?) -> Int32 {
            switch orientation {
            case .landscapeRight: return 0
            case .landscapeLeft: return 2
            case .portraitUpsideDown: return 3
            default: return 1
            }
        }

        private static func uniforms(pixelBuffer: CVPixelBuffer?, viewport: CGSize, mode: ColorMode, intensity: Float, rotation: Int32, demo: Bool, fill: Bool) -> ComparisonUniforms {
            let width = pixelBuffer.map(CVPixelBufferGetWidth) ?? 1280
            let height = pixelBuffer.map(CVPixelBufferGetHeight) ?? 720
            let fullRange = pixelBuffer.map { CVPixelBufferGetPixelFormatType($0) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange } ?? true
            let matrix = pixelBuffer.flatMap { CVBufferCopyAttachment($0, kCVImageBufferYCbCrMatrixKey, nil) as? String }
            let redCr: Float
            let greenCb: Float
            let greenCr: Float
            let blueCb: Float
            if matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) || (matrix == nil && width < 1280) {
                (redCr, greenCb, greenCr, blueCb) = (1.402, -0.344136, -0.714136, 1.772)
            } else if matrix == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) {
                (redCr, greenCb, greenCr, blueCb) = (1.4746, -0.164553, -0.571353, 1.8814)
            } else {
                (redCr, greenCb, greenCr, blueCb) = (1.5748, -0.187324, -0.468124, 1.8556)
            }
            return ComparisonUniforms(
                viewportSize: SIMD2(Float(viewport.width), Float(viewport.height)),
                sourceSize: SIMD2(Float(width), Float(height)),
                range: SIMD4(fullRange ? 0 : 16 / 255, fullRange ? 1 : 255 / 219, 128 / 255, fullRange ? 1 : 255 / 224),
                coefficients: SIMD4(redCr, greenCb, greenCr, blueCb),
                flags: SIMD4(Int32(mode.rawValue), rotation, demo ? 1 : 0, fill ? 1 : 0),
                parameters: SIMD4(intensity, 0, 0, 0)
            )
        }

        private func fail(_ message: String) {
            guard !reportedFailure else { return }
            reportedFailure = true
            // Defer state mutation until outside UIViewRepresentable's update transaction.
            DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
        }
    }
}

/// Layout matches ComparisonUniforms in ColorShaders.metal (80 bytes).
nonisolated struct ComparisonUniforms {
    var viewportSize: SIMD2<Float>
    var sourceSize: SIMD2<Float>
    var range: SIMD4<Float>
    var coefficients: SIMD4<Float>
    var flags: SIMD4<Int32>
    var parameters: SIMD4<Float>
}

private nonisolated enum RendererError: Error { case setup, pixelFormat }

private nonisolated final class CameraTextures: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let lumaWrapper: CVMetalTexture
    let chromaWrapper: CVMetalTexture
    let luma: any MTLTexture
    let chroma: any MTLTexture

    init(pixelBuffer: CVPixelBuffer, lumaWrapper: CVMetalTexture, chromaWrapper: CVMetalTexture, luma: any MTLTexture, chroma: any MTLTexture) {
        self.pixelBuffer = pixelBuffer
        self.lumaWrapper = lumaWrapper
        self.chromaWrapper = chromaWrapper
        self.luma = luma
        self.chroma = chroma
    }
}

/// Coalesces capture-queue notifications into at most one pending main-queue update.
private nonisolated final class DrawRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var active = true
    private let draw: @MainActor @Sendable () -> Void

    init(draw: @escaping @MainActor @Sendable () -> Void) { self.draw = draw }

    func request() {
        lock.lock()
        guard active, !pending else { lock.unlock(); return }
        pending = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pending = false
            let active = self.active
            self.lock.unlock()
            if active { self.draw() }
        }
    }

    func invalidate() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

/// Never waits on the main/capture queues, and never puts more than two frames on the GPU.
private nonisolated final class GPUCapacity: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var needsRedraw = false

    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count < 2 else { needsRedraw = true; return false }
        count += 1
        return true
    }

    func release() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count -= 1
        let redraw = needsRedraw
        needsRedraw = false
        return redraw
    }
}
#endif
