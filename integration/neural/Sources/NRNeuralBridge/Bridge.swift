import Foundation
import CoreVideo
import ScreenCore
import NRNeuralABI

private enum Status: Int32 {
    case ok = 0, busy = 1, invalidArgument = 2, notReady = 3, cancelled = 4, failed = 5, stale = 6
}
private enum State: Int32 { case uninitialized = 0, loading = 1, ready = 2, processing = 3, failed = 4 }

private struct FrameRequest: @unchecked Sendable {
    let pixels: CVPixelBuffer
    let timestamp: Double
    let generation: UInt64
    let settings: RenderSettings
    let callback: NRNeuralFrameCallback
    let context: UnsafeMutableRawPointer?
}
private enum Work: @unchecked Sendable {
    case initialize(String, NRNeuralInitializationCallback, UnsafeMutableRawPointer?)
    case process(FrameRequest)
}

private final class NeuralRuntime: @unchecked Sendable {
    static let shared = NeuralRuntime()
    // Completion and invalidate are serialized too: after invalidate returns,
    // no callback can start delivering an older generation. Recursive locking
    // allows a callback to retain its output and submit its next request.
    private let lock = NSRecursiveLock()
    private var state: State = .uninitialized
    private var generation: UInt64 = 0
    private var lastAcceptedTimestamp = -Double.infinity
    private var lastTimings: NRNeuralTimings?
    private var settings: RenderSettings = {
        var value = RenderSettings()
        value.processingLongEdge = 1920
        value.profile = "standard"
        value.intensity = 1; value.tone = 1; value.structure = 1; value.split = 0.5
        return value
    }()
    private let continuation: AsyncStream<Work>.Continuation

