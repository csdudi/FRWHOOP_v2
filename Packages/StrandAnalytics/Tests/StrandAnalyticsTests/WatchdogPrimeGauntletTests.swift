import XCTest
@testable import StrandAnalytics
import WhoopProtocol

// =====================================================================================
// AUDIT-ONLY harness. Prime Agent Watchdog v2.5 notification-validity benchmark.
// 2026-09-24. This file does not change production behaviour and is not shipped.
//
// Two clearly separated evidence layers:
//   * "blackbox"   - native-unit synthetic tapes -> WatchdogWindowBuilder.build ->
//                    sequential Watchdog.evaluate with the real Core ML / fallback models.
//   * "controlled" - audit-only residual/forecast offsets fed to Watchdog.combine so exact
//                    threshold boundaries can be hit (Core ML cannot produce opaque J values).
//
// Every fixture carries an INDEPENDENT expected outcome computed in `Expect` from the
// catalog text BEFORE any production code runs. Threshold literals below are transcribed
// from docs/FRWHOOP_WATCHDOG_FEATURE_CATALOG.md (not read from WatchdogCalibration or
// WatchdogConfig) so threshold drift is itself detected.
// =====================================================================================

/// Catalog literals (docs/FRWHOOP_WATCHDOG_FEATURE_CATALOG.md).
enum Catalog {
    static let tNote = 1.0
    static let tActive = 1.6
    static let tSevere = 2.4
    static let persistTicks = 2
    static let escalateDelta = 0.5
    static let rearmTicks = 15
    static let tickSeconds = 20
    static let minCoverage = 0.80
    static let maxEmptyMinutes = 6
    static let whoop4Freshness = 60
    static let whoop5Freshness = 90
    static let restHrHigh = 120.0
    static let restHrLow = 35.0
    static let tempLowC = 28.0
    static let tempHighC = 38.0
    static let respLow = 6.0
    static let respHigh = 30.0
    static let rmssdLow = 8.0
    static let rmssdHigh = 250.0
    static let familyHoldMinutes = 2
    static let familyHoldTicks = 6          // 2 minutes at 20 s ticks
    static let maxEventSeconds = 45 * 60
    static let postWorkoutSeconds = 20 * 60
    static let bandFirstMinutes = 14
    static let bandStepMax = 0.02
    static let bandClampLo = 0.75
    static let bandClampHi = 1.40
    static let bandResidualCap = 2.5
    static let bandLearnCap = 1.20
    static let sessionCapUp = 1.05
    static let sessionCapDown = 0.95
    static let sessionResetHours = 4
    static let sessionResetTicks = 4 * 3600 / 20
    static let phaseMatureDays = 7
    static let phaseBlendSidecar = 0.70
    static let phaseDailyWriteMinutes = 12
    static let episodeRearmTicks = 15
    static let maxJoint = 2.0                // analytic ceiling of RMS*(1+breadth)
}

/// Independent expectation, computed from the catalog text only.
struct Expect {
    var labels: Set<String>          // acceptable event labels
    var severityCeiling: WatchdogSeverity
    var mayNotify: Bool              // wearer notification permitted?
    var quality: String              // "pass" | "unavailable"
    var unavailableReason: String?   // when quality == unavailable
    init(labels: Set<String>, severityCeiling: WatchdogSeverity, mayNotify: Bool,
         quality: String = "pass", unavailableReason: String? = nil) {
        self.labels = labels
        self.severityCeiling = severityCeiling
        self.mayNotify = mayNotify
        self.quality = quality
        self.unavailableReason = unavailableReason
    }
}

/// Stable (run-independent) seed derivation so every row is reproducible from its manifest.
func stableSeed(_ s: String, _ i: Int) -> UInt64 {
    var h: UInt64 = 1469598103934665603
    for b in Array(s.utf8) { h = (h ^ UInt64(b)) &* 1099511628211 }
    return h &* 1_000_003 &+ UInt64(i)
}

let EXTREME_FAMILY: Set<String> = ["safety_bound", "abnormal_still_tachycardia",
                                   "abnormal_multi_direction", "abnormal_spo2_still"]

/// Deterministic seeded generator (SplitMix64).
struct RNG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 &+ 0x2545F4914F6CDD1D }
    mutating func next() -> UInt64 {
        s = s &+ 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func d() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func between(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * d() }
    mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    mutating func chance(_ p: Double) -> Bool { d() < p }
}

/// One row of machine-readable replay output.
struct AuditRow: Codable {
    var layer: String
    var stage: String
    var fixtureId: String
    var seed: UInt64
    var klass: String
    var deviceFamily: String
    var eventId: String
    var activityClass: String
    var activityFamily: String
    var quality: String
    var unavailable: String?
    var modelVersion: String
    var promptSource: String
    var phaseFamily: String
    var observed: [Double?]
    var hats: [Double?]
    var sigmas: [Double?]
    var residuals: [Double?]
    var mask: [Bool]
    var breadth: Double
    var joint: Double
    var forecastJoint: Double
    var fused: Double
    var eventLabel: String
    var cutReason: String
    var explained: Bool
    var severity: String
    var episodeState: String
    var episodeId: String?
    var early: Bool
    var trust: Int
    var bandEligible: Bool
    var bandScale: [Double]
    var bandAnchor: [Double]
    var bandN: Int
    var sessionN: Int
    var shouldNotify: Bool
    var notifyReason: String
    var expectedLabels: [String]
    var expectedSeverityCeiling: String
    var expectedMayNotify: Bool
    var expectedQuality: String
    var labelOk: Bool?
    var severityOk: Bool?
    var notifyOk: Bool?
    var l1Before: String
    var l1After: String
    var nonFinite: Bool
    var wallMs: Double
    var note: String
}

final class AuditLog {
    static let repoRoot: String = {
        // Tests/StrandAnalyticsTests/<file> -> Packages/StrandAnalytics
        let pkg = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return pkg.path
    }()
    static let outDir: String = {
        let env = ProcessInfo.processInfo.environment["WD_AUDIT_DIR"]
        return env ?? (repoRoot + "/Baseline/units")
    }()
    static private var handles: [String: FileHandle] = [:]
    static private let lock = NSLock()
    static var counts: [String: Int] = [:]

    static func ensureDir() {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    }

