import Foundation
import WhoopProtocol

public enum WatchdogSeverity: String, Equatable, Sendable, Codable {
    case withinLimits
    case note
    case candidate
    case active
    case severe
    case dataUnavailable
}

public enum WatchdogEpisodeState: String, Equatable, Sendable, Codable {
    case withinLimits
    case candidate
    case active
    case recovering
    case resolved
    case dataUnavailable
}

public struct WatchdogSignalEvidence: Equatable, Sendable, Codable {
    public var name: String
    public var observed: Double?
    public var usual: Double?
    public var reconstructed: Double?
    public var energy: Double
    public var unit: String
    public var trustPct: Int
    /// Native-unit half-width of the live in-range band around reconstruction.
    public var rangeHalf: Double

    public init(name: String, observed: Double?, usual: Double?, reconstructed: Double?,
                energy: Double, unit: String, trustPct: Int = 0, rangeHalf: Double = 0) {
        self.name = name
        self.observed = observed
        self.usual = usual
        self.reconstructed = reconstructed
        self.energy = energy
        self.unit = unit
        self.trustPct = trustPct
        self.rangeHalf = rangeHalf
    }
}

public struct WatchdogCarry: Equatable, Sendable, Codable {
    public var episodeId: String?
    public var consecutiveMismatchTicks: Int
    public var lastNotifiedAt: Int?
    public var consecutiveQuietTicks: Int
    public var priorState: WatchdogEpisodeState?
    public var lastHeldResp: Double?
    public var lastHeldHRV: Double?
    public var lastHeldTemp: Double?
    public var lastHeldSpO2: Double?
    public var lastJointEnergy: Double
    public var lastSafety: Bool
    public var lastForecastHR: [Double]
    public var lastForecastHRV: [Double]
    public var lastForecastTemp: [Double]
    public var lastForecastResp: [Double]
    public var lastForecastRHR: [Double]
    public var lastForecastSpO2: [Double]
    public var consecutiveInRangeTicks: Int
    public var quietAbsHR: Double
    public var quietAbsRHR: Double
    public var quietAbsHRV: Double
    public var quietAbsTemp: Double
    public var quietAbsResp: Double
    public var quietAbsSpO2: Double
    public var quietN: Int
    public var lastForecastUnix: Int
    public var quietJointEma: Double
    public var lastReconEnergy: Double

    public static let empty = WatchdogCarry()

