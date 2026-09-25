import Foundation

public enum WatchdogPhase: String, Equatable, Sendable, Codable, CaseIterable {
    case sleep, late, morning, midday, evening
}

public enum WatchdogActivityFamily: String, Equatable, Sendable, Codable, CaseIterable {
    case still, walk, endurance, resistance, postWorkout = "post_workout", other
}

public struct WatchdogPhaseKey: Equatable, Hashable, Sendable, Codable {
    public var phase: WatchdogPhase
    public var family: WatchdogActivityFamily
    public init(phase: WatchdogPhase, family: WatchdogActivityFamily) {
        self.phase = phase
        self.family = family
    }
    public var id: String { "\(phase.rawValue)×\(family.rawValue)" }
}

public struct WatchdogPhaseEntry: Equatable, Sendable, Codable {
    public var center: [Double]
    public var mad: [Double]
    public var nDays: Int
    public var updatedDay: String

    public init(center: [Double] = Array(repeating: 0, count: 6),
                mad: [Double] = Array(repeating: 0, count: 6),
                nDays: Int = 0, updatedDay: String = "") {
        self.center = center
        self.mad = mad
        self.nDays = nDays
        self.updatedDay = updatedDay
    }
}

public struct WatchdogPhaseUsualStore: Equatable, Sendable, Codable {
    public var entries: [String: WatchdogPhaseEntry]
    public static let empty = WatchdogPhaseUsualStore(entries: [:])
    public init(entries: [String: WatchdogPhaseEntry] = [:]) { self.entries = entries }

    public static let matureDays = 7
    public static let blendSidecar = 0.70
    public static let dailyGain = 0.15

    public static func phase(nowUnix: Int, sleepBit: Bool) -> WatchdogPhase {
        if sleepBit { return .sleep }
        let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(nowUnix)))
        if hour < 5 { return .late }
        if hour < 12 { return .morning }
        if hour < 17 { return .midday }
        return .evening
    }

    public static func family(label: WatchdogEventLabel, cls: WatchdogActivityClass) -> WatchdogActivityFamily {
        if label == .postWorkout { return .postWorkout }
        switch cls {
        case .still, .stand: return .still
        case .walk: return .walk
        case .run, .cycleLike: return .endurance
        case .resistance: return .resistance
        case .unknown, .artifact: return .other
        }
    }

    public func mature(_ key: WatchdogPhaseKey) -> WatchdogPhaseEntry? {
        guard let e = entries[key.id], e.nDays >= Self.matureDays else { return nil }
        return e
    }

    public mutating func writeDay(key: WatchdogPhaseKey, dayMedian: [Double], civilDay: String) {
        guard key.family != .other else { return }
        guard dayMedian.count == 6, dayMedian.allSatisfy(\.isFinite) else { return }
        var e = entries[key.id] ?? WatchdogPhaseEntry()
        if e.updatedDay == civilDay { return }
        if e.nDays == 0 {
            e.center = dayMedian
            e.mad = Array(repeating: 0, count: 6)
        } else {
            e.center = zip(e.center, dayMedian).map { 0.85 * $0 + Self.dailyGain * $1 }
        }
        e.nDays += 1
        e.updatedDay = civilDay
        entries[key.id] = e
    }

    public func blendPrompt(_ prompt: UniTSPrompt, key: WatchdogPhaseKey) -> UniTSPrompt {
        guard let e = mature(key), e.center.count == 6 else { return prompt }
        var out = prompt
        func mix(_ layer: Double?, _ idx: Int) -> Double? {
            guard let layer else { return e.center[idx] }
            return (1 - Self.blendSidecar) * layer + Self.blendSidecar * e.center[idx]
        }
        out.hr = mix(prompt.hr, 0)
        out.rhr = mix(prompt.rhr, 1)
        out.hrv = mix(prompt.hrv, 2)
        out.temp = mix(prompt.temp, 3)
        out.resp = mix(prompt.resp, 4)
        out.spo2 = mix(prompt.spo2, 5)
        return out
    }
}

/// Green band: small weighted steps. Not frozen, not yanked by one minute.
/// `q` accumulates typical |r| on eligible still minutes. After 14 minutes, `anchor` is
/// that first typical width. Scale is `q / anchor`, stepped by at most `stepMax` and
/// clamped to 0.75…1.40 so the range can drift but cannot go loose.
public enum WatchdogBand: Sendable {
    public static let version = "band-v2-medium"
    public static let targetLo = 0.90
    public static let targetHi = 0.95
    public static let clampLo = 0.75
    public static let clampHi = 1.40
    public static let firstMinutes = 14
    public static let residualCap = 2.5
    /// |r| allowed into the EMA — a 2.4 still-spike must not own q.
    public static let learnCap = 1.20
    public static let qFloor = 0.08
    /// Max |Δscale| on one eligible tick.
    public static let stepMax = 0.02
    public static let nCap = 14 * 24 * 3

    public static func alpha(nElig: Int) -> Double {
        2 / Double(min(max(nElig, 1), nCap) + 1)
    }

    public static func update(absResidual: [Double], eligible: Bool,
                              q: inout [Double], anchor: inout [Double],
                              n: inout Int, initialized: inout Bool) -> [Double] {
        var scale = Array(repeating: 1.0, count: 6)
        return update(absResidual: absResidual, eligible: eligible, q: &q, anchor: &anchor,
                      n: &n, initialized: &initialized, scale: &scale)
    }

    public static func update(absResidual: [Double], eligible: Bool,
                              q: inout [Double], anchor: inout [Double],
                              n: inout Int, initialized: inout Bool,
                              scale: inout [Double]) -> [Double] {
        if q.count < 6 { q = Array(repeating: 0, count: 6) }
        if anchor.count < 6 { anchor = Array(repeating: 1, count: 6) }
        if scale.count < 6 { scale = Array(repeating: 1, count: 6) }
        guard eligible, absResidual.count >= 6 else { return scale }
        if absResidual.contains(where: { $0 >= residualCap }) { return scale }
        n += 1
        let a = alpha(nElig: n)
        for k in 0..<6 {
            let x = min(max(absResidual[k], 0), learnCap)
            q[k] = (1 - a) * q[k] + a * x
        }
        if !initialized && n >= firstMinutes {
            for k in 0..<6 {
                anchor[k] = max(q[k], qFloor)
                scale[k] = 1
            }
            initialized = true
            return scale
        }
        guard initialized else { return scale }
        for k in 0..<6 {
            let desired = min(clampHi, max(clampLo, q[k] / max(anchor[k], qFloor)))
            let prev = scale[k].isFinite && scale[k] > 0 ? scale[k] : 1
            let delta = min(stepMax, max(-stepMax, desired - prev))
            scale[k] = min(clampHi, max(clampLo, prev + delta))
        }
        return scale
    }

    public static func apply(_ scales: [Double], to values: [Double]) -> [Double] {
        guard let g = scales.first, g.isFinite, g > 0 else { return values }
        return values.map { $0 * g }
    }
}