    static func append(_ name: String, _ line: String) {
        lock.lock(); defer { lock.unlock() }
        ensureDir()
        let path = outDir + "/" + name
        if handles[name] == nil {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            handles[name] = FileHandle(forWritingAtPath: path)
            handles[name]?.seekToEndOfFile()
        }
        handles[name]?.write(Data((line + "\n").utf8))
        counts[name, default: 0] += 1
        if counts[name]! % 25 == 0 { try? handles[name]?.synchronize() }
    }

    static func writeJSON(_ name: String, _ obj: Any) {
        ensureDir()
        let path = outDir + "/" + name
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: path))
        }
    }

    static func row(_ r: AuditRow, file: String) {
        let enc = JSONEncoder()
        if let d = try? enc.encode(r), let s = String(data: d, encoding: .utf8) { append(file, s) }
    }

    static func note(_ s: String) { append("stage_notes.log", "\(Date().timeIntervalSince1970) \(s)") }
}

// =====================================================================================
// Tape factory: native-unit synthetic 30-minute windows, deterministic per (class, seed).
// =====================================================================================

struct Tape {
    var feed: WatchdogFeed
    var expect: Expect
    var nowUnix: Int
    var carrySeed: WatchdogCarry
    var intent: String
    var activityIntent: String
}

enum TapeFactory {
    static let quietPrompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)

    /// Local-midnight-anchored time so sleep/awake phase is deterministic.
    static func localBase(day: Int, hour: Int) -> Int {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 1 + day; c.hour = hour; c.minute = 0; c.second = 0
        let d = Calendar.current.date(from: c) ?? Date(timeIntervalSince1970: 1_800_000_000)
        return Int(d.timeIntervalSince1970)
    }

    static func feed(now: Int, family: DeviceFamily, cadence: Int = 1,
                     hr: (Int) -> Int?, temp: (Int) -> Double?, resp: (Int) -> Double?,
                     spo2: (Int) -> Double?, motion: (Int) -> Double?,
                     steps: ((Int) -> Int?)?, imuDyn: ((Int) -> Double?)?,
                     rrJitter: Int, wristOff: Bool = false) -> WatchdogFeed {
        let start = now - WatchdogConfig.contextSeconds
        var hrs: [HRSample] = []
        var rrs: [RRInterval] = []
        var temps: [WatchdogScalarSample] = []
        var resps: [WatchdogScalarSample] = []
        var mots: [WatchdogScalarSample] = []
        var spo2s: [WatchdogScalarSample] = []
        var stepsOut: [StepSample] = []
        var imuOut: [WatchdogIMUSample] = []
        for m in 0..<WatchdogConfig.seqLen {
            let mStart = start + m * 60
            for t in stride(from: mStart, to: mStart + 60, by: cadence) {
                if let bpm = hr(m) { hrs.append(HRSample(ts: t, bpm: bpm)) }
                if let v = temp(m) { temps.append(WatchdogScalarSample(ts: t, value: v)) }
                if let v = resp(m) { resps.append(WatchdogScalarSample(ts: t, value: v)) }
                if let v = motion(m) { mots.append(WatchdogScalarSample(ts: t, value: v)) }
                if let v = spo2(m) { spo2s.append(WatchdogScalarSample(ts: t, value: v)) }
                if let cls = steps?(m) { stepsOut.append(StepSample(ts: t, counter: 1, activityClass: cls)) }
                if let dyn = imuDyn?(m) {
                    imuOut.append(WatchdogIMUSample(ts: t, x: 1, y: 0, z: 0, dynAccel: dyn))
                }
                if let bpm = hr(m) {
                    let base = Int((60000.0 / Double(max(bpm, 30))).rounded())
                    let jit = rrJitter == 0 ? 0 : ((t % 3 == 0) ? rrJitter : -rrJitter / 2)
                    rrs.append(RRInterval(ts: t, rrMs: max(300, base + jit)))
                }
            }
        }
        return WatchdogFeed(family: family, hrSource: .v18, nowUnix: now,
                            hr: hrs, rr: rrs, skinTempC: temps, respPerMin: resps,
                            motion: mots, spo2Pct: spo2s, wristOff: wristOff,
                            imu: imuOut, steps: stepsOut)
    }

    /// Seeded noise helpers.
    static func jitter(_ r: inout RNG, _ v: Double, _ amp: Double) -> Double { v + r.between(-amp, amp) }

    static func make(klass: String, family: DeviceFamily, seed: UInt64, day: Int = 0,
                     tick: Int = 0, now: Int? = nil) -> Tape {
        var r = RNG(seed)
        let cadence = family == .whoop5 ? 30 : 1
        func hrStill(_ lo: Double, _ hi: Double) -> Int { Int(r.between(lo, hi).rounded()) }

        switch klass {
        // ------------------------------------------------------------------ negatives
        case "normal_sleep":
            let t = now ?? (localBase(day: day, hour: 1) + tick * 20)
            let h = hrStill(46, 58); let hrv = r.between(55, 95); let tp = r.between(32.4, 34.0)
            let rp = r.between(10, 16); let sp = r.between(95.5, 99)
            let feed = TapeFactory.feed(now: t, family: family, cadence: cadence,
                hr: { m in h + (m % 4) - 2 }, temp: { _ in tp + 0.02 },
                resp: { m in rp + Double(m % 3) / 3 }, spo2: { _ in sp },
                motion: { _ in 0.0 }, steps: { _ in 0 }, imuDyn: { _ in 0.01 },
                rrJitter: Int(r.between(20, 60)))
            return Tape(feed: feed,
                        expect: Expect(labels: ["normal_sleep"], severityCeiling: .active, mayNotify: false),
                        nowUnix: t, carrySeed: .empty, intent: "quiet sleep, still, explained",
                        activityIntent: "still")

        case "normal_still_awake":
            let t = now ?? (localBase(day: day, hour: 12) + tick * 20)
            let h = hrStill(55, 78); let hrv = r.between(35, 60); let tp = r.between(32.8, 34.4)
            let rp = r.between(10, 18); let sp = r.between(95, 99)
            let motion = r.between(0.0, 0.05)
            let feed = TapeFactory.feed(now: t, family: family, cadence: cadence,
                hr: { m in h + (m % 5) - 2 }, temp: { _ in tp }, resp: { _ in rp },
                spo2: { _ in sp }, motion: { _ in motion }, steps: { _ in 0 },
                imuDyn: { _ in motion * 0.2 }, rrJitter: Int(r.between(20, 70)))
            return Tape(feed: feed,
                        expect: Expect(labels: ["normal_still_awake"], severityCeiling: .active, mayNotify: false),
                        nowUnix: t, carrySeed: .empty, intent: "quiet awake still", activityIntent: "still")

        case "walk", "run", "cycle", "lift":
            let t = now ?? (localBase(day: day, hour: 12) + tick * 20)
            var lo: Double = 0, hi: Double = 0, motion: Double = 0, stepClass: Int = 0, dyn: Double = 0
            switch klass {
            case "walk": (lo, hi, motion, stepClass, dyn) = (78, 105, r.between(0.36, 0.50), 1, 0.10)
            case "run":  (lo, hi, motion, stepClass, dyn) = (118, 152, r.between(0.60, 0.85), 2, 0.35)
            case "cycle":(lo, hi, motion, stepClass, dyn) = (100, 132, r.between(0.26, 0.48), 3, 0.16)
            default:     (lo, hi, motion, stepClass, dyn) = (92, 118, r.between(0.24, 0.44), 3, 0.30)
            }
            let h = hrStill(lo, hi)
            let lift = (klass == "lift")
            let feed = TapeFactory.feed(now: t, family: family, cadence: cadence,
                hr: { m in h + (m % 6) - 3 },
                temp: { _ in r.between(32.6, 34.2) - motion * 0.1 },
                resp: { _ in r.between(15, 24) }, spo2: { _ in r.between(94, 99) },
                motion: { _ in motion },
                steps: { _ in stepClass },
                imuDyn: { m in lift ? ((m % 2 == 0) ? dyn * 1.6 : dyn * 0.2) : (dyn + 0.02) },
                rrJitter: Int(r.between(20, 60)))
            let label: String
            switch klass {
            case "walk": label = "workout_walk"
            case "run": label = "workout_run"
            case "cycle": label = "workout_cycle"
            default: label = "workout_lift"
            }
            return Tape(feed: feed,
                        expect: Expect(labels: [label, "normal_still_awake"], severityCeiling: .active,
                                       mayNotify: false),
                        nowUnix: t, carrySeed: .empty, intent: "explained \(klass)", activityIntent: klass)

        case "post_workout":
            let t = now ?? (localBase(day: day, hour: 13) + tick * 20)
            let h = hrStill(70, 95)
            var carry = WatchdogCarry.empty
            carry.lastWorkoutEndUnix = t - Int(r.between(3, 19) * 60)
            let feed = TapeFactory.feed(now: t, family: family, cadence: cadence,
                hr: { m in h + (m % 4) - 2 }, temp: { _ in r.between(32.8, 34.6) },
                resp: { _ in r.between(13, 20) }, spo2: { _ in r.between(95, 99) },
                motion: { _ in r.between(0.0, 0.06) }, steps: { _ in 0 },
                imuDyn: { _ in 0.01 }, rrJitter: Int(r.between(20, 60)))
            return Tape(feed: feed,
                        expect: Expect(labels: ["post_workout", "normal_still_awake"],
                                       severityCeiling: .active, mayNotify: false),
                        nowUnix: t, carrySeed: carry,
                        intent: "still within 20 min of an exercise family end", activityIntent: "still")

        case "artifact":
            let t = now ?? (localBase(day: day, hour: 12) + tick * 20)
            let motion = r.between(0.40, 0.70)
            let feed = TapeFactory.feed(now: t, family: family, cadence: cadence,
                hr: { m in hrStill(60, 95) + (m % 3) - 1 }, temp: { _ in r.between(32.8, 34.4) },
                resp: { _ in r.between(12, 22) }, spo2: { _ in r.between(95, 99) },
                motion: { _ in motion },
                steps: nil, imuDyn: { m in (m % 2 == 0) ? 0.9 : 0.05 },
                rrJitter: Int(r.between(20, 60)))
            return Tape(feed: feed,
                        expect: Expect(labels: ["artifact_spike"], severityCeiling: .active, mayNotify: false),
                        nowUnix: t, carrySeed: .empty, intent: "high dynAccel CV motion artifact",
                        activityIntent: "artifact")

        case "gap":
            let t = now ?? (localBase(day: day, hour: 12) + tick * 20)
            let h = hrStill(55, 80)
            let gapStart = r.int(20); let gapLen = 1 + r.int(5)      // 1..5 empty minutes
            let feed = TapeFactory.feed(now: t, family: family, cadence: cadence,
                hr: { m in (m >= gapStart && m < gapStart + gapLen) ? nil : h + (m % 4) - 2 },
                temp: { _ in r.between(32.8, 34.4) }, resp: { _ in r.between(11, 18) },
                spo2: { _ in r.between(95, 99) }, motion: { _ in r.between(0.0, 0.04) },
                steps: { _ in 0 }, imuDyn: { _ in 0.01 }, rrJitter: Int(r.between(20, 60)))
            return Tape(feed: feed,
                        expect: Expect(labels: ["normal_still_awake"], severityCeiling: .active, mayNotify: false),
                        nowUnix: t, carrySeed: .empty,
                        intent: "\(gapLen) empty HR minutes (below the 6-minute fail)", activityIntent: "still")

        case "wrist_off":
            let t = now ?? (localBase(day: day, hour: 12) + tick * 20)
            var feed = TapeFactory.feed(now: t, family: family, cadence: cadence,
                hr: { _ in 62 }, temp: { _ in 33.0 }, resp: { _ in 14 }, spo2: { _ in 97 },
                motion: { _ in 0.0 }, steps: { _ in 0 }, imuDyn: { _ in 0.01 }, rrJitter: 40)
            feed.wristOff = true
            return Tape(feed: feed,
                        expect: Expect(labels: ["wrist_off"], severityCeiling: .dataUnavailable,
                                       mayNotify: false, quality: "unavailable", unavailableReason: "wristOff"),
                        nowUnix: t, carrySeed: .empty, intent: "strap off", activityIntent: "still")

        case "mixed":
            // A window that crosses a family cut: the previous family persists in carry.
            let t = now ?? (localBase(day: day, hour: 12) + tick * 20)
            var carry = WatchdogCarry.empty
            carry.lastActivityFamily = "walk"
            carry.lastEventFamily = "walk"
            carry.lastEventStartUnix = t - 300
            carry.familyStableTicks = 4
            carry.lastActivityFamily = "still"
            let feed = TapeFactory.feed(now: t, family: family, cadence: cadence,
                hr: { m in (m < 15) ? 90 : 60 }, temp: { _ in 33.0 }, resp: { _ in 14 },
                spo2: { _ in 97 }, motion: { m in m < 15 ? 0.40 : 0.0 },
                steps: { m in m < 15 ? 1 : 0 }, imuDyn: { _ in 0.05 }, rrJitter: 40)
            return Tape(feed: feed,
                        expect: Expect(labels: ["mixed_rejected", "normal_still_awake", "workout_walk",
                                                "abnormal_multi_direction"],
                                       severityCeiling: .active, mayNotify: false),
                        nowUnix: t, carrySeed: carry,
                        intent: "walk->still inside one 30-minute window", activityIntent: "mixed")

        // ------------------------------------------------------------------ positives
        case "abnormal_still_tachycardia":
            let t = now ?? (localBase(day: day, hour: 12) + tick * 20)
            let h = hrStill(95, 118)                                  // under the 120 safety cap
            let feed = TapeFactory.feed(now: t, family: family, cadence: cadence,
                hr: { m in h + (m % 4) - 2 }, temp: { _ in r.between(33.0, 33.6) },
                resp: { _ in r.between(13, 16) }, spo2: { _ in r.between(96, 98) },
                motion: { _ in 0.0 }, steps: { _ in 0 },
                imuDyn: { _ in 0.01 }, rrJitter: Int(r.between(20, 60)))
            return Tape(feed: feed,
                        expect: Expect(labels: ["abnormal_still_tachycardia", "abnormal_multi_direction"],
                                       severityCeiling: .severe, mayNotify: true),
                        nowUnix: t, carrySeed: .empty,
                        intent: "still, HR far above usual, other channels quiet", activityIntent: "still")

        case "abnormal_multi_direction":
            let t = now ?? (localBase(day: day, hour: 12) + tick * 20)
            let h = hrStill(90, 118)
            let hrv = r.between(18, 32); let tp = r.between(34.2, 37.4); let rp = r.between(20, 28)
            let sp = r.between(91, 95)
            let feed = TapeFactory.feed(now: t, family: family, cadence: cadence,
                hr: { m in h + (m % 4) - 2 }, temp: { _ in tp }, resp: { _ in rp },
                spo2: { _ in sp }, motion: { _ in 0.0 }, steps: { _ in 0 },
                imuDyn: { _ in 0.01 }, rrJitter: Int(r.between(60, 130)))
            return Tape(feed: feed,
                        expect: Expect(labels: ["abnormal_multi_direction"],
                                       severityCeiling: .severe, mayNotify: true),
                        nowUnix: t, carrySeed: .empty,
                        intent: "several vitals off together while still", activityIntent: "still")

        case "abnormal_spo2_still":
            let t = now ?? (localBase(day: day, hour: 12) + tick * 20)
            let h = hrStill(56, 66)                                  // HR quiet
            let tp = r.between(35.0, 37.2); let rp = r.between(20, 27)
            let hrv = r.between(20, 34); let sp = r.between(89, 93)
            let feed = TapeFactory.feed(now: t, family: family, cadence: cadence,
                hr: { m in h + (m % 4) - 2 }, temp: { _ in tp }, resp: { _ in rp },
                spo2: { _ in sp }, motion: { _ in 0.0 }, steps: { _ in 0 },
                imuDyn: { _ in 0.01 }, rrJitter: Int(r.between(60, 130)))
            return Tape(feed: feed,
                        expect: Expect(labels: ["abnormal_spo2_still", "abnormal_multi_direction"],
                                       severityCeiling: .severe, mayNotify: true),
                        nowUnix: t, carrySeed: .empty,
                        intent: "SpO2 down while HR quiet and still", activityIntent: "still")

        case "safety_bound":
            let t = now ?? (localBase(day: day, hour: 12) + tick * 20)
            let kind = r.int(4)
            var h = hrStill(60, 80); var tp = r.between(33.0, 34.0); var rp = r.between(12, 16)
            switch kind {
            case 0: h = Int(r.between(122, 165).rounded())
            case 1: h = Int(r.between(20, 34).rounded())
            case 2: tp = r.between(38.2, 39.6)
            default: rp = r.between(31, 44)
            }
            let feed = TapeFactory.feed(now: t, family: family, cadence: cadence,
                hr: { m in h + (m % 3) - 1 }, temp: { _ in tp }, resp: { _ in rp },
                spo2: { _ in r.between(94, 99) }, motion: { _ in 0.0 }, steps: { _ in 0 },
                imuDyn: { _ in 0.01 }, rrJitter: Int(r.between(20, 60)))
            return Tape(feed: feed,
                        expect: Expect(labels: ["safety_bound"], severityCeiling: .severe, mayNotify: true),
                        nowUnix: t, carrySeed: .empty,
                        intent: "still safety extrema kind \(kind)", activityIntent: "still")

        default:
            let t = now ?? (localBase(day: day, hour: 12) + tick * 20)
            var feed = TapeFactory.feed(now: t, family: family, cadence: cadence,
                hr: { _ in 60 }, temp: { _ in 33.1 }, resp: { _ in 14 }, spo2: { _ in 97 },
                motion: { _ in 0 }, steps: nil, imuDyn: nil, rrJitter: 40)
            feed.wristOff = true
            return Tape(feed: feed,
                        expect: Expect(labels: ["wrist_off"], severityCeiling: .dataUnavailable,
                                       mayNotify: false, quality: "unavailable", unavailableReason: "wristOff"),
                        nowUnix: t, carrySeed: .empty, intent: "unknown class", activityIntent: "unknown")
        }
    }
}

