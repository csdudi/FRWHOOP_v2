import Foundation

/// Read-only usual prompt. Never written back into Layer 1.
public struct UniTSPrompt: Equatable, Sendable {
    public var hr: Double?
    public var rhr: Double?
    public var hrv: Double?
    /// Established awake-rest HRV (ms). Never averaged with sleep. Nil unless that copy is shown.
    public var hrvAwake: Double?
    /// `hrv` came from overnight sleep HRV; live rest is then scaled by `hrvSleepToAwake`.
    public var hrvAnchoredInSleep: Bool
    public var source: WatchdogPromptSource
    public var temp: Double?
    public var resp: Double?
    public var spo2: Double?
    /// Personal residual scale in native units (Layer 1 display MAD). Floors apply in `UniTSRuntime`.
    public var scaleHR: Double
    public var scaleRHR: Double
    public var scaleHRV: Double
    public var scaleTemp: Double
    public var scaleResp: Double
    public var scaleSpO2: Double

    public init(hr: Double? = nil, rhr: Double? = nil, hrv: Double? = nil,
                hrvAwake: Double? = nil, hrvAnchoredInSleep: Bool = false,
                source: WatchdogPromptSource = .awakeRest,
                temp: Double? = nil, resp: Double? = nil, spo2: Double? = nil,
                scaleHR: Double = WatchdogConfig.hrScale,
                scaleRHR: Double = WatchdogConfig.hrScale,
                scaleHRV: Double = WatchdogConfig.hrvScale,
                scaleTemp: Double = WatchdogConfig.tempScale,
                scaleResp: Double = WatchdogConfig.respScale,
                scaleSpO2: Double = WatchdogConfig.spo2Scale) {
        self.hr = hr
        self.rhr = rhr
        self.hrv = hrv
        self.hrvAwake = hrvAwake
        self.hrvAnchoredInSleep = hrvAnchoredInSleep
        self.source = source
        self.temp = temp
        self.resp = resp
        self.spo2 = spo2
        self.scaleHR = scaleHR
        self.scaleRHR = scaleRHR
        self.scaleHRV = scaleHRV
        self.scaleTemp = scaleTemp
        self.scaleResp = scaleResp
        self.scaleSpO2 = scaleSpO2
    }

    public static func from(evaluations: [LBEvaluation]) -> UniTSPrompt {
        func center(_ series: LBSeries) -> Double? {
            evaluations.first(where: { $0.series == series })?.copyLong?.centerDisplay
            ?? evaluations.first(where: { $0.series == series })?.copy7?.centerDisplay
        }
        func shownCenter(_ series: LBSeries) -> Double? {
            guard let ev = evaluations.first(where: { $0.series == series }) else { return nil }
            let trust = max(ev.usualTrustPctLong, ev.usualTrustPct7)
            guard trust >= LongitudinalBaseline.trustHideThreshold else { return nil }
            return ev.copyLong?.centerDisplay ?? ev.copy7?.centerDisplay
        }
        let sleepHRV = center(.sleepHRVLn)
        let awakeHRV = shownCenter(.awakeRestHRVLn)
        // Instant HR usual is daytime rest / all-day HR. Sleep RHR never fills this slot.
        let hr = shownCenter(.awakeRestHR) ?? shownCenter(.continuousHR)
        // Still RHR usual is overnight / still-gated only. Daytime HR never fills this slot.
        let rhr = shownCenter(.sleepRHR) ?? center(.sleepRHR)
        let source: WatchdogPromptSource
        if hr == nil && rhr == nil && sleepHRV == nil {
            source = .population
        } else if hr != nil && rhr != nil {
            source = .mixed
        } else if hr != nil {
            source = .awakeRest
        } else {
            source = .sleep
        }
        return UniTSPrompt(
            hr: hr,
            rhr: rhr,
            hrv: sleepHRV,
            hrvAwake: awakeHRV,
            hrvAnchoredInSleep: sleepHRV != nil && awakeHRV == nil,
            source: source,
            temp: center(.sleepTemp),
            resp: center(.sleepResp),
            spo2: center(.sleepSpO2Mean),
            scaleHR: displayMAD(evaluations, .awakeRestHR, shownOnly: true)
                ?? displayMAD(evaluations, .continuousHR, shownOnly: true)
                ?? WatchdogConfig.hrScale,
            scaleRHR: displayMAD(evaluations, .sleepRHR, shownOnly: false)
                ?? WatchdogConfig.hrScale,
            scaleHRV: (awakeHRV != nil ? displayMAD(evaluations, .awakeRestHRVLn, shownOnly: true) : nil)
                ?? displayMAD(evaluations, .sleepHRVLn, shownOnly: false)
                ?? WatchdogConfig.hrvScale,
            scaleTemp: displayMAD(evaluations, .sleepTemp, shownOnly: false) ?? WatchdogConfig.tempScale,
            scaleResp: displayMAD(evaluations, .sleepResp, shownOnly: false) ?? WatchdogConfig.respScale,
            scaleSpO2: displayMAD(evaluations, .sleepSpO2Mean, shownOnly: false) ?? WatchdogConfig.spo2Scale
        )
    }