    public init(episodeId: String? = nil, consecutiveMismatchTicks: Int = 0,
                lastNotifiedAt: Int? = nil, consecutiveQuietTicks: Int = 0,
                priorState: WatchdogEpisodeState? = nil,
                lastHeldResp: Double? = nil, lastHeldHRV: Double? = nil,
                lastHeldTemp: Double? = nil, lastHeldSpO2: Double? = nil,
                lastJointEnergy: Double = 0, lastSafety: Bool = false,
                lastForecastHR: [Double] = [], lastForecastHRV: [Double] = [],
                lastForecastTemp: [Double] = [], lastForecastResp: [Double] = [],
                lastForecastRHR: [Double] = [], lastForecastSpO2: [Double] = [],
                consecutiveInRangeTicks: Int = 0,
                quietAbsHR: Double = 0, quietAbsRHR: Double = 0, quietAbsHRV: Double = 0,
                quietAbsTemp: Double = 0, quietAbsResp: Double = 0, quietAbsSpO2: Double = 0,
                quietN: Int = 0, lastForecastUnix: Int = 0, quietJointEma: Double = 0,
                lastReconEnergy: Double = 0) {
        self.episodeId = episodeId
        self.consecutiveMismatchTicks = consecutiveMismatchTicks
        self.lastNotifiedAt = lastNotifiedAt
        self.consecutiveQuietTicks = consecutiveQuietTicks
        self.priorState = priorState
        self.lastHeldResp = lastHeldResp
        self.lastHeldHRV = lastHeldHRV
        self.lastHeldTemp = lastHeldTemp
        self.lastHeldSpO2 = lastHeldSpO2
        self.lastJointEnergy = lastJointEnergy
        self.lastSafety = lastSafety
        self.lastForecastHR = lastForecastHR
        self.lastForecastHRV = lastForecastHRV
        self.lastForecastTemp = lastForecastTemp
        self.lastForecastResp = lastForecastResp
        self.lastForecastRHR = lastForecastRHR
        self.lastForecastSpO2 = lastForecastSpO2
        self.consecutiveInRangeTicks = consecutiveInRangeTicks
        self.quietAbsHR = quietAbsHR
        self.quietAbsRHR = quietAbsRHR
        self.quietAbsHRV = quietAbsHRV
        self.quietAbsTemp = quietAbsTemp
        self.quietAbsResp = quietAbsResp
        self.quietAbsSpO2 = quietAbsSpO2
        self.quietN = quietN
        self.lastForecastUnix = lastForecastUnix
        self.quietJointEma = quietJointEma
        self.lastReconEnergy = lastReconEnergy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodeId = try c.decodeIfPresent(String.self, forKey: .episodeId)
        consecutiveMismatchTicks = try c.decodeIfPresent(Int.self, forKey: .consecutiveMismatchTicks) ?? 0
        lastNotifiedAt = try c.decodeIfPresent(Int.self, forKey: .lastNotifiedAt)
        consecutiveQuietTicks = try c.decodeIfPresent(Int.self, forKey: .consecutiveQuietTicks) ?? 0
        priorState = try c.decodeIfPresent(WatchdogEpisodeState.self, forKey: .priorState)
        lastHeldResp = try c.decodeIfPresent(Double.self, forKey: .lastHeldResp)
        lastHeldHRV = try c.decodeIfPresent(Double.self, forKey: .lastHeldHRV)
        lastHeldTemp = try c.decodeIfPresent(Double.self, forKey: .lastHeldTemp)
        lastHeldSpO2 = try c.decodeIfPresent(Double.self, forKey: .lastHeldSpO2)
        lastJointEnergy = try c.decodeIfPresent(Double.self, forKey: .lastJointEnergy) ?? 0
        lastSafety = try c.decodeIfPresent(Bool.self, forKey: .lastSafety) ?? false
        lastForecastHR = try c.decodeIfPresent([Double].self, forKey: .lastForecastHR) ?? []
        lastForecastHRV = try c.decodeIfPresent([Double].self, forKey: .lastForecastHRV) ?? []
        lastForecastTemp = try c.decodeIfPresent([Double].self, forKey: .lastForecastTemp) ?? []
        lastForecastResp = try c.decodeIfPresent([Double].self, forKey: .lastForecastResp) ?? []
        lastForecastRHR = try c.decodeIfPresent([Double].self, forKey: .lastForecastRHR) ?? []
        lastForecastSpO2 = try c.decodeIfPresent([Double].self, forKey: .lastForecastSpO2) ?? []
        consecutiveInRangeTicks = try c.decodeIfPresent(Int.self, forKey: .consecutiveInRangeTicks) ?? 0
        quietAbsHR = try c.decodeIfPresent(Double.self, forKey: .quietAbsHR) ?? 0
        quietAbsRHR = try c.decodeIfPresent(Double.self, forKey: .quietAbsRHR) ?? 0
        quietAbsHRV = try c.decodeIfPresent(Double.self, forKey: .quietAbsHRV) ?? 0
        quietAbsTemp = try c.decodeIfPresent(Double.self, forKey: .quietAbsTemp) ?? 0
        quietAbsResp = try c.decodeIfPresent(Double.self, forKey: .quietAbsResp) ?? 0
        quietAbsSpO2 = try c.decodeIfPresent(Double.self, forKey: .quietAbsSpO2) ?? 0
        quietN = try c.decodeIfPresent(Int.self, forKey: .quietN) ?? 0
        lastForecastUnix = try c.decodeIfPresent(Int.self, forKey: .lastForecastUnix) ?? 0
        quietJointEma = try c.decodeIfPresent(Double.self, forKey: .quietJointEma) ?? 0
        lastReconEnergy = try c.decodeIfPresent(Double.self, forKey: .lastReconEnergy) ?? 0
    }
}