// =====================================================================================
// Layer 1 fingerprint helper (isolation evidence).
// =====================================================================================

enum L1 {
    static func tape(_ base: Double, n: Int = 41) -> [LBDailyObservation] {
        let asOf = "2026-09-01"
        let te = LongitudinalBaseline.isoEpochDay(asOf)!
        return (1...40).map {
            LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(te - $0),
                               value: base + Double($0 % 3) * 0.4, qualityStatus: .ok)
        } + [LBDailyObservation(day: asOf, value: base, qualityStatus: .ok)]
    }
    static let asOf = "2026-09-01"
    static let series: [LBSeries] = [.sleepRHR, .awakeRestHR, .sleepHRVLn, .awakeRestHRVLn,
                                     .sleepTemp, .sleepResp, .sleepSpO2Mean, .continuousHR]
    static func evaluations() -> [LBEvaluation] {
        let bases: [LBSeries: Double] = [.sleepRHR: 52, .awakeRestHR: 72, .sleepHRVLn: 60,
                                         .awakeRestHRVLn: 45, .sleepTemp: 33.2, .sleepResp: 14.5,
                                         .sleepSpO2Mean: 96.5, .continuousHR: 66]
        return series.map { s in
            LongitudinalBaseline.evaluate(asOf: asOf, series: s, observations: tape(bases[s] ?? 60))
        }
    }
    static func fingerprint() -> String {
        var h: UInt64 = 1469598103934665603
        var bytes: [UInt8] = []
        for ev in evaluations() {
            bytes.append(contentsOf: Array(ev.series.rawValue.utf8))
            for v in [ev.copy7?.center ?? -1, ev.copyLong?.center ?? -1,
                      ev.copy7?.spread ?? -1, ev.copyLong?.spread ?? -1,
                      Double(ev.kBandUsed), Double(ev.nCleanLong), Double(ev.nLong), Double(ev.n7),
                      Double(ev.usualTrustPctLong), Double(ev.usualTrustPct7)] {
                bytes.append(contentsOf: Array(String(format: "%.6f", v).utf8))
            }
        }
        for b in bytes { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }
}

