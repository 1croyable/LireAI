import MetalKit
import MetalPerformanceShaders
import UIKit

/// A single paper mesh. Every vertex keeps its original page UV while the
/// crease and reflected edge are derived from the same A-to-P constraint.
@MainActor
final class PageCurlMetalView: MTKView, MTKViewDelegate {
    private struct Vertex {
        var position: SIMD4<Float>
        var textureInfo: SIMD4<Float>
    }

    private struct ShadowUniforms {
        var fold: SIMD4<Float> = .zero       // midpoint, normal
        var edge: SIMD4<Float> = .zero       // finger, initial y, opacity
        var viewport: SIMD4<Float> = .zero   // width, height, render mode
        var paper = SIMD4<Float>(0.949, 0.937, 0.910, 1)
        var surface: SIMD4<Float> = .zero    // reserved x/y/z, active flag
    }

    private final class CachedTexture: NSObject {
        let texture: MTLTexture
        init(_ texture: MTLTexture) { self.texture = texture }
    }

    private static let columns = 64
    private static let rows = 96
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let shadowDepthState: MTLDepthStencilState
    private let shadowBlur: MPSImageGaussianBlur
    private let textureLoader: MTKTextureLoader
    private let textures = NSCache<UIImage, CachedTexture>()
    private let backgroundVertices: MTLBuffer
    private let indices: MTLBuffer
    private let indexCount: Int
    private let pageVertices: MTLBuffer
    private var backgroundTexture: MTLTexture?
    private var pageTexture: MTLTexture?
    private var shadowMaskTexture: MTLTexture?
    private var blurredShadowTexture: MTLTexture?
    private var shadowMaskDepthTexture: MTLTexture?
    private var pageOpacity: Float = 1
    private var shadows = ShadowUniforms()
    var isReady: Bool { backgroundTexture != nil && pageTexture != nil }