public struct WatchdogResult: Equatable, Sendable, Codable {
    public var severity: WatchdogSeverity
    public var episodeState: WatchdogEpisodeState
    public var episodeId: String?
    public var headline: String
    public var episodeLine: String
    public var monitoringCurrent: Bool
    public var monitoringLabel: String
    public var mode: String
    public var unavailable: WatchdogUnavailable?
    public var coverage: Double
    public var hrSource: String
    public var family: String
    public var lastTickUnix: Int
    public var windowStartUnix: Int
    public var horizonHR: [Double]
    public var horizonHRV: [Double]
    public var horizonTemp: [Double]
    public var horizonResp: [Double]
    public var horizonRHR: [Double]
    public var horizonSpO2: [Double]
    public var reconstructedHR: [Double]
    public var reconstructedHRV: [Double]
    public var reconstructedTemp: [Double]
    public var reconstructedResp: [Double]
    public var reconstructedRHR: [Double]
    public var reconstructedSpO2: [Double]
    /// Per-minute UniTS predicted half-width (same units as the reconstructed strip).
    public var rangeHR: [Double]
    public var rangeHRV: [Double]
    public var rangeTemp: [Double]
    public var rangeResp: [Double]
    public var rangeRHR: [Double]
    public var rangeSpO2: [Double]
    public var signals: [WatchdogSignalEvidence]
    public var contributing: [String]
    public var qualityLine: String
    public var versionLine: String
    public var shouldNotify: Bool
    public var carry: WatchdogCarry
    public var modelVersion: String
    public var trustPct: Int
    public var jointEnergy: Double
    public var forecastEnergy: Double
    public var fusedEnergy: Double
    public var promptSource: WatchdogPromptSource
    public var notifyReason: String
    public var activityLabel: String
    public var activityDetail: String
    public var sigmaAdaptive: Bool
    public var qualityGate: String
}

public enum Watchdog {
    public static func evaluate(window: Result<WatchdogWindow, WatchdogUnavailable>,
                                prompt: UniTSPrompt,
                                evaluations: [LBEvaluation] = [],
                                dayLog: LBDayLog? = nil,
                                nowUnix: Int,
                                liveIntervalMinutes: Int = WatchdogConfig.defaultLiveIntervalMinutes,
                                previous: WatchdogCarry = .empty,
                                inject: WatchdogInject? = nil) -> WatchdogResult {
        var carry = previous
        if let inject {
            return applyInject(inject, nowUnix: nowUnix, interval: liveIntervalMinutes, carry: &carry)
        }
        switch window {
        case .failure(let reason):
            carry.consecutiveMismatchTicks = 0
            return unavailable(reason, nowUnix: nowUnix, interval: liveIntervalMinutes, carry: carry)
        case .success(let win):
            if let reason = WatchdogQuality.gate(win) {
                carry.consecutiveMismatchTicks = 0
                return unavailable(reason, nowUnix: nowUnix, interval: liveIntervalMinutes, carry: carry)
            }
            let residual: UniTSResidual
            do {
                residual = try UniTSRuntime().reconstruct(win, prompt: prompt)
            } catch {
                return unavailable(.empty, nowUnix: nowUnix, interval: liveIntervalMinutes, carry: carry)
            }
            return combine(window: win, residual: residual, prompt: prompt, evaluations: evaluations,
                           dayLog: dayLog, nowUnix: nowUnix, interval: liveIntervalMinutes, carry: &carry)
        }
    }

    public enum WatchdogInject: String, Sendable {
        case quiet
        case severe
    }