// =====================================================================================
// Tally + gates
// =====================================================================================

final class Tally {
    static let shared = Tally()
    let lock = NSLock()
    var classes: [String: [String: Double]] = [:]      // key: "<layer>|<klass>|<family>"
    var counters: [String: Double] = [:]
    var gateFailures: [String] = []
    var notes: [String] = []

    func bump(_ key: String, _ field: String, _ by: Double = 1) {
        lock.lock(); defer { lock.unlock() }
        classes[key, default: [:]][field, default: 0] += by
    }
    func count(_ key: String, _ by: Double = 1) {
        lock.lock(); defer { lock.unlock() }
        counters[key, default: 0] += by
    }
    func fail(_ g: String) {
        lock.lock(); defer { lock.unlock() }
        if !gateFailures.contains(g) { gateFailures.append(g) }
    }
    func flush(_ stage: String) {
        lock.lock(); defer { lock.unlock() }
        var obj: [String: Any] = [:]
        obj["stage"] = stage
        var cls: [String: Any] = [:]
        for (k, v) in classes { cls[k] = v }
        obj["classes"] = cls
        obj["counters"] = counters
        obj["gateFailures"] = gateFailures
        obj["notes"] = notes
        AuditLog.writeJSON("WatchdogPrimeAgentTally_2026-09-24.json", obj)
    }
}

