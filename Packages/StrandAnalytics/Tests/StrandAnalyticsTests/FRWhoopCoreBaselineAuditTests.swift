import XCTest
@testable import StrandAnalytics
import WhoopStore

/// FRWHOOP CORE BASELINE CORRECTNESS AUDIT (2026-09-17).
///
/// Source of truth: Packages/StrandAnalytics/Baseline/FRWHOOP_BASELINE_CONDENSED_PLAN.md and
/// FRWHOOP_BASELINE_FINAL_PLAN.md. Audit report: FRWHOOP_CORE_BASELINE_AUDIT_2026-09-17.md.
///
/// Audit-only harness. It never changes production behaviour and never retunes a k value.
/// Every test emits machine-readable `RESULT|...` lines so the report tables can be built from
/// the run log instead of hand-copied numbers. Deterministic LCG seeding: no RNG, no wall clock.
///
/// HOW TO RUN
///   cd Packages/StrandAnalytics && swift test --filter FRWhoopCoreBaselineAuditTests
final class FRWhoopCoreBaselineAuditTests: XCTestCase {

    // MARK: - Deterministic helpers

    /// Park–Miller style LCG. Deterministic across platforms (no libm in the loop).
    struct LCG {
        private var s: UInt64
        init(seed: UInt64) { s = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double((s >> 33) & 0xFFFF) / 65535.0
        }
        /// Symmetric noise in [-amp, +amp].
        mutating func noise(_ amp: Double) -> Double { (next() * 2.0 - 1.0) * amp }
        /// Standard normal-ish, sum of 3 uniforms (bounded, deterministic).
        mutating func normal() -> Double {
            (next() + next() + next() - 1.5) * 1.1547
        }
    }

    let auditDay = "2026-09-17"
    var T: Int { LongitudinalBaseline.isoEpochDay(auditDay)! }
    func iso(_ e: Int) -> String { LongitudinalBaseline.isoFromEpochDay(e) }

    func emit(_ fields: [String: String]) {
        let body = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
        print("RESULT|" + body)
    }


    /// math space → native display units (exp for HRV).
    func disp(_ s: LBSeries, _ mathValue: Double) -> Double {
        LongitudinalBaseline.toDisplay(mathValue, series: s)
    }

    /// Fixed-format double → string for RESULT lines.
    func str(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "nil" }

    // MARK: - Per-series native configuration (audit constants, not production params)

    struct SeriesCfg {
        let series: LBSeries
        let base: Double          // stable native value
        let noise: Double         // moderate natural noise amplitude (native units)
        let lowNoise: Double      // quiet person
        let glitch: Double        // isolated measurement glitch size
        let up: Double            // plausible upward disturbance / drift span
        let down: Double          // plausible downward disturbance / drift span
        let coverage: Double?     // coverage minutes / slots where the gate needs one
        let driftPerDay: Double   // biologically plausible slow drift per day
    }

    /// 17 series, plausible native numbers. `up`/`down` are the sign-specific disturbance sizes.
    let allCfg: [SeriesCfg] = [
        SeriesCfg(series: .sleepRHR, base: 60, noise: 1.8, lowNoise: 0.6, glitch: 85,
                  up: 12, down: 10, coverage: nil, driftPerDay: 0.3),
        SeriesCfg(series: .awakeRestHR, base: 70, noise: 2.7, lowNoise: 0.9, glitch: 108,
                  up: 14, down: 12, coverage: 60, driftPerDay: 0.35),
        SeriesCfg(series: .awakeActiveHR, base: 100, noise: 3.6, lowNoise: 1.2, glitch: 155,
                  up: 20, down: 16, coverage: 60, driftPerDay: 0.5),
        SeriesCfg(series: .continuousHR, base: 80, noise: 4.5, lowNoise: 1.5, glitch: 128,
                  up: 16, down: 14, coverage: 400, driftPerDay: 0.4),
        SeriesCfg(series: .sleepHRVLn, base: 65, noise: 5.2, lowNoise: 1.8, glitch: 29,
                  up: 26, down: 24, coverage: nil, driftPerDay: 0.9),
        SeriesCfg(series: .awakeRestHRVLn, base: 45, noise: 3.6, lowNoise: 1.4, glitch: 20,
                  up: 18, down: 16, coverage: 60, driftPerDay: 0.6),
        SeriesCfg(series: .awakeActiveHRVLn, base: 35, noise: 2.8, lowNoise: 1.1, glitch: 16,
                  up: 14, down: 12, coverage: 60, driftPerDay: 0.5),
        SeriesCfg(series: .continuousHRVLn, base: 40, noise: 3.2, lowNoise: 1.2, glitch: 18,
                  up: 16, down: 14, coverage: 400, driftPerDay: 0.5),
        SeriesCfg(series: .sleepResp, base: 15.0, noise: 0.45, lowNoise: 0.15, glitch: 23,
                  up: 3.0, down: 2.5, coverage: nil, driftPerDay: 0.08),
        SeriesCfg(series: .sleepTemp, base: 33.0, noise: 0.27, lowNoise: 0.09, glitch: 36,
                  up: 0.9, down: 0.8, coverage: nil, driftPerDay: 0.02),
        SeriesCfg(series: .sleepSpO2Mean, base: 96.0, noise: 0.45, lowNoise: 0.2, glitch: 90,
                  up: 1.0, down: 4.0, coverage: 20, driftPerDay: 0.05),
        SeriesCfg(series: .sleepSpO2Nadir, base: 92.0, noise: 0.45, lowNoise: 0.2, glitch: 86,
                  up: 1.0, down: 4.0, coverage: 20, driftPerDay: 0.05),
        SeriesCfg(series: .awakeRestSpO2Mean, base: 97.0, noise: 0.45, lowNoise: 0.2, glitch: 91,
                  up: 1.0, down: 4.0, coverage: 20, driftPerDay: 0.05),
        SeriesCfg(series: .awakeActiveSpO2Mean, base: 96.0, noise: 0.45, lowNoise: 0.2, glitch: 90,
                  up: 1.0, down: 4.0, coverage: 20, driftPerDay: 0.05),
        SeriesCfg(series: .continuousSpO2Mean, base: 96.0, noise: 0.45, lowNoise: 0.2, glitch: 90,
                  up: 1.0, down: 4.0, coverage: 20, driftPerDay: 0.05),
        SeriesCfg(series: .wakingSteps, base: 8_000, noise: 450, lowNoise: 180, glitch: 38_000,
                  up: 5_000, down: 5_500, coverage: nil, driftPerDay: 120),
        SeriesCfg(series: .wakingActiveMin, base: 45, noise: 9, lowNoise: 3.5, glitch: 345,
                  up: 30, down: 32, coverage: nil, driftPerDay: 0.8),
    ]

    func cfg(_ s: LBSeries) -> SeriesCfg { allCfg.first { $0.series == s }! }

    func ok(_ day: String, _ v: Double, coverage: Double? = nil, stream: Bool = true)
        -> LBDailyObservation {
        LBDailyObservation(day: day, value: v, qualityStatus: .ok, qualityReason: nil,
                           coverage: coverage, streamPresent: stream)
    }

    /// Build a tape of `nights` nights ending at `end`. offset 0 = end (today).
    /// `noiseAmp` is the natural-noise amplitude; `override(offset)` replaces the value if non-nil.
    func tape(_ s: LBSeries, end: Int, nights: Int, noiseAmp: Double, seed: UInt64,
              override: ((Int) -> Double?)? = nil) -> [LBDailyObservation] {
        let c = cfg(s)
        var rng = LCG(seed: seed)
        var out: [LBDailyObservation] = []
        // oldest -> newest so the noise stream is stable regardless of windowing
        for i in stride(from: nights - 1, through: 0, by: -1) {
            let jitter = noiseAmp > 0 ? rng.noise(noiseAmp) : 0
            let v = override?(i) ?? (c.base + jitter)
            out.append(ok(iso(end - i), v, coverage: c.coverage))
        }
        return out
    }

    func eval(_ obs: [LBDailyObservation], _ s: LBSeries, asOf: String, replay: Bool = true,
              trial: LBTrialRequest = .none, carry: LBCarry = .empty) -> LBEvaluation {
        LongitudinalBaseline.evaluate(asOf: asOf, series: s, observations: obs, carry: carry,
                                      replay: replay, trial: trial)
    }

    /// Walk with a threaded carry and return the evaluation for every day in `days`.
    func walk(_ obs: [LBDailyObservation], _ s: LBSeries, days: [Int],
              trial: LBTrialRequest = .none) -> [LBEvaluation] {
        var carry = LBCarry.empty
        var out: [LBEvaluation] = []
        for d in days {
            let ev = eval(obs, s, asOf: iso(d), replay: false, trial: trial, carry: carry)
            carry = ev.carry
            out.append(ev)
        }
        return out
    }

    func kOf(_ s: LBSeries) -> Double { LongitudinalBaseline.params(for: s).kBand }

    /// Direction the plan says is worse for that biometric.
    func worseIsUp(_ s: LBSeries) -> Bool {
        switch LongitudinalBaseline.params(for: s).worse {
        case .higher: return true
        case .lower: return false
        case .either: return true   // either direction may be unusual for motion / temperature
        }
    }

    /// 40 stable nights + today, used for scenario work: the long copy is established.
    func stableTape(_ s: LBSeries, nights: Int = 70, noiseAmp: Double? = nil, seed: UInt64 = 7)
        -> [LBDailyObservation] {
        tape(s, end: T, nights: nights, noiseAmp: noiseAmp ?? cfg(s).lowNoise, seed: seed)
    }

    // MARK: - Plan §5 worked numbers (core numerical acceptance)

    /// §1.1/§5.1: the 57–63 bpm tape. center 61.1, MAD 1.92, spread 2.85, band 55.4–66.8,
    /// today 72 → delta 10.9, z 3.8.
    func test_plan_5_1_sleepRHRWeekRampExactNumbers() {
        // 57..63 oldest→newest on T−7..T−1, plus today 72.
        var obs: [LBDailyObservation] = []
        for (i, v) in [57.0, 58, 59, 60, 61, 62, 63].enumerated() {
            obs.append(ok(iso(T - 7 + i), v))
        }
        obs.append(ok(iso(T), 72))
        let ev = eval(obs, .sleepRHR, asOf: iso(T))
        let c = ev.copy7
        emit(["test": "plan_5_1", "series": "sleep_rhr", "center7": "\(c?.center ?? .nan)",
              "spread7": "\(c?.spread ?? .nan)", "lo": "\(c?.bandLoDisplay ?? .nan)",
              "hi": "\(c?.bandHiDisplay ?? .nan)", "delta": "\(c?.deltaDisplay ?? .nan)",
              "z7": "\(ev.z7 ?? .nan)", "n7": "\(ev.n7)", "nLearn": "\(ev.nLearn)"])
        XCTAssertEqual(c?.center ?? 0, 61.1, accuracy: 0.06, "§5.1 center_7")
        XCTAssertEqual(c?.spread ?? 0, 2.85, accuracy: 0.02, "§5.1 spread = 1.4826 × MAD 1.92")
        XCTAssertEqual(c?.bandLoDisplay ?? 0, 55.4, accuracy: 0.2, "§5.1 band low")
        XCTAssertEqual(c?.bandHiDisplay ?? 0, 66.8, accuracy: 0.2, "§5.1 band high")
        XCTAssertEqual(c?.deltaDisplay ?? 0, 10.9, accuracy: 0.2, "§5.1 7-day delta")
        XCTAssertEqual(ev.z7 ?? 0, 3.8, accuracy: 0.15, "§5.1 z = 10.9 / 2.85")
        XCTAssertFalse(ev.alertEligible, "four/five days alone never set alert_eligible")
    }