    static func combine(window: WatchdogWindow,
                        residual: UniTSResidual,
                        prompt: UniTSPrompt,
                        evaluations: [LBEvaluation],
                        dayLog: LBDayLog?,
                        nowUnix: Int,
                        interval: Int,
                        carry: inout WatchdogCarry) -> WatchdogResult {
        let confounded = dayLog?.confoundsUsual == true
        let lastHR = UniTSRuntime.lastPaired(window.hr, residual.reconstructedHR)
        let lastRHR = UniTSRuntime.lastPaired(window.rhr, residual.reconstructedRHR)
        let lastHRV = UniTSRuntime.lastPaired(window.hrv, residual.reconstructedHRV)
        let lastTemp = UniTSRuntime.lastPaired(window.temp, residual.reconstructedTemp)
        let lastResp = UniTSRuntime.lastPaired(window.resp, residual.reconstructedResp)
        let lastSpO2 = UniTSRuntime.lastPaired(window.spo2, residual.reconstructedSpO2)
        let adapted = WatchdogAdaptive.apply(residual, window: window,
                                             lastHR: lastHR, lastRHR: lastRHR, lastHRV: lastHRV,
                                             lastTemp: lastTemp, lastResp: lastResp, lastSpO2: lastSpO2,
                                             carry: &carry)
        let safety = WatchdogSafety.fired(window)
        let previousSafety = carry.lastSafety
        let previousFused = carry.lastJointEnergy
        let eHR = adapted.energy(for: .hr)
        let eRHR = adapted.energy(for: .rhr)
        let eHRV = adapted.energy(for: .hrv)
        let eTemp = adapted.energy(for: .temp)
        let eResp = adapted.energy(for: .resp)
        let eSpO2 = adapted.energy(for: .spo2)
        let reconJ = adapted.jointEnergy
        if reconJ < WatchdogCalibration.tNote {
            carry.quietJointEma = 0.92 * carry.quietJointEma + 0.08 * reconJ
        }
        let personalT = carry.quietN >= 8 ? min(0.4, carry.quietJointEma) : 0
        let forecast = WatchdogForecastRuntime().step(window: window, residual: adapted, prompt: prompt,
                                                     carry: carry, nowUnix: nowUnix)
        let fusedRaw = reconJ < WatchdogCalibration.tNote
            ? reconJ
            : WatchdogScores.fused(recon: reconJ, forecast: forecast.energy)
        let fused = max(0, fusedRaw - personalT)
        var hot: [String] = []
        if eHR >= WatchdogCalibration.tNote { hot.append("HR") }
        if eRHR >= WatchdogCalibration.tNote { hot.append("RHR") }
        if eHRV >= WatchdogCalibration.tNote { hot.append("HRV") }
        if eTemp >= WatchdogCalibration.tNote { hot.append("Temp") }
        if eResp >= WatchdogCalibration.tNote { hot.append("Resp") }
        if eSpO2 >= WatchdogCalibration.tNote { hot.append("SpO2") }
        let personalOff = evaluations.contains {
            $0.alertEligible && LongitudinalBaseline.isOffUsual(z: $0.zLong, k: $0.kBandUsed)
        }
        if fused >= WatchdogCalibration.tNote || personalOff {
            carry.consecutiveMismatchTicks += 1
            carry.consecutiveInRangeTicks = 0
        } else {
            carry.consecutiveMismatchTicks = 0
            carry.consecutiveInRangeTicks += 1
        }
        let persistTicks = carry.consecutiveMismatchTicks

        let severity = WatchdogScores.severity(fused: fused, persistTicks: persistTicks, safety: safety,
                                               confounded: confounded, personalOff: personalOff)

        let hadEpisode = carry.episodeId != nil
        if severity == .withinLimits || severity == .note {
            // keep episode id while recovering
        } else if carry.episodeId == nil {
            carry.episodeId = "wd-\(nowUnix)"
        }
        let openedEpisode = !hadEpisode && carry.episodeId != nil
            && (severity == .candidate || severity == .active || severity == .severe)

        let state = nextState(severity: severity, carry: &carry)
        let (notify, reason) = WatchdogNotifyPolicy.decision(severity: severity, openedEpisode: openedEpisode,
                                                            safety: safety, previousSafety: previousSafety,
                                                            fused: fused, previousFused: previousFused,
                                                            recon: reconJ, previousRecon: carry.lastReconEnergy)
        if notify { carry.lastNotifiedAt = nowUnix }
        carry.lastJointEnergy = fused
        carry.lastReconEnergy = reconJ
        carry.lastSafety = safety
        if forecast.ranStudent { carry.lastForecastUnix = nowUnix }
        carry.lastForecastHR = forecast.nextHR
        carry.lastForecastHRV = forecast.nextHRV
        carry.lastForecastTemp = forecast.nextTemp
        carry.lastForecastResp = forecast.nextResp
        carry.lastForecastRHR = forecast.nextRHR
        carry.lastForecastSpO2 = forecast.nextSpO2

        let trustHR = predictionTrust(energy: eHR, usual: prompt.hr, coverage: window.coverage,
                                      usualTrust: layer1UsualTrust(evaluations, matching: [.awakeRestHR, .continuousHR]),
                                      persistTicks: persistTicks, hot: hot.contains("HR"))
        let trustRHR = predictionTrust(energy: eRHR, usual: prompt.rhr, coverage: window.coverage,
                                       usualTrust: layer1UsualTrust(evaluations, matching: [.sleepRHR]),
                                       persistTicks: persistTicks, hot: hot.contains("RHR"))
        let trustHRV = {
            var t = predictionTrust(energy: eHRV, usual: prompt.hrvAwake ?? prompt.hrv, coverage: window.coverage,
                                    usualTrust: layer1UsualTrust(evaluations, matching: prompt.hrvAwake != nil
                                                                 ? [.awakeRestHRVLn] : [.sleepHRVLn]),
                                    persistTicks: persistTicks, hot: hot.contains("HRV"))
            if prompt.hrvAnchoredInSleep { t = min(t, 28) }
            return t
        }()
        let trustTemp = predictionTrust(energy: eTemp, usual: prompt.temp, coverage: window.coverage,
                                        usualTrust: layer1UsualTrust(evaluations, matching: [.sleepTemp]),
                                        persistTicks: persistTicks, hot: hot.contains("Temp"))
        let trustResp = predictionTrust(energy: eResp, usual: prompt.resp, coverage: window.coverage,
                                        usualTrust: layer1UsualTrust(evaluations, matching: [.sleepResp]),
                                        persistTicks: persistTicks, hot: hot.contains("Resp"))
        let trustSpO2 = predictionTrust(energy: eSpO2, usual: prompt.spo2, coverage: window.coverage,
                                        usualTrust: layer1UsualTrust(evaluations, matching: [.sleepSpO2Mean]),
                                        persistTicks: persistTicks, hot: hot.contains("SpO2"))

        let signals: [WatchdogSignalEvidence] = [
            .init(name: "HR", observed: lastHR?.obs, usual: prompt.hr,
                  reconstructed: lastHR?.hat, energy: eHR, unit: "bpm", trustPct: trustHR,
                  rangeHalf: adapted.rangeHalf(for: .hr)),
            .init(name: "RHR", observed: lastRHR?.obs, usual: prompt.rhr,
                  reconstructed: lastRHR?.hat, energy: eRHR, unit: "bpm", trustPct: trustRHR,
                  rangeHalf: adapted.rangeHalf(for: .rhr)),
            .init(name: "HRV", observed: lastHRV?.obs, usual: prompt.hrvAwake ?? prompt.hrv,
                  reconstructed: lastHRV?.hat, energy: eHRV, unit: "ms", trustPct: trustHRV,
                  rangeHalf: adapted.rangeHalf(for: .hrv)),
            .init(name: "Temp", observed: lastTemp?.obs, usual: prompt.temp,
                  reconstructed: lastTemp?.hat, energy: eTemp, unit: "°C", trustPct: trustTemp,
                  rangeHalf: adapted.rangeHalf(for: .temp)),
            .init(name: "Resp", observed: lastResp?.obs, usual: prompt.resp,
                  reconstructed: lastResp?.hat, energy: eResp, unit: "/min", trustPct: trustResp,
                  rangeHalf: adapted.rangeHalf(for: .resp)),
            .init(name: "SpO2", observed: lastSpO2?.obs, usual: prompt.spo2,
                  reconstructed: lastSpO2?.hat, energy: eSpO2, unit: "%", trustPct: trustSpO2,
                  rangeHalf: adapted.rangeHalf(for: .spo2)),
            .init(name: "Motion", observed: last(window.motion), usual: nil,
                  reconstructed: nil, energy: 0, unit: "", trustPct: 0)
        ]

        carry.lastHeldResp = lastResp?.obs ?? carry.lastHeldResp
        carry.lastHeldHRV = lastHRV?.obs ?? carry.lastHeldHRV
        carry.lastHeldTemp = lastTemp?.obs ?? carry.lastHeldTemp
        carry.lastHeldSpO2 = lastSpO2?.obs ?? carry.lastHeldSpO2

        let pageTrust: Int
        if hot.isEmpty {
            pageTrust = [trustHR, trustRHR, trustHRV, trustTemp, trustResp, trustSpO2].filter { $0 > 0 }.min()
                ?? Int((window.coverage * 100).rounded())
        } else {
            pageTrust = signals.filter { hot.contains($0.name) }.map(\.trustPct).min() ?? 0
        }

        let copy = copyFor(severity: severity, state: state, confounded: confounded)

        return WatchdogResult(
            severity: severity,
            episodeState: state,
            episodeId: carry.episodeId,
            headline: copy.headline,
            episodeLine: copy.episodeLine,
            monitoringCurrent: window.newestAgeSeconds <= 180,
            monitoringLabel: window.newestAgeSeconds <= 180 ? "CURRENT" : "WAITING",
            mode: "live",
            unavailable: nil,
            coverage: window.coverage,
            hrSource: window.hrSource.rawValue,
            family: window.family.rawValue,
            lastTickUnix: nowUnix,
            windowStartUnix: window.startUnix,
            horizonHR: window.hr.map { $0 ?? .nan },
            horizonHRV: window.hrv.map { $0 ?? .nan },
            horizonTemp: window.temp.map { $0 ?? .nan },
            horizonResp: window.resp.map { $0 ?? .nan },
            horizonRHR: window.rhr.map { $0 ?? .nan },
            horizonSpO2: window.spo2.map { $0 ?? .nan },
            reconstructedHR: adapted.reconstructedHR.map { $0 ?? .nan },
            reconstructedHRV: adapted.reconstructedHRV.map { $0 ?? .nan },
            reconstructedTemp: adapted.reconstructedTemp.map { $0 ?? .nan },
            reconstructedResp: adapted.reconstructedResp.map { $0 ?? .nan },
            reconstructedRHR: adapted.reconstructedRHR.map { $0 ?? .nan },
            reconstructedSpO2: adapted.reconstructedSpO2.map { $0 ?? .nan },
            rangeHR: adapted.scaleHR,
            rangeHRV: adapted.scaleHRV,
            rangeTemp: adapted.scaleTemp,
            rangeResp: adapted.scaleResp,
            rangeRHR: adapted.scaleRHR,
            rangeSpO2: adapted.scaleSpO2,
            signals: signals,
            contributing: hot,
            qualityLine: String(format: "Coverage %.0f%% · %@ · %@ · tick %ds",
                                window.coverage * 100,
                                WatchdogActivityRuntime.displayName(
                                    WatchdogActivityClass.labels(logits: window.activityLogits).last ?? "unknown"),
                                adapted.modelVersion == WatchdogConfig.fallbackModelVersion
                                    ? "prior fallback" : adapted.modelVersion,
                                WatchdogConfig.tickSeconds),
            versionLine: "\(WatchdogConfig.configVersion) · \(adapted.modelVersion)+\(WatchdogForecastRuntime.modelVersion) · episode \(carry.episodeId ?? "none")",
            shouldNotify: notify,
            carry: carry,
            modelVersion: adapted.modelVersion,
            trustPct: pageTrust,
            jointEnergy: reconJ,
            forecastEnergy: forecast.energy,
            fusedEnergy: fused,
            promptSource: prompt.source,
            notifyReason: reason,
            activityLabel: WatchdogActivityClass.labels(logits: window.activityLogits).last ?? WatchdogActivityClass.unknown.rawValue,
            activityDetail: WatchdogActivityRuntime.displayName(
                WatchdogActivityClass.labels(logits: window.activityLogits).last ?? WatchdogActivityClass.unknown.rawValue),
            sigmaAdaptive: carry.quietN >= 8,
            qualityGate: "bucket-v1"
        )
    }