// =====================================================================================
// Runner
// =====================================================================================

enum Runner {
    static var l1Start = L1.fingerprint()

    struct TickOut {
        var result: WatchdogResult
        var window: WatchdogWindow?
        var residual: UniTSResidual?
        var prompt: UniTSPrompt
        var quality: String
        var unavailable: String?
        var activityClass: String
        var agreement: String
        var wallMs: Double
    }

    /// Full production path: window builder -> quality gate -> prompt -> UniTS -> combine.
    /// `Watchdog.combine` is exactly the function `Watchdog.evaluate` calls after the gate.
    /// The replica exists so the audit can record hats/sigmas/residuals for every tape.
    static func tick(feed: WatchdogFeed, carry: inout WatchdogCarry,
                     prompt: UniTSPrompt = TapeFactory.quietPrompt,
                     evaluations: [LBEvaluation] = [], dayLog: LBDayLog? = nil,
                     now: Int, interval: Int = 5, crossCheck: Bool = false) -> TickOut {
        let t0 = Date()
        let built = WatchdogWindowBuilder.build(feed)
        var agreement = "n/a"
        switch built {
        case .failure(let reason):
            var c = carry
            let r = Watchdog.evaluate(window: built, prompt: prompt, evaluations: evaluations,
                                      dayLog: dayLog, nowUnix: now, liveIntervalMinutes: interval,
                                      previous: c)
            if crossCheck {
                var c2 = carry
                let r2 = Watchdog.evaluate(window: built, prompt: prompt, evaluations: evaluations,
                                           dayLog: dayLog, nowUnix: now, liveIntervalMinutes: interval,
                                           previous: c2)
                agreement = (r.jointEnergy == r2.jointEnergy && r.shouldNotify == r2.shouldNotify
                             && r.severity == r2.severity) ? "ok" : "mismatch"
                _ = c2
            }
            c = r.carry
            carry = c
            return TickOut(result: r, window: nil, residual: nil, prompt: prompt,
                           quality: "unavailable", unavailable: reason.rawValue,
                           activityClass: "unknown", agreement: agreement,
                           wallMs: Date().timeIntervalSince(t0) * 1000)
        case .success(let win):
            if let reason = WatchdogQuality.gate(win) {
                var c = carry
                let r = Watchdog.evaluate(window: built, prompt: prompt, evaluations: evaluations,
                                          dayLog: dayLog, nowUnix: now, liveIntervalMinutes: interval,
                                          previous: c)
                c = r.carry; carry = c
                return TickOut(result: r, window: win, residual: nil, prompt: prompt,
                               quality: "unavailable", unavailable: reason.rawValue,
                               activityClass: "unknown", agreement: agreement,
                               wallMs: Date().timeIntervalSince(t0) * 1000)
            }
            // Mirror the prompt resolution inside Watchdog.evaluate so the log shows what the model saw.
            let clsRaw = WatchdogActivityClass.labels(logits: win.activityLogits).last ?? "unknown"
            let cls = WatchdogActivityClass.allCases.first(where: { $0.rawValue == clsRaw }) ?? .unknown
            let tail = WatchdogLiveTail.resolve(win)
            let sleepNow = WatchdogEventLabeler.sleepIntervalOpen(win.sleepIntervals, unix: now)
            let phase = WatchdogPhaseUsualStore.phase(nowUnix: now, sleepBit: sleepNow)
            let fam = WatchdogPhaseUsualStore.family(label: .normalStillAwake, cls: cls)
            let blendFam: WatchdogActivityFamily = tail.stillNow ? .still : fam
            let livePrompt = carry.phaseUsual.blendPrompt(prompt, key: WatchdogPhaseKey(phase: phase, family: blendFam))
            let residual = (try? UniTSRuntime().reconstruct(win, prompt: livePrompt)) ?? nil
            var c = carry
            var r: WatchdogResult
            if let residual {
                r = Watchdog.combine(window: win, residual: residual, prompt: livePrompt,
                                     evaluations: evaluations, dayLog: dayLog, nowUnix: now,
                                     interval: interval, carry: &c)
            } else {
                r = Watchdog.evaluate(window: built, prompt: prompt, evaluations: evaluations,
                                      dayLog: dayLog, nowUnix: now, liveIntervalMinutes: interval,
                                      previous: c)
                c = r.carry
            }
            if crossCheck {
                var c2 = carry
                let r2 = Watchdog.evaluate(window: built, prompt: prompt, evaluations: evaluations,
                                           dayLog: dayLog, nowUnix: now, liveIntervalMinutes: interval,
                                           previous: c2)
                agreement = (abs(r.jointEnergy - r2.jointEnergy) < 1e-9 && r.shouldNotify == r2.shouldNotify
                             && r.severity == r2.severity && r.eventLabel == r2.eventLabel) ? "ok" : "mismatch"
                if agreement == "mismatch" { Tally.shared.count("evaluate_replica_mismatch") }
            }
            carry = c
            return TickOut(result: r, window: win, residual: residual, prompt: livePrompt,
                           quality: "pass", unavailable: nil,
                           activityClass: WatchdogActivityClass.labels(logits: win.activityLogits).last ?? "unknown",
                           agreement: agreement,
                           wallMs: Date().timeIntervalSince(t0) * 1000)
        }
    }