    /// Half the Layer 1 usual band in display units, divided by k → 1 MAD. Same copy as the prompt; never averaged.
    static func displayMAD(_ evaluations: [LBEvaluation], _ series: LBSeries, shownOnly: Bool) -> Double? {
        guard let ev = evaluations.first(where: { $0.series == series }) else { return nil }
        if shownOnly {
            let trust = max(ev.usualTrustPctLong, ev.usualTrustPct7)
            guard trust >= LongitudinalBaseline.trustHideThreshold else { return nil }
        }
        let copy = ev.copyLong ?? ev.copy7
        guard let copy else { return nil }
        let half = max(copy.bandHiDisplay - copy.centerDisplay, copy.centerDisplay - copy.bandLoDisplay)
        let k = max(ev.kBandUsed, 1)
        let mad = half / k
        return mad.isFinite && mad > 0 ? mad : nil
    }
}

public struct UniTSResidual: Equatable, Sendable {
    public var energy: [WatchdogWindow.Channel: Double]
    public var rangeHalf: [WatchdogWindow.Channel: Double]
    /// Per-minute predicted half-width around \(\hat{x}_t\) (native units).
    public var scaleHR: [Double]
    public var scaleRHR: [Double]
    public var scaleHRV: [Double]
    public var scaleTemp: [Double]
    public var scaleResp: [Double]
    public var scaleSpO2: [Double]
    public var reconstructedHR: [Double?]
    public var reconstructedRHR: [Double?]
    public var reconstructedHRV: [Double?]
    public var reconstructedTemp: [Double?]
    public var reconstructedResp: [Double?]
    public var reconstructedSpO2: [Double?]
    public var modelVersion: String
    public var jointEnergy: Double

    public func energy(for channel: WatchdogWindow.Channel) -> Double {
        energy[channel] ?? 0
    }

    public func rangeHalf(for channel: WatchdogWindow.Channel) -> Double {
        rangeHalf[channel] ?? 0
    }

    public func scale(for channel: WatchdogWindow.Channel) -> [Double] {
        switch channel {
        case .hr: return scaleHR
        case .rhr: return scaleRHR
        case .hrv: return scaleHRV
        case .temp: return scaleTemp
        case .resp: return scaleResp
        case .spo2: return scaleSpO2
        case .motion: return []
        }
    }
}

/// Per-vital reconstruction (UniTS AD job). Frozen physiological priors, no on-device training.
/// Each channel has its own coupling to motion / time; they are never one shared slope.
public struct UniTSRuntime: Sendable {
    public init() {}

    public func reconstruct(_ window: WatchdogWindow, prompt: UniTSPrompt) throws -> UniTSResidual {
        let occ = Self.occupancy(window)
        if let residual = Self.coreMLResidual(window: window, prompt: prompt, occupancy: occ) {
            return residual
        }
        return Self.priorResidual(window: window, prompt: prompt, occupancy: occ)
    }