    /// Layer 1 TRUST for the series that feed this live channel. Two copies are never averaged:
    /// each evaluation contributes `max(long, week)`, then the best matching series is kept.
    static func layer1UsualTrust(_ evaluations: [LBEvaluation], matching: [LBSeries]) -> Int {
        evaluations
            .filter { matching.contains($0.series) }
            .map { max($0.usualTrustPctLong, $0.usualTrustPct7) }
            .max() ?? 0
    }

    /// Live TRUST v2 — how much to believe this vital’s in-range / off call. Not health, not a diagnosis.
    ///
    /// `50×U + 35×C + 15×E`, then hard caps:
    /// - **U** personal usual: Layer 1 TRUST 0…1, but only if that TRUST is at least 35 (a shown usual).
    /// - **C** coverage: fraction of the 30-minute HR window that is filled.
    /// - **E** evidence: in-range = how close to the reconstruction (`1 − energy/tau`);
    ///   off = how large and how persistent the residual is.
    /// - No shown personal usual → cap **28**. No prompt number at all → cap **18**.
    public static func predictionTrust(energy: Double, usual: Double?, coverage: Double,
                                       usualTrust: Int, persistTicks: Int, hot: Bool) -> Int {
        let coverage01 = max(0, min(1, coverage))
        let usual01 = max(0, min(1, Double(usualTrust) / 100.0))
        let hasShownUsual = usual != nil && usualTrust >= LongitudinalBaseline.trustHideThreshold
        let tau = max(WatchdogCalibration.tNote, 0.01)
        let tauSevere = max(WatchdogCalibration.tSevere, 0.01)
        let evidence: Double
        if hot {
            let persist = min(1, Double(max(persistTicks, 0)) / 2.0)
            let magnitude = min(1, energy / tauSevere)
            evidence = 0.40 + 0.60 * magnitude * max(0.35, persist)
        } else {
            evidence = max(0, 1 - energy / tau)
        }
        var score = 50.0 * (hasShownUsual ? usual01 : 0)
            + 35.0 * coverage01
            + 15.0 * evidence
        if !hasShownUsual { score = min(score, 28) }
        if usual == nil { score = min(score, 18) }
        return max(0, min(100, Int(score.rounded())))
    }

