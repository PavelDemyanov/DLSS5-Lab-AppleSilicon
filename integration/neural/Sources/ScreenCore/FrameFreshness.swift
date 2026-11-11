import Foundation

/// The age of the newest completed capture, in the same monotonic clock as
/// ScreenCaptureKit timestamps. Re-rendering a timestamp never renews it.
public struct FrameFreshness: Sendable {
    public enum State: Equatable, Sendable { case awaitingFirstFrame, fresh, stale }

    public let maximumAge: Double
    public private(set) var capturedAt: Double?

    public init(maximumAge: Double = 1) {
        precondition(maximumAge.isFinite && maximumAge > 0)
        self.maximumAge = maximumAge
    }

    /// Returns true only for a genuinely newer capture, not a settings redraw.
    @discardableResult
    public mutating func observe(capturedAt timestamp: Double) -> Bool {
        guard timestamp.isFinite, timestamp >= 0,
              capturedAt.map({ timestamp > $0 }) ?? true else { return false }
        capturedAt = timestamp
        return true
    }

    public func state(at now: Double) -> State {
        guard let capturedAt else { return .awaitingFirstFrame }
        let age = now - capturedAt
        return now.isFinite && age >= 0 && age <= maximumAge ? .fresh : .stale
    }

    public mutating func reset() { capturedAt = nil }
}