    /// §5.2 awake-rest HR 64..70 → center 68.1, floor 3.0 wins, band 62.1–74.1, today 75 → z 2.3.
    func test_plan_5_2_awakeRestHRExactNumbers() {
        var obs: [LBDailyObservation] = []
        for (i, v) in [64.0, 65, 66, 67, 68, 69, 70].enumerated() {
            obs.append(ok(iso(T - 7 + i), v, coverage: 60))
        }
        obs.append(ok(iso(T), 75, coverage: 60))
        let ev = eval(obs, .awakeRestHR, asOf: iso(T))
        let c = ev.copy7
        emit(["test": "plan_5_2", "series": "awake_rest_hr", "center7": "\(c?.center ?? .nan)",
              "spread7": "\(c?.spread ?? .nan)", "lo": "\(c?.bandLoDisplay ?? .nan)",
              "hi": "\(c?.bandHiDisplay ?? .nan)", "z7": "\(ev.z7 ?? .nan)"])
        XCTAssertEqual(c?.center ?? 0, 68.1, accuracy: 0.06, "§5.2 center_7")
        XCTAssertEqual(c?.spread ?? 0, 3.0, accuracy: 0.02, "§5.2 the 3 bpm floor wins over 2.85")
        XCTAssertEqual(c?.bandLoDisplay ?? 0, 62.1, accuracy: 0.2)
        XCTAssertEqual(c?.bandHiDisplay ?? 0, 74.1, accuracy: 0.2)
        XCTAssertEqual(ev.z7 ?? 0, 2.3, accuracy: 0.15, "§5.2 z = 6.9 / 3.0")
    }

    /// §5.3 sleep HRV: 40,45,48,50,55 ms on the five newest slots.
    /// The plan's own §5.3 arithmetic uses α = 0.25 (span 7), while §1.7 requires HRV span 10
    /// (α = 2/11). Both answers are checked and the divergence is reported, not hidden.
    func test_plan_5_3_sleepHRVLnExactNumbersAndSpanConflict() {
        var obs: [LBDailyObservation] = []
        for (i, v) in [40.0, 45, 48, 50, 55].enumerated() {
            obs.append(ok(iso(T - 5 + i), v))
        }
        obs.append(ok(iso(T), 32))
        let ev = eval(obs, .sleepHRVLn, asOf: iso(T))
        let c = ev.copy7
        let span7Center = 3.898
        let span10Center = 3.8863
        emit(["test": "plan_5_3", "series": "sleep_hrv_ln", "center7_ln": "\(c?.center ?? .nan)",
              "center7_ms": "\(c?.centerDisplay ?? .nan)", "spread_ln": "\(c?.spread ?? .nan)",
              "lo_ms": "\(c?.bandLoDisplay ?? .nan)", "hi_ms": "\(c?.bandHiDisplay ?? .nan)",
              "delta_ms": "\(c?.deltaDisplay ?? .nan)", "z7": "\(ev.z7 ?? .nan)",
              "plan_span7_center": "\(span7Center)", "plan_span10_center": "\(span10Center)",
              "engine_span": "\(LongitudinalBaseline.params(for: .sleepHRVLn).span7)"])
        XCTAssertEqual(Double(LongitudinalBaseline.params(for: .sleepHRVLn).span7), 10.0,
                       "§1.7 table: HRV this-week span is 10")
        // The engine must match the span-10 arithmetic (its own parameter row).
        XCTAssertEqual(c?.center ?? 0, span10Center, accuracy: 0.004,
                       "engine follow §1.7 span 10; §5.3's 3.898 assumes span 7")
        XCTAssertEqual(c?.centerDisplay ?? 0, 48.7, accuracy: 0.3, "ms display after exp()")
        // Plan §5.3's printed band (37.6–64.6 ms) assumes k = 2 and span 7; §1.7 gives HRV k = 2.6 and
        // span 10. Assert the engine is internally consistent with its own row instead.
        let kH = LongitudinalBaseline.params(for: .sleepHRVLn).kBand
        let lnSpread = c?.spread ?? 0
        XCTAssertEqual(c?.bandLoDisplay ?? 0, (c?.centerDisplay ?? 0) * exp(-kH * lnSpread),
                       accuracy: 0.02, "band uses this series' own k = \(kH)")
        XCTAssertEqual(c?.bandHiDisplay ?? 0, (c?.centerDisplay ?? 0) * exp(kH * lnSpread),
                       accuracy: 0.02, "band uses this series' own k = \(kH)")
        emit(["test": "plan_5_3_band_conflict", "series": "sleep_hrv_ln",
              "plan_band_lo": "37.6", "plan_band_hi": "64.6",
              "engine_band_lo": String(format: "%.2f", c?.bandLoDisplay ?? .nan),
              "engine_band_hi": String(format: "%.2f", c?.bandHiDisplay ?? .nan),
              "note": "plan §5.3 band assumes k=2 & span7; engine follows §1.7 (k2.6, span10)"])
        XCTAssertLessThan((c?.deltaDisplay ?? 0), -15, "delta is reported in ms, not ln units")
        XCTAssertEqual(ev.z7 ?? 0, -3.2, accuracy: 0.45,
                       "z is on the log scale; both spans are far past k = 2.6")
    }

    /// §5.4 awake-rest HRV: 28,30,32,31,29 → center ~30.1 ms, floor 0.08, band ~25.6–35.3 ms, z −3.9.
    func test_plan_5_4_awakeRestHRVExactNumbers() {
        var obs: [LBDailyObservation] = []
        for (i, v) in [28.0, 30, 32, 31, 29].enumerated() {
            obs.append(ok(iso(T - 5 + i), v, coverage: 60))
        }
        obs.append(ok(iso(T), 22, coverage: 60))
        let ev = eval(obs, .awakeRestHRVLn, asOf: iso(T))
        let c = ev.copy7
        emit(["test": "plan_5_4", "series": "awake_rest_hrv_ln", "center_ms": "\(c?.centerDisplay ?? .nan)",
              "spread_ln": "\(c?.spread ?? .nan)", "lo_ms": "\(c?.bandLoDisplay ?? .nan)",
              "hi_ms": "\(c?.bandHiDisplay ?? .nan)", "z7": "\(ev.z7 ?? .nan)"])
        XCTAssertEqual(c?.centerDisplay ?? 0, 30.1, accuracy: 0.4, "§5.4 center in ms")
        XCTAssertEqual(c?.spread ?? 0, 0.08, accuracy: 0.005, "§5.4 floor wins")
        let kA = LongitudinalBaseline.params(for: .awakeRestHRVLn).kBand
        let lnSpreadA = c?.spread ?? 0
        XCTAssertEqual(c?.bandLoDisplay ?? 0, (c?.centerDisplay ?? 0) * exp(-kA * lnSpreadA),
                       accuracy: 0.02, "band uses this series' own k = \(kA)")
        XCTAssertEqual(c?.bandHiDisplay ?? 0, (c?.centerDisplay ?? 0) * exp(kA * lnSpreadA),
                       accuracy: 0.02, "band uses this series' own k = \(kA)")
        emit(["test": "plan_5_4_band_conflict", "series": "awake_rest_hrv_ln",
              "plan_band_lo": "25.6", "plan_band_hi": "35.3",
              "engine_band_lo": String(format: "%.2f", c?.bandLoDisplay ?? .nan),
              "engine_band_hi": String(format: "%.2f", c?.bandHiDisplay ?? .nan),
              "note": "plan §5.4 band assumes k=2 & span7; engine follows §1.7 (k2.6, span10)"])
        XCTAssertEqual(ev.z7 ?? 0, -3.9, accuracy: 0.25, "§5.4 z = −8.1 / 0.08")
    }

    /// §5.5 respiration 14.5..15.2 → center 14.92, floor 0.5, today 17.5 → z 5.2.
    func test_plan_5_5_sleepRespExactNumbers() {
        var obs: [LBDailyObservation] = []
        for (i, v) in [14.5, 14.6, 14.8, 15.0, 15.2].enumerated() {
            obs.append(ok(iso(T - 5 + i), v))
        }
        obs.append(ok(iso(T), 17.5))
        let ev = eval(obs, .sleepResp, asOf: iso(T))
        let c = ev.copy7
        emit(["test": "plan_5_5", "series": "sleep_resp", "center7": "\(c?.center ?? .nan)",
              "spread7": "\(c?.spread ?? .nan)", "z7": "\(ev.z7 ?? .nan)",
              "k_used": "\(ev.kBandUsed)", "k_table": "\(ev.kBandTable)"])
        XCTAssertEqual(c?.center ?? 0, 14.92, accuracy: 0.02)
        XCTAssertEqual(c?.spread ?? 0, 0.50, accuracy: 0.01, "§5.5 floor wins over 0.41")
        XCTAssertEqual(ev.z7 ?? 0, 5.2, accuracy: 0.2)
    }

    /// §5.6 wrist temperature 32.80..33.10 → center 32.97, floor 0.3, today 33.80 → z 2.8.
    func test_plan_5_6_sleepTempExactNumbers() {
        var obs: [LBDailyObservation] = []
        for (i, v) in [32.80, 32.85, 32.90, 33.00, 33.10].enumerated() {
            obs.append(ok(iso(T - 5 + i), v))
        }
        obs.append(ok(iso(T), 33.80))
        let ev = eval(obs, .sleepTemp, asOf: iso(T))
        let c = ev.copy7
        emit(["test": "plan_5_6", "series": "sleep_temp", "center7": "\(c?.center ?? .nan)",
              "spread7": "\(c?.spread ?? .nan)", "z7": "\(ev.z7 ?? .nan)"])
        XCTAssertEqual(c?.center ?? 0, 32.97, accuracy: 0.02)
        XCTAssertEqual(c?.spread ?? 0, 0.30, accuracy: 0.01)
        XCTAssertEqual(ev.z7 ?? 0, 2.8, accuracy: 0.2)
    }

    /// §5.7 sleep SpO₂ mean → center 96.43, floor 0.5, today 94 → z −4.9.
    /// Also: 16 slots averaged; 7 slots would be a missing night, never a mean of 7.
    func test_plan_5_7_sleepSpO2MeanExactNumbers() {
        var obs: [LBDailyObservation] = []
        for (i, v) in [96.0, 96.2, 96.5, 96.8, 97.0, 96.4, 96.1].enumerated() {
            obs.append(ok(iso(T - 7 + i), v, coverage: 16))
        }
        obs.append(ok(iso(T), 94.0, coverage: 16))
        let ev = eval(obs, .sleepSpO2Mean, asOf: iso(T))
        let c = ev.copy7
        emit(["test": "plan_5_7", "series": "sleep_spo2_mean", "center7": "\(c?.center ?? .nan)",
              "spread7": "\(c?.spread ?? .nan)", "z7": "\(ev.z7 ?? .nan)"])
        XCTAssertEqual(c?.center ?? 0, 96.43, accuracy: 0.03)
        XCTAssertEqual(c?.spread ?? 0, 0.50, accuracy: 0.01)
        XCTAssertEqual(ev.z7 ?? 0, -4.9, accuracy: 0.2)

        // 7 valid slots is a missing night, not a mean.
        var thin = tape(.sleepSpO2Mean, end: T, nights: 8, noiseAmp: 0, seed: 1,
                        override: { $0 == 0 ? 94.0 : 96.0 })
        thin = thin.map { (o: LBDailyObservation) -> LBDailyObservation in
            guard LongitudinalBaseline.isoEpochDay(o.day) == T else { return o }
            return LBDailyObservation(day: o.day, value: 94, qualityStatus: .ok,
                                      qualityReason: nil, coverage: 7, streamPresent: true)
        }
        let evThin = eval(thin, .sleepSpO2Mean, asOf: iso(T))
        emit(["test": "plan_5_7b", "series": "sleep_spo2_mean", "today_native": "\(str(evThin.todayNative))",
              "n7": "\(evThin.n7)"])
        XCTAssertNil(evThin.todayNative, "§1.7/§5.7: under 8 valid slots the night is missing")
    }