    /// Core ML UniTS-AD checkpoint: both \(\hat{x}\) and \(\sigma\) come from one inference.
    static func coreMLResidual(window: WatchdogWindow, prompt: UniTSPrompt, occupancy: [Double]) -> UniTSResidual? {
        let bases = resolvedBases(window: window, prompt: prompt)
        let personal = [prompt.scaleHR, prompt.scaleRHR, prompt.scaleHRV,
                        prompt.scaleTemp, prompt.scaleResp, prompt.scaleSpO2]
        var occ = occupancy
        if occ.count < WatchdogConfig.seqLen {
            occ.append(contentsOf: Array(repeating: occ.last ?? 0, count: WatchdogConfig.seqLen - occ.count))
        }
        if occ.count > WatchdogConfig.seqLen { occ = Array(occ.prefix(WatchdogConfig.seqLen)) }
        guard let pred = UniTSCoreMLSession.shared.predict(
            occupancy: occ,
            prompt: bases.map { $0 ?? 0 },
            personalScale: personal,
            observed: packObserved(window, bases: bases)
        ) else { return nil }
        func hat(_ channel: Int, valid: Bool) -> [Double?] {
            guard valid, channel < pred.hat.count else {
                return Array(repeating: nil, count: WatchdogConfig.seqLen)
            }
            return pred.hat[channel].map { Optional($0) }
        }
        func scale(_ channel: Int) -> [Double] {
            guard channel < pred.sigma.count else {
                return Array(repeating: personal[channel], count: WatchdogConfig.seqLen)
            }
            return pred.sigma[channel]
        }
        let hatHR = hat(0, valid: bases[0] != nil)
        let hatRHR = hat(1, valid: bases[1] != nil)
        let hatHRV = hat(2, valid: bases[2] != nil)
        let hatTemp = hat(3, valid: bases[3] != nil)
        let hatResp = hat(4, valid: bases[4] != nil)
        let hatSpO2 = hat(5, valid: bases[5] != nil)
        return finishResidual(
            window: window, prompt: prompt,
            hatHR: hatHR, hatRHR: hatRHR, hatHRV: hatHRV,
            hatTemp: hatTemp, hatResp: hatResp, hatSpO2: hatSpO2,
            scaleHR: scale(0), scaleRHR: scale(1), scaleHRV: scale(2),
            scaleTemp: scale(3), scaleResp: scale(4), scaleSpO2: scale(5),
            modelVersion: WatchdogConfig.modelVersion
        )
    }

    static func priorResidual(window: WatchdogWindow, prompt: UniTSPrompt, occupancy: [Double]) -> UniTSResidual {
        physicsResidual(window: window, prompt: prompt, occupancy: occupancy)
    }

