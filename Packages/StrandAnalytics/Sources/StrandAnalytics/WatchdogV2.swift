import Foundation
import WhoopProtocol

/// v2 calibration. Quiet-window residual coverage, not this-window scatter. Engineering, not clinical.
public enum WatchdogCalibration: Sendable {
    public static let version = "cal-v1"
    public static let quietCoverage = 0.95
    public static let coldStartGain = 2.5
    public static let tNote = 1.0
    public static let tActive = 1.6
    public static let tSevere = 2.4
    public static let persistTicks = 2
    public static let escalateDelta = 0.5
    public static let rearmTicks = 15
    public static let forecastAlpha = 0.5
    public static let maxEmptyMinutes = 6
    public static let forecastHorizon = 5

    public static func sigmaScale(_ channel: WatchdogWindow.Channel) -> Double {
        switch channel {
        case .hr: return 1.0
        case .rhr: return 1.0
        case .hrv: return 1.0
        case .temp: return 1.0
        case .resp: return 1.0
        case .spo2: return 1.0
        case .motion: return 1.0
        }
    }

    public static func applySigma(_ raw: [Double], channel: WatchdogWindow.Channel, coldStart: Bool) -> [Double] {
        let g = (coldStart ? coldStartGain : 1.0) * sigmaScale(channel)
        return raw.map { $0 * g }
    }
}

public enum WatchdogPopulationPriors: Sendable {
    public static let hr = 60.0
    public static let rhr = 60.0
    public static let hrv = 40.0
    public static let temp = 33.0
    public static let resp = 14.0
    public static let spo2 = 97.0

    public static func value(_ channel: WatchdogWindow.Channel) -> Double {
        switch channel {
        case .hr: return hr
        case .rhr: return rhr
        case .hrv: return hrv
        case .temp: return temp
        case .resp: return resp
        case .spo2: return spo2
        case .motion: return 0
        }
    }
}

public enum WatchdogPromptSource: String, Equatable, Sendable, Codable {
    case population
    case sleep
    case awakeRest
    case mixed
}

public enum WatchdogActivityClass: String, Equatable, Sendable, CaseIterable {
    case still, stand, walk, run, cycleLike, resistance, artifact, unknown

    public static var count: Int { allCases.count }

    public var index: Int {
        Self.allCases.firstIndex(of: self) ?? (Self.count - 1)
    }

    public static func unknownLogits(minutes: Int = WatchdogConfig.seqLen) -> [[Double]] {
        (0..<minutes).map { _ in
            var row = Array(repeating: 0.0, count: count)
            row[WatchdogActivityClass.unknown.index] = 1
            return row
        }
    }

    public static func labels(logits: [[Double]]) -> [String] {
        logits.map { row in
            guard let i = row.enumerated().max(by: { $0.element < $1.element })?.offset,
                  i < allCases.count else { return unknown.rawValue }
            return allCases[i].rawValue
        }
    }
}

public enum WatchdogQuality: Sendable {
    public static func bucketCoverage(_ window: WatchdogWindow) -> Double {
        guard window.seqLen > 0 else { return 0 }
        return Double(window.hr.filter { $0 != nil }.count) / Double(window.seqLen)
    }

    public static func maxEmptyMinutes(_ hr: [Double?]) -> Int {
        var best = 0
        var run = 0
        for v in hr {
            if v == nil {
                run += 1
                best = max(best, run)
            } else {
                run = 0
            }
        }
        return best
    }

    public static func freshnessLimit(_ family: DeviceFamily) -> Int {
        family == .whoop5 ? WatchdogConfig.whoop5FreshnessSeconds : WatchdogConfig.whoop4FreshnessSeconds
    }

    public static func gate(_ window: WatchdogWindow) -> WatchdogUnavailable? {
        if bucketCoverage(window) + 1e-9 < WatchdogConfig.minCoverage { return .coverage }
        if window.newestAgeSeconds > freshnessLimit(window.family) { return .stale }
        if maxEmptyMinutes(window.hr) >= WatchdogCalibration.maxEmptyMinutes { return .gap }
        return nil
    }
}

public enum WatchdogSafety: Sendable {
    public static func fired(_ window: WatchdogWindow) -> Bool {
        Watchdog.safetyCap(window: window)
    }
}

public enum WatchdogAdaptive: Sendable {
    public static let quietEma = 0.08
    public static let artifactGain = 1.7