    init?(curlFrame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("LireAI page curl: Metal device unavailable")
            return nil
        }
        let bundledLibrary = try? device.makeDefaultLibrary(bundle: .main)
        guard let library = bundledLibrary ?? device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "pageCurlVertex"),
              let fragment = library.makeFunction(name: "pageCurlFragment"),
              let queue = device.makeCommandQueue() else {
            NSLog("LireAI page curl: shader library or command queue unavailable")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float
        if let color = descriptor.colorAttachments[0] {
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .sourceAlpha
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        let compiledPipeline: MTLRenderPipelineState
        do { compiledPipeline = try device.makeRenderPipelineState(descriptor: descriptor) }
        catch {
            NSLog("LireAI page curl: pipeline creation failed: %@", String(describing: error))
            return nil
        }
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        let shadowDepth = MTLDepthStencilDescriptor()
        shadowDepth.depthCompareFunction = .always
        shadowDepth.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: depth),
              let shadowDepthState = device.makeDepthStencilState(descriptor: shadowDepth) else { return nil }

        let quad: [Vertex] = [
            Vertex(position: SIMD4(-1, 1, 0.95, 0), textureInfo: SIMD4(0, 0, 0, 1)),
            Vertex(position: SIMD4(1, 1, 0.95, 0), textureInfo: SIMD4(1, 0, 0, 1)),
            Vertex(position: SIMD4(-1, -1, 0.95, 0), textureInfo: SIMD4(0, 1, 0, 1)),
            Vertex(position: SIMD4(1, 1, 0.95, 0), textureInfo: SIMD4(1, 0, 0, 1)),
            Vertex(position: SIMD4(1, -1, 0.95, 0), textureInfo: SIMD4(1, 1, 0, 1)),
            Vertex(position: SIMD4(-1, -1, 0.95, 0), textureInfo: SIMD4(0, 1, 0, 1))
        ]
        guard let backgroundVertices = device.makeBuffer(bytes: quad,
                                                        length: quad.count * MemoryLayout<Vertex>.stride) else { return nil }
        var triangleIndices: [UInt16] = []
        triangleIndices.reserveCapacity(Self.columns * Self.rows * 6)
        for row in 0..<Self.rows {
            for column in 0..<Self.columns {
                let a = UInt16(row * (Self.columns + 1) + column)
                let b = a + 1
                let c = a + UInt16(Self.columns + 1)
                triangleIndices.append(contentsOf: [a, b, c, b, c + 1, c])
            }
        }
        var paperMesh: [Vertex] = []
        paperMesh.reserveCapacity((Self.columns + 1) * (Self.rows + 1))
        for row in 0...Self.rows {
            let v = Float(row) / Float(Self.rows)
            for column in 0...Self.columns {
                let u = Float(column) / Float(Self.columns)
                paperMesh.append(Vertex(position: SIMD4(u, v, 0, 1),
                                        textureInfo: SIMD4(u, v, 0, 1)))
            }
        }
        guard let indices = device.makeBuffer(bytes: triangleIndices,
                                              length: triangleIndices.count * MemoryLayout<UInt16>.stride),
              let pageVertices = device.makeBuffer(bytes: paperMesh,
                                                   length: paperMesh.count * MemoryLayout<Vertex>.stride) else { return nil }

        self.queue = queue
        self.pipeline = compiledPipeline
        self.depthState = depthState
        self.shadowDepthState = shadowDepthState
        self.shadowBlur = MPSImageGaussianBlur(device: device, sigma: 9)
        self.textureLoader = MTKTextureLoader(device: device)
        self.backgroundVertices = backgroundVertices
        self.indices = indices
        self.indexCount = triangleIndices.count
        self.pageVertices = pageVertices
        super.init(frame: curlFrame, device: device)
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        clearColor = MTLClearColor(red: 0.985, green: 0.973, blue: 0.941, alpha: 1)
        framebufferOnly = true
        isOpaque = true
        isUserInteractionEnabled = false
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        textures.totalCostLimit = 48 * 1024 * 1024
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Use frame initializer") }

    /// Allocate expensive render targets before the first finger-down so the
    /// initial curl does not pay for Metal texture allocation and blur setup.
    func warmUp(scale explicitScale: CGFloat? = nil) {
        let scale = max(1, explicitScale ?? window?.screen.scale ?? traitCollection.displayScale)
        if bounds.width > 0, bounds.height > 0 {
            contentScaleFactor = scale
            drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        }
        _ = prepareShadowTargets()
    }

    func preload(_ images: [UIImage]) {
        for image in images { _ = texture(for: image) }
    }

    func purgeTextureCache() {
        textures.removeAllObjects()
    }

    func setPaperColor(_ color: UIColor) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
        shadows.paper = SIMD4(Float(red), Float(green), Float(blue), Float(alpha))
        clearColor = MTLClearColor(red: Double(red), green: Double(green),
                                   blue: Double(blue), alpha: Double(alpha))
    }

    @discardableResult
    func prepare(current: UIImage, target: UIImage, forward: Bool) -> Bool {
        let background = forward ? target : current
        let moving = forward ? current : target
        backgroundTexture = texture(for: background)
        pageTexture = texture(for: moving)
        return isReady
    }

    func replaceDestination(_ image: UIImage, forward: Bool) {
        guard forward else { return }
        backgroundTexture = texture(for: image)
        setNeedsDisplay()
    }

    private func texture(for image: UIImage) -> MTLTexture? {
        if let cached = textures.object(forKey: image) { return cached.texture }
        guard let pixels = image.cgImage, let device else { return nil }
        let options: [MTKTextureLoader.Option: Any] = [
            .origin: MTKTextureLoader.Origin.topLeft,
            .SRGB: false,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue
        ]
        let texture: MTLTexture
        do { texture = try textureLoader.newTexture(cgImage: pixels, options: options) }
        catch {
            NSLog("LireAI page curl: texture loader failed; using BGRA upload: %@", String(describing: error))
            guard let uploaded = uploadBGRA(pixels, device: device) else { return nil }
            texture = uploaded
        }
        textures.setObject(CachedTexture(texture), forKey: image,
                           cost: texture.width * texture.height * 4)
        return texture
    }

    private func uploadBGRA(_ image: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        let rowBytes = width * 4
        var pixels = Data(count: rowBytes * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: rowBytes,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                                              CGImageAlphaInfo.premultipliedFirst.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: address, bytesPerRow: rowBytes)
        }
        return texture
    }

    private func prepareShadowTargets() -> Bool {
        guard let device else { return false }
        let width = max(1, Int(ceil(drawableSize.width * 0.5)))
        let height = max(1, Int(ceil(drawableSize.height * 0.5)))
        if shadowMaskTexture?.width == width,
           shadowMaskTexture?.height == height,
           blurredShadowTexture?.width == width,
           blurredShadowTexture?.height == height,
           shadowMaskDepthTexture?.width == width,
           shadowMaskDepthTexture?.height == height { return true }

        let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorPixelFormat, width: width, height: height,
            mipmapped: false)
        maskDescriptor.storageMode = .private
        maskDescriptor.usage = [.renderTarget, .shaderRead]
        let blurredDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorPixelFormat, width: width, height: height,
            mipmapped: false)
        blurredDescriptor.storageMode = .private
        blurredDescriptor.usage = [.shaderRead, .shaderWrite]
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: depthStencilPixelFormat, width: width, height: height,
            mipmapped: false)
        depthDescriptor.storageMode = .private
        depthDescriptor.usage = .renderTarget
        shadowMaskTexture = device.makeTexture(descriptor: maskDescriptor)
        blurredShadowTexture = device.makeTexture(descriptor: blurredDescriptor)
        shadowMaskDepthTexture = device.makeTexture(descriptor: depthDescriptor)
        return shadowMaskTexture != nil && blurredShadowTexture != nil
            && shadowMaskDepthTexture != nil
    }

    func update(finger: CGPoint, initialY: CGFloat, forward: Bool, opacity: CGFloat,
                constrainTurnAtSpine: Bool = true) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let width = Float(bounds.width)
        let height = Float(bounds.height)

        let fold = PaperFoldGeometry.make(size: bounds.size,
                                          initialY: initialY,
                                          finger: finger,
                                          constrainTurnAtSpine: forward && constrainTurnAtSpine)
        let radius = Float(PaperFoldGeometry.curlRadius(for: fold.distance))
        let curlMidpoint = fold.surfaceMidpoint(radius: CGFloat(radius))
        shadows.fold = SIMD4(Float(curlMidpoint.x), Float(curlMidpoint.y),
                             Float(fold.normal.dx), Float(fold.normal.dy))
        shadows.edge = SIMD4(Float(fold.finger.x), Float(fold.finger.y),
                             Float(fold.initialY), Float(opacity))
        shadows.viewport = SIMD4(width, height, 1, radius)
        shadows.surface = SIMD4(0, 0, 0, fold.distance >= 1 ? 1 : 0)
        pageOpacity = Float(opacity)
        shadows.edge.w = pageOpacity
        setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let backgroundTexture, let pageTexture,
              let command = queue.makeCommandBuffer(), prepareShadowTargets(),
              let shadowMaskTexture, let blurredShadowTexture,
              let shadowMaskDepthTexture else { return }

        let maskPass = MTLRenderPassDescriptor()
        maskPass.colorAttachments[0].texture = shadowMaskTexture
        maskPass.colorAttachments[0].loadAction = .clear
        maskPass.colorAttachments[0].storeAction = .store
        maskPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        maskPass.depthAttachment.texture = shadowMaskDepthTexture
        maskPass.depthAttachment.loadAction = .clear
        maskPass.depthAttachment.storeAction = .dontCare
        maskPass.depthAttachment.clearDepth = 1
        guard let maskEncoder = command.makeRenderCommandEncoder(descriptor: maskPass) else { return }
        maskEncoder.setRenderPipelineState(pipeline)
        maskEncoder.setCullMode(.none)
        maskEncoder.setDepthStencilState(shadowDepthState)
        maskEncoder.setVertexBuffer(pageVertices, offset: 0, index: 0)
        maskEncoder.setFragmentTexture(pageTexture, index: 0)
        maskEncoder.setFragmentTexture(pageTexture, index: 1)
        var maskAlpha = pageOpacity
        maskEncoder.setFragmentBytes(&maskAlpha,
                                     length: MemoryLayout<Float>.stride,
                                     index: 0)
        var maskUniforms = shadows
        maskUniforms.viewport.z = 2
        maskEncoder.setVertexBytes(&maskUniforms,
                                   length: MemoryLayout<ShadowUniforms>.stride,
                                   index: 2)
        maskEncoder.setFragmentBytes(&maskUniforms,
                                     length: MemoryLayout<ShadowUniforms>.stride,
                                     index: 1)
        maskEncoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: indexCount,
                                          indexType: .uint16,
                                          indexBuffer: indices,
                                          indexBufferOffset: 0)
        maskEncoder.endEncoding()

        shadowBlur.encode(commandBuffer: command,
                          sourceTexture: shadowMaskTexture,
                          destinationTexture: blurredShadowTexture)

        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)

        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(backgroundVertices, offset: 0, index: 0)
        encoder.setFragmentTexture(backgroundTexture, index: 0)
        encoder.setFragmentTexture(blurredShadowTexture, index: 1)
        var backgroundAlpha: Float = 1
        encoder.setFragmentBytes(&backgroundAlpha,
                                 length: MemoryLayout<Float>.stride,
                                 index: 0)
        var backgroundShadows = shadows
        backgroundShadows.viewport.z = 1
        encoder.setVertexBytes(&backgroundShadows,
                               length: MemoryLayout<ShadowUniforms>.stride,
                               index: 2)
        encoder.setFragmentBytes(&backgroundShadows,
                                 length: MemoryLayout<ShadowUniforms>.stride,
                                 index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        encoder.setDepthStencilState(shadowDepthState)
        encoder.setVertexBuffer(backgroundVertices, offset: 0, index: 0)
        encoder.setFragmentTexture(blurredShadowTexture, index: 0)
        var shadowAlpha: Float = 1
        encoder.setFragmentBytes(&shadowAlpha,
                                 length: MemoryLayout<Float>.stride,
                                 index: 0)
        var paperShadow = shadows
        paperShadow.viewport.z = 3
        paperShadow.surface.y = 0.2
        encoder.setVertexBytes(&paperShadow,
                               length: MemoryLayout<ShadowUniforms>.stride,
                               index: 2)
        encoder.setFragmentBytes(&paperShadow,
                                 length: MemoryLayout<ShadowUniforms>.stride,
                                 index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(pageVertices, offset: 0, index: 0)
        encoder.setFragmentTexture(pageTexture, index: 0)
        var initialPageAlpha = pageOpacity
        encoder.setFragmentBytes(&initialPageAlpha,
                                 length: MemoryLayout<Float>.stride,
                                 index: 0)
        var initialPaper = shadows
        initialPaper.viewport.z = 0
        encoder.setVertexBytes(&initialPaper,
                               length: MemoryLayout<ShadowUniforms>.stride,
                               index: 2)
        encoder.setFragmentBytes(&initialPaper,
                                 length: MemoryLayout<ShadowUniforms>.stride,
                                 index: 1)
        encoder.drawIndexedPrimitives(type: .triangle,
                                      indexCount: indexCount,
                                      indexType: .uint16,
                                      indexBuffer: indices,
                                      indexBufferOffset: 0)

        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        shadowMaskTexture = nil
        blurredShadowTexture = nil
        shadowMaskDepthTexture = nil
        _ = prepareShadowTargets()
    }
}
