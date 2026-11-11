import Foundation

public struct FrameSize: Equatable, Sendable, Codable {
    public var width: Int
    public var height: Int
    public init(_ width: Int, _ height: Int) { self.width = width; self.height = height }
    /// Keep the original aspect ratio, even dimensions and never supersample.
    public func processing(longEdge: Int) -> FrameSize {
        let factor = min(1, Double(max(64, longEdge)) / Double(max(1, max(width, height))))
        return FrameSize(max(2, Int(Double(width) * factor) / 2 * 2),
                         max(2, Int(Double(height) * factor) / 2 * 2))
    }
}

public struct RenderSettings: Codable, Equatable, Sendable {
    public var neuralEnabled = true
    public var temporal = true
    public var processingLongEdge = 512
    public var captureFPS = 30
    public var intensity: Float = 1
    public var tone: Float = 1
    public var structure: Float = 1
    public var split: Float = 0
    public var profile = "natural"
    public init() {}
    public mutating func sanitize() {
        processingLongEdge = min(1920, max(320, processingLongEdge))
        captureFPS = min(60, max(5, captureFPS))
        intensity = intensity.isFinite ? min(2, max(0, intensity)) : 1
        tone = tone.isFinite ? min(2, max(0, tone)) : 1
        structure = structure.isFinite ? min(2, max(0, structure)) : 1
        split = split.isFinite ? min(1, max(0, split)) : 0
        if !["natural", "standard", "cinematic", "neutral"].contains(profile) { profile = "natural" }
    }
}

/// A reset is needed after source switches, geometry changes, control changes,
/// bypass, or a long interruption. Dropped captures alone are fine: flow is
/// estimated between the two frames that actually reach the model.
public struct HistoryBoundary: Equatable, Sendable {
    public let size: FrameSize
    public let profile: String
    public let tone: Float
    public let structure: Float
    public let intensity: Float
    public let temporal: Bool
    public init(size: FrameSize, settings: RenderSettings) {
        self.size = size; profile = settings.profile; tone = settings.tone
        structure = settings.structure; intensity = settings.intensity; temporal = settings.temporal
    }
}

/// Thread-safe bounded handoff. A slow renderer retains only the latest pending
/// frame; it never builds seconds of desktop latency behind an unbounded queue.
public final class LatestFrames<Element: Sendable>: @unchecked Sendable {
    public let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation
    private let lock = NSLock()
    private var droppedCount = 0
    public init() {
        let pair = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream; continuation = pair.continuation
    }
    public var dropped: Int { lock.lock(); defer { lock.unlock() }; return droppedCount }
    public func yield(_ element: Element) {
        if case .dropped = continuation.yield(element) {
            lock.lock(); droppedCount += 1; lock.unlock()
        }
    }
    public func finish() { continuation.finish() }
}