    public static func apply(_ residual: UniTSResidual, window: WatchdogWindow,
                             lastHR: (obs: Double, hat: Double)?,
                             lastRHR: (obs: Double, hat: Double)?,
                             lastHRV: (obs: Double, hat: Double)?,
                             lastTemp: (obs: Double, hat: Double)?,
                             lastResp: (obs: Double, hat: Double)?,
                             lastSpO2: (obs: Double, hat: Double)?,
                             carry: inout WatchdogCarry) -> UniTSResidual {
        var out = residual
        let artifact = WatchdogActivityRuntime.isArtifact(window.activityLogits)
        let still = WatchdogActivityRuntime.isStillish(window.activityLogits)
        func absr(_ p: (obs: Double, hat: Double)?) -> Double {
            guard let p else { return 0 }
            return abs(p.obs - p.hat)
        }
        func lastZ(_ p: (obs: Double, hat: Double)?, scale: [Double]) -> Double {
            guard let p else { return 0 }
            return absr(p) / max(scale.last ?? 1, 0.01)
        }
        let lastBandZ = max(
            lastZ(lastHR, scale: residual.scaleHR),
            lastZ(lastRHR, scale: residual.scaleRHR),
            lastZ(lastHRV, scale: residual.scaleHRV),
            lastZ(lastTemp, scale: residual.scaleTemp),
            lastZ(lastResp, scale: residual.scaleResp),
            lastZ(lastSpO2, scale: residual.scaleSpO2)
        )
        if residual.jointEnergy < WatchdogCalibration.tNote || lastBandZ < 1.0 {
            let a = quietEma
            carry.quietAbsHR = (1 - a) * carry.quietAbsHR + a * absr(lastHR)
            carry.quietAbsRHR = (1 - a) * carry.quietAbsRHR + a * absr(lastRHR)
            carry.quietAbsHRV = (1 - a) * carry.quietAbsHRV + a * absr(lastHRV)
            carry.quietAbsTemp = (1 - a) * carry.quietAbsTemp + a * absr(lastTemp)
            carry.quietAbsResp = (1 - a) * carry.quietAbsResp + a * absr(lastResp)
            carry.quietAbsSpO2 = (1 - a) * carry.quietAbsSpO2 + a * absr(lastSpO2)
            carry.quietN += 1
        }
        let art = artifact ? artifactGain : 1.0
        var corr = 1.0
        if still {
            let hrE = residual.energy(for: .hr)
            let hrvE = residual.energy(for: .hrv)
            if hrE >= WatchdogCalibration.tNote && hrvE < 0.35 { corr = 1.35 }
            if hrE >= WatchdogCalibration.tNote && hrvE >= WatchdogCalibration.tNote { corr = 0.90 }
        }
        func bump(_ scale: [Double], quiet: Double) -> [Double] {
            let floor = carry.quietN >= 8 ? quiet : 0
            return scale.map { max($0, floor) * art * corr }
        }
        let oldHR = out.scaleHR.last ?? 1
        let oldRHR = out.scaleRHR.last ?? 1
        let oldHRV = out.scaleHRV.last ?? 1
        let oldTemp = out.scaleTemp.last ?? 1
        let oldResp = out.scaleResp.last ?? 1
        let oldSpO2 = out.scaleSpO2.last ?? 1
        out.scaleHR = bump(out.scaleHR, quiet: carry.quietAbsHR)
        out.scaleRHR = bump(out.scaleRHR, quiet: carry.quietAbsRHR)
        out.scaleHRV = bump(out.scaleHRV, quiet: carry.quietAbsHRV)
        out.scaleTemp = bump(out.scaleTemp, quiet: carry.quietAbsTemp)
        out.scaleResp = bump(out.scaleResp, quiet: carry.quietAbsResp)
        out.scaleSpO2 = bump(out.scaleSpO2, quiet: carry.quietAbsSpO2)
        func rescale(_ e: Double, old: Double, new: Double) -> Double {
            e * (max(old, 0.01) / max(new, 0.01))
        }
        var energy = out.energy
        energy[.hr] = rescale(residual.energy(for: .hr), old: oldHR, new: out.scaleHR.last ?? oldHR)
        energy[.rhr] = rescale(residual.energy(for: .rhr), old: oldRHR, new: out.scaleRHR.last ?? oldRHR)
        energy[.hrv] = rescale(residual.energy(for: .hrv), old: oldHRV, new: out.scaleHRV.last ?? oldHRV)
        energy[.temp] = rescale(residual.energy(for: .temp), old: oldTemp, new: out.scaleTemp.last ?? oldTemp)
        energy[.resp] = rescale(residual.energy(for: .resp), old: oldResp, new: out.scaleResp.last ?? oldResp)
        energy[.spo2] = rescale(residual.energy(for: .spo2), old: oldSpO2, new: out.scaleSpO2.last ?? oldSpO2)
        out.energy = energy
        out.rangeHalf[.hr] = out.scaleHR.last ?? residual.rangeHalf(for: .hr)
        out.rangeHalf[.rhr] = out.scaleRHR.last ?? residual.rangeHalf(for: .rhr)
        out.rangeHalf[.hrv] = out.scaleHRV.last ?? residual.rangeHalf(for: .hrv)
        out.rangeHalf[.temp] = out.scaleTemp.last ?? residual.rangeHalf(for: .temp)
        out.rangeHalf[.resp] = out.scaleResp.last ?? residual.rangeHalf(for: .resp)
        out.rangeHalf[.spo2] = out.scaleSpO2.last ?? residual.rangeHalf(for: .spo2)
        var joint = WatchdogScores.joint(energies: [
            energy[.hr] ?? 0, energy[.rhr] ?? 0, energy[.hrv] ?? 0,
            energy[.temp] ?? 0, energy[.resp] ?? 0, energy[.spo2] ?? 0
        ])
        if artifact { joint *= 0.72 }
        out.jointEnergy = joint
        return out
    }
}