    static func safetyCap(window: WatchdogWindow) -> Bool {
        let still = WatchdogActivityRuntime.isStillish(window.activityLogits)
            || (last(window.motion) ?? 0) < 0.15
        guard still else { return false }
        if let hi = window.hrMax.compactMap({ $0 }).max(), hi > WatchdogConfig.restHrHigh { return true }
        if let lo = window.hrMin.compactMap({ $0 }).min(), lo > 0, lo < WatchdogConfig.restHrLow { return true }
        if let t = last(window.temp), t < WatchdogConfig.tempLowC || t > WatchdogConfig.tempHighC { return true }
        if let r = last(window.resp), r < WatchdogConfig.respLow || r > WatchdogConfig.respHigh { return true }
        if let h = last(window.hrv), h > 0, h < WatchdogConfig.rmssdLow || h > WatchdogConfig.rmssdHigh { return true }
        return false
    }

    static func nextState(severity: WatchdogSeverity, carry: inout WatchdogCarry) -> WatchdogEpisodeState {
        let prior = carry.priorState
        let open: Set<WatchdogEpisodeState> = [.candidate, .active, .recovering]
        let state: WatchdogEpisodeState
        switch severity {
        case .dataUnavailable:
            carry.consecutiveQuietTicks = 0
            state = .dataUnavailable
        case .candidate:
            carry.consecutiveQuietTicks = 0
            state = .candidate
        case .active, .severe:
            carry.consecutiveQuietTicks = 0
            state = .active
        case .note:
            if open.contains(prior ?? .withinLimits) {
                carry.consecutiveQuietTicks += 1
                state = carry.consecutiveQuietTicks >= 2 ? .resolved : .recovering
            } else {
                carry.consecutiveQuietTicks = 0
                state = .withinLimits
            }
        case .withinLimits:
            if open.contains(prior ?? .withinLimits) {
                carry.consecutiveQuietTicks += 1
                state = carry.consecutiveQuietTicks >= 2 ? .resolved : .recovering
            } else {
                carry.consecutiveQuietTicks = 0
                state = .withinLimits
            }
        }
        if state == .resolved || (state == .withinLimits && carry.consecutiveMismatchTicks == 0) {
            if carry.consecutiveInRangeTicks >= WatchdogCalibration.rearmTicks {
                carry.episodeId = nil
            }
        }
        carry.priorState = state
        return state
    }

