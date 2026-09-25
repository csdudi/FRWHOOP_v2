import Foundation

/// Frozen Watchdog / UniTS-AD knobs (`FRWHOOP_WATCHDOG.md`). Engineering defaults, not clinical limits.
public enum WatchdogConfig: Sendable {
    public static let seqLen = 30
    public static let gridSeconds = 60
    public static let contextSeconds = seqLen * gridSeconds
    public static let liveIntervals = [1, 2, 5, 10]
    public static let defaultLiveIntervalMinutes = 5
    /// How often the live baseline re-reads the strap. Not a patient control; each vital picks its own lookback.
    public static let tickSeconds = 20
    /// Episode notify is `WatchdogNotifyPolicy`. Item 7 deleted the 1800 s mute; keep 0 so old reads are honest.
    public static let notifyCooldownSeconds = 0

    public static let tau = 1.0
    public static let tauSevere = 2.0

    public static let whoop4MaxGapSeconds = 5
    public static let whoop5MaxGapSeconds = 90
    public static let whoop4FreshnessSeconds = 60
    public static let whoop5FreshnessSeconds = 90
    public static let minCoverage = 0.80

    public static let hrScale = 5.0
    public static let hrvScale = 8.0
    public static let tempScale = 0.35
    public static let respScale = 3.0
    public static let spo2Scale = 2.0
    /// Occupancy 1.0 is treated as ~50% of this person's rest HR as a moderate-effort bump
    /// (Karvonen-style %HRR without age; occupancy is not %VO2). See FRWHOOP_WATCHDOG.md §1.3.2.
    public static let hrEffortFraction = 0.50
    /// Linear occupancy so small motion changes show on the HR dotted line.
    public static let hrMotionPower = 1.0
    public static let hrMotionSmoothMinutes = 1
    public static let hrTrackAlpha = 0.40
    /// Kept for inject/tests that add a round bpm bump; reconstruction uses `hrEffortFraction * rest`.
    public static let motionHrGain = 28.0
    /// Meta-analysis mean RMSSD drop during/after exercise vs pre (ms) at occupancy 1, then scaled
    /// by this person's still RMSSD / `hrvDropRefMs`. Chen et al., Medicina 2024.
    public static let hrvExerciseDropMs = 4.96
    public static let hrvDropRefMs = 50.0
    public static let hrvMotionSmoothMinutes = 2
    public static let hrvTrackAlpha = 0.28
    /// Wrist temperature falls with activity (masking), not a core-temp rise.
    /// Martínez-Nicolás et al., PLOS ONE 2013.
    public static let tempMotionGain = -0.15
    public static let tempLagMinutes = 6
    public static let tempTrackAlpha = 0.18
    /// Moderate effort, not VO2max. Resting rate is personal; occupancy 1 adds 60% of that rest rate.
    public static let respEffortFraction = 0.60
    public static let respMotionPower = 1.0
    public static let respSmoothMinutes = 1
    public static let respTrackAlpha = 0.32
    public static let spo2SmoothMinutes = 2
    public static let spo2TrackAlpha = 0.12
    /// Resting HR uses still minutes in this trailing window, not the full 30-minute HR mix.
    public static let rhrLookbackSeconds = 10 * 60
    public static let spo2LookbackSeconds = 30 * 60

    public static let restHrHigh = 120.0
    public static let restHrLow = 35.0
    public static let tempLowC = 28.0
    public static let tempHighC = 38.0
    public static let respLow = 6.0
    public static let respHigh = 30.0
    public static let rmssdLow = 8.0
    public static let rmssdHigh = 250.0

    /// Half-width the frozen reconstructor cannot beat, as a fraction of \(\hat{x}_t\).
    /// This is reconstruction SNR for that channel (sampling + physiology the model does not
    /// resolve), not this window’s residual scatter. See FRWHOOP_WATCHDOG.md §1.3.3.
    public static let hrReconFraction = 0.12
    public static let rhrReconFraction = 0.07
    public static let hrvReconFraction = 0.22
    public static let tempReconFraction = 0.0
    public static let respReconFraction = 0.10
    public static let spo2ReconFraction = 0.0
    /// Occupancy coupling is a prior, not a point. Extra half-width at occ 1.
    public static let hrEffortUncert = 0.15
    public static let respEffortUncert = 0.20
    /// Chen 2024 RMSSD MD 95% CI half-width at the 50 ms reference (~3.04 ms).
    public static let hrvDropUncertMs = 3.04
    public static let tempGainUncert = 0.10

    public static let modelVersion = "units-ad-coreml-v2"
    public static let fallbackModelVersion = "units-ad-recon-v4"
    public static let coreMLCheckpoint = "UniTS_AD.mlpackage"
    public static let configVersion = "watchdog-v2.5"
    public static let forecastModelVersion = "timesfm3-student-v2"
    public static let activityFeatureWidth = 20
    public static let paramSet = "v1.review"

    public static let intervalKey = "noop.watchdog.liveIntervalMinutes"
    public static let lastNotifyKey = "noop.watchdog.lastNotifyUnix"
    public static let episodeIdKey = "noop.watchdog.episodeId"
    public static let mismatchTicksKey = "noop.watchdog.mismatchTicks"

    public static func clampInterval(_ minutes: Int) -> Int {
        liveIntervals.contains(minutes) ? minutes : defaultLiveIntervalMinutes
    }
}
