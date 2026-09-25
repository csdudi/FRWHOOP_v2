import Foundation

/// Live event geometry: UniTS decides **what**; TimesFM helps **when**; memory names repeats.
/// No human event labels. Quality / wrist-off / safety stay device rules.
public struct WatchdogEventDecision: Equatable, Sendable {
    public var label: WatchdogEventLabel
    public var cut: Bool
    public var cutReason: String
    public var explained: Bool

    public init(label: WatchdogEventLabel, cut: Bool, cutReason: String, explained: Bool) {
        self.label = label
        self.cut = cut
        self.cutReason = cutReason
        self.explained = explained
    }
}

public enum WatchdogEventGeometry: Sendable {
    public static let version = "geometry-v2-selflabel"
    public static let persist = 2

    public static func isExercise(_ cls: WatchdogActivityClass) -> Bool {
        switch cls {
        case .walk, .run, .cycleLike, .resistance: return true
        default: return false
        }
    }

    public static func family(of cls: WatchdogActivityClass) -> String {
        WatchdogEventLabeler.family(of: cls)
    }

    /// UniTS: quiet recon means activity-conditioned hat explains the strip.
    public static func explainedByUnits(reconJ: Double) -> Bool {
        reconJ < WatchdogCalibration.tNote
    }

    /// TimesFM: path leaving while recon may still be quiet.
    public static func forecastOnset(forecastJ: Double, previousForecastJ: Double, aboveTicks: Int) -> Bool {
        _ = previousForecastJ
        return forecastJ >= WatchdogCalibration.tNote && aboveTicks == persist
    }

    public static func unitsRegimeOnset(reconJ: Double, previousReconJ: Double, aboveTicks: Int) -> Bool {
        _ = previousReconJ
        return reconJ >= WatchdogCalibration.tNote && aboveTicks == persist
    }

    public static func what(cls: WatchdogActivityClass, reconJ: Double, forecastJ: Double,
                            safety: Bool, artifact: Bool, postWorkout: Bool, sleep: Bool,
                            hrHot: Bool, breadth: Double, spo2Hot: Bool = false) -> WatchdogEventLabel {
        if artifact { return .artifactSpike }
        if safety { return .safetyBound }
        let explained = explainedByUnits(reconJ: reconJ)
        if isExercise(cls) {
            if explained {
                switch cls {
                case .walk: return .workoutWalk
                case .run: return .workoutRun
                case .cycleLike: return .workoutCycle
                case .resistance: return .workoutLift
                default: break
                }
            }
            return breadth >= 0.45 ? .abnormalMultiDirection : .abnormalStillTachycardia
        }
        if postWorkout && (cls == .still || cls == .stand) && explained { return .postWorkout }
        if explained && forecastJ >= WatchdogCalibration.tNote { return .forecastDriftOnly }
        if !explained {
            if spo2Hot && !hrHot { return .abnormalSpo2Still }
            if hrHot && breadth < 0.34 { return .abnormalStillTachycardia }
            return .abnormalMultiDirection
        }
        if sleep { return .normalSleep }
        return .normalStillAwake
    }

    public static func resolve(cls: WatchdogActivityClass,
                               familyStableTicks: Int,
                               previousFamily: String,
                               reconJ: Double,
                               forecastJ: Double,
                               previousReconJ: Double,
                               previousForecastJ: Double,
                               reconAboveTicks: Int,
                               forecastAboveTicks: Int,
                               safety: Bool,
                               artifact: Bool,
                               postWorkout: Bool,
                               sleep: Bool,
                               hrHot: Bool,
                               breadth: Double,
                               eventAgeSeconds: Int,
                               spo2Hot: Bool = false) -> WatchdogEventDecision {
        var unused = WatchdogEventMemory.empty
        return resolve(cls: cls, familyStableTicks: familyStableTicks, previousFamily: previousFamily,
                       reconJ: reconJ, forecastJ: forecastJ, previousReconJ: previousReconJ,
                       previousForecastJ: previousForecastJ, reconAboveTicks: reconAboveTicks,
                       forecastAboveTicks: forecastAboveTicks, safety: safety, artifact: artifact,
                       postWorkout: postWorkout, sleep: sleep, hrHot: hrHot, breadth: breadth,
                       eventAgeSeconds: eventAgeSeconds, spo2Hot: spo2Hot, signature: [],
                       memory: &unused)
    }

    public static func resolve(cls: WatchdogActivityClass,
                               familyStableTicks: Int,
                               previousFamily: String,
                               reconJ: Double,
                               forecastJ: Double,
                               previousReconJ: Double,
                               previousForecastJ: Double,
                               reconAboveTicks: Int,
                               forecastAboveTicks: Int,
                               safety: Bool,
                               artifact: Bool,
                               postWorkout: Bool,
                               sleep: Bool,
                               hrHot: Bool,
                               breadth: Double,
                               eventAgeSeconds: Int,
                               spo2Hot: Bool,
                               signature: [Double],
                               memory: inout WatchdogEventMemory) -> WatchdogEventDecision {
        let fam = family(of: cls)
        let explained = explainedByUnits(reconJ: reconJ)
        var label = what(cls: cls, reconJ: reconJ, forecastJ: forecastJ, safety: safety,
                         artifact: artifact, postWorkout: postWorkout, sleep: sleep,
                         hrHot: hrHot, breadth: breadth, spo2Hot: spo2Hot)
        if !WatchdogEventMemory.isQuality(label), !signature.isEmpty {
            label = memory.observe(teacher: label, explained: explained, sig: signature)
        }
        var reason = "continue"
        var cut = false
        if eventAgeSeconds >= WatchdogEventLabeler.maxEventSeconds {
            cut = true
            reason = "max-length"
        }
        if fam != previousFamily && !previousFamily.isEmpty && familyStableTicks >= WatchdogEventLabeler.familyHoldMinutes {
            cut = true
            reason = "class-hold"
        }
        if unitsRegimeOnset(reconJ: reconJ, previousReconJ: previousReconJ, aboveTicks: reconAboveTicks) {
            cut = true
            reason = "units-regime"
        }
        if forecastOnset(forecastJ: forecastJ, previousForecastJ: previousForecastJ, aboveTicks: forecastAboveTicks) {
            cut = true
            reason = "timesfm-onset"
        }
        if artifact { cut = true; reason = "artifact" }
        return WatchdogEventDecision(label: label, cut: cut, cutReason: reason, explained: explained)
    }
}