    static func copyFor(severity: WatchdogSeverity, state: WatchdogEpisodeState,
                        confounded: Bool) -> (headline: String, episodeLine: String) {
        if state == .recovering {
            return ("This stretch is settling toward your usual.",
                    "Recovering · waiting for two quiet ticks · not a diagnosis")
        }
        if state == .resolved {
            return ("This stretch looks like you.",
                    "Resolved · episode closed")
        }
        switch severity {
        case .withinLimits:
            return ("This stretch looks like you.",
                    "Within limits · no current deviation detected")
        case .note:
            return ("One odd reading. Noted, not an alert.",
                    "Note · one signal, one window")
        case .candidate:
            return ("A pattern is forming.",
                    confounded
                    ? "Candidate · logged context is holding the page"
                    : "Candidate · waiting for the stretch to persist")
        case .active:
            return ("This stretch is unlike your usual.",
                    "Active · several signals, still not a diagnosis")
        case .severe:
            return ("This stretch is far from your reconstructed range.",
                    "Severe · local notice if permitted · not a diagnosis")
        case .dataUnavailable:
            return ("Watching is not current.",
                    "Data unavailable · not recovered")
        }
    }

    static func last(_ xs: [Double?]) -> Double? {
        xs.reversed().first(where: { $0 != nil }) ?? nil
    }