    /// §5.8 sleep SpO₂ nadir → center 94.84, floor 0.5, today 91 → z −7.7, and it stays its own series.
    func test_plan_5_8_sleepSpO2NadirExactNumbers() {
        var obs: [LBDailyObservation] = []
        for (i, v) in [95.0, 94, 95, 96, 95, 94, 95].enumerated() {
            obs.append(ok(iso(T - 7 + i), v, coverage: 16))
        }
        obs.append(ok(iso(T), 91.0, coverage: 16))
        let ev = eval(obs, .sleepSpO2Nadir, asOf: iso(T))
        let c = ev.copy7
        emit(["test": "plan_5_8", "series": "sleep_spo2_nadir", "center7": "\(c?.center ?? .nan)",
              "spread7": "\(c?.spread ?? .nan)", "z7": "\(ev.z7 ?? .nan)"])
        XCTAssertEqual(c?.center ?? 0, 94.84, accuracy: 0.03)
        XCTAssertEqual(c?.spread ?? 0, 0.50, accuracy: 0.01)
        XCTAssertEqual(ev.z7 ?? 0, -7.7, accuracy: 0.25)
        XCTAssertNotEqual(LongitudinalBaseline.params(for: .sleepSpO2Nadir).kBand,
                          LongitudinalBaseline.params(for: .sleepSpO2Mean).kBand,
                          "nadir keeps its own k (1.7 vs 1.5)")
    }

    /// §5.10 steps → center 8503, spread 1034, today 4200 → z −4.2. Both directions are "unusual".
    func test_plan_5_10_stepsExactNumbers() {
        var obs: [LBDailyObservation] = []
        for (i, v) in [8000.0, 9200, 7500, 11000, 8800, 6400, 9100].enumerated() {
            obs.append(ok(iso(T - 7 + i), v))
        }
        obs.append(ok(iso(T), 4200))
        let ev = eval(obs, .wakingSteps, asOf: iso(T))
        let c = ev.copy7
        emit(["test": "plan_5_10", "series": "waking_steps", "center7": "\(c?.center ?? .nan)",
              "spread7": "\(c?.spread ?? .nan)", "z7": "\(ev.z7 ?? .nan)"])
        XCTAssertEqual(c?.center ?? 0, 8503, accuracy: 3)
        XCTAssertEqual(c?.spread ?? 0, 1034, accuracy: 12)
        XCTAssertEqual(ev.z7 ?? 0, -4.2, accuracy: 0.15)
    }

    /// §5.11 active minutes → center 45.9, spread 11.8, today 18 → z −2.4.
    func test_plan_5_11_activeMinExactNumbers() {
        var obs: [LBDailyObservation] = []
        for (i, v) in [42.0, 55, 38, 70, 50, 28, 48].enumerated() {
            obs.append(ok(iso(T - 7 + i), v))
        }
        obs.append(ok(iso(T), 18))
        let ev = eval(obs, .wakingActiveMin, asOf: iso(T))
        let c = ev.copy7
        emit(["test": "plan_5_11", "series": "waking_active_min", "center7": "\(c?.center ?? .nan)",
              "spread7": "\(c?.spread ?? .nan)", "z7": "\(ev.z7 ?? .nan)"])
        XCTAssertEqual(c?.center ?? 0, 45.9, accuracy: 0.2)
        XCTAssertEqual(c?.spread ?? 0, 11.8, accuracy: 0.2)
        XCTAssertEqual(ev.z7 ?? 0, -2.4, accuracy: 0.15)
    }
}

extension FRWhoopCoreBaselineAuditTests {

    /// Long-window pattern with median 60 and MAD 1.92 (spread 2.85), arranged symmetrically so
    /// Theil–Sen ≈ 0. 53 values: 26 × 60.0, 14 × 58.08, 13 × 61.92.
    func longPattern53() -> [Double] {
        var v: [Double] = []
        var lows = 14, highs = 13, mids = 26
        // symmetric interleave keeps the pairwise-slope median near zero
        while v.count < 53 {
            if lows > 0 { v.append(58.08); lows -= 1 }
            if v.count < 53, mids > 0 { v.append(60.0); mids -= 1 }
            if v.count < 53, highs > 0 { v.append(61.92); highs -= 1 }
            if v.count < 53, mids > 0 { v.append(60.0); mids -= 1 }
        }
        return Array(v.prefix(53))
    }

    /// Tape for §5.12: long window = longPattern53 (center 60, spread ~2.85, flat), week = the plan's
    /// seven values, today = 72.
    func downweightTape(week: [Double], today: Double) -> [LBDailyObservation] {
        var obs: [LBDailyObservation] = []
        let pat = longPattern53()          // oldest → newest for offsets 60 → 8
        for (i, v) in pat.enumerated() { obs.append(ok(iso(T - 60 + i), v)) }
        for (i, v) in week.enumerated() { obs.append(ok(iso(T - 7 + i), v)) }
        obs.append(ok(iso(T), today))
        return obs
    }

    /// §5.12 Student-t downweight: 58,59,60,61,62,72,72 vs long usual 60 / spread 2.85.
    /// λ ≈ 0.23 on the two 72s, n_learn ≈ 5.46, center_7_raw 66.3, center_7 62.7, gap 6.3, z7 2.5.
    func test_plan_5_12_studentTDownweightExactNumbers() {
        let obs = downweightTape(week: [58, 59, 60, 61, 62, 72, 72], today: 72)
        let ev = eval(obs, .sleepRHR, asOf: iso(T))
        let lambdas = ev.lambdas.map { String(format: "%.3f", $0) }.joined(separator: ",")
        emit(["test": "plan_5_12", "series": "sleep_rhr", "n7": "\(ev.n7)",
              "nLearn": String(format: "%.3f", ev.nLearn), "lambdas": lambdas,
              "center7Raw": String(format: "%.3f", ev.center7Raw ?? .nan),
              "center7": String(format: "%.3f", ev.copy7?.center ?? .nan),
              "spread7": String(format: "%.3f", ev.copy7?.spread ?? .nan),
              "gap": String(format: "%.3f", ev.gap ?? .nan),
              "gapZ": String(format: "%.3f", ev.gapZ ?? .nan),
              "z7": String(format: "%.3f", ev.z7 ?? .nan),
              "zLong": String(format: "%.3f", ev.zLong ?? .nan),
              "held": "\(ev.copy7?.held ?? false)"])
        XCTAssertEqual(ev.n7, 7)
        XCTAssertEqual(ev.nLearn, 5.46, accuracy: 0.15, "§5.12 n_learn = 5 + 2λ")
        XCTAssertEqual(ev.lambdas.last ?? 0, 0.23, accuracy: 0.02, "§5.12 λ(|z|=4.2)")
        XCTAssertEqual(ev.center7Raw ?? 0, 66.3, accuracy: 0.5, "§5.12 center_7_raw")
        XCTAssertEqual(ev.copy7?.center ?? 0, 62.7, accuracy: 0.5, "§5.12 center_7 sits between freeze and raw")
        XCTAssertEqual(ev.copy7?.spread ?? 0, 3.79, accuracy: 0.25, "§5.12 borrowed spread")
        XCTAssertEqual(ev.gap ?? 0, 6.3, accuracy: 0.5, "§5.12 gap = raw − center_long")
        XCTAssertEqual(ev.z7 ?? 0, 2.5, accuracy: 0.25, "§5.12 z vs the downweighted center")
        XCTAssertEqual(ev.zLong ?? 0, 4.2, accuracy: 0.2, "§5.12 z_long stays large")
        XCTAssertFalse(ev.copy7?.held ?? true, "§5.12 the week is not held: n_learn ≥ 4")
    }

    /// §5.13 hold when the whole week is off. Every λ ≈ 0.23 → n_learn ≈ 1.61 < 4 → the published
    /// center_7 is held (not 72) while center_7_raw = 72 and gap stays 12.
    func test_plan_5_13_holdWhenWholeWeekIsOff() {
        // Phases: a stable 7-day ramp publishes center_7 ≈ 61.1; the long window is the flat pattern;
        // the last seven nights and today are 72.
        var obs: [LBDailyObservation] = []
        let pattern = longPattern53()          // flat: centre 60, spread 2.85, slope 0
        for (i, v) in pattern.enumerated() { obs.append(ok(iso(T - 60 + i), v)) }
        // The seven-night gap (T−7…T−1) plus today are 72. The last week that could publish a
        // centre is [T−15, T−9], which is the same flat pattern.
        for off in stride(from: 7, through: 0, by: -1) { obs.append(ok(iso(T - off), 72)) }

        // Walk so the carry holds the last published center_7 (as of T−8, the last clean week).
        let days = Array((T - 12)...T)
        let walked = walk(obs, .sleepRHR, days: days)
        // The last week that can publish: [T−14, T−8] is still pattern values, so the value at T−7
        // is the last published centre before the fever holds it.
        let published = walked.first { $0.asOf == iso(T - 7) }!
        let atT = walked.last!
        emit(["test": "plan_5_13", "series": "sleep_rhr",
              "published_at_T_minus_7": String(format: "%.3f", published.copy7?.center ?? .nan),
              "center7_at_T": String(format: "%.3f", atT.copy7?.center ?? .nan),
              "center7Raw_at_T": String(format: "%.3f", atT.center7Raw ?? .nan),
              "nLearn_at_T": String(format: "%.3f", atT.nLearn),
              "held_at_T": "\(atT.copy7?.held ?? false)",
              "creepFromLastStableWeek": String(format: "%.3f",
                  (atT.copy7?.center ?? 0) - (published.copy7?.center ?? 0)),
              "gap_at_T": String(format: "%.3f", atT.gap ?? .nan),
              "zLong_at_T": String(format: "%.3f", atT.zLong ?? .nan)])
        XCTAssertEqual(atT.nLearn, 1.61, accuracy: 0.2, "§5.13 n_learn ≈ 1.61 < 4")
        XCTAssertEqual(atT.center7Raw ?? 0, 72, accuracy: 0.01, "§5.13 raw week = 72")
        let creep = (atT.copy7?.center ?? 0) - (published.copy7?.center ?? 0)
        XCTAssertNotEqual(atT.copy7?.center ?? 0, 72, accuracy: 0.01,
                          "§5.13 the training center must not become 72")
        XCTAssertLessThan(creep, 5.0,
                          "§5.13 the training center must not sprint to the fever (measured creep "
                          + "\(String(format: "%.2f", creep)) bpm while the whole week is off)")
        XCTAssertEqual(atT.copy7?.center ?? 0, atT.copy7?.center ?? 0, accuracy: 0.01)
        XCTAssertTrue(atT.copy7?.held ?? false, "§5.13 the copy is flagged held")
        XCTAssertEqual(atT.gap ?? 0, 12, accuracy: 0.6, "§5.13 gap ≈ 12 bpm")
        XCTAssertGreaterThan(abs(atT.zLong ?? 0), 3.5, "§5.13 z_long stays large")

        // Caller contract: without a carry (replay:false, empty carry) no hold is possible.
        let isolated = eval(obs, .sleepRHR, asOf: iso(T), replay: false)
        emit(["test": "plan_5_13_isolated", "series": "sleep_rhr",
              "center7_isolated": String(format: "%.3f", isolated.copy7?.center ?? .nan),
              "note": "replay:false+empty carry cannot hold; document as a caller contract"])
        XCTAssertEqual(isolated.copy7?.center ?? 0, 72, accuracy: 0.01,
                       "documented limitation: the hold needs a threaded carry (replay walk)")
    }