    static func row(layer: String, stage: String, fixtureId: String, seed: UInt64, klass: String,
                    family: DeviceFamily, out: TickOut, carryBefore: WatchdogCarry,
                    expect: Expect, intent: String, fingerprints: (String, String),
                    note: String) -> AuditRow {
        let r = out.result
        let w = out.window
        let res = out.residual
        func ch(_ c: WatchdogWindow.Channel) -> Double? {
            guard let w else { return nil }
            return UniTSRuntime.lastPaired(w.series(c), res?.reconstructed(c) ?? Array(repeating: nil, count: 30))?.obs
        }
        func hat(_ c: WatchdogWindow.Channel) -> Double? {
            guard let w else { return nil }
            return UniTSRuntime.lastPaired(w.series(c), res?.reconstructed(c) ?? Array(repeating: nil, count: 30))?.hat
        }
        func sig(_ c: WatchdogWindow.Channel) -> Double? { res?.scale(for: c).last ?? nil }
        let obs: [Double?] = [ch(.hr), ch(.rhr), ch(.hrv), ch(.temp), ch(.resp), ch(.spo2)]
        let hats: [Double?] = [hat(.hr), hat(.rhr), hat(.hrv), hat(.temp), hat(.resp), hat(.spo2)]
        let sigmas: [Double?] = [sig(.hr), sig(.rhr), sig(.hrv), sig(.temp), sig(.resp), sig(.spo2)]
        let resid: [Double?] = zip(obs, hats).enumerated().map { i, pair in
            guard let o = pair.0, let h = pair.1, let s = sigmas[i], s > 0 else { return nil }
            return (o - h) / s
        }
        let rhrAllowed = w.map { WatchdogActivityRuntime.isStillish($0.activityLogits) } ?? false
        var dirEma = carryBefore.dirEma
        let artifact = w.map { WatchdogActivityRuntime.isArtifact($0.activityLogits) } ?? false
        let dir = WatchdogDirection.compute(rawR: resid, rhrAllowed: rhrAllowed, artifact: artifact,
                                            dirEma: &dirEma)
        let nf = (obs + hats).contains { ($0 ?? 0).isNaN || ($0 ?? 0).isInfinite }
            || [r.jointEnergy, r.forecastEnergy, r.fusedEnergy, Double(r.trustPct)].contains {
                !$0.isFinite
            }
        let allVals: [Double?] = obs + hats + sigmas
        let nonFiniteAny = nf || allVals.contains { ($0 ?? 0).isNaN || ($0 ?? 0).isInfinite }
        let labelOk: Bool? = out.quality == "pass" ? expect.labels.contains(r.eventLabel) : nil
        let sevOrder: [WatchdogSeverity] = [.dataUnavailable, .withinLimits, .note, .candidate, .active, .severe]
        let sevOk: Bool = (sevOrder.firstIndex(of: r.severity) ?? 0) <= (sevOrder.firstIndex(of: expect.severityCeiling) ?? 0)
        let qualityOk: Bool = (out.quality == expect.quality)
            && (expect.unavailableReason == nil || out.unavailable == expect.unavailableReason)
        let notifyOk: Bool = expect.mayNotify || !r.shouldNotify
        let key = "\(layer)|\(klass)|\(family.rawValue)"
        Tally.shared.bump(key, "n")
        if r.shouldNotify { Tally.shared.bump(key, "notifications") }
        if r.severity == .severe { Tally.shared.bump(key, "severe") }
        if r.severity == .dataUnavailable { Tally.shared.bump(key, "unavailable") }
        if labelOk == false { Tally.shared.bump(key, "labelMiss"); Tally.shared.bump(key, "labelMiss__\(r.eventLabel)") }
        if !sevOk { Tally.shared.bump(key, "severityOver"); Tally.shared.bump(key, "severityOver__\(r.severity.rawValue)") }
        if !qualityOk { Tally.shared.bump(key, "qualityError") }
        if !notifyOk { Tally.shared.bump(key, "notifyViolation") }
        if nonFiniteAny { Tally.shared.bump(key, "nonFinite") }
        if r.earlyFlag { Tally.shared.bump(key, "early") }
        if labelOk == true { Tally.shared.bump(key, "labelOk") }
        if out.agreement == "mismatch" { Tally.shared.bump(key, "replicaMismatch") }
        return AuditRow(
            layer: layer, stage: stage, fixtureId: fixtureId, seed: seed, klass: klass,
            deviceFamily: family.rawValue, eventId: r.episodeId ?? "none",
            activityClass: out.activityClass, activityFamily: WatchdogEventLabeler.family(of:
                WatchdogActivityClass.allCases.first(where: { $0.rawValue == out.activityClass }) ?? .unknown),
            quality: out.quality, unavailable: out.unavailable,
            modelVersion: r.modelVersion, promptSource: r.promptSource.rawValue,
            phaseFamily: WatchdogPhaseUsualStore.phase(nowUnix: r.lastTickUnix,
                                                       sleepBit: r.eventLabel == "normal_sleep").rawValue,
            observed: obs, hats: hats, sigmas: sigmas, residuals: resid,
            mask: dir.mask, breadth: dir.breadth, joint: r.jointEnergy, forecastJoint: r.forecastEnergy,
            fused: r.fusedEnergy, eventLabel: r.eventLabel, cutReason: r.cutReason,
            explained: r.eventExplained, severity: r.severity.rawValue,
            episodeState: r.episodeState.rawValue, episodeId: r.episodeId, early: r.earlyFlag,
            trust: r.trustPct, bandEligible: WatchdogEventLabeler.bandEligible(
                WatchdogEventLabel(rawValue: r.eventLabel) ?? .normalStillAwake),
            bandScale: r.carry.bandScale, bandAnchor: r.carry.bandAnchor, bandN: r.carry.bandN,
            sessionN: r.carry.sessionN, shouldNotify: r.shouldNotify, notifyReason: r.notifyReason,
            expectedLabels: expect.labels.sorted(), expectedSeverityCeiling: expect.severityCeiling.rawValue,
            expectedMayNotify: expect.mayNotify, expectedQuality: expect.quality,
            labelOk: labelOk, severityOk: sevOk, notifyOk: notifyOk,
            l1Before: fingerprints.0, l1After: fingerprints.1, nonFinite: nonFiniteAny,
            wallMs: out.wallMs, note: "\(intent) | \(note)")
    }
}

