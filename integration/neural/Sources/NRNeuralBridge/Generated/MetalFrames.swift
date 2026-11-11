import Foundation
import MetalKit
import CoreVideo
import ScreenCore
import DLSSMLX

enum PortError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

enum ShaderLibrary {
    static func make(device: MTLDevice) throws -> MTLLibrary {
        // SwiftPM's generated accessor looks next to the executable or in its
        // original build directory. A distributable .app must use its own
        // Contents/Resources bundle, with no dependency on that build folder.
        let packaged = Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("DLSS_5_APPLE_SILICON_NeuralScreenMac.bundle"))
        }
        let resources = packaged ?? Bundle.module
        guard let url = resources.url(forResource: "Shaders", withExtension: "metal") else {
            throw PortError.message("Shaders.metal was not found in the application resources.")
        }
        return try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
    }
}

/// Immutable ownership only; completion handlers never read or mutate pixels.
struct RetainedMetalResources: @unchecked Sendable {
    let buffers: [CVPixelBuffer]
    let textures: [CVMetalTexture]
}

/// Accessed serially by RenderEngine. Every buffer uses IOSurface storage so
/// capture, MLX, Metal presentation and the encoder can share retained frames.
final class MetalFrames {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let resizeState: MTLComputePipelineState
    private let compositeState: MTLComputePipelineState
    private var cache: CVMetalTextureCache
    private var pools = [String: CVPixelBufferPool]()

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw PortError.message("An Apple Metal GPU is not available.")
        }
        self.device = device; self.queue = queue
        let library = try ShaderLibrary.make(device: device)
        resizeState = try device.makeComputePipelineState(function: library.makeFunction(name: "resizeFrame")!)
        compositeState = try device.makeComputePipelineState(function: library.makeFunction(name: "compositeFrame")!)
        var created: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &created) == kCVReturnSuccess, let created else {
            throw PortError.message("Could not create the Metal texture cache.")
        }
        cache = created
    }

    func allocate(_ size: FrameSize, half: Bool = false) throws -> CVPixelBuffer {
        let key = "\(size.width)x\(size.height)-\(half)"
        if pools[key] == nil {
            var pool: CVPixelBufferPool?
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
                kCVPixelBufferPixelFormatTypeKey as String: half ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
                throw PortError.message("Could not allocate buffer \(key).")
            }
            // A resize must not retain pools for every intermediate geometry.
            if pools.count >= 6 { pools.removeAll(); CVMetalTextureCacheFlush(cache, 0) }
            pools[key] = pool
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pools[key]!, &buffer) == kCVReturnSuccess, let buffer else {
            throw PortError.message("Could not obtain a frame from the buffer pool.")
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return buffer
    }

    func texture(_ buffer: CVPixelBuffer) throws -> (CVMetalTexture, MTLTexture) {
        let format: MTLPixelFormat = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_64RGBAHalf ? .rgba16Float : .bgra8Unorm
        var wrapper: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &wrapper) == kCVReturnSuccess,
              let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else {
            throw PortError.message("Could not import the pixel buffer into Metal.")
        }
        return (wrapper, texture)
    }

    func resize(_ buffer: CVPixelBuffer, to size: FrameSize) async throws -> MLXPixelBuffer {
        let output = try allocate(size)
        try await dispatch(resizeState, buffers: [buffer, output], output: size)
        return MLXPixelBuffer(output)
    }

    func composite(original: CVPixelBuffer, input: CVPixelBuffer, processed: CVPixelBuffer, split: Float) async throws -> MLXPixelBuffer {
        let size = FrameSize(CVPixelBufferGetWidth(original), CVPixelBufferGetHeight(original))
        let output = try allocate(size)
        try await dispatch(compositeState, buffers: [original, input, processed, output], output: size, split: split)
        return MLXPixelBuffer(output)
    }

    private func dispatch(_ state: MTLComputePipelineState, buffers: [CVPixelBuffer], output: FrameSize, split: Float? = nil) async throws {
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw PortError.message("Could not create the Metal command buffer.")
        }
        let textures = try buffers.map(texture)
        encoder.setComputePipelineState(state)
        for (index, pair) in textures.enumerated() { encoder.setTexture(pair.1, index: index) }
        if var split { encoder.setBytes(&split, length: MemoryLayout<Float>.size, index: 0) }
        encoder.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        let retained = RetainedMetalResources(buffers: buffers, textures: textures.map { $0.0 })
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { completed in
                withExtendedLifetime(retained) {
                    if let error = completed.error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            command.commit()
        }
    }
}