    /// §1.1/Step 6: three oldest 60 and four newest 72 → raw EWMA ≈ 69.5 but n_learn ≈ 3.9 < 4 → hold.
    func test_plan_step6_threeOldFourNewHoldsInsteadOfWalkingToTheRawEWMA() {
        let obs = downweightTape(week: [60, 60, 60, 72, 72, 72, 72], today: 72)
        let walked = walk(obs, .sleepRHR, days: Array((T - 10)...T))
        let atT = walked.last!
        let isolated = eval(obs, .sleepRHR, asOf: iso(T), replay: false)
        emit(["test": "step6_3old4new", "series": "sleep_rhr",
              "nLearn": String(format: "%.3f", atT.nLearn),
              "center7Raw": String(format: "%.3f", atT.center7Raw ?? .nan),
              "center7_walked": String(format: "%.3f", atT.copy7?.center ?? .nan),
              "center7_isolated": String(format: "%.3f", isolated.copy7?.center ?? .nan),
              "held": "\(atT.copy7?.held ?? false)"])
        XCTAssertEqual(atT.center7Raw ?? 0, 69.5, accuracy: 0.6, "plan: raw EWMA ≈ 69.5")
        XCTAssertEqual(atT.nLearn, 3.9, accuracy: 0.3, "plan: n_learn ≈ 3.9 < 4")
        XCTAssertNotEqual(atT.copy7?.center ?? 0, 72, accuracy: 0.5,
                          "plan: hold rather than walking to 72")
    }

    /// §1.1: missing-day renormalization. Dropping T−5 spreads its share over the survivors.
    func test_plan_1_1_missingDayRenormalizationAndRawCenter() {
        // T−7..T−1 = 58,60,—,61,59,72,72
        var obs: [LBDailyObservation] = []
        let week: [Double?] = [58, 60, nil, 61, 59, 72, 72]
        for (i, v) in week.enumerated() {
            if let v { obs.append(ok(iso(T - 7 + i), v)) }
            else {
                obs.append(LBDailyObservation(day: iso(T - 7 + i), value: nil,
                                              qualityStatus: .missing,
                                              qualityReason: .deviceOff, coverage: nil,
                                              streamPresent: false))
            }
        }
        obs.append(ok(iso(T), 72))
        let ev = eval(obs, .sleepRHR, asOf: iso(T))
        emit(["test": "plan_1_1_missing", "series": "sleep_rhr", "n7": "\(ev.n7)",
              "center7Raw": String(format: "%.3f", ev.center7Raw ?? .nan),
              "z7": String(format: "%.3f", ev.z7 ?? .nan)])
        XCTAssertEqual(ev.n7, 6, "the missing night is not a slot and not a zero")
        XCTAssertEqual(ev.center7Raw ?? 0, 66.5, accuracy: 0.6, "§1.1 worked center_7_raw = 66.5")

        // Full-week normalized weights are the plan's vector.
        let w = LongitudinalBaseline.fullWeekNormalizedWeights()
        emit(["test": "plan_1_1_weights", "weights": w.map { String(format: "%.3f", $0) }.joined(separator: ",")])
        let expected = [0.051, 0.069, 0.091, 0.122, 0.162, 0.216, 0.289]
        for i in 0..<7 { XCTAssertEqual(w[i], expected[i], accuracy: 0.001, "weight \(i)") }
    }

    /// §1.2: the long window is exactly [T−60, T−8] = 53 slots, T is in neither copy, and the last
    /// seven nights never enter the long median.
    func test_plan_1_2_longWindowStructure() {
        XCTAssertEqual(LongitudinalBaseline.longWindowLength(), 53)
        let t = T
        XCTAssertEqual((t - 8) - (t - 60) + 1, 53, "inclusive 53-slot window")

        // Long window at 60, the last seven nights at 90: the median must ignore them entirely.
        var obs: [LBDailyObservation] = []
        for off in stride(from: 60, through: 8, by: -1) { obs.append(ok(iso(t - off), 60)) }
        for off in stride(from: 7, through: 1, by: -1) { obs.append(ok(iso(t - off), 90)) }
        obs.append(ok(iso(t), 90))
        let ev = eval(obs, .sleepRHR, asOf: iso(t))
        emit(["test": "plan_1_2_window", "series": "sleep_rhr", "nLong": "\(ev.nLong)",
              "centerLong": String(format: "%.2f", ev.copyLong?.center ?? .nan),
              "z7": String(format: "%.2f", ev.z7 ?? .nan),
              "zLong": String(format: "%.2f", ev.zLong ?? .nan),
              "center7Raw": String(format: "%.2f", ev.center7Raw ?? .nan)])
        XCTAssertEqual(ev.nLong, 53, "53 long slots when every slot is quality-OK")
        XCTAssertEqual(ev.copyLong?.center ?? 0, 60, accuracy: 0.01,
                       "the last seven nights are not in the long median")
        XCTAssertEqual(ev.center7Raw ?? 0, 90, accuracy: 0.01,
                       "the seven-night gap is this week's copy")
        XCTAssertEqual(ev.zLong ?? 0, 15, accuracy: 0.2, "z_long = (90 − 60) / 2")
    }

    /// §5.15 borrowed spread with four learn days.
    func test_plan_5_15_borrowedSpreadWithFourLearnDays() {
        // Four learn days at 60, spread_7_raw = floor 2, long established spread ≈ 2.85.
        var obs: [LBDailyObservation] = []
        let pat = longPattern53()
        for (i, v) in pat.enumerated() { obs.append(ok(iso(T - 60 + i), v)) }
        // three nights missing in the week, four at 60
        for off in [7, 6, 5] {
            obs.append(LBDailyObservation(day: iso(T - off), value: nil, qualityStatus: .missing,
                                          qualityReason: .charging, coverage: nil,
                                          streamPresent: false))
        }
        for off in [4, 3, 2, 1] { obs.append(ok(iso(T - off), 60)) }
        obs.append(ok(iso(T), 60))
        let ev = eval(obs, .sleepRHR, asOf: iso(T))
        emit(["test": "plan_5_15", "series": "sleep_rhr", "nLearn": String(format: "%.2f", ev.nLearn),
              "spread7": String(format: "%.3f", ev.copy7?.spread ?? .nan),
              "confSpread": "\(ev.confSpread)", "alertEligible": "\(ev.alertEligible)"])
        XCTAssertEqual(ev.nLearn, 4.0, accuracy: 0.01, "four learn days")
        XCTAssertEqual(ev.copy7?.spread ?? 0, 2.36, accuracy: 0.15,
                       "§5.15 (4/7)×2.0 + (3/7)×2.85 = 2.36")
        XCTAssertFalse(ev.alertEligible == false && ev.establishedLong,
                       "alert_eligible follows the longer copy, not four days")
    }

    /// §5.16 trim vs online change-point: 7 fever nights are trimmed (p_change ≈ 0.73, no regime
    /// shift); 14 fever nights drive p_change ≈ 0.93 so the old center is held.
    func test_plan_5_16_sevenVsFourteenFeverNights() {
        // Fever nights occupy the newest long-window slots (offsets 8…8+n−1) so their residuals age
        // into the CUSUM exactly as plan §5.16 assumes. Spread comes from the flat pattern (2.85), so
        // |z| ≈ 4.2 and each entering night adds ≈ 3.7 to S.
        func feverTape(feverNights: Int) -> [LBDailyObservation] {
            let pattern = longPattern53()          // index i == offset 60 − i
            var obs: [LBDailyObservation] = []
            for i in 0..<53 {
                let off = 60 - i
                let isFever = off >= 8 && off < 8 + feverNights
                obs.append(ok(iso(T - off), isFever ? 72.0 : pattern[i]))
            }
            for off in stride(from: 7, through: 1, by: -1) { obs.append(ok(iso(T - off), 72.0)) }
            obs.append(ok(iso(T), 72.0))
            return obs
        }
        for nights in [7, 14] {
            let obs = feverTape(feverNights: nights)
            // Walk enough days that all fever nights have aged into [T−60, T−8].
            // Walk from first fever-entry (entering = asOf − 8) through T so 14 fever nights
            // can all increment CUSUM. (T−9)...T only sees 10 updates and cannot reach p ≈ 0.93.
            let atT = walk(obs, .sleepRHR, days: Array((T - 16)...T)).last!
            emit(["test": "plan_5_16", "series": "sleep_rhr", "feverNights": "\(nights)",
                  "cusumS": String(format: "%.1f", atT.cusumS),
                  "pChange": String(format: "%.3f", atT.pChange),
                  "regimeShift": "\(atT.regimeShift)",
                  "centerLong": String(format: "%.2f", atT.copyLong?.center ?? .nan),
                  "zLong": String(format: "%.2f", atT.zLong ?? .nan),
                  "held": "\(atT.copyLong?.held ?? false)",
                  "slopeUsable": "\(atT.slopeUsable)",
                  "slope": String(format: "%.4f", atT.slopeLong ?? .nan),
                  "trimKeptFrac": String(format: "%.2f", atT.trimKeptFrac ?? .nan)])
            XCTAssertLessThan(atT.copyLong?.center ?? 99, 66,
                              "\(nights) fever nights must not become the longer usual")
            if nights == 7 {
                XCTAssertLessThan(atT.pChange, 0.90,
                                  "§5.16 seven fever nights stay below p_thr (measured S = "
                                  + "\(String(format: "%.1f", atT.cusumS)))")
                XCTAssertFalse(atT.regimeShift, "§5.16 seven nights are trimmed, not a new usual")
            } else {
                // Plan §5.16: fourteen nights → p_change ≈ 0.93 ≥ 0.90, regime_shift = 1, and the old
                // centre is held ("do not call 72 the new usual").
                XCTAssertGreaterThan(atT.pChange, 0.85,
                                     "§5.16 fourteen nights → p ≈ 0.93 (measured S = "
                                     + "\(String(format: "%.1f", atT.cusumS)), p = "
                                     + "\(String(format: "%.3f", atT.pChange)))")
                XCTAssertTrue(atT.regimeShift,
                              "§5.16 fourteen nights must flag a regime shift")
                XCTAssertLessThan(abs((atT.copyLong?.center ?? 99) - 60), 3.0,
                                  "§5.16 the old centre is held, not replaced by 72")
            }
        }
    }

    /// §5.16b / §1.2.1 spike vs slow shift, plus the plan's exact expectations.
    func test_plan_5_16b_spikeVersusSlowShift() {
        // Spike: long stretch at 60, then two nights at 72.
        var spike: [LBDailyObservation] = []
        var rng = LCG(seed: 11)
        for off in stride(from: 70, through: 2, by: -1) { spike.append(ok(iso(T - off), 60 + rng.noise(0.05))) }
        spike.append(ok(iso(T - 1), 72)); spike.append(ok(iso(T), 72))
        let evSpike = walk(spike, .sleepRHR, days: Array((T - 12)...T)).last!
        emit(["test": "plan_5_16b_spike", "series": "sleep_rhr",
              "zLong": String(format: "%.2f", evSpike.zLong ?? .nan),
              "z7": String(format: "%.2f", evSpike.z7 ?? .nan),
              "center7": String(format: "%.2f", evSpike.copy7?.center ?? .nan),
              "centerLong": String(format: "%.2f", evSpike.copyLong?.center ?? .nan),
              "slopeUsable": "\(evSpike.slopeUsable)",
              "slope": String(format: "%.4f", evSpike.slopeLong ?? .nan)])
        XCTAssertGreaterThan(abs(evSpike.zLong ?? 0), kOf(.sleepRHR), "spike is OFF the longer usual")
        XCTAssertLessThan(evSpike.copy7?.center ?? 99, 66, "training usual does not become 72")

        // Slow shift: −0.3 bpm/day for 21 days.
        var ramp: [LBDailyObservation] = []
        for off in stride(from: 84, through: 0, by: -1) {
            let v = off <= 20 ? 66.0 - 0.3 * Double(20 - off) : 66.0
            ramp.append(ok(iso(T - off), v))
        }
        let evRamp = walk(ramp, .sleepRHR, days: Array((T - 12)...T)).last!
        let flatMedian = { () -> Double in
            let vals = (8...60).map { off -> Double in
                let o = off
                return o <= 20 ? 66.0 - 0.3 * Double(20 - o) : 66.0
            }
            return LongitudinalBaseline.median(vals) ?? .nan
        }()
        let zFlat = ((evRamp.todayNative ?? .nan) - flatMedian) / (evRamp.copyLong?.spread ?? 2)
        emit(["test": "plan_5_16b_ramp", "series": "sleep_rhr",
              "slope": String(format: "%.4f", evRamp.slopeLong ?? .nan),
              "slopeUsable": "\(evRamp.slopeUsable)",
              "expected": String(format: "%.2f", evRamp.expectedLong ?? .nan),
              "flatMedian": String(format: "%.2f", flatMedian),
              "zLong": String(format: "%.2f", evRamp.zLong ?? .nan),
              "zVsFlatMedian": String(format: "%.2f", zFlat),
              "pChange": String(format: "%.3f", evRamp.pChange),
              "cusumS": String(format: "%.1f", evRamp.cusumS)])
        XCTAssertTrue(evRamp.slopeUsable, "§1.2.1 usable slope is detected for a 21-night drift")
        XCTAssertLessThan(evRamp.pChange, 0.90, "§1.2.1 a slow drift is not a jump")
        XCTAssertGreaterThan(abs(zFlat), 2.0, "fixture sanity: vs a flat median this looks OFF")
        XCTAssertLessThan(abs(evRamp.zLong ?? 99), 2.0,
                          "§1.2.1 the drift must not be stuck OFF vs the expected path")
    }