    static func unavailable(_ reason: WatchdogUnavailable, nowUnix: Int, interval: Int,
                            carry: WatchdogCarry) -> WatchdogResult {
        var carry = carry
        carry.consecutiveQuietTicks = 0
        carry.priorState = .dataUnavailable
        if reason == .wristOff {
            carry.lastHeldResp = nil
            carry.lastHeldHRV = nil
            carry.lastHeldTemp = nil
            carry.lastHeldSpO2 = nil
        }
        return WatchdogResult(
            severity: .dataUnavailable,
            episodeState: .dataUnavailable,
            episodeId: carry.episodeId,
            headline: "Watching is not current.",
            episodeLine: "Data unavailable (\(reason.rawValue)) · not recovered",
            monitoringCurrent: false,
            monitoringLabel: reason == .stale ? "STALE" : "NOT CURRENT",
            mode: "live",
            unavailable: reason,
            coverage: 0,
            hrSource: "",
            family: "",
            lastTickUnix: nowUnix,
            windowStartUnix: nowUnix - WatchdogConfig.contextSeconds,
            horizonHR: [],
            horizonHRV: [],
            horizonTemp: [],
            horizonResp: [],
            horizonRHR: [],
            horizonSpO2: [],
            reconstructedHR: [],
            reconstructedHRV: [],
            reconstructedTemp: [],
            reconstructedResp: [],
            reconstructedRHR: [],
            reconstructedSpO2: [],
            rangeHR: [],
            rangeHRV: [],
            rangeTemp: [],
            rangeResp: [],
            rangeRHR: [],
            rangeSpO2: [],
            signals: [],
            contributing: [],
            qualityLine: "Tick \(WatchdogConfig.tickSeconds)s · \(reason.rawValue)",
            versionLine: "\(WatchdogConfig.configVersion) · \(WatchdogConfig.modelVersion)",
            shouldNotify: false,
            carry: carry,
            modelVersion: WatchdogConfig.modelVersion,
            trustPct: 0,
            jointEnergy: 0,
            forecastEnergy: 0,
            fusedEnergy: 0,
            promptSource: .population,
            notifyReason: "unavailable",
            activityLabel: WatchdogActivityClass.unknown.rawValue,
            activityDetail: WatchdogActivityRuntime.displayName(WatchdogActivityClass.unknown.rawValue),
            sigmaAdaptive: false,
            qualityGate: reason.rawValue
        )
    }

    static func applyInject(_ inject: WatchdogInject, nowUnix: Int, interval: Int,
                            carry: inout WatchdogCarry) -> WatchdogResult {
        let feed: WatchdogFeed
        let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)
        switch inject {
        case .quiet:
            feed = Self.syntheticFeed(now: nowUnix, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        case .severe:
            feed = Self.syntheticFeed(now: nowUnix, hr: 96, hrv: 16, temp: 34.3, resp: 22, motion: 0)
        }
        let win = WatchdogWindowBuilder.build(feed)
        if inject == .severe { carry.consecutiveMismatchTicks = max(carry.consecutiveMismatchTicks, 1) }
        return evaluate(window: win, prompt: prompt, nowUnix: nowUnix, liveIntervalMinutes: interval,
                        previous: carry, inject: Optional<WatchdogInject>.none)
    }

    public static func syntheticFeed(now: Int, hr: Double, hrv: Double, temp: Double,
                                     resp: Double, motion: Double,
                                     family: DeviceFamily = .whoop4) -> WatchdogFeed {
        let start = now - WatchdogConfig.contextSeconds
        var hrs: [HRSample] = []
        var rrs: [RRInterval] = []
        var temps: [WatchdogScalarSample] = []
        var resps: [WatchdogScalarSample] = []
        var mots: [WatchdogScalarSample] = []
        var spo2: [WatchdogScalarSample] = []
        for t in start..<now {
            hrs.append(HRSample(ts: t, bpm: Int(hr.rounded())))
            if t % 1 == 0 {
                let rrMs = Int((60000.0 / max(hr, 30)).rounded())
                rrs.append(RRInterval(ts: t, rrMs: rrMs))
            }
            temps.append(WatchdogScalarSample(ts: t, value: temp))
            resps.append(WatchdogScalarSample(ts: t, value: resp))
            mots.append(WatchdogScalarSample(ts: t, value: motion))
            spo2.append(WatchdogScalarSample(ts: t, value: 97))
        }
        // RMSSD is computed from RR; for inject we also stamp 5-min identity by using a jittered RR for quiet,
        // and a tight RR for low HRV. Low HRV: smaller beat-to-beat diff.
        if hrv < 30 {
            rrs = (start..<now).map { t in
                RRInterval(ts: t, rrMs: Int((60000.0 / max(hr, 30)).rounded()))
            }
        } else {
            rrs = (start..<now).enumerated().map { i, t in
                let jitter = (i % 3 == 0) ? 40 : -20
                return RRInterval(ts: t, rrMs: max(400, Int((60000.0 / max(hr, 30)).rounded()) + jitter))
            }
        }
        return WatchdogFeed(family: family, hrSource: .v18, nowUnix: now,
                            hr: hrs, rr: rrs, skinTempC: temps, respPerMin: resps, motion: mots,
                            spo2Pct: spo2)
    }
}