extension UniTSResidual {
    /// Audit-only accessor: per-minute hat for a channel.
    func reconstructed(_ channel: WatchdogWindow.Channel) -> [Double?] {
        switch channel {
        case .hr: return reconstructedHR
        case .rhr: return reconstructedRHR
        case .hrv: return reconstructedHRV
        case .temp: return reconstructedTemp
        case .resp: return reconstructedResp
        case .spo2: return reconstructedSpO2
        case .motion: return []
        }
    }
}

// =====================================================================================
// Stages
// =====================================================================================

final class WatchdogPrimeGauntletTests: XCTestCase {

    static let negFile = "WatchdogPrimeAgentReplay_2026-09-24.jsonl"
    static var l1Start = ""

    override class func setUp() {
        AuditLog.ensureDir()
        l1Start = L1.fingerprint()
        AuditLog.note("gauntlet start dir=\(AuditLog.outDir) l1=\(l1Start)")
    }

    static var nNeg: Int { Int(ProcessInfo.processInfo.environment["WD_N_NEG"] ?? "") ?? 1000 }
    static var nPos: Int { Int(ProcessInfo.processInfo.environment["WD_N_POS"] ?? "") ?? 250 }
    static var nHours: Int { Int(ProcessInfo.processInfo.environment["WD_N_HOURS"] ?? "") ?? 100 }
    static var nBound: Int { Int(ProcessInfo.processInfo.environment["WD_N_BOUND"] ?? "") ?? 100 }

    static let negatives = ["normal_sleep", "normal_still_awake", "walk", "run", "cycle", "lift",
                            "post_workout", "artifact", "gap", "wrist_off", "mixed"]
    static let positives = ["abnormal_still_tachycardia", "abnormal_multi_direction",
                            "abnormal_spo2_still", "safety_bound"]

    /// Variant mutations applied to a class tape. Each variant declares its own expected quality state.
    static func variant(_ tape: Tape, _ v: String, family: DeviceFamily) -> Tape {
        var t = tape
        let start = t.nowUnix - WatchdogConfig.contextSeconds
        switch v {
        case "plain":
            return t
        case "stale":
            // Newest HR sample one second past the family freshness limit.
            let limit = family == .whoop5 ? Catalog.whoop5Freshness : Catalog.whoop4Freshness
            t.feed.hr = t.feed.hr.filter { $0.ts < t.nowUnix - limit - 1 }
            t.expect = Expect(labels: ["stale"], severityCeiling: .dataUnavailable, mayNotify: false,
                              quality: "unavailable", unavailableReason: "stale")
            t.intent += " | newest sample \(limit + 1)s stale"
            return t
        case "stale_edge":
            // Exactly at the freshness limit: must still be accepted (contract: fail only past the limit).
            let limit = family == .whoop5 ? Catalog.whoop5Freshness : Catalog.whoop4Freshness
            t.feed.hr = t.feed.hr.filter { $0.ts < t.nowUnix - limit }
            t.expect = Expect(labels: t.expect.labels, severityCeiling: t.expect.severityCeiling,
                              mayNotify: false)
            t.intent += " | newest sample exactly at the \(limit)s limit"
            return t
        case "lowcov":
            t.feed.hr = t.feed.hr.filter { (($0.ts - start) / 60) % 4 != 0 }
            t.expect = Expect(labels: ["coverage"], severityCeiling: .dataUnavailable, mayNotify: false,
                              quality: "unavailable", unavailableReason: "coverage")
            t.intent += " | 75% bucket coverage"
            return t
        case "cov_edge":
            t.feed.hr = t.feed.hr.filter { $0.ts - start >= 6 * 60 }   // exactly 24/30 filled
            t.expect = Expect(labels: t.expect.labels, severityCeiling: t.expect.severityCeiling,
                              mayNotify: false)
            t.intent += " | exactly 24/30 buckets (80%)"
            return t
        case "gap5":
            t.feed.hr = t.feed.hr.filter { !(($0.ts - start) / 60 >= 10 && ($0.ts - start) / 60 < 15) }
            t.expect = Expect(labels: t.expect.labels, severityCeiling: t.expect.severityCeiling,
                              mayNotify: false)
            t.intent += " | five empty HR minutes"
            return t
        case "gap6":
            t.feed.hr = t.feed.hr.filter { !(($0.ts - start) / 60 >= 10 && ($0.ts - start) / 60 < 16) }
            t.expect = Expect(labels: ["gap"], severityCeiling: .dataUnavailable, mayNotify: false,
                              quality: "unavailable", unavailableReason: "gap")
            t.intent += " | six empty HR minutes"
            return t
        case "wristoff":
            t.feed.wristOff = true
            t.expect = Expect(labels: ["wrist_off"], severityCeiling: .dataUnavailable, mayNotify: false,
                              quality: "unavailable", unavailableReason: "wristOff")
            t.intent += " | wrist_off flag"
            return t
        case "dupe":
            t.feed.hr = t.feed.hr + t.feed.hr.map { HRSample(ts: $0.ts, bpm: $0.bpm) }
            t.feed.rr = t.feed.rr + t.feed.rr.map { RRInterval(ts: $0.ts, rrMs: $0.rrMs) }
            t.intent += " | duplicated timestamps and RR identity"
            return t
        case "holdforward":
            t.feed.skinTempC = t.feed.skinTempC.filter { $0.ts < start + 300 }
            t.feed.spo2Pct = t.feed.spo2Pct.filter { $0.ts < start + 300 }
            t.feed.respPerMin = t.feed.respPerMin.filter { $0.ts < start + 300 }
            t.intent += " | temp/SpO2/resp only in the first 5 minutes (hold-forward)"
            return t
        case "noimu":
            t.feed.steps = []
            t.feed.imu = []
            t.feed.motion = []
            t.intent += " | no IMU / steps / motion rows at all"
            return t
        case "late":
            // Late-arriving samples: every sample is stamped 40 s after its minute boundary.
            t.feed.hr = t.feed.hr.map { HRSample(ts: $0.ts + 40, bpm: $0.bpm) }.filter { $0.ts < t.nowUnix }
            t.intent += " | late-arriving samples"
            return t
        default:
            return t
        }
    }