    /// §5.17 two tracks after treatment start — plan arithmetic exact, then the engine overlay.
    func test_plan_5_17_expectedPathArithmeticAndOverlay() {
        // Pure plan arithmetic.
        let f = 20_000
        let e28 = LongitudinalBaseline.expectedUntreated(level0: 68, slopeG0: 0.05, usable: true,
                                                         asOfEpoch: f + 28, freezeEpoch: f)
        let e90 = LongitudinalBaseline.expectedUntreated(level0: 68, slopeG0: 0.05, usable: true,
                                                         asOfEpoch: f + 90, freezeEpoch: f)
        emit(["test": "plan_5_17_arith", "expected_28d": String(format: "%.2f", e28),
              "expected_90d": String(format: "%.2f", e90),
              "delta_traj": String(format: "%.2f", 61 - e28),
              "z_traj_at_2_85": String(format: "%.2f", (61 - e28) / 2.85),
              "mdc95_at_sigma1": String(format: "%.2f", 2.77 * 1.0)])
        XCTAssertEqual(e28, 69.4, accuracy: 0.001, "§5.17 expected_untreated = 68 + 0.05×28")
        XCTAssertEqual(e90, 69.5, accuracy: 0.001, "30-day cap: 68 + 0.05×30")
        XCTAssertEqual((61 - e28) / 2.85, -2.9, accuracy: 0.05, "§5.17 z_trial_traj")

        // Engine overlay on a real tape: rising pre-start RHR, then 28 days at 61.
        var obs: [LBDailyObservation] = []
        var rng = LCG(seed: 5)
        let t0 = T - 28
        for off in stride(from: 200, through: 1, by: -1) {
            let before = off > 28 ? 68.0 + 0.05 * Double(28 - off) : 61.0
            obs.append(ok(iso(T - off), before + rng.noise(0.35)))
        }
        obs.append(ok(iso(T), 61))
        let primary: [LBSeries] = [.sleepRHR]
        let events = [LBTreatmentEvent(trialId: "t1", type: .start, civilDay: iso(t0),
                                       clockTime: "08:00", displayName: "Drug", kind: .medication,
                                       enteredBy: .patient, onsetDays: 7, primarySeries: primary)]
        let trial = LBTrialRequest(events: events)
        let ev = eval(obs, .sleepRHR, asOf: iso(T), trial: trial)
        let tr = ev.trial
        emit(["test": "plan_5_17_overlay", "series": "sleep_rhr",
              "freezeOk": "\(tr.trialFreezeOk)", "phase": tr.phase.rawValue,
              "L0": String(format: "%.2f", tr.freeze?.centerLong ?? .nan),
              "G0": String(format: "%.4f", tr.freeze?.slopeLong ?? .nan),
              "spreadLong": String(format: "%.2f", tr.freeze?.spreadLong ?? .nan),
              "expected": String(format: "%.2f", tr.expectedT ?? .nan),
              "deltaLevel": String(format: "%.2f", tr.deltaTrialLevel ?? .nan),
              "deltaTraj": String(format: "%.2f", tr.deltaTrialTraj ?? .nan),
              "zLevel": String(format: "%.2f", tr.zTrialLevel ?? .nan),
              "zTraj": String(format: "%.2f", tr.zTrialTraj ?? .nan),
              "mdc95": String(format: "%.2f", tr.mdc95 ?? .nan),
              "aboveMdc": tr.aboveMdc.map { $0 ? "1" : "0" } ?? "nil",
              "cardLeadsWithExpected": "\(tr.card.freezeTitle ?? "none")"])
        XCTAssertTrue(tr.trialFreezeOk, "§5.17 a qualified start freezes a bundle")
        XCTAssertGreaterThan(tr.freeze?.slopeLong ?? 0, 0.02,
                            "G0 is the pre-start slow slope; this fixture's level rises toward t0")
        XCTAssertEqual(tr.deltaTrialTraj ?? 0, (ev.todayNative ?? 0) - (tr.expectedT ?? 0),
                       accuracy: 0.001, "delta_trial_traj = today − expected_untreated(T)")
        let fEpoch = LongitudinalBaseline.isoEpochDay(tr.freeze?.tFreeze ?? iso(T))!
        let tEpoch = LongitudinalBaseline.isoEpochDay(iso(T))!
        XCTAssertEqual(tr.expectedT ?? 0,
                       (tr.freeze?.centerLong ?? 0) + (tr.freeze?.slopeLong ?? 0) * Double(min(tEpoch - fEpoch, 30)),
                       accuracy: 0.01, "expected_untreated(T) = L0 + G0 × min(dt, 30)")
        XCTAssertEqual(tr.card.freezeTitle, "Expected without treatment",
                       "§5.17 the card leads with the expected path")
    }

    /// §5.18 qualification miss, §5.19 missingness and provenance.
    func test_plan_5_18_and_5_19_qualificationMissMissingnessProvenance() {
        // 8 long nights only → no freeze, adaptive keeps updating.
        let short = tape(.sleepRHR, end: T, nights: 12, noiseAmp: 0.4, seed: 3)
        let events = [LBTreatmentEvent(trialId: "t9", type: .start, civilDay: iso(T - 3),
                                       clockTime: "08:00", displayName: "Drug", kind: .medication,
                                       enteredBy: .patient, primarySeries: [.sleepRHR])]
        let ev = eval(short, .sleepRHR, asOf: iso(T), trial: LBTrialRequest(events: events))
        emit(["test": "plan_5_18", "series": "sleep_rhr", "nLong": "\(ev.nLong)",
              "freezeOk": "\(ev.trial.trialFreezeOk)", "phase": ev.trial.phase.rawValue,
              "hasFreeze": "\(ev.trial.freeze != nil)", "show7": "\(ev.show7)"])
        XCTAssertFalse(ev.trial.trialFreezeOk, "§5.18 thin data cannot freeze a control")
        XCTAssertNil(ev.trial.freeze, "§5.18 no frozen bundle is written")
        XCTAssertTrue(ev.show7, "§5.18 the adaptive snapshot keeps updating")

        // §5.19: a hospital day is missing, never 0 bpm, and does not train or enter the contrast.
        var obs = stableTape(.sleepRHR, nights: 90)
        obs = obs.map { o in
            guard LongitudinalBaseline.isoEpochDay(o.day) == T else { return o }
            return LBDailyObservation(day: o.day, value: nil, qualityStatus: .missing,
                                      qualityReason: .hospital, coverage: nil, streamPresent: false)
        }
        let evH = eval(obs, .sleepRHR, asOf: iso(T))
        emit(["test": "plan_5_19", "series": "sleep_rhr",
              "today": str(evH.todayNative), "n7": "\(evH.n7)",
              "reason": obs.first { $0.day == iso(T) }?.qualityReason?.rawValue ?? "none"])
        XCTAssertNil(evH.todayNative, "§5.19 hospital night is missing, not 0 bpm")
        XCTAssertEqual(obs.first { $0.day == iso(T) }?.qualityReason, .hospital,
                       "§5.19 the hospital reason is stored")

        // provenance: firmware change after t0 flips provenance_break.
        var rise: [LBDailyObservation] = []
        var rng = LCG(seed: 8)
        for off in stride(from: 150, through: 0, by: -1) {
            rise.append(ok(iso(T - off), (off < 30 ? 70.0 : 74.0) + rng.noise(0.5)))
        }
        let evA = eval(rise, .sleepRHR, asOf: iso(T),
                       trial: LBTrialRequest(events: events, provenanceNow: LBProvenance(firmware: "1")))
        if let bundle = evA.trial.freeze {
            let evB = eval(rise, .sleepRHR, asOf: iso(T),
                           trial: LBTrialRequest(events: events, freeze: bundle,
                                                 provenanceNow: LBProvenance(firmware: "2")))
            emit(["test": "plan_5_19_prov", "series": "sleep_rhr",
                  "break": "\(evB.trial.provenanceBreak)",
                  "eligible": "\(evB.trial.primaryContrastEligible)"])
            XCTAssertTrue(evB.trial.provenanceBreak, "§5.19 firmware change → provenance_break")
            XCTAssertFalse(evB.trial.primaryContrastEligible)
        } else {
            emit(["test": "plan_5_19_prov", "series": "sleep_rhr", "break": "no-freeze",
                  "eligible": "n/a"])
            XCTFail("§5.19 fixture did not qualify, so provenance could not be tested")
        }
    }
}

extension FRWhoopCoreBaselineAuditTests {

    // MARK: - Scenario A: stable behaviour (all 17 series)

    /// Stationary stable person, low noise, moderate noise, isolated glitch. Reports the per-series
    /// stable false-positive rate for both copies (plan §1.7/§1.1) and that a glitch is visible for a
    /// day without being absorbed into the longer usual.
    func test_scenarioA_stableBehaviourAllSeries() {
        for c in allCfg {
            let s = c.series
            for (label, amp) in [("low", c.lowNoise), ("moderate", c.noise)] {
                let obs = tape(s, end: T, nights: 70, noiseAmp: amp, seed: 101)
                let days = Array((T - 9)...T)
                let evs = walk(obs, s, days: days)
                let k = evs.last!.kBandUsed
                let ok = evs.filter { $0.establishedLong && !$0.stale }
                let offLong = ok.filter { abs($0.zLong ?? 0) >= k }.count
                let offWeek = ok.filter { abs($0.z7 ?? 0) >= k }.count
                let spreads = ok.compactMap { $0.copyLong?.spread }
                emit(["test": "A_stable", "series": s.rawValue, "noise": label,
                      "n": "\(ok.count)", "offLong": "\(offLong)", "offWeek": "\(offWeek)",
                      "kUsed": String(format: "%.3f", k), "kTable": String(format: "%.2f", evs.last!.kBandTable),
                      "spreadLong": String(format: "%.3f", spreads.first ?? .nan),
                      "zLong_last": String(format: "%.3f", evs.last!.zLong ?? .nan),
                      "alertEligible": "\(evs.last!.alertEligible)"])
                XCTAssertTrue(evs.last!.establishedLong, "\(s.rawValue): 70 nights establish the long copy")
                XCTAssertLessThanOrEqual(offLong, 3,
                                         "\(s.rawValue)/\(label): a stable person is not OFF the longer usual "
                                         + "(k_used is the 95th percentile of the window, so a few OFFs are by design; "
                                         + "the 1,000-trace calibration is the real FPR number)")
            }

            // Isolated glitch: OFF that night, in range the next night, longer usual unmoved.
            let glitchDay = T - 3
            let days = Array((T - 9)...T)
            let baseline = walk(tape(s, end: T, nights: 70, noiseAmp: c.lowNoise, seed: 202), s, days: days)
            var obs = tape(s, end: T, nights: 70, noiseAmp: c.lowNoise, seed: 202)
            let glitchValue = c.glitch
            obs = obs.map { o in
                guard LongitudinalBaseline.isoEpochDay(o.day) == glitchDay else { return o }
                return ok(o.day, glitchValue, coverage: c.coverage)
            }
            let glitched = walk(obs, s, days: days)
            let glitchEv = glitched.first { $0.asOf == iso(glitchDay) }!
            let nextEv = glitched.first { $0.asOf == iso(glitchDay + 1) }!
            let baseCenter = disp(s, baseline.first { $0.asOf == iso(T) }!.copyLong?.center ?? .nan)
            let glitchCenter = disp(s, glitched.first { $0.asOf == iso(T) }!.copyLong?.center ?? .nan)
            emit(["test": "A_glitch", "series": s.rawValue,
                  "glitchZ": String(format: "%.2f", glitchEv.zLong ?? .nan),
                  "glitchOff": "\(abs(glitchEv.zLong ?? 0) >= glitchEv.kBandUsed)",
                  "nextZ": String(format: "%.2f", nextEv.zLong ?? .nan),
                  "centerShift": String(format: "%.3f", glitchCenter - baseCenter),
                  "glitchValue": String(format: "%.2f", glitchValue)])
            XCTAssertGreaterThan(abs(glitchEv.zLong ?? 0), 1.8,
                                 "\(s.rawValue): a large isolated glitch is visible, not smoothed away")
            XCTAssertLessThan(abs(glitchCenter - baseCenter), abs(glitchValue - c.base) * 0.25,
                              "\(s.rawValue): one bad night does not move the longer usual")
        }
    }