public enum WatchdogScores: Sendable {
    public static func joint(energies: [Double]) -> Double {
        let xs = energies.filter { $0.isFinite }
        guard !xs.isEmpty else { return 0 }
        let l2 = sqrt(xs.reduce(0) { $0 + $1 * $1 }) / sqrt(Double(xs.count))
        let mx = xs.max() ?? 0
        return max(l2, mx)
    }

    public static func fused(recon: Double, forecast: Double) -> Double {
        max(recon, WatchdogCalibration.forecastAlpha * max(0, forecast))
    }

    public static func severity(fused: Double, persistTicks: Int, safety: Bool, confounded: Bool,
                                personalOff: Bool) -> WatchdogSeverity {
        if safety { return .severe }
        if confounded {
            return fused >= WatchdogCalibration.tNote ? .candidate : .note
        }
        let persist = persistTicks >= WatchdogCalibration.persistTicks
        if fused >= WatchdogCalibration.tSevere && persist { return .severe }
        if fused >= WatchdogCalibration.tActive && persist { return .active }
        if fused >= WatchdogCalibration.tNote && persist { return .candidate }
        if fused >= WatchdogCalibration.tNote || personalOff { return .note }
        return .withinLimits
    }

    public static func shouldNotify(severity: WatchdogSeverity, openedEpisode: Bool,
                                    safety: Bool, previousSafety: Bool,
                                    fused: Double, previousFused: Double) -> (Bool, String) {
        WatchdogNotifyPolicy.decision(severity: severity, openedEpisode: openedEpisode,
                                      safety: safety, previousSafety: previousSafety,
                                      fused: fused, previousFused: previousFused,
                                      recon: fused, previousRecon: previousFused)
    }
}

/// Episode notify (item 7). No wall-clock 1800 s mute.
/// Escalate follows reconstruction J, not forecast skill (Lane B must not re-page a stable recon).
public enum WatchdogNotifyPolicy: Sendable {
    public static func decision(severity: WatchdogSeverity, openedEpisode: Bool,
                                safety: Bool, previousSafety: Bool,
                                fused: Double, previousFused: Double,
                                recon: Double = 0, previousRecon: Double = 0) -> (Bool, String) {
        guard severity == .severe else { return (false, "not-severe") }
        if openedEpisode { return (true, "episode-start") }
        if safety && !previousSafety { return (true, "safety") }
        let prior = previousRecon
        if recon >= prior + WatchdogCalibration.escalateDelta { return (true, "escalate") }
        return (false, "stable-episode")
    }
}

/// TimesFM-style on-device forecast student (patched causal decoder).
/// Teacher recipe is google-research/timesfm (`google/timesfm-3.0-pytorch`);
/// the App Store binary loads `TimesFM3_Student.mlpackage`, not the 330M weights.
public struct WatchdogForecastRuntime: Sendable {
    public static let modelVersion = WatchdogConfig.forecastModelVersion

