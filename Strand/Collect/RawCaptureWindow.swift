import Foundation
import WhoopProtocol

/// Bounded, on-demand raw-capture window. Never 24/7 — clamps to a sane max.
/// The Collector ORs `isActive(at:)` into its raw-persist gate; the deadline
/// auto-expires the window so a missed stop callback can't leak raw forever.
struct RawCaptureWindow {
    static let minSeconds: TimeInterval = 1
    /// The UI starts a short research window by default. The controller deadline, not a view timer,
    /// owns producer shutdown if the app remains alive but the user never taps Stop.
    static let researchSessionDefaultSeconds = SensorAcquisitionController.defaultResearchDurationSeconds
    /// A hard safety ceiling for any caller, including future lab UI. High-rate capture is not a
    /// general-purpose always-on mode.
    static let maxSeconds = SensorAcquisitionController.maximumDurationSeconds
    static func clamp(_ s: TimeInterval) -> TimeInterval { min(max(s, minSeconds), maxSeconds) }

    private var deadline: TimeInterval?       // monotonic deadline; nil = inactive
    /// Returns true while the window is open, inclusive of the deadline instant (`t <= deadline`).
    func isActive(at t: TimeInterval) -> Bool { if let d = deadline { return t <= d } else { return false } }
    mutating func open(at t: TimeInterval, duration: TimeInterval) { deadline = t + Self.clamp(duration) }
    mutating func close() { deadline = nil }
}