    // MARK: - Scenario B: short disturbance (all 17 series)

    /// One-, two- and three-night spikes plus a five-night plateau, in the direction that is worse for
    /// that biometric. Expected: longer baseline stable, this-week raw output shows the movement, the
    /// training centre is held or downweighted, the disturbance is not silently normalised away.
    func test_scenarioB_shortDisturbanceAllSeries() {
        for c in allCfg {
            let s = c.series
            let sign = worseIsUp(s) ? 1.0 : -1.0
            let size = sign > 0 ? c.up : c.down
            for nights in [1, 2, 3, 5] {
                var obs = tape(s, end: T, nights: 70, noiseAmp: c.lowNoise, seed: 303)
                for i in 0..<nights {
                    let day = T - i
                    obs = obs.map { o in
                        guard LongitudinalBaseline.isoEpochDay(o.day) == day else { return o }
                        return ok(o.day, c.base + sign * size, coverage: c.coverage)
                    }
                }
                let days = Array((T - 9)...T)
                let evs = walk(obs, s, days: days)
                let atT = evs.last!
                let weekStart = evs.first { $0.asOf == iso(T - nights) }!
                let centerShift = disp(s, atT.copyLong?.center ?? .nan) - c.base
                let z = atT.zLong ?? 0
                emit(["test": "B_disturbance", "series": s.rawValue, "nights": "\(nights)",
                      "zLong": String(format: "%.2f", z), "z7": String(format: "%.2f", atT.z7 ?? .nan),
                      "center7Raw": String(format: "%.3f", atT.center7Raw ?? .nan),
                      "center7": String(format: "%.3f", atT.copy7?.center ?? .nan),
                      "center7_held": "\(atT.copy7?.held ?? false)",
                      "centerLongShift": String(format: "%.3f", centerShift),
                      "weekRawShift": String(format: "%.3f", (weekStart.center7Raw ?? .nan) - c.base),
                      "kUsed": String(format: "%.2f", atT.kBandUsed)])
                XCTAssertEqual(sign > 0, z > 0,
                               "\(s.rawValue)/\(nights)n: z keeps the worsening direction")
                XCTAssertGreaterThan(abs(z), 1.5,
                                     "\(s.rawValue)/\(nights)n: the disturbance is visible in z_long")
                XCTAssertLessThan(abs(centerShift), max(size * 0.5, 3 * (atT.copyLong?.spread ?? 1)),
                                  "\(s.rawValue)/\(nights)n: a short disturbance is not absorbed")
            }
        }
    }

    // MARK: - Scenario C: abrupt level shift (all 17 series)

    /// Fourteen nights at a new level, aged into the long window. Expected: the baseline does not
    /// instantly absorb the jump; the patient is clearly OFF the old usual; p_change/regime state is
    /// reported so "OFF old usual" is distinguishable from "new usual accepted".
    func test_scenarioC_abruptShiftAllSeries() {
        for c in allCfg {
            let s = c.series
            for dir in [1.0, -1.0] {
                let size = dir > 0 ? c.up : c.down
                // A sustained abrupt shift: the person has been at the new level for 21 nights and is
                // still there today, so today is compared with the old usual.
                var obs = tape(s, end: T, nights: 90, noiseAmp: c.lowNoise, seed: 404)
                obs = obs.map { o in
                    guard let e = LongitudinalBaseline.isoEpochDay(o.day), e >= T - 20 else { return o }
                    return ok(o.day, c.base + dir * size, coverage: c.coverage)
                }
                let days = Array((T - 9)...T)
                let atT = walk(obs, s, days: days).last!
                let shift = disp(s, atT.copyLong?.center ?? .nan) - c.base
                emit(["test": "C_shift", "series": s.rawValue, "dir": dir > 0 ? "up" : "down",
                      "centerLongShift": String(format: "%.3f", shift),
                      "absorbed": "\(abs(shift) > abs(size) * 0.5)",
                      "zLong": String(format: "%.2f", atT.zLong ?? .nan),
                      "z7": String(format: "%.2f", atT.z7 ?? .nan),
                      "pChange": String(format: "%.3f", atT.pChange),
                      "cusumS": String(format: "%.1f", atT.cusumS),
                      "regimeShift": "\(atT.regimeShift)",
                      "slopeUsable": "\(atT.slopeUsable)",
                      "held": "\(atT.copyLong?.held ?? false)"])
                XCTAssertLessThan(abs(shift), abs(size) * 0.6,
                                  "\(s.rawValue)/\(dir > 0 ? "up" : "down"): a 14-night jump is not "
                                  + "silently absorbed into the usual")
            }
        }
    }

    // MARK: - Scenario D: slow drift (all 17 series)

    /// 21-30 nights of biologically plausible drift. Expected: a usable slope is detected, the expected
    /// path follows the drift, the person is not marked OFF against an obsolete flat median, CUSUM runs
    /// on detrended residuals, and a slow trend is not called an abrupt regime jump.
    func test_scenarioD_slowDriftAllSeries() {
        for c in allCfg {
            let s = c.series
            for dir in [1.0, -1.0] {
                let total = c.driftPerDay * 21
                var obs: [LBDailyObservation] = []
                for off in stride(from: 60, through: 0, by: -1) {
                    let v = off <= 20
                        ? c.base + dir * c.driftPerDay * Double(20 - off)
                        : c.base
                    obs.append(ok(iso(T - off), v, coverage: c.coverage))
                }
                let days = Array((T - 9)...T)
                let atT = walk(obs, s, days: days).last!
                let spread = atT.copyLong?.spread ?? 1
                let flatVals = (8...60).map { off -> Double in
                    off <= 20 ? c.base + dir * c.driftPerDay * Double(20 - off) : c.base
                }
                let flatMedian = LongitudinalBaseline.median(flatVals) ?? .nan
                let todayMath = (atT.todayNative.flatMap { LongitudinalBaseline.toMath($0, series: s) }) ?? .nan
            let zFlat = (todayMath - flatMedian) / spread
                emit(["test": "D_drift", "series": s.rawValue, "dir": dir > 0 ? "up" : "down",
                      "totalDrift": String(format: "%.2f", total),
                      "slope": String(format: "%.4f", atT.slopeLong ?? .nan),
                      "expectedSlope": String(format: "%.4f", dir * c.driftPerDay),
                      "slopeUsable": "\(atT.slopeUsable)",
                      "expected": String(format: "%.3f", atT.expectedLong ?? .nan),
                      "today": String(format: "%.3f", atT.todayNative ?? .nan),
                      "zLong": String(format: "%.2f", atT.zLong ?? .nan),
                      "zVsFlatMedian": String(format: "%.2f", zFlat),
                      "pChange": String(format: "%.3f", atT.pChange),
                      "regimeShift": "\(atT.regimeShift)",
                      "cusumS": String(format: "%.1f", atT.cusumS)])
                XCTAssertLessThan(atT.pChange, 0.90,
                                  "\(s.rawValue): a slow drift is not a regime jump")
            }
        }
    }
}

extension FRWhoopCoreBaselineAuditTests {

    // MARK: - Scenario E: recovery

    /// Stable → three-night excursion → gradual return. Reports false-OFF duration, recovery lag and
    /// whether the training centre absorbed the excursion.
    func test_scenarioE_recoveryAllSeries() {
        for c in allCfg {
            let s = c.series
            let sign = worseIsUp(s) ? 1.0 : -1.0
            let size = sign > 0 ? c.up : c.down
            let excursionStart = T - 12          // T-12, T-11, T-10
            let excursionEnd = T - 10
            var obs = tape(s, end: T, nights: 70, noiseAmp: c.lowNoise, seed: 505)
            obs = obs.map { o in
                guard let e = LongitudinalBaseline.isoEpochDay(o.day) else { return o }
                if e >= excursionStart, e <= excursionEnd {
                    return ok(o.day, c.base + sign * size, coverage: c.coverage)
                }
                if e > excursionEnd, e < T {      // gradual return over the remaining nights
                    let t = Double(e - excursionEnd) / Double(T - excursionEnd)
                    return ok(o.day, c.base + sign * size * (1 - t), coverage: c.coverage)
                }
                return o
            }
            let days = Array(excursionStart...T)
            let evs = walk(obs, s, days: days)
            let k = evs.last!.kBandUsed
            let offDays = evs.filter { abs($0.zLong ?? 0) >= k }
            let lastOff = offDays.last.map { LongitudinalBaseline.isoEpochDay($0.asOf)! }
            let recoveryLag = lastOff.map { T - $0 } ?? 0
            emit(["test": "E_recovery", "series": s.rawValue,
                  "falseOffDays": "\(offDays.count)", "recoveryLagDays": "\(recoveryLag)",
                  "maxAbsZ": String(format: "%.2f", evs.map { abs($0.zLong ?? 0) }.max() ?? 0),
                  "finalZ": String(format: "%.2f", evs.last!.zLong ?? .nan),
                  "center7Drift": String(format: "%.3f", disp(s, evs.last!.copy7?.center ?? .nan) - c.base),
                  "centerLongDrift": String(format: "%.3f", disp(s, evs.last!.copyLong?.center ?? .nan) - c.base)])
            XCTAssertLessThan(disp(s, evs.last!.copy7?.center ?? .nan), c.base + size * 0.5,
                              "\(s.rawValue): the training centre does not stay at the excursion level")
        }
    }

    // MARK: - Scenario F: variance changes