    /// Physics prior used as Core ML input / load-fail fallback. Not the v2 detector.
    static func physicsResidual(window: WatchdogWindow, prompt: UniTSPrompt, occupancy: [Double]) -> UniTSResidual {
        let hatHR = reconstructHR(observed: window.hr, prompt: prompt.hr, occupancy: occupancy)
        let hatRHR = reconstructRHR(observed: window.rhr, prompt: prompt.rhr)
        let hatHRV = reconstructHRV(observed: window.hrv, prompt: prompt, occupancy: occupancy)
        let hatTemp = reconstructTemp(observed: window.temp, prompt: prompt.temp, occupancy: occupancy)
        let hatResp = reconstructResp(observed: window.resp, prompt: prompt.resp, occupancy: occupancy)
        let hatSpO2 = reconstructSpO2(observed: window.spo2, prompt: prompt.spo2, occupancy: occupancy)

        let hrBase = prompt.hr ?? WatchdogPopulationPriors.hr
        let hrvBase = prompt.hrvAwake ?? prompt.hrv ?? WatchdogPopulationPriors.hrv
        let respBase = prompt.resp ?? WatchdogPopulationPriors.resp
        let hrSmooth = trailingMean(occupancy, taps: WatchdogConfig.hrMotionSmoothMinutes)
        let hrvSmooth = trailingMean(occupancy, taps: WatchdogConfig.hrvMotionSmoothMinutes)
        let tempLag = trailingMean(occupancy, taps: WatchdogConfig.tempLagMinutes)
        let respSmooth = trailingMean(occupancy, taps: WatchdogConfig.respSmoothMinutes)

        let scaleHR = predictedScale(
            hat: hatHR, floor: WatchdogConfig.hrScale, personal: prompt.scaleHR,
            reconFraction: WatchdogConfig.hrReconFraction,
            coupling: hrSmooth.map { WatchdogConfig.hrEffortUncert * hrBase * pow(max(0, $0), WatchdogConfig.hrMotionPower) })
        let scaleRHR = predictedScale(
            hat: hatRHR, floor: WatchdogConfig.hrScale, personal: prompt.scaleRHR,
            reconFraction: WatchdogConfig.rhrReconFraction,
            coupling: Array(repeating: 0, count: hatRHR.count))
        let scaleHRV = predictedScale(
            hat: hatHRV, floor: WatchdogConfig.hrvScale, personal: prompt.scaleHRV,
            reconFraction: WatchdogConfig.hrvReconFraction,
            coupling: hrvSmooth.map { WatchdogConfig.hrvDropUncertMs * $0 * (hrvBase / WatchdogConfig.hrvDropRefMs) })
        let scaleTemp = predictedScale(
            hat: hatTemp, floor: WatchdogConfig.tempScale, personal: prompt.scaleTemp,
            reconFraction: WatchdogConfig.tempReconFraction,
            coupling: tempLag.map { WatchdogConfig.tempGainUncert * $0 })
        let scaleResp = predictedScale(
            hat: hatResp, floor: WatchdogConfig.respScale, personal: prompt.scaleResp,
            reconFraction: WatchdogConfig.respReconFraction,
            coupling: respSmooth.map { WatchdogConfig.respEffortUncert * respBase * pow(max(0, $0), WatchdogConfig.respMotionPower) })
        let scaleSpO2 = predictedScale(
            hat: hatSpO2, floor: WatchdogConfig.spo2Scale, personal: prompt.scaleSpO2,
            reconFraction: WatchdogConfig.spo2ReconFraction,
            coupling: Array(repeating: 0, count: hatSpO2.count))
        return finishResidual(
            window: window, prompt: prompt,
            hatHR: hatHR, hatRHR: hatRHR, hatHRV: hatHRV,
            hatTemp: hatTemp, hatResp: hatResp, hatSpO2: hatSpO2,
            scaleHR: scaleHR, scaleRHR: scaleRHR, scaleHRV: scaleHRV,
            scaleTemp: scaleTemp, scaleResp: scaleResp, scaleSpO2: scaleSpO2,
            modelVersion: WatchdogConfig.fallbackModelVersion
        )
    }

    static func resolvedBases(window: WatchdogWindow, prompt: UniTSPrompt) -> [Double?] {
        [
            prompt.hr ?? WatchdogPopulationPriors.hr,
            prompt.rhr ?? WatchdogPopulationPriors.rhr,
            prompt.hrvAwake ?? prompt.hrv ?? WatchdogPopulationPriors.hrv,
            prompt.temp ?? WatchdogPopulationPriors.temp,
            prompt.resp ?? WatchdogPopulationPriors.resp,
            prompt.spo2 ?? WatchdogPopulationPriors.spo2
        ]
    }

    static func packObserved(_ window: WatchdogWindow, bases: [Double?]) -> [[Double]] {
        func fill(_ xs: [Double?], _ base: Double?) -> [Double] {
            let seed = base ?? 0
            var last = seed
            return (0..<WatchdogConfig.seqLen).map { i in
                if i < xs.count, let v = xs[i] {
                    last = v
                    return v
                }
                return last
            }
        }
        return [
            fill(window.hr, bases[0]),
            fill(window.rhr, bases[1]),
            fill(window.hrv, bases[2]),
            fill(window.temp, bases[3]),
            fill(window.resp, bases[4]),
            fill(window.spo2, bases[5])
        ]
    }