    public func step(window: WatchdogWindow, residual: UniTSResidual,
                     prompt: UniTSPrompt = UniTSPrompt(),
                     carry: WatchdogCarry,
                     nowUnix: Int = 0) -> (energy: Double, nextHR: [Double], nextHRV: [Double],
                                           nextTemp: [Double], nextResp: [Double],
                                           nextRHR: [Double], nextSpO2: [Double], ranStudent: Bool) {
        let h = WatchdogCalibration.forecastHorizon
        func lastObs(_ obs: [Double?], _ scale: [Double]) -> (obs: [Double], sig: [Double]) {
            var pairs: [(Double, Double)] = []
            for i in 0..<obs.count {
                if let o = obs[i] {
                    let s = i < scale.count ? scale[i] : 1
                    pairs.append((o, max(s, 0.01)))
                }
            }
            let tail = pairs.suffix(h)
            return (tail.map(\.0), tail.map(\.1))
        }
        func energy(obs: [Double], pred: [Double], sig: [Double]) -> Double {
            guard !obs.isEmpty else { return 0 }
            let n = min(obs.count, pred.count, sig.count)
            guard n > 0 else { return 0 }
            var z: [Double] = []
            for i in 0..<n {
                z.append(abs(obs[i] - pred[i]) / max(sig[i], 0.01))
            }
            return z.max() ?? 0
        }
        let hr = lastObs(window.hr, residual.scaleHR)
        let rhr = lastObs(window.rhr, residual.scaleRHR)
        let hrv = lastObs(window.hrv, residual.scaleHRV)
        let temp = lastObs(window.temp, residual.scaleTemp)
        let resp = lastObs(window.resp, residual.scaleResp)
        let spo2 = lastObs(window.spo2, residual.scaleSpO2)

        var e = 0.0
        if carry.lastForecastHR.count == h {
            e = max(e, energy(obs: hr.obs, pred: Array(carry.lastForecastHR.prefix(hr.obs.count)), sig: hr.sig))
        }
        if carry.lastForecastHRV.count == h {
            e = max(e, energy(obs: hrv.obs, pred: Array(carry.lastForecastHRV.prefix(hrv.obs.count)), sig: hrv.sig))
        }
        if carry.lastForecastTemp.count == h {
            e = max(e, energy(obs: temp.obs, pred: Array(carry.lastForecastTemp.prefix(temp.obs.count)), sig: temp.sig))
        }
        if carry.lastForecastResp.count == h {
            e = max(e, energy(obs: resp.obs, pred: Array(carry.lastForecastResp.prefix(resp.obs.count)), sig: resp.sig))
        }
        if carry.lastForecastRHR.count == h {
            e = max(e, energy(obs: rhr.obs, pred: Array(carry.lastForecastRHR.prefix(rhr.obs.count)), sig: rhr.sig))
        }
        if carry.lastForecastSpO2.count == h {
            e = max(e, energy(obs: spo2.obs, pred: Array(carry.lastForecastSpO2.prefix(spo2.obs.count)), sig: spo2.sig))
        }

        let skipStudent = nowUnix > 0 && carry.lastForecastUnix > 0
            && (nowUnix - carry.lastForecastUnix) < 60
            && carry.lastForecastHR.count == h
        if skipStudent {
            return (e, carry.lastForecastHR, carry.lastForecastHRV, carry.lastForecastTemp,
                    carry.lastForecastResp, carry.lastForecastRHR, carry.lastForecastSpO2, false)
        }

        func hold(_ hat: [Double?]) -> [Double] {
            let last = hat.reversed().compactMap { $0 }.first ?? 0
            return Array(repeating: last, count: h)
        }
        func fillHat(_ xs: [Double?], _ base: Double?) -> [Double] {
            let seed = base ?? 0
            var last = seed
            return (0..<WatchdogConfig.seqLen).map { i in
                if i < xs.count, let v = xs[i], v.isFinite {
                    last = v
                    return v
                }
                return last
            }
        }
        let bases = UniTSRuntime.resolvedBases(window: window, prompt: prompt)
        let history = [
            fillHat(residual.reconstructedHR, bases[0]),
            fillHat(residual.reconstructedRHR, bases[1]),
            fillHat(residual.reconstructedHRV, bases[2]),
            fillHat(residual.reconstructedTemp, bases[3]),
            fillHat(residual.reconstructedResp, bases[4]),
            fillHat(residual.reconstructedSpO2, bases[5])
        ]
        let occ = UniTSRuntime.occupancy(window)
        let promptVec = [
            bases[0] ?? WatchdogPopulationPriors.hr,
            bases[1] ?? WatchdogPopulationPriors.rhr,
            bases[2] ?? WatchdogPopulationPriors.hrv,
            bases[3] ?? WatchdogPopulationPriors.temp,
            bases[4] ?? WatchdogPopulationPriors.resp,
            bases[5] ?? WatchdogPopulationPriors.spo2
        ]
        if let forecast = TimesFMStudentSession.shared.predict(history: history, prompt: promptVec, occupancy: occ),
           forecast.count == 6, forecast.allSatisfy({ $0.count == h }) {
            return (e, forecast[0], forecast[2], forecast[3], forecast[4], forecast[1], forecast[5], true)
        }
        return (e, hold(residual.reconstructedHR), hold(residual.reconstructedHRV),
                hold(residual.reconstructedTemp), hold(residual.reconstructedResp),
                hold(residual.reconstructedRHR), hold(residual.reconstructedSpO2), true)
    }
}
