import Foundation
import CoreVideo
import DLSSCore
import DLSSMLX
import DLSSMedia
import ScreenCore

struct CapturedFrame: @unchecked Sendable {
    let pixels: CVPixelBuffer
    let capturedAt: Double
}

struct RenderedFrame: @unchecked Sendable {
    let pixels: CVPixelBuffer
    let capturedAt: Double
    let milliseconds: Double
    let processingSize: FrameSize
    let neural: Bool
}

struct RenderStageTimings: Sendable {
    var resize: Double = 0
    var motion: Double = 0
    var inference: Double = 0
    var write: Double = 0
    var composite: Double = 0
}

actor RenderEngine {
    private(set) var lastTimings = RenderStageTimings()
    private let surfaces: MetalFrames
    private var renderer: MLXNeuralRenderingDeviceTemporalBackend?
    private var flow: NativeOpticalFlow?
    private var writer: MLXPixelBufferWriter?
    private var modelURL: URL?
    private var boundary: HistoryBoundary?
    private var index = 0
    private var streamID: UInt64 = 1
    private var lastTimestamp: Double = 0
    private var retainedResult: (timestamp: Double, boundary: HistoryBoundary, small: MLXPixelBuffer, processed: MLXPixelBuffer)?

    init() throws { surfaces = try MetalFrames() }

    func loadModel(_ url: URL) throws {
        let next = try MLXNeuralRenderingDeviceTemporalBackend(packageURL: url,
            executionMode: .metalFused, computePrecision: .float16)
        renderer = next; modelURL = url; invalidateHistory()
    }

    func invalidateHistory() {
        boundary = nil; flow = nil; writer = nil; retainedResult = nil
        index = 0; streamID &+= 1; lastTimestamp = 0
    }

    // Bridge adaptation: discard all frame history while keeping already
    // prepared writers and the optical-flow session for this same boundary.
    // A new stream ID/frame zero also resets the neural backend's history.
    func resetHistoryPreservingResources() async {
        retainedResult = nil
        index = 0; streamID &+= 1; lastTimestamp = 0
        await flow?.reset()
    }

    func process(_ frame: CapturedFrame, settings: RenderSettings) async throws -> RenderedFrame {
        let begin = ProcessInfo.processInfo.systemUptime
        lastTimings = RenderStageTimings()
        let size = FrameSize(CVPixelBufferGetWidth(frame.pixels), CVPixelBufferGetHeight(frame.pixels))
        let work = size.processing(longEdge: settings.processingLongEdge)
        guard settings.neuralEnabled, settings.intensity > 0 else {
            if index > 0 { await resetHistoryPreservingResources() }
            return RenderedFrame(pixels: frame.pixels, capturedAt: frame.capturedAt,
                                 milliseconds: 0, processingSize: work, neural: false)
        }
        guard let renderer else { throw PortError.message("NR.dlss has not finished loading.") }
        let next = HistoryBoundary(size: work, settings: settings)
        if let retained = retainedResult, retained.timestamp == frame.capturedAt, retained.boundary == next {
            let output = try await surfaces.composite(original: frame.pixels, input: retained.small.buffer,
                                                       processed: retained.processed.buffer, split: settings.split)
            return RenderedFrame(pixels: output.buffer, capturedAt: frame.capturedAt,
                milliseconds: (ProcessInfo.processInfo.systemUptime - begin) * 1000, processingSize: work, neural: true)
        }
        if next.size != boundary?.size || next.temporal != boundary?.temporal {
            // Only geometry and temporal-mode changes rebuild GPU resources.
            invalidateHistory(); boundary = next
            writer = try MLXPixelBufferWriter(width: work.width, height: work.height, halfOutput: true)
            if settings.temporal { flow = try NativeOpticalFlow(width: work.width, height: work.height) }
        } else if next != boundary {
            // Sliders reset history, not writer/optical-flow allocation.
            await resetHistoryPreservingResources(); boundary = next
        } else if index > 0 && frame.capturedAt - lastTimestamp > 0.5 {
            // A pause invalidates frame history, not the prepared GPU/session.
            // After an explicit reset, timestamp zero is only a sentinel.
            await resetHistoryPreservingResources()
        }
        lastTimestamp = frame.capturedAt
        let resizeBegin = ProcessInfo.processInfo.systemUptime
        let small = try await surfaces.resize(frame.pixels, to: work)
        let rgb = try MLXVideoFrame(pixelBuffer: small)
        lastTimings.resize = (ProcessInfo.processInfo.systemUptime - resizeBegin) * 1000
        let motionBegin = ProcessInfo.processInfo.systemUptime
        let motion = try await flow?.prepare(rgb, index: index, sceneCutThreshold: 0.3)
        lastTimings.motion = (ProcessInfo.processInfo.systemUptime - motionBegin) * 1000
        let profile = NeuralRenderingControlProfile(rawValue: settings.profile) ?? .natural
        let controls = NeuralRenderingFeatureControls(normalizedStyle: Float(profile.styleIndex) / 128,
            localToneStrength: settings.tone, localStructureStrength: settings.structure)
        let inferenceBegin = ProcessInfo.processInfo.systemUptime
        let result = try await renderer.renderVideoFrame(rgb, motion: motion,
            context: NeuralRenderFrameContext(streamID: streamID, frameIndex: UInt64(index)),
            processingScale: 1, temporal: settings.temporal,
            outputOptions: MLXVideoOutputOptions(width: work.width, height: work.height,
                                                 detailStrength: 1, colourStrength: 1),
            featureControls: controls, intensity: settings.intensity)
        lastTimings.inference = (ProcessInfo.processInfo.systemUptime - inferenceBegin) * 1000
        index += 1
        let writeBegin = ProcessInfo.processInfo.systemUptime
        let processed = try await writer!.write(result)
        lastTimings.write = (ProcessInfo.processInfo.systemUptime - writeBegin) * 1000
        retainedResult = (frame.capturedAt, next, small, processed)
        let compositeBegin = ProcessInfo.processInfo.systemUptime
        let output = try await surfaces.composite(original: frame.pixels, input: small.buffer,
                                                 processed: processed.buffer, split: settings.split)
        lastTimings.composite = (ProcessInfo.processInfo.systemUptime - compositeBegin) * 1000
        return RenderedFrame(pixels: output.buffer, capturedAt: frame.capturedAt,
            milliseconds: (ProcessInfo.processInfo.systemUptime - begin) * 1000,
            processingSize: work, neural: true)
    }
}