    private init() {
        let pair = AsyncStream<Work>.makeStream()
        continuation = pair.continuation
        // Exactly one consumer; RenderEngine may suspend for GPU completion,
        // but no other initialize/process can enter it in the meantime.
        Task.detached(priority: .userInitiated) { [self] in await run(pair.stream) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }
    var currentState: Int32 { locked { state.rawValue } }

    func initialize(_ path: String, callback: @escaping NRNeuralInitializationCallback,
                    context: UnsafeMutableRawPointer?) -> Int32 {
        locked {
            guard state != .loading && state != .processing else { return Status.busy.rawValue }
            guard path.hasPrefix("/") else { return Status.invalidArgument.rawValue }
            state = .loading; generation &+= 1; lastAcceptedTimestamp = -.infinity; lastTimings = nil
            continuation.yield(.initialize(path, callback, context))
            return Status.ok.rawValue
        }
    }

    func process(_ pixels: CVPixelBuffer, timestamp: Double,
                 callback: @escaping NRNeuralFrameCallback, context: UnsafeMutableRawPointer?) -> Int32 {
        locked {
            if state == .loading || state == .processing { return Status.busy.rawValue }
            guard state == .ready else { return Status.notReady.rawValue }
            guard timestamp.isFinite, timestamp >= 0,
                  CVPixelBufferGetWidth(pixels) > 0, CVPixelBufferGetHeight(pixels) > 0,
                  CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
                  CVPixelBufferGetIOSurface(pixels) != nil,
                  (CVBufferCopyAttachment(pixels, kCVImageBufferTransferFunctionKey, nil) as? String) == (kCVImageBufferTransferFunction_sRGB as String),
                  (CVBufferCopyAttachment(pixels, kCVImageBufferColorPrimariesKey, nil) as? String) == (kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
            else { return Status.invalidArgument.rawValue }
            guard timestamp > lastAcceptedTimestamp else { return Status.stale.rawValue }
            lastAcceptedTimestamp = timestamp
            state = .processing
            continuation.yield(.process(FrameRequest(pixels: pixels, timestamp: timestamp,
                generation: generation, settings: settings, callback: callback, context: context)))
            return Status.ok.rawValue
        }
    }

    func controls(intensity: Float, tone: Float, structure: Float, split: Float, longEdge: UInt32? = nil) -> Int32 {
        locked {
            guard state != .loading && state != .processing else { return Status.busy.rawValue }
            guard [intensity, tone, structure, split].allSatisfy(\.isFinite),
                  (0...2).contains(intensity), (0...2).contains(tone), (0...2).contains(structure),
                  (0...1).contains(split),
                  longEdge == nil || [640, 960, 1280, 1600, 1920].contains(longEdge!)
            else { return Status.invalidArgument.rawValue }
            let resolution = Int(longEdge ?? UInt32(settings.processingLongEdge))
            let historyChanged = settings.intensity != intensity || settings.tone != tone ||
                settings.structure != structure || settings.processingLongEdge != resolution
            settings.intensity = intensity; settings.tone = tone
            settings.structure = structure; settings.split = split
            settings.processingLongEdge = resolution
            if historyChanged { generation &+= 1 }
            return Status.ok.rawValue
        }
    }

    func copyTimings(_ output: UnsafeMutablePointer<NRNeuralTimings>) -> Int32 {
        locked {
            guard let lastTimings else { return Status.notReady.rawValue }
            output.pointee = lastTimings
            return Status.ok.rawValue
        }
    }

    func invalidate() {
        locked { generation &+= 1; lastAcceptedTimestamp = -.infinity }
    }

    private func run(_ stream: AsyncStream<Work>) async {
        var engine: RenderEngine?
        var engineGeneration: UInt64?
        for await work in stream {
            switch work {
            case let .initialize(path, callback, context):
                do {
                    // Drop the old model before attempting a replacement. A
                    // failed initialization cannot silently use the old model.
                    engine = nil; engineGeneration = nil
                    try NeuralResources.validate()
                    let next = try RenderEngine()
                    try await next.loadModel(URL(fileURLWithPath: path, isDirectory: true))
                    engine = next
                    locked { state = .ready; callback(Status.ok.rawValue, nil, context) }
                } catch {
                    let message = error.localizedDescription
                    locked {
                        state = .failed
                        message.withCString { callback(Status.failed.rawValue, $0, context) }
                    }
                }
            case let .process(request):
                do {
                    guard let engine else { throw PortError.message("The neural model is not initialized.") }
                    if engineGeneration != request.generation {
                        await engine.resetHistoryPreservingResources(); engineGeneration = request.generation
                    }
                    let stillCurrent = locked { generation == request.generation }
                    guard stillCurrent else { complete(request, output: nil, milliseconds: 0, error: nil); continue }
                    let result = try await engine.process(CapturedFrame(pixels: request.pixels,
                        capturedAt: request.timestamp), settings: request.settings)
                    let timings = await engine.lastTimings
                    locked {
                        if request.generation == generation {
                            lastTimings = NRNeuralTimings(resizeMilliseconds: timings.resize,
                                motionMilliseconds: timings.motion, inferenceMilliseconds: timings.inference,
                                writeMilliseconds: timings.write, compositeMilliseconds: timings.composite,
                                totalMilliseconds: result.milliseconds,
                                processingWidth: UInt32(result.processingSize.width),
                                processingHeight: UInt32(result.processingSize.height))
                        }
                    }
                    complete(request, output: result.pixels, milliseconds: result.milliseconds, error: nil)
                } catch {
                    engineGeneration = nil
                    complete(request, output: nil, milliseconds: 0, error: error.localizedDescription)
                }
            }
        }
    }

    private func complete(_ request: FrameRequest, output: CVPixelBuffer?, milliseconds: Double, error: String?) {
        locked {
            state = .ready
            if generation != request.generation {
                "The frame was invalidated before completion.".withCString {
                    request.callback(Status.cancelled.rawValue, nil, request.timestamp, milliseconds, $0, request.context)
                }
            } else if let error {
                error.withCString { request.callback(Status.failed.rawValue, nil, request.timestamp, milliseconds, $0, request.context) }
            } else {
                request.callback(Status.ok.rawValue, output, request.timestamp, milliseconds, nil, request.context)
            }
        }
    }
}

@_cdecl("NRNeuralInitialize")
public func bridgeInitialize(_ modelPath: UnsafePointer<CChar>?, _ callback: NRNeuralInitializationCallback?,
                             _ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let modelPath, let callback, let path = String(validatingCString: modelPath), !path.isEmpty else {
        return Status.invalidArgument.rawValue
    }
    return NeuralRuntime.shared.initialize(path, callback: callback, context: context)
}

@_cdecl("NRNeuralProcess")
public func bridgeProcess(_ input: UnsafeMutableRawPointer?, _ timestamp: Double,
                          _ callback: NRNeuralFrameCallback?, _ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let input, let callback else { return Status.invalidArgument.rawValue }
    let pixels = Unmanaged<CVPixelBuffer>.fromOpaque(input).takeUnretainedValue()
    return NeuralRuntime.shared.process(pixels, timestamp: timestamp, callback: callback, context: context)
}

@_cdecl("NRNeuralSetControls")
public func bridgeControls(_ intensity: Float, _ tone: Float, _ structure: Float, _ split: Float) -> Int32 {
    NeuralRuntime.shared.controls(intensity: intensity, tone: tone, structure: structure, split: split)
}

@_cdecl("NRNeuralSetSettings")
public func bridgeSettings(_ intensity: Float, _ tone: Float, _ structure: Float, _ split: Float,
                           _ processingLongEdge: UInt32) -> Int32 {
    NeuralRuntime.shared.controls(intensity: intensity, tone: tone, structure: structure,
                                  split: split, longEdge: processingLongEdge)
}

@_cdecl("NRNeuralCopyLastTimings")
public func bridgeTimings(_ output: UnsafeMutablePointer<NRNeuralTimings>?) -> Int32 {
    guard let output else { return Status.invalidArgument.rawValue }
    return NeuralRuntime.shared.copyTimings(output)
}

@_cdecl("NRNeuralInvalidate")
public func bridgeInvalidate() { NeuralRuntime.shared.invalidate() }

@_cdecl("NRNeuralGetState")
public func bridgeGetState() -> Int32 { NeuralRuntime.shared.currentState }