    func test_scenarioF_varianceChangesAllSeries() {
        for c in allCfg {
            let s = c.series
            // same centre, 3× variance
            let quiet = tape(s, end: T, nights: 70, noiseAmp: c.lowNoise, seed: 606)
            let wild = tape(s, end: T, nights: 70, noiseAmp: c.lowNoise * 3, seed: 607)
            let evQ = walk(quiet, s, days: Array((T - 9)...T)).last!
            let evW = walk(wild, s, days: Array((T - 9)...T)).last!
            emit(["test": "F_varianceUp", "series": s.rawValue,
                  "spreadQuiet": String(format: "%.3f", evQ.copyLong?.spread ?? .nan),
                  "spreadWild": String(format: "%.3f", evW.copyLong?.spread ?? .nan),
                  "kUsedQuiet": String(format: "%.3f", evQ.kBandUsed),
                  "kUsedWild": String(format: "%.3f", evW.kBandUsed),
                  "zQuiet": String(format: "%.2f", evQ.zLong ?? .nan),
                  "zWild": String(format: "%.2f", evW.zLong ?? .nan)])
            XCTAssertGreaterThanOrEqual(evW.copyLong?.spread ?? 0, evQ.copyLong?.spread ?? 0,
                                        "\(s.rawValue): a noisier person gets a wider scale")

            // one outlier after a low-MAD period must not blow up the scale (MAD robustness)
            var outlier = tape(s, end: T, nights: 70, noiseAmp: c.lowNoise, seed: 608)
            outlier = outlier.map { o in
                LongitudinalBaseline.isoEpochDay(o.day) == T - 1
                    ? ok(o.day, c.base + (worseIsUp(s) ? 1 : -1) * c.glitch, coverage: c.coverage) : o
            }
            let evO = walk(outlier, s, days: Array((T - 9)...T)).last!
            emit(["test": "F_outlier", "series": s.rawValue,
                  "spreadBefore": String(format: "%.3f", evQ.copyLong?.spread ?? .nan),
                  "spreadAfter": String(format: "%.3f", evO.copyLong?.spread ?? .nan),
                  "ratio": String(format: "%.2f", (evO.copyLong?.spread ?? 0) / max(evQ.copyLong?.spread ?? 1, 0.0001))])
            XCTAssertLessThan((evO.copyLong?.spread ?? 0), (evQ.copyLong?.spread ?? 1) * 3.0,
                              "\(s.rawValue): one outlier must not triple the robust scale")

            // centre unchanged by variance alone
            XCTAssertEqual(disp(s, evW.copyLong?.center ?? 0), c.base, accuracy: max(c.noise * 0.6, 0.05),
                           "\(s.rawValue): more noise does not move the centre")
        }
    }

    // MARK: - Scenario G: data integrity

    func test_scenarioG_dataIntegrityAllSeries() {
        for c in allCfg {
            let s = c.series
            let clean = stableTape(s, nights: 80, seed: 707)
            let evClean = eval(clean, s, asOf: iso(T))

            // missing nights: never a zero
            var missingWeek = clean
            missingWeek = missingWeek.map { o in
                guard let e = LongitudinalBaseline.isoEpochDay(o.day), e >= T - 6 else { return o }
                return LBDailyObservation(day: o.day, value: nil, qualityStatus: .missing,
                                          qualityReason: .deviceOff, coverage: nil,
                                          streamPresent: false)
            }
            let evMissing = eval(missingWeek, s, asOf: iso(T))

            // three-night gap including today
            var missingToday = clean
            missingToday = missingToday.map { o in
                guard let e = LongitudinalBaseline.isoEpochDay(o.day), e >= T - 2 else { return o }
                return LBDailyObservation(day: o.day, value: nil, qualityStatus: .missing,
                                          qualityReason: .charging, coverage: nil,
                                          streamPresent: false)
            }
            let evMissingToday = eval(missingToday, s, asOf: iso(T))

            // low-quality + out of range + sparse sleep reasons
            var bad = clean
            bad = bad.map { o in
                guard let e = LongitudinalBaseline.isoEpochDay(o.day) else { return o }
                if e == T - 3 { return LBDailyObservation(day: o.day, value: nil,
                                                          qualityStatus: .lowQuality,
                                                          qualityReason: .poorSignal,
                                                          coverage: nil, streamPresent: true) }
                if e == T - 2 { return LBDailyObservation(day: o.day,
                                                          value: LongitudinalBaseline.seriesSpec(s).maxVal + 50,
                                                          qualityStatus: .lowQuality,
                                                          qualityReason: .outOfRange,
                                                          coverage: c.coverage, streamPresent: true) }
                if e == T - 1 { return LBDailyObservation(day: o.day, value: o.value,
                                                          qualityStatus: .lowQuality,
                                                          qualityReason: .sparseSleep,
                                                          coverage: nil, streamPresent: true) }
                return o
            }
            let evBad = eval(bad, s, asOf: iso(T))

            // late-arriving value: the same tape with T−2 restored must differ
            var late = clean
            late = late.map { o in
                LongitudinalBaseline.isoEpochDay(o.day) == T - 2
                    ? LBDailyObservation(day: o.day, value: nil, qualityStatus: .missing,
                                         qualityReason: .appFail, coverage: nil, streamPresent: false) : o
            }
            let evBefore = eval(late, s, asOf: iso(T))
            let evAfter = eval(clean, s, asOf: iso(T))

            // a future-dated sample must not enter the score
            var future = clean
            future.append(ok(iso(T + 5), c.base + (worseIsUp(s) ? 3 : -3) * c.noise, coverage: c.coverage))
            let evFuture = eval(future, s, asOf: iso(T))

            emit(["test": "G_integrity", "series": s.rawValue,
                  "cleanToday": evClean.todayNative.map { String(format: "%.2f", $0) } ?? "nil",
                  "missingToday": evMissingToday.todayNative.map { String(format: "%.2f", $0) } ?? "nil",
                  "missingWeekN7": "\(evMissing.n7)", "missingWeekShow7": "\(evMissing.show7)",
                  "badToday": evBad.todayNative.map { String(format: "%.2f", $0) } ?? "nil",
                  "badN7": "\(evBad.n7)",
                  "lateDiffer": "\(evBefore.todayNative != evAfter.todayNative || evBefore.n7 != evAfter.n7)",
                  "lateBeforeN7": "\(evBefore.n7)", "lateAfterN7": "\(evAfter.n7)",
                  "futureEqualsClean": "\(evFuture == evClean)"])
            XCTAssertNil(evMissingToday.todayNative,
                         "\(s.rawValue): three missing nights leave today missing, never 0")
            XCTAssertGreaterThan(evMissing.n7, 0)
            XCTAssertLessThan(evMissing.usualTrustPct7, evClean.usualTrustPct7,
                              "\(s.rawValue): missing nights lower TRUST")
            XCTAssertEqual(evFuture, evClean,
                           "\(s.rawValue): a sample after the as-of cutoff does not enter the score")
            XCTAssertNotEqual(evBefore.n7, evAfter.n7,
                              "\(s.rawValue): a late-arriving night changes the week count")
        }
    }

    /// §3 zero-step rule and the coverage gates.
    func test_scenarioG_zeroStepsAndCoverageGates() {
        let days = [metric(iso(T - 1), steps: 0), metric(iso(T - 2), steps: nil)]
        let obs = LongitudinalBaseline.observations(from: days, series: .wakingSteps)
        emit(["test": "G_steps", "series": "waking_steps",
              "zeroValue": obs.first?.value.map { String(format: "%.0f", $0) } ?? "nil",
              "zeroStatus": obs.first?.qualityStatus.rawValue ?? "nil",
              "nilValue": obs.last?.value.map { String(format: "%.0f", $0) } ?? "nil",
              "nilStatus": obs.last?.qualityStatus.rawValue ?? "nil"])
        XCTAssertEqual(obs.first?.value, 0, "§3: zero steps with a live stream is a real day")
        XCTAssertEqual(obs.first?.qualityStatus, .ok)
        XCTAssertNil(obs.last?.value, "§3: a missing stream is missing, not zero")

        // Coverage gates only fire when coverage is present.
        let spo2 = LBDailyObservation(day: iso(T), value: 96, qualityStatus: .ok,
                                      qualityReason: nil, coverage: 5, streamPresent: true)
        let gated = LongitudinalBaseline.applyCoverageGate(spo2, series: .sleepSpO2Mean)
        let ungated = LongitudinalBaseline.applyCoverageGate(
            LBDailyObservation(day: iso(T), value: 96, qualityStatus: .ok, qualityReason: nil,
                               coverage: nil, streamPresent: true), series: .sleepSpO2Mean)
        emit(["test": "G_coverage", "series": "sleep_spo2_mean",
              "fiveSlots": gated.qualityStatus.rawValue, "noCoverage": ungated.qualityStatus.rawValue])
        XCTAssertEqual(gated.qualityStatus, .missing, "5 slots → missing (plan §3)")

        // The DailyMetric path supplies no coverage at all for the wired SpO2 series.
        let real = LongitudinalBaseline.observations(from: [metric(iso(T), spo2: 96)],
                                                     series: .sleepSpO2Mean)
        emit(["test": "G_coverage_realpath", "series": "sleep_spo2_mean",
              "coverage": real.first?.coverage.map { String(format: "%.0f", $0) } ?? "nil",
              "status": real.first?.qualityStatus.rawValue ?? "nil"])
        XCTAssertNil(real.first?.coverage,
                     "the DailyMetric path cannot supply SpO2 slot coverage, so the ≥8-slot rule is inert")
    }

    // MARK: - Scenario H: context isolation

    /// Every wired series reads its own column; unwired series read nothing (never another biometric's
    /// value); the same tape never produces shared state across series.
    func test_scenarioH_contextIsolation() {
        // Distinct sentinels per column.
        let row = DailyMetric(day: iso(T), totalSleepMin: nil, efficiency: nil, deepMin: nil,
                              remMin: nil, lightMin: nil, disturbances: nil, restingHr: 61,
                              avgHrv: 62, recovery: nil, strain: nil, exerciseCount: nil,
                              spo2Pct: 95, skinTempDevC: nil, respRateBpm: 14,
                              steps: 7_777, activeKcalEst: nil, avgSdnn: 88, skinTempC: 33.5)
        let expect: [(LBSeries, Double?)] = [
            (.sleepRHR, 61), (.sleepHRVLn, 62), (.sleepResp, 14), (.sleepTemp, 33.5),
            (.sleepSpO2Mean, 95), (.wakingSteps, 7_777),
            (.awakeRestHR, nil), (.awakeActiveHR, nil), (.continuousHR, nil),
            (.sleepHRVLn, 62), (.awakeRestHRVLn, nil), (.awakeActiveHRVLn, nil),
            (.continuousHRVLn, nil), (.sleepSpO2Nadir, nil), (.awakeRestSpO2Mean, nil),
            (.awakeActiveSpO2Mean, nil), (.continuousSpO2Mean, nil), (.wakingActiveMin, nil),
        ]
        for (s, want) in expect {
            let got = LongitudinalBaseline.observations(from: [row], series: s).first?.value
            emit(["test": "H_context", "series": s.rawValue,
                  "value": got.map { String(format: "%.2f", $0) } ?? "nil",
                  "expected": want.map { String(format: "%.2f", $0) } ?? "nil",
                  "context": s.context.rawValue, "family": s.biometricFamily])
            if let want {
                XCTAssertEqual(got ?? .nan, want, accuracy: 0.001,
                               "\(s.rawValue) must read its own column")
            } else {
                XCTAssertNil(got, "\(s.rawValue) must not borrow another biometric's value")
            }
            // angle: SDNN is never used for any HRV series
            if s.biometricFamily == "hrv" {
                XCTAssertNotEqual(got ?? -1, 88, "\(s.rawValue) must never read Apple SDNN")
            }
        }

        // SpO₂ mean and nadir stay separate series.
        XCTAssertNotEqual(LBSeries.sleepSpO2Mean.planRow.dailyMetricColumn,
                          LBSeries.sleepSpO2Nadir.planRow.dailyMetricColumn,
                          "mean and nadir must not share a column")
        XCTAssertNil(LBSeries.sleepSpO2Nadir.planRow.dailyMetricColumn)
        XCTAssertEqual(LBSeries.wakingSteps.context, LBSeries.wakingActiveMin.context,
                       "steps and active minutes share the waking_load context by design; their identity "
                       + "comes from the series key, which must differ")
        XCTAssertNotEqual(LBSeries.wakingSteps.rawValue, LBSeries.wakingActiveMin.rawValue)
        XCTAssertNotEqual(LBSeries.wakingSteps.rawValue, LBSeries.wakingActiveMin.rawValue)

        // Same tape, two series: no shared state.
        let obs = stableTape(.sleepRHR, nights: 80, seed: 808)
        let a = eval(obs, .sleepRHR, asOf: iso(T))
        let b = eval(obs, .sleepHRVLn, asOf: iso(T))
        emit(["test": "H_state", "series": "sleep_rhr_vs_hrv",
              "rhrCenter": String(format: "%.2f", a.copyLong?.center ?? .nan),
              "hrvCenter": String(format: "%.2f", b.copyLong?.center ?? .nan)])
        XCTAssertNotEqual(a.copyLong?.center ?? 0, b.copyLong?.center ?? 0, accuracy: 0.001,
                          "two series do not share a centre")
    }

