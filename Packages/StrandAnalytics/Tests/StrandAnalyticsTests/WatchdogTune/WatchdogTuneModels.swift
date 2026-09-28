import Foundation
@testable import StrandAnalytics
import WhoopProtocol

/// One synthetic catalog event. Label is the **recipe** (intended). Replay records what evaluate named.
struct WatchdogTuneRecipe: Equatable, Sendable {
    var event: WatchdogEvent
    var family: DeviceFamily
    var kind: Kind

    enum Kind: Equatable, Sendable {
        case still
        case sleep
        case walk
        case run
        case cycle
        case lift
        case post
        case artifact
        case wristOff
        case gap
        case forecastDrift
        case stillTachycardia
        case multiDirection
        case spo2Still
        case safety
        case mixedWalk
        case stillCoverMinutes
        case feltIll
    }
}

struct WatchdogTuneWindowRow: Equatable, Sendable {
    var eventId: String
    var intended: WatchdogEventLabel
    var actual: WatchdogEventLabel
    var family: String
    var mixedDropped: Bool
    var usedEvaluate: Bool
    var usedInjectedJoint: Bool
    var qualityGate: String
    var severity: WatchdogSeverity
    var shouldNotify: Bool
    var earlyFlag: Bool
    var jointEnergy: Double
    var forecastEnergy: Double
    var bandN: Int
    var bandReady: Bool
    var bandKey: String
    var sidecarEntries: Int
    var calibrationSource: String
}

struct WatchdogTuneRates: Equatable, Sendable {
    var windowsKept: Int
    var windowsDroppedMixed: Int
    var nameAgree: Int
    var fprSevereOrNotify: Int
    var forecastSevereOrNotify: Int
    var missSafety: Int
    var missEarly: Int
    var missAbnormalTach: Int
    var missAbnormalMulti: Int
    var missAbnormalSpo2: Int
    var missWristOff: Int
    var bandMinutesLearned: Int
    var bandReadyWindows: Int
    var residualSidecarWrites: Int
    var confoundedBandN: Int
}

struct WatchdogTuneReport: Equatable, Sendable {
    var calibrationSource: String
    var realWhoop5: String
    var generatedUnix: Int
    var recipes: Int
    var rates: WatchdogTuneRates
    var rows: [WatchdogTuneWindowRow]
    var constraintsOk: Bool
    var constraintNotes: [String]
}