    static func finishResidual(window: WatchdogWindow, prompt: UniTSPrompt,
                               hatHR: [Double?], hatRHR: [Double?], hatHRV: [Double?],
                               hatTemp: [Double?], hatResp: [Double?], hatSpO2: [Double?],
                               scaleHR: [Double], scaleRHR: [Double], scaleHRV: [Double],
                               scaleTemp: [Double], scaleResp: [Double], scaleSpO2: [Double],
                               modelVersion: String) -> UniTSResidual {
        let sHR = WatchdogCalibration.applySigma(scaleHR, channel: .hr, coldStart: prompt.hr == nil)
        let sRHR = WatchdogCalibration.applySigma(scaleRHR, channel: .rhr, coldStart: prompt.rhr == nil)
        let sHRV = WatchdogCalibration.applySigma(scaleHRV, channel: .hrv,
                                                 coldStart: prompt.source == .population || prompt.hrvAnchoredInSleep)
        let sTemp = WatchdogCalibration.applySigma(scaleTemp, channel: .temp,
                                                  coldStart: prompt.temp == nil || prompt.source == .population)
        let sResp = WatchdogCalibration.applySigma(scaleResp, channel: .resp,
                                                  coldStart: prompt.resp == nil || prompt.source == .population)
        let sSpO2 = WatchdogCalibration.applySigma(scaleSpO2, channel: .spo2,
                                                  coldStart: prompt.spo2 == nil || prompt.source == .population)
        let hrScore = score(window.hr, hatHR, floor: WatchdogConfig.hrScale, personal: prompt.scaleHR, predicted: sHR)
        let rhrObs = WatchdogWindowBuilder.maskLookback(window.rhr, keepSeconds: WatchdogConfig.rhrLookbackSeconds)
        let rhrHat = WatchdogWindowBuilder.maskLookback(hatRHR, keepSeconds: WatchdogConfig.rhrLookbackSeconds)
        let rhrPredicted = WatchdogWindowBuilder.maskLookback(sRHR.map { Optional($0) },
                                                             keepSeconds: WatchdogConfig.rhrLookbackSeconds)
            .map { $0 ?? WatchdogConfig.hrScale }
        let rhrScore = score(rhrObs, rhrHat, floor: WatchdogConfig.hrScale, personal: prompt.scaleRHR, predicted: rhrPredicted)
        let hrvScore = score(window.hrv, hatHRV, floor: WatchdogConfig.hrvScale, personal: prompt.scaleHRV, predicted: sHRV)
        let tempScore = score(window.temp, hatTemp, floor: WatchdogConfig.tempScale, personal: prompt.scaleTemp, predicted: sTemp)
        let respScore = score(window.resp, hatResp, floor: WatchdogConfig.respScale, personal: prompt.scaleResp, predicted: sResp)
        let spo2Score = score(window.spo2, hatSpO2, floor: WatchdogConfig.spo2Scale, personal: prompt.scaleSpO2, predicted: sSpO2)
        var energy: [WatchdogWindow.Channel: Double] = [:]
        var rangeHalf: [WatchdogWindow.Channel: Double] = [:]
        energy[.hr] = hrScore.energy; rangeHalf[.hr] = hrScore.rangeHalf
        energy[.rhr] = rhrScore.energy; rangeHalf[.rhr] = rhrScore.rangeHalf
        energy[.hrv] = hrvScore.energy; rangeHalf[.hrv] = hrvScore.rangeHalf
        energy[.temp] = tempScore.energy; rangeHalf[.temp] = tempScore.rangeHalf
        energy[.resp] = respScore.energy; rangeHalf[.resp] = respScore.rangeHalf
        energy[.spo2] = spo2Score.energy; rangeHalf[.spo2] = spo2Score.rangeHalf
        energy[.motion] = 0
        rangeHalf[.motion] = 0
        let joint = WatchdogScores.joint(energies: [hrScore.energy, rhrScore.energy, hrvScore.energy,
                                                    tempScore.energy, respScore.energy, spo2Score.energy])
        return UniTSResidual(
            energy: energy,
            rangeHalf: rangeHalf,
            scaleHR: sHR,
            scaleRHR: sRHR,
            scaleHRV: sHRV,
            scaleTemp: sTemp,
            scaleResp: sResp,
            scaleSpO2: sSpO2,
            reconstructedHR: hatHR,
            reconstructedRHR: hatRHR,
            reconstructedHRV: hatHRV,
            reconstructedTemp: hatTemp,
            reconstructedResp: hatResp,
            reconstructedSpO2: hatSpO2,
            modelVersion: modelVersion,
            jointEnergy: joint
        )
    }