    // ---------------------------------------------------------------- S1 quality and window failure
    func testS1QualityAndWindowFailure() throws {
        let variants = ["plain", "stale", "stale_edge", "lowcov", "cov_edge", "gap5", "gap6",
                        "wristoff", "dupe", "holdforward", "noimu", "late"]
        var rows = 0
        for family in [DeviceFamily.whoop4, DeviceFamily.whoop5] {
            for klass in Self.negatives + ["empty"] {
                for v in variants {
                    for i in 0..<8 {
                        let seed = stableSeed("S1-" + klass, i)
                        if klass == "empty" {
                            let t = TapeFactory.localBase(day: i, hour: 12)
                            let feed = WatchdogFeed(family: family, hrSource: .v18, nowUnix: t)
                            var carry = WatchdogCarry.empty
                            let out = Runner.tick(feed: feed, carry: &carry, now: t)
                            let row = Runner.row(layer: "blackbox", stage: "S1-quality", fixtureId: "S1-empty-\(family.rawValue)-\(i)",
                                                 seed: seed, klass: "empty", family: family, out: out,
                                                 carryBefore: .empty,
                                                 expect: Expect(labels: ["empty"], severityCeiling: .dataUnavailable,
                                                                mayNotify: false, quality: "unavailable"),
                                                 intent: "empty window", fingerprints: (Self.l1Start, Self.l1Start),
                                                 note: v)
                            AuditLog.row(row, file: Self.negFile); rows += 1
                            continue
                        }
                        let tape = Self.variant(TapeFactory.make(klass: klass, family: family, seed: seed, day: i), v, family: family)
                        var carry = tape.carrySeed
                        let out = Runner.tick(feed: tape.feed, carry: &carry, now: tape.nowUnix)
                        let row = Runner.row(layer: "blackbox", stage: "S1-quality",
                                             fixtureId: "S1-\(klass)-\(v)-\(family.rawValue)-\(i)",
                                             seed: seed, klass: klass, family: family, out: out,
                                             carryBefore: tape.carrySeed, expect: tape.expect,
                                             intent: tape.intent, fingerprints: (Self.l1Start, Self.l1Start),
                                             note: v)
                        AuditLog.row(row, file: Self.negFile); rows += 1
                    }
                }
            }
        }
        Tally.shared.count("S1_rows", Double(rows))
        Tally.shared.flush("S1")
        let cv = Tally.shared.counters
        let covErrors = cv["S1_coverage_gate_errors"] ?? 0
        print("S1 rows=\(rows) coverageGateErrors=\(covErrors)")
    }

    // ---------------------------------------------------------------- S2 negative volume catalog
    func testS2NegativeVolumeCatalog() throws {
        var rows = 0
        let started = Date()
        for family in [DeviceFamily.whoop4, DeviceFamily.whoop5] {
            for klass in Self.negatives {
                var notifications = 0
                var severityOver = 0
                var labelMiss = 0
                var nonFinite = 0
                var qualityErrors = 0
                for i in 0..<Self.nNeg {
                    let seed = stableSeed("S2-" + klass + "-" + family.rawValue, i)
                    let tape = TapeFactory.make(klass: klass, family: family, seed: seed, day: i % 6)
                    var carry = tape.carrySeed
                    let out = Runner.tick(feed: tape.feed, carry: &carry, now: tape.nowUnix,
                                          crossCheck: i % 50 == 0)
                    let row = Runner.row(layer: "blackbox", stage: "S2-negative-volume",
                                         fixtureId: "S2-\(klass)-\(family.rawValue)-\(i)", seed: seed,
                                         klass: klass, family: family, out: out,
                                         carryBefore: tape.carrySeed, expect: tape.expect,
                                         intent: tape.intent, fingerprints: (Self.l1Start, Self.l1Start),
                                         note: "volume")
                    AuditLog.row(row, file: Self.negFile)
                    rows += 1
                    if row.shouldNotify { notifications += 1 }
                    if row.severityOk == false { severityOver += 1 }
                    if row.labelOk == false { labelMiss += 1 }
                    if row.nonFinite { nonFinite += 1 }
                    if out.quality == "pass" && (tape.expect.quality != "pass") { qualityErrors += 1 }
                    if out.quality == "unavailable" && tape.expect.quality == "pass" { qualityErrors += 1 }
                    if rows % 500 == 0 {
                        Tally.shared.flush("S2-progress")
                        AuditLog.note("S2 progress rows=\(rows) elapsed=\(Int(Date().timeIntervalSince(started)))s")
                    }
                }
                print("S2 \(family.rawValue) \(klass): n=\(Self.nNeg) notify=\(notifications) severityOver=\(severityOver) labelMiss=\(labelMiss) nonFinite=\(nonFinite) qualityErrors=\(qualityErrors)")
                Tally.shared.count("S2_total_notifications", Double(notifications))
                Tally.shared.count("S2_total_severity_over", Double(severityOver))
            }
        }
        Tally.shared.count("S2_rows", Double(rows))
        Tally.shared.flush("S2")
    }
}