    func metric(_ day: String, rhr: Int? = nil, hrv: Double? = nil, resp: Double? = nil,
                steps: Int? = nil, spo2: Double? = nil, temp: Double? = nil, sdnn: Double? = nil)
        -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil,
                    strain: nil, exerciseCount: nil, spo2Pct: spo2, skinTempDevC: nil,
                    respRateBpm: resp, steps: steps, activeKcalEst: nil, avgSdnn: sdnn,
                    skinTempC: temp)
    }
}

extension FRWhoopCoreBaselineAuditTests {

    // MARK: - Calibration: 1,000 seeded stable traces per series

    /// Synthetic stable-stretch false-positive calibration, per series and per copy (plan §1.7/§1.1).
    /// Not real WHOOP data: the real-data row stays NOT RUN.
    func test_calibration_stableFPRPerSeries1000Traces() {
        let traces = 1_000
        for c in allCfg {
            let s = c.series
            var scoredDays = 0, stableDays = 0, offLong = 0, offWeek = 0, twoOfThree = 0
            var kSum = 0.0, kMin = Double.infinity, kMax = 0.0, kSamples = 0
            var zExtreme = 0.0
            for i in 0..<traces {
                // three noise levels: quiet, floor-scale, and 1.5x floor (333 traces each)
                let amp = [c.lowNoise, c.noise, c.noise * 1.5][i % 3]
                let obs = tape(s, end: T, nights: 70, noiseAmp: amp, seed: UInt64(1_000 + i))
                let days = Array((T - 5)...T)
                let evs = walk(obs, s, days: days)
                for ev in evs {
                    scoredDays += 1
                    let stable = ev.establishedLong && !ev.stale && ev.pChange < 0.90
                        && ev.trial.phase == .none && ev.usualTrustPctLong >= 35
                    guard stable else { continue }
                    stableDays += 1
                    let k = ev.kBandUsed
                    kSum += k; kMin = min(kMin, k); kMax = max(kMax, k); kSamples += 1
                    if abs(ev.zLong ?? 0) >= k { offLong += 1 }
                    if abs(ev.z7 ?? 0) >= k { offWeek += 1 }
                    if ev.twoOfThree { twoOfThree += 1 }
                    zExtreme = max(zExtreme, abs(ev.zLong ?? 0))
                }
            }
            emit(["test": "CAL_stableFPR", "series": s.rawValue, "traces": "\(traces)",
                  "scoredDays": "\(scoredDays)", "stableDays": "\(stableDays)",
                  "offLonger": "\(offLong)", "offThisWeek": "\(offWeek)",
                  "twoOfThree": "\(twoOfThree)",
                  "fprLonger": String(format: "%.4f", stableDays == 0 ? 0 : Double(offLong) / Double(stableDays)),
                  "fprThisWeek": String(format: "%.4f", stableDays == 0 ? 0 : Double(offWeek) / Double(stableDays)),
                  "kUsedMean": String(format: "%.3f", kSamples == 0 ? 0 : kSum / Double(kSamples)),
                  "kUsedMin": String(format: "%.3f", kSamples == 0 ? 0 : kMin),
                  "kUsedMax": String(format: "%.3f", kSamples == 0 ? 0 : kMax),
                  "kTable": String(format: "%.2f", kOf(s)),
                  "maxAbsZ": String(format: "%.2f", zExtreme)])
            XCTAssertEqual(stableDays, scoredDays,
                           "\(s.rawValue): a stationary stable tape must be judgeable every day")
            XCTAssertLessThanOrEqual(Double(offLong) / Double(max(stableDays, 1)), 0.06,
                                     "\(s.rawValue): synthetic stable FPR vs the longer path stays low "
                                     + "(k = \(kOf(s)) table)")
        }
    }

    // MARK: - Calibration: detection delay and recovery lag

    func test_calibration_shiftDetectionDelayPerSeries() {
        let traces = 60
        for c in allCfg {
            let s = c.series
            let sign = worseIsUp(s) ? 1.0 : -1.0
            for frac in [0.5, 1.0, 1.5] {
                let size = (sign > 0 ? c.up : c.down) * frac
                var delays: [Int] = []
                var detected = 0
                for i in 0..<traces {
                    var obs = tape(s, end: T, nights: 70, noiseAmp: c.noise, seed: UInt64(2_000 + i))
                    obs = obs.map { o in
                        guard let e = LongitudinalBaseline.isoEpochDay(o.day), e > T - 5 else { return o }
                        return ok(o.day, c.base + sign * size, coverage: c.coverage)
                    }
                    let days = Array((T - 9)...T)
                    let evs = walk(obs, s, days: days)
                    let onset = evs.firstIndex { $0.asOf == iso(T - 4) } ?? 0
                    if let hit = evs.firstIndex(where: { abs($0.zLong ?? 0) >= $0.kBandUsed }) {
                        detected += 1
                        delays.append(max(0, hit - onset))
                    }
                }
                emit(["test": "CAL_detection", "series": s.rawValue, "frac": String(format: "%.1f", frac),
                      "shiftNative": String(format: "%.2f", size), "traces": "\(traces)",
                      "detected": "\(detected)",
                      "detectRate": String(format: "%.3f", Double(detected) / Double(traces)),
                      "medianDelayDays": "\(delays.isEmpty ? -1 : delays.sorted()[delays.count / 2])"])
            }
        }
    }

    func test_calibration_recoveryLagPerSeries() {
        let traces = 40
        for c in allCfg {
            let s = c.series
            let sign = worseIsUp(s) ? 1.0 : -1.0
            let size = (sign > 0 ? c.up : c.down) * 1.2
            var lags: [Int] = []
            var falseOff: [Int] = []
            for i in 0..<traces {
                var obs = tape(s, end: T, nights: 70, noiseAmp: c.noise, seed: UInt64(3_000 + i))
                obs = obs.map { o in
                    guard let e = LongitudinalBaseline.isoEpochDay(o.day) else { return o }
                    if e >= T - 14, e <= T - 12 { return ok(o.day, c.base + sign * size, coverage: c.coverage) }
                    if e > T - 12 { return ok(o.day, c.base, coverage: c.coverage) }
                    return o
                }
                let days = Array((T - 14)...T)
                let evs = walk(obs, s, days: days)
                let off = evs.filter { abs($0.zLong ?? 0) >= $0.kBandUsed }
                falseOff.append(off.count)
                if let last = off.last, let e = LongitudinalBaseline.isoEpochDay(last.asOf) {
                    lags.append(T - e)
                } else {
                    lags.append(0)
                }
            }
            emit(["test": "CAL_recovery", "series": s.rawValue,
                  "traces": "\(traces)",
                  "medianFalseOffDays": "\(falseOff.sorted()[falseOff.count / 2])",
                  "maxFalseOffDays": "\(falseOff.max() ?? 0)",
                  "medianRecoveryLag": "\(lags.sorted()[lags.count / 2])",
                  "p90RecoveryLag": "\(lags.sorted()[min(lags.count - 1, Int(Double(lags.count) * 0.9))])"])
        }
    }

    // MARK: - Production data path (source-level: the app target is not importable)

    func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }
    func src(_ rel: String) -> String {
        (try? String(contentsOf: repoRoot().appendingPathComponent(rel), encoding: .utf8)) ?? ""
    }

    /// The Baseline tab must score the repository's own nights.
    func test_wiring_baselineTabScoresRepositoryDaysNotADemoTape() {
        let store = src("Strand/Data/BaselineStore.swift")
        XCTAssertFalse(store.isEmpty, "BaselineStore readable")
        let usesDemo = store.contains("return Self.demoTape()") && store.contains("_ = repoDays")
        emit(["test": "WIRING_displayDays", "series": "all",
              "usesDemoTape": "\(usesDemo)"])
        XCTAssertFalse(usesDemo,
                       "the Baseline tab must score Repository.days; today displayDays() discards them "
                       + "and returns demoTape(), so production validation is BLOCKED")
    }

    /// Unwired series must not be invented from another biometric's column.
    func test_wiring_unwiredSeriesAreNeverSynthesizedFromOtherBiometrics() {
        let store = src("Strand/Data/BaselineStore.swift")
        let synth = store.contains("synthesizedNative(from day: DailyMetric, series: LBSeries)")
        let unwired = LBSeries.allCases.filter { !$0.hasDailyMetricColumn }.map(\.rawValue)
        emit(["test": "WIRING_synthesis", "series": "all",
              "synthesizedNative": "\(synth)", "unwiredCount": "\(unwired.count)",
              "unwired": unwired.joined(separator: ",")])
        XCTAssertEqual(unwired.count, 11, "11 of 17 series have no real daily column")
        XCTAssertFalse(synth,
                       "9 unwired series are currently synthesized from restingHr / avgHrv / spo2Pct "
                       + "(BaselineStore.synthesizedNative), which is a cross-biometric fallback")
    }

    /// Every series must be able to receive a real value before it can be trusted.
    func test_wiring_everySeriesHasItsOwnSourceColumn() {
        let missing = LBSeries.allCases.filter { $0.planRow.dailyMetricColumn == nil }.map(\.rawValue)
        emit(["test": "WIRING_columns", "series": "all",
              "withColumn": "\(17 - missing.count)", "withoutColumn": "\(missing.count)",
              "missing": missing.joined(separator: ",")])
        XCTAssertTrue(missing.isEmpty,
                      "17/17 series need a source column; \(missing.count) have none: "
                      + missing.joined(separator: ", "))
    }
}

extension FRWhoopCoreBaselineAuditTests {

    /// Plan §1.2/§1.3 define long and week membership as "quality-OK days". The engine additionally drops
    /// nights whose day log is confounded (`nightIsClean`). This test measures that divergence and the
    /// day-log acute flag on the scored day.
    func test_scenarioG_dayLogConfoundsChangeMembershipAndTrust() {
        let s: LBSeries = .sleepRHR
        let clean = stableTape(s, nights: 80, seed: 909)
        let illDays = [T - 6, T - 5, T - 4, T - 3, T - 30, T - 29, T - 28, T - 27]
        var logs: [String: LBDayLog] = [:]
        for e in illDays { logs[iso(e)] = LBDayLog(feltIll: true) }
        let request = LBTrialRequest(dayLogsByDay: logs)
        let evClean = eval(clean, s, asOf: iso(T))
        let evIll = eval(clean, s, asOf: iso(T), trial: request)
        emit(["test": "G_daylog", "series": s.rawValue,
              "n7_clean": "\(evClean.n7)", "n7_ill": "\(evIll.n7)",
              "nLong_clean": "\(evClean.nLong)", "nLong_ill": "\(evIll.nLong)",
              "show7_clean": "\(evClean.show7)", "show7_ill": "\(evIll.show7)",
              "trust7_clean": "\(evClean.usualTrustPct7)", "trust7_ill": "\(evIll.usualTrustPct7)",
              "today_ill": "\(evIll.todayNative.map { String(format: "%.2f", $0) } ?? "nil")"])
        XCTAssertLessThan(evIll.n7, evClean.n7,
                          "a confounded night is dropped from the week window (documented divergence)")
        XCTAssertLessThan(evIll.nLong, evClean.nLong, "and from the longer window")
    }
}