    /// Instant HR: Layer 1 awake usual plus class-effort occupancy. Missing usual → population prior, never this-window median.
    static func reconstructHR(observed: [Double?], prompt: Double?, occupancy: [Double]) -> [Double?] {
        let smooth = trailingMean(occupancy, taps: WatchdogConfig.hrMotionSmoothMinutes)
        let base = prompt ?? WatchdogPopulationPriors.hr
        let target: [Double?] = zip(observed, smooth).map { _, occ in
            let lift = WatchdogConfig.hrEffortFraction * base * pow(max(0, occ), WatchdogConfig.hrMotionPower)
            return clamp(base + lift, lo: 35, hi: 190)
        }
        return track(target, alpha: WatchdogConfig.hrTrackAlpha)
    }

    /// Resting HR is still-gated. Expected stays the rest usual (not a second HR graph).
    static func reconstructRHR(observed: [Double?], prompt: Double?) -> [Double?] {
        let base = prompt ?? WatchdogPopulationPriors.rhr
        return observed.map { _ in
            return clamp(base, lo: 35, hi: 120)
        }
    }

    /// Live RMSSD: shown awake-rest usual if it exists; otherwise this person's sleep HRV;
    /// otherwise this window's median until a Layer 1 copy exists.
    static func reconstructHRV(observed: [Double?], prompt: UniTSPrompt, occupancy: [Double]) -> [Double?] {
        let smooth = trailingMean(occupancy, taps: WatchdogConfig.hrvMotionSmoothMinutes)
        let rest = prompt.hrvAwake ?? prompt.hrv ?? WatchdogPopulationPriors.hrv
        let target: [Double?] = zip(observed, smooth).map { _, occ in
            let drop = WatchdogConfig.hrvExerciseDropMs * occ * (rest / WatchdogConfig.hrvDropRefMs)
            return clamp(rest - drop, lo: WatchdogConfig.rmssdLow, hi: WatchdogConfig.rmssdHigh)
        }
        return track(target, alpha: WatchdogConfig.hrvTrackAlpha)
    }

    /// Wrist skin temp: activity *decreases* expected WT (masking), lagged, then EMA.
    static func reconstructTemp(observed: [Double?], prompt: Double?, occupancy: [Double]) -> [Double?] {
        let lagged = trailingMean(occupancy, taps: WatchdogConfig.tempLagMinutes)
        let base = prompt ?? WatchdogPopulationPriors.temp
        let target: [Double?] = zip(observed, lagged).map { _, occ in
            return clamp(base + WatchdogConfig.tempMotionGain * occ, lo: 28, hi: 38)
        }
        return track(target, alpha: WatchdogConfig.tempTrackAlpha)
    }

    /// Breathing: this person's rest rate plus occupancy × 60% of that rest, then EMA.
    static func reconstructResp(observed: [Double?], prompt: Double?, occupancy: [Double]) -> [Double?] {
        let smooth = trailingMean(occupancy, taps: WatchdogConfig.respSmoothMinutes)
        let base = prompt ?? WatchdogPopulationPriors.resp
        let target: [Double?] = zip(observed, smooth).map { _, occ in
            let lift = WatchdogConfig.respEffortFraction * base * pow(max(0, occ), WatchdogConfig.respMotionPower)
            return clamp(base + lift, lo: WatchdogConfig.respLow, hi: WatchdogConfig.respHigh)
        }
        return track(target, alpha: WatchdogConfig.respTrackAlpha)
    }

    /// SpO₂ expected is this person's usual, or the window median until a copy exists.
    /// Motion is not a predicted desaturation; observed is not mixed into \(\hat{x}\) when a usual exists.
    static func reconstructSpO2(observed: [Double?], prompt: Double?, occupancy: [Double]) -> [Double?] {
        _ = occupancy
        let base = prompt ?? WatchdogPopulationPriors.spo2
        let target: [Double?] = observed.map { _ in
            return clamp(base, lo: 88, hi: 100)
        }
        return track(target, alpha: WatchdogConfig.spo2TrackAlpha)
    }

    /// Causal EMA so each minute keeps a memory of the last prediction (small baseline changes).
    static func track(_ target: [Double?], alpha: Double) -> [Double?] {
        let a = min(1, max(0.05, alpha))
        var last: Double?
        return target.map { value -> Double? in
            guard let value else { return last }
            if let prev = last {
                let next = (1 - a) * prev + a * value
                last = next
                return next
            }
            last = value
            return value
        }
    }

    /// Kept for tests / call sites that still pass a single slope.
    static func generate(_ observed: [Double?], prompt: Double?, motion: [Double?],
                         motionGain: Double, requireObserved: Bool = true) -> [Double?] {
        let fallback = median(observed.compactMap { $0 })
        let base = prompt ?? fallback
        return zip(observed, motion).map { value, occ in
            if requireObserved, value == nil { return nil }
            guard let base else { return nil }
            let activity = occ ?? 0
            return base + motionGain * max(0, activity)
        }
    }

    static func occupancy(_ window: WatchdogWindow) -> [Double] {
        WatchdogActivityRuntime.effortOccupancy(motion: window.motion, logits: window.activityLogits)
    }

    static func occupancy(_ motion: [Double?]) -> [Double] {
        motion.map { max(0, min(1, $0 ?? 0)) }
    }

    static func trailingMean(_ xs: [Double], taps: Int) -> [Double] {
        let n = max(1, taps)
        guard !xs.isEmpty else { return [] }
        var out = Array(repeating: 0.0, count: xs.count)
        var run = 0.0
        var q: [Double] = []
        q.reserveCapacity(n)
        for i in 0..<xs.count {
            q.append(xs[i])
            run += xs[i]
            if q.count > n { run -= q.removeFirst() }
            out[i] = run / Double(q.count)
        }
        return out
    }

    static func clamp(_ x: Double, lo: Double, hi: Double) -> Double {
        min(hi, max(lo, x))
    }

    /// Last minute where both live and reconstruction exist. Do not pair a held/latest
    /// reading with a later occupancy-only hat — that falsely flags a gap as off.
    static func lastPaired(_ observed: [Double?], _ hat: [Double?]) -> (obs: Double, hat: Double)? {
        for (o, h) in zip(observed, hat).reversed() {
            if let o, let h { return (obs: o, hat: h) }
        }
        return nil
    }

    /// Predicted half-width around \(\hat{x}_t\): max(floor, Layer 1 MAD, reconstructor SNR × |hat|,
    /// occupancy coefficient uncertainty). Never this window’s residual scatter.
    static func predictedScale(hat: [Double?], floor: Double, personal: Double,
                               reconFraction: Double, coupling: [Double]) -> [Double] {
        hat.enumerated().map { i, h in
            let recon = abs(h ?? 0) * max(0, reconFraction)
            let coup = i < coupling.count ? max(0, coupling[i]) : 0
            return max(floor, personal, recon, coup)
        }
    }

    /// Location vs reconstruction. `predicted` is the per-minute UniTS band; if nil, scale is
    /// max(floor, personal) only (unit tests of the energy formula).
    static func score(_ observed: [Double?], _ hat: [Double?],
                      floor: Double, personal: Double,
                      predicted: [Double]? = nil) -> (energy: Double, rangeHalf: Double) {
        var weighted: [Double] = []
        weighted.reserveCapacity(observed.count)
        var lastAbs = 0.0
        var lastScale = max(floor, personal)
        var havePair = false
        for i in 0..<observed.count {
            guard i < hat.count, let o = observed[i], let h = hat[i] else { continue }
            let predictedI = predicted.flatMap { i < $0.count ? $0[i] : nil } ?? 0
            let scale = max(floor, personal, predictedI)
            guard scale > 0 else { continue }
            weighted.append((o - h) / scale)
            lastAbs = abs(o - h)
            lastScale = scale
            havePair = true
        }
        guard havePair, lastScale > 0 else { return (0, max(floor, personal)) }
        let loc = median(weighted) ?? 0
        let now = lastAbs / lastScale
        return (max(abs(loc), now), lastScale)
    }

    static func mae(_ observed: [Double?], _ hat: [Double?], scale: Double) -> Double {
        var sum = 0.0
        var n = 0
        for (o, h) in zip(observed, hat) {
            guard let o, let h, scale > 0 else { continue }
            sum += abs(o - h) / scale
            n += 1
        }
        return n == 0 ? 0 : sum / Double(n)
    }

    static func median(_ xs: [Double]) -> Double? {
        let s = xs.sorted()
        guard !s.isEmpty else { return nil }
        let m = s.count / 2
        if s.count % 2 == 1 { return s[m] }
        return (s[m - 1] + s[m]) / 2
    }
}
