import XCTest
@testable import StrandAnalytics
import WhoopStore

/// FRWHOOP longitudinal-baseline gauntlet.
///
/// Requirements source: Packages/StrandAnalytics/Baseline/FRWHOOP_BASELINE_REVIEW_CHANGES.md
/// (eight review items, equal weight; the acceptance pack is at the end of that file).
///
/// Every test names the review item it measures. Tests whose assertions encode a *required* proof
/// fail when the requirement is not met, so this file is a gap detector, not a regression suite.
/// No production code is changed by this file. Fixtures are deterministic (no RNG, no wall clock,
/// no real WHOOP data).
///
/// HOW TO RUN
///   cd Packages/StrandAnalytics && swift test --filter FRWhoopBaselineGauntletTests
///
/// EXPECTED RED ROWS (gap detectors, documented in FRWHOOP_BASELINE_AUDIT_REPORT.md). These fail on
/// the current tree on purpose; they turn green only when the named gap is fixed:
///   test_gauntlet_item1_printedTableCarriesPerSeriesRates        - no per-series rate is printed
///   test_gauntlet_item1_stableDayCountCoversTheWholeStableStretch - the counter only scans 8 nights
///   test_gauntlet_item1_stableGatePChangeIsNotVacuous             - the p_change gate is always 0
///   test_gauntlet_item3_slowShiftThreeWeeksIsNotStuckOff          - a 21-day shift is still OFF
///   test_gauntlet_item4_cardShowsTrustAndHowOffWithoutLegacyConfidence - longer box HOW OFF is nil
///   test_gauntlet_item5_provenanceBreakAfterStartIsNotScoredAsChange   - app never feeds provenance
/// Everything else in this file must stay green: those rows are requirement checks that pass today
/// and must not regress.
final class FRWhoopBaselineGauntletTests: XCTestCase {

    // MARK: - Deterministic fixture helpers

    /// Last scored civil day used by most fixtures.
    let tEnd = "2026-06-30"
    var T: Int { LongitudinalBaseline.isoEpochDay(tEnd)! }

    func iso(_ epoch: Int) -> String { LongitudinalBaseline.isoFromEpochDay(epoch) }

    func ok(_ day: String, _ value: Double, coverage: Double? = nil,
            stream: Bool = true) -> LBDailyObservation {
        LBDailyObservation(day: day, value: value, qualityStatus: .ok,
                           qualityReason: nil, coverage: coverage, streamPresent: stream)
    }

    func low(_ day: String, _ value: Double?, reason: LBQualityReason,
             coverage: Double? = nil) -> LBDailyObservation {
        LBDailyObservation(day: day, value: value, qualityStatus: .lowQuality,
                           qualityReason: reason, coverage: coverage, streamPresent: true)
    }

    func missing(_ day: String, reason: LBQualityReason = .deviceOff) -> LBDailyObservation {
        LBDailyObservation(day: day, value: nil, qualityStatus: .missing,
                           qualityReason: reason, coverage: nil, streamPresent: false)
    }

    /// Deterministic alternating jitter: +amp on even offset, -amp on odd. Anticorrelated by design,
    /// so a flat tape keeps MAD ~ amp and lag-1 r1 stays negative (n_eff stays large).
    func altern(_ offset: Int, _ amp: Double) -> Double { offset % 2 == 0 ? amp : -amp }

    /// Tape that ends at `end`, `nights` nights long, oldest..newest, offset 0 = `end`.
    /// `v(offset)` returns the native value for that night.
    func history(end: Int, nights: Int, _ v: (Int) -> Double) -> [LBDailyObservation] {
        (0..<nights).map { i in
            let offset = i
            return ok(iso(end - offset), v(offset))
        }
    }

    /// Flat tape: `base` plus deterministic jitter.
    func flatTape(end: Int, nights: Int, base: Double, amp: Double = 0,
                  coverage: Double? = nil) -> [LBDailyObservation] {
        history(end: end, nights: nights) { off in base + altern(off, amp) }
            .map { ok($0.day, $0.value ?? base, coverage: coverage) }
    }

    /// Replace the value on specific epochs (keeps quality ok).
    func withValues(_ obs: [LBDailyObservation], _ overrides: [Int: Double]) -> [LBDailyObservation] {
        obs.map { o in
            guard let e = LongitudinalBaseline.isoEpochDay(o.day), let v = overrides[e] else { return o }
            return ok(o.day, v, coverage: o.coverage)
        }
    }

    func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        if s.isEmpty { return .nan }
        if s.count % 2 == 1 { return s[s.count / 2] }
        return (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    func longWindowValues(_ obs: [LBDailyObservation], series: LBSeries, end: Int) -> [Double] {
        let byDay = Dictionary(uniqueKeysWithValues: obs.map { ($0.day, $0) })
        var out: [Double] = []
        for e in (end - 60)...(end - 8) {
            if let o = byDay[iso(e)], o.qualityStatus == .ok, let v = o.value { out.append(v) }
        }
        return out
    }

    func eval(_ obs: [LBDailyObservation], _ series: LBSeries, asOf: String, replay: Bool = true,
              trial: LBTrialRequest = .none) -> LBEvaluation {
        LongitudinalBaseline.evaluate(asOf: asOf, series: series, observations: obs,
                                      replay: replay, trial: trial)
    }

    func startEvent(id: String = "trial-1", day: String, onset: Int? = 7,
                    primaries: [LBSeries] = [], stop: Bool = false,
                    patientSaysClear: Bool = false, lastDose: String? = nil,
                    stopDay: String? = nil, notes: String? = nil,
                    washout: Int? = 7) -> [LBTreatmentEvent] {
        var events = [LBTreatmentEvent(trialId: id, type: .start, civilDay: day,
                                       clockTime: "08:00", displayName: "Drug X",
                                       kind: .medication, doseText: "10 mg",
                                       enteredBy: .patient, notes: notes,
                                       onsetDays: onset, washoutDays: washout,
                                       primarySeries: primaries)]
        if stop {
            events.append(LBTreatmentEvent(trialId: id, type: .stop, civilDay: stopDay ?? iso(T),
                                           clockTime: "20:00", displayName: "Drug X",
                                           kind: .medication, enteredBy: .patient,
                                           stopReason: .completed, washoutDays: washout,
                                           lastDoseDay: lastDose,
                                           patientSaysClear: patientSaysClear))
        }
        return events
    }

    // MARK: - Item 1: stable-stretch false-positive calibration

    /// Item 1 proof rows: `stable_rhr_60`, `stable_hrv`, `stable_resp`, `stable steps`.
    /// Required: one row per series, never one pooled number; the real-WHOOP row stays "not run yet".
    func test_gauntlet_item1_stableFPRTableHasOneRowPerSeriesAndRealRowNotRun() {
        let tapes: [(series: LBSeries, observations: [LBDailyObservation], asOf: String)] = [
            (.sleepRHR, flatTape(end: T, nights: 120, base: 60, amp: 0.4), iso(T)),
            (.sleepHRVLn, flatTape(end: T, nights: 120, base: 65, amp: 1.5), iso(T)),
            (.sleepResp, flatTape(end: T, nights: 120, base: 15, amp: 0.15), iso(T)),
            (.wakingSteps, flatTape(end: T, nights: 120, base: 8_000, amp: 250), iso(T)),
        ]
        let rows = LongitudinalBaseline.stableFalsePositiveTable(tapes: tapes)
        print("ITEM1 FPR TABLE\n" + LongitudinalBaseline.printStableFPRTable(rows))
        XCTAssertEqual(rows.count, 4, "item 1: one FPR row per series, never one pooled number")
        for r in rows {
            XCTAssertFalse(r.realWhoopRun, "item 1: the real-WHOOP row must stay explicitly not run")
            XCTAssertGreaterThan(r.nStableDays, 0,
                                 "\(r.series.rawValue): no stable day counted, so no FPR exists")
        }
        XCTAssertTrue(LongitudinalBaseline.printStableFPRTable(rows).contains("not run yet"),
                      "item 1: 'real WHOOP 5.0 - not run yet' is required honesty")
    }

    /// Item 1 protocol: the counter runs over the stable stretch of the tape. A 150-night flat tape is
    /// stable from establishment onward, so the denominator must cover it, not the last few nights.
    func test_gauntlet_item1_stableDayCountCoversTheWholeStableStretch() {
        let obs = flatTape(end: T, nights: 150, base: 60, amp: 0.4)
        let rows = LongitudinalBaseline.stableFalsePositiveTable(
            tapes: [(series: .sleepRHR, observations: obs, asOf: iso(T))])
        let row = rows[0]
        print("ITEM1 stable days counted=\(row.nStableDays) over a 150-night stable tape")
        XCTAssertGreaterThanOrEqual(
            row.nStableDays, 100,
            "item 1: FPR must be counted per series over the stable stretch (150 stable nights here). "
            + "A count of \(row.nStableDays) cannot calibrate k.")
    }

    /// Item 1 acceptance pack: "Per-series rates printed".
    func test_gauntlet_item1_printedTableCarriesPerSeriesRates() {
        let obs = flatTape(end: T, nights: 120, base: 60, amp: 0.4)
        let rows = LongitudinalBaseline.stableFalsePositiveTable(
            tapes: [(series: .sleepRHR, observations: obs, asOf: iso(T))])
        let printed = LongitudinalBaseline.printStableFPRTable(rows)
        XCTAssertGreaterThanOrEqual(rows[0].rateLonger, 0)
        XCTAssertTrue(printed.contains("%"),
                      "item 1 acceptance: per-series rates printed, not only counts:\n\(printed)")
    }

    /// Item 1 stable filter: "p_change below threshold". On the harness path each stable day is
    /// re-scored with `replay: false`, so CUSUM starts at 0 and p_change is always 0: the criterion
    /// cannot reject a shifting tape. The online walk of the same tape must agree.
    func test_gauntlet_item1_stableGatePChangeIsNotVacuous() {
        // 60 flat nights, a 12-night fever plateau (T-41...T-30), then 20 flat nights.
        var obs = flatTape(end: T, nights: 140, base: 60, amp: 0.4)
        var plate: [Int: Double] = [:]
        for e in (T - 41)...(T - 30) { plate[e] = 72 }
        obs = withValues(obs, plate)

        let online = eval(obs, .sleepRHR, asOf: iso(T), replay: true)
        let isolated = eval(obs, .sleepRHR, asOf: iso(T), replay: false)
        print("ITEM1 p_change online=\(online.pChange) isolated=\(isolated.pChange) "
              + "S_online=\(online.cusumS) S_isolated=\(isolated.cusumS)")
        XCTAssertGreaterThan(online.pChange, 0.0,
                             "fixture sanity: a walked tape keeps CUSUM mass on the scored day")
        XCTAssertEqual(
            isolated.pChange, online.pChange, accuracy: 1e-9,
            "item 1: stable-day classification must use online state. With replay:false the "
            + "p_change < p_thr criterion is always true (p_change=\(isolated.pChange)), so a "
            + "shifting tape is counted as a stable false positive.")
    }

    // MARK: - Item 2: per-biometric parameters, gates, transforms

    /// Item 2: the v1 starting table in FRWHOOP_BASELINE_REVIEW_CHANGES.md, per series.
    func test_gauntlet_item2_paramsTableMatchesTheReviewStartingTable() {
        let p = LongitudinalBaseline.params
        XCTAssertEqual(p(.sleepRHR).kBand, 2.0); XCTAssertEqual(p(.sleepRHR).span7, 7)
        XCTAssertEqual(p(.sleepRHR).nLongEstablished, 14); XCTAssertEqual(p(.sleepRHR).floor, 2)
        XCTAssertEqual(p(.sleepRHR).worse, .higher)
        XCTAssertEqual(p(.awakeRestHR).kBand, 2.0); XCTAssertEqual(p(.awakeRestHR).floor, 3)
        XCTAssertEqual(p(.awakeActiveHR).kBand, 2.2); XCTAssertEqual(p(.awakeActiveHR).floor, 4)
        XCTAssertEqual(p(.continuousHR).kBand, 2.2); XCTAssertEqual(p(.continuousHR).floor, 5)
        XCTAssertEqual(p(.sleepHRVLn).kBand, 2.6); XCTAssertEqual(p(.sleepHRVLn).span7, 10)
        XCTAssertEqual(p(.sleepHRVLn).floor, 0.08); XCTAssertEqual(p(.sleepHRVLn).worse, .lower)
        XCTAssertEqual(p(.sleepHRVLn).alpha, 2.0 / 11.0, accuracy: 1e-12)
        XCTAssertEqual(p(.sleepResp).kBand, 1.6); XCTAssertEqual(p(.sleepResp).floor, 0.5)
        XCTAssertEqual(p(.sleepTemp).worse, .either)
        XCTAssertEqual(p(.sleepSpO2Mean).kBand, 1.5)
        XCTAssertEqual(p(.sleepSpO2Nadir).kBand, 1.7)
        XCTAssertEqual(p(.wakingSteps).kBand, 2.4); XCTAssertEqual(p(.wakingSteps).nLongEstablished, 21)
        XCTAssertEqual(p(.wakingSteps).floor, 500)
        XCTAssertEqual(p(.wakingActiveMin).nLongEstablished, 21)
        XCTAssertEqual(p(.sleepHRVLn).kBand, p(.sleepHRVLn).kBand)
        XCTAssertNotEqual(p(.sleepRHR).kBand, p(.sleepHRVLn).kBand)
        XCTAssertGreaterThan(p(.sleepHRVLn).span7, p(.sleepRHR).span7)
        XCTAssertEqual(LongitudinalBaseline.seriesSpec(.sleepRHR).floor, 2)
        XCTAssertEqual(LongitudinalBaseline.seriesSpec(.sleepHRVLn).floor, 0.08)
    }

    /// Item 2 proof: "Same +-2% native wiggle: respiratory rate IN RANGE, HRV not auto-OFF from RHR's k".
    /// A ~+6% respiratory excursion sits inside resp's own k (1.6) and outside RHR's k (2.0).
    func test_gauntlet_item2_respExcursionIsJudgedWithRespsOwnK() {
        var obs = flatTape(end: T, nights: 90, base: 15.0, amp: 0.05)
        obs = withValues(obs, [T: 15.9])
        let ev = eval(obs, .sleepResp, asOf: iso(T))
        let z = ev.zLong ?? 0
        print("ITEM2 resp z_long=\(z) k_resp=\(LongitudinalBaseline.params(for: .sleepResp).kBand) "
              + "k_rhr=\(LongitudinalBaseline.params(for: .sleepRHR).kBand)")
        XCTAssertGreaterThan(z, 1.6, "fixture sanity: excursion is past resp's own k")
        XCTAssertLessThan(z, 2.0, "fixture sanity: excursion is inside RHR's k")
        XCTAssertTrue(LongitudinalBaseline.isOffUsual(z: z, k: LongitudinalBaseline.params(for: .sleepResp).kBand),
                      "item 2: respiration is judged with its own row (k=1.6)")
        XCTAssertFalse(LongitudinalBaseline.isOffUsual(z: z, k: LongitudinalBaseline.params(for: .sleepRHR).kBand),
                       "item 2: RHR's k was not copied onto respiration")
    }

    /// Item 2 proof: HRV is allowed to move more (native drop of ~17%) before OFF, because its row
    /// carries k=2.6 in ln space; RHR's k=2.0 would have called it OFF.
    func test_gauntlet_item2_hrvDropIsNotForcedThroughRHRsK() {
        var obs = flatTape(end: T, nights: 90, base: 65.0, amp: 0.05)
        obs = withValues(obs, [T: 54.0])
        let ev = eval(obs, .sleepHRVLn, asOf: iso(T))
        let z = ev.zLong ?? 0
        print("ITEM2 hrv z_long=\(z) k_hrv=2.6 k_rhr=2.0")
        XCTAssertLessThan(z, -2.0, "fixture sanity: drop is past RHR's k")
        XCTAssertGreaterThan(z, -2.6, "fixture sanity: drop is inside HRV's own k")
        XCTAssertFalse(LongitudinalBaseline.isOffUsual(z: z, k: LongitudinalBaseline.params(for: .sleepHRVLn).kBand),
                       "item 2: HRV is judged in ln space with its own k")
        XCTAssertTrue(LongitudinalBaseline.isOffUsual(z: z, k: LongitudinalBaseline.params(for: .sleepRHR).kBand),
                      "item 2: HRV must not be forced through RHR's k")
    }

    /// Item 2: "Nights to establish" differ per series and are actually used.
    func test_gauntlet_item2_establishCountDiffersBySeriesAndIsUsed() {
        // 25 nights present means 17 nights inside the 53-night long window (offsets 8...24),
        // which is at or above 14 for rest series and below 21 for the activity-mix series.
        let rhr = flatTape(end: T, nights: 25, base: 60, amp: 0.4)
        let steps = flatTape(end: T, nights: 25, base: 8_000, amp: 120)
        let evR = eval(rhr, .sleepRHR, asOf: iso(T))
        let evS = eval(steps, .wakingSteps, asOf: iso(T))
        print("ITEM2 establish: rhr nLong=\(evR.nLong) est=\(evR.establishedLong) "
              + "steps nLong=\(evS.nLong) est=\(evS.establishedLong)")
        XCTAssertTrue(evR.establishedLong, "item 2: rest series establish at 14 nights")
        XCTAssertFalse(evS.establishedLong, "item 2: steps need 21 nights before a longer usual exists")
    }

    /// Item 2: "span_7 may differ" - HRV's this-week window is 10 nights, RHR's is 7.
    func test_gauntlet_item2_thisWeekWindowFollowsTheSeriesSpan() {
        // 11 nights present: offsets 1...10 fill the window for the widest per-series span.
        let hrv = flatTape(end: T, nights: 11, base: 65, amp: 0.05)
        let rhr = flatTape(end: T, nights: 11, base: 60, amp: 0.4)
        let evH = eval(hrv, .sleepHRVLn, asOf: iso(T))
        let evR = eval(rhr, .sleepRHR, asOf: iso(T))
        print("ITEM2 span: hrv n7=\(evH.n7) rhr n7=\(evR.n7)")
        XCTAssertEqual(evH.n7, 10, "item 2: HRV's this-week usual uses the 10-night span from its row")
        XCTAssertEqual(evR.n7, 7, "item 2: sleep RHR's this-week usual stays at 7 nights")
    }

    // MARK: - Item 3: two-night spike vs multi-week slow shift

    /// Item 3 fixture `spike_rhr_two_nights`: long stretch at 60, then two nights at 72.
    /// Must show: OFF the longer usual, and this week's *training* usual does not become 72.
    func test_gauntlet_item3_spikeTwoNightsIsOffLongerUsualAndDoesNotTrainTheWeekTo72() {
        var obs = flatTape(end: T, nights: 90, base: 60, amp: 0.4)
        obs = withValues(obs, [T - 1: 72, T: 72])
        let ev = eval(obs, .sleepRHR, asOf: iso(T))
        print("ITEM3 spike zLong=\(ev.zLong ?? .nan) z7=\(ev.z7 ?? .nan) "
              + "center7=\(ev.copy7?.center ?? .nan) center7Raw=\(ev.center7Raw ?? .nan) "
              + "twoOfThree=\(ev.twoOfThree) runLength=\(ev.runLength)")
        XCTAssertTrue(LongitudinalBaseline.isOffUsual(z: ev.zLong, k: 2.0),
                      "item 3: two ugly nights are OFF the longer usual")
        XCTAssertLessThan(ev.copy7?.center ?? 99, 63,
                          "item 3: this week's training usual must not become the fever")
        XCTAssertLessThan(ev.center7Raw ?? 99, 66,
                          "item 3: even the raw 7-day center stays near twice-60, it is not 72")
        XCTAssertTrue(ev.twoOfThree, "item 3: two of the last three nights are past k")
    }

    /// Item 3 fixture `slow_shift_rhr_three_weeks`: RHR falls ~0.3 bpm/day for ~21 days.
    /// Must show: not stuck OFF vs the moving expected path, and no false "new disease jump".
    func test_gauntlet_item3_slowShiftThreeWeeksIsNotStuckOff() {
        // 60 nights at 66, then 21 nights falling 0.3/day, today = 60.
        var obs: [LBDailyObservation] = []
        for off in 0..<82 {
            let v: Double
            if off <= 20 { v = 66.0 - 0.3 * Double(20 - off) } else { v = 66.0 }
            obs.append(ok(iso(T - off), v + altern(off, 0.4)))
        }
        let ev = eval(obs, .sleepRHR, asOf: iso(T))
        let flat = median(longWindowValues(obs, series: .sleepRHR, end: T))
        let spread = ev.copyLong?.spread ?? 2.0
        let zFlat = ((ev.todayNative ?? .nan) - flat) / spread
        print("ITEM3 shift slope=\(ev.slopeLong ?? .nan) usable=\(ev.slopeUsable) "
              + "expected=\(ev.expectedLong ?? .nan) flatMedian=\(flat) spread=\(spread) "
              + "zLong=\(ev.zLong ?? .nan) zVsFlat=\(zFlat) pChange=\(ev.pChange) "
              + "regime=\(ev.regimeShift) held=\(ev.copyLong?.held ?? false)")
        XCTAssertLessThan(zFlat, -2.0, "fixture sanity: vs a flat number this patient looks OFF")
        XCTAssertGreaterThan(ev.zLong ?? -99, -2.0,
                             "item 3: a 21-day slow shift must not be stuck OFF vs the expected path "
                             + "(slope=\(ev.slopeLong ?? .nan) usable=\(ev.slopeUsable) "
                             + "expected=\(ev.expectedLong ?? .nan) vs today=\(ev.todayNative ?? .nan))")
        XCTAssertFalse(ev.regimeShift,
                       "item 3: p_change must not read a slow shift as a new disease jump")
        XCTAssertLessThan(ev.pChange, 0.90)
    }

    /// Item 3 control: when the drift spans the long window the detrending machinery is demonstrably
    /// live (slope usable, expected path tracks, CUSUM runs on residuals, no false regime shift).
    func test_gauntlet_item3_slowShiftAcrossTheLongWindowIsNotStuckOff() {
        // 60 nights falling 0.3/day then continuing on to today: the whole long window is a ramp.
        var obs: [LBDailyObservation] = []
        for off in 0..<80 {
            obs.append(ok(iso(T - off), 72.0 - 0.3 * Double(79 - off) + altern(off, 0.4)))
        }
        let ev = eval(obs, .sleepRHR, asOf: iso(T))
        let flat = median(longWindowValues(obs, series: .sleepRHR, end: T))
        print("ITEM3 windowRamp slope=\(ev.slopeLong ?? .nan) usable=\(ev.slopeUsable) "
              + "expected=\(ev.expectedLong ?? .nan) flatMedian=\(flat) zLong=\(ev.zLong ?? .nan) "
              + "pChange=\(ev.pChange) regime=\(ev.regimeShift)")
        XCTAssertTrue(ev.slopeUsable, "item 3: a slope spanning the long window must pass the gate")
        XCTAssertLessThan(ev.slopeLong ?? 0, -0.2, "item 3: Theil-Sen recovers ~ -0.3 bpm/day")
        XCTAssertNotNil(ev.expectedLong, "item 3: store expected_long on the snapshot")
        XCTAssertLessThan(abs(ev.expectedLong ?? 99), 72.0,
                          "item 3: the expected path follows the drift, it is not the flat old level")
        XCTAssertLessThan(ev.pChange, 0.90, "item 3: no false regime shift on a slow drift")
        XCTAssertGreaterThanOrEqual(flat - (ev.expectedLong ?? flat), 0.0,
                                    "sanity: the flat median sits above the detrended path")
    }

    /// Item 3 cap: "do not project a 30-day slope 90 days past the last long night".
    func test_gauntlet_item3_thirtyDayProjectionCap() {
        let freeze = 20_000
        let capped = LongitudinalBaseline.expectedUntreated(
            level0: 60, slopeG0: 0.5, usable: true, asOfEpoch: freeze + 90, freezeEpoch: freeze)
        let inside = LongitudinalBaseline.expectedUntreated(
            level0: 60, slopeG0: 0.5, usable: true, asOfEpoch: freeze + 10, freezeEpoch: freeze)
        print("ITEM3 cap: at +10 = \(inside), at +90 = \(capped)")
        XCTAssertEqual(inside, 65.0, accuracy: 1e-9, "item 3: inside the cap the path is L0 + G0*dt")
        XCTAssertEqual(capped, 75.0, accuracy: 1e-9,
                       "item 3: a 30-day cap = L0 + G0*30; 90 days must not be projected")
        let flatCap = LongitudinalBaseline.expectedUntreated(
            level0: 60, slopeG0: 0.5, usable: false, asOfEpoch: freeze + 90, freezeEpoch: freeze)
        XCTAssertEqual(flatCap, 60.0, accuracy: 1e-9, "item 3/6: unusable slope compares to the level")
    }

    /// Item 3: the live longer copy stops projecting when the last usable long night is older than
    /// the 30-day horizon, and TRUST on that copy drops.
    func test_gauntlet_item3_horizonBeyondLastLongNightDropsTheProjection() {
        // The long window [T-60, T-8] has no usable night in its newest 30 days, but the week is
        // present, so the copy is not stale: the cap, not staleness, must stop the projection.
        var obs: [LBDailyObservation] = []
        for off in 0..<90 where !(31...59).contains(off) {
            obs.append(ok(iso(T - off), 66.0 + altern(off, 0.4)))
        }
        let ev = eval(obs, .sleepRHR, asOf: iso(T))
        print("ITEM3 horizon: slope=\(ev.slopeLong ?? .nan) usable=\(ev.slopeUsable) "
              + "expected=\(ev.expectedLong ?? .nan) stale=\(ev.stale) trustLong=\(ev.usualTrustPctLong)")
        XCTAssertFalse(ev.slopeUsable,
                       "item 3: no slope projection when the newest usable long night is >30 days old")
        XCTAssertEqual(ev.expectedLong ?? .nan, ev.copyLong?.center ?? .nan, accuracy: 1e-9,
                       "item 3: beyond the cap the copy falls back to the flat center")
    }

    /// Item 3: CUSUM runs on residuals vs the path, so a slow drift does not accumulate as a shift.
    func test_gauntlet_item3_cusumRunsOnDetrendedResiduals() {
        var obs: [LBDailyObservation] = []
        for off in 0..<80 {
            obs.append(ok(iso(T - off), 66.0 - 0.25 * Double(79 - off) + altern(off, 0.4)))
        }
        let ev = eval(obs, .sleepRHR, asOf: iso(T))
        let flat = median(longWindowValues(obs, series: .sleepRHR, end: T))
        print("ITEM3 cusum S=\(ev.cusumS) pChange=\(ev.pChange) regime=\(ev.regimeShift) "
              + "today=\(ev.todayNative ?? .nan) flatMedian=\(flat)")
        XCTAssertLessThan(ev.cusumS, 20.0,
                          "item 3: CUSUM on detrended residuals must not build S on a slow drift "
                          + "(S=\(ev.cusumS), p_change=\(ev.pChange))")
        XCTAssertFalse(ev.regimeShift, "item 3: no regime shift on a slow drift")
    }

    // MARK: - Item 4: TRUST vs HOW OFF

    /// Item 4 acceptance: TRUST and HOW OFF must disagree when they should, and HOW OFF must match
    /// the Student-t two-tail of |z| with df = max(n_eff - 1, 3).
    func test_gauntlet_item4_howOffMatchesStudentTTable() {
        let a = LongitudinalBaseline.howUnusualPct(z: 2.0, nEff: 4)!
        let b = LongitudinalBaseline.howUnusualPct(z: 3.0, nEff: 4)!
        let c = LongitudinalBaseline.howUnusualPct(z: 1.0, nEff: 4)!
        let d = LongitudinalBaseline.howUnusualPct(z: 2.0, nEff: 30)!
        let floored = LongitudinalBaseline.howUnusualPct(z: 2.0, nEff: 1)!
        print("ITEM4 howOff: t2/df3=\(a) t3/df3=\(b) t1/df3=\(c) t2/df29=\(d) t2/nEff1=\(floored)")
        XCTAssertEqual(Double(a), 86.07, accuracy: 1.0, "item 4: two-tail t(2, df=3) = 86.07%")
        XCTAssertEqual(Double(b), 94.23, accuracy: 1.0, "item 4: two-tail t(3, df=3) = 94.23%")
        XCTAssertEqual(Double(c), 60.90, accuracy: 1.0, "item 4: two-tail t(1, df=3) = 60.90%")
        XCTAssertEqual(Double(d), 94.51, accuracy: 1.0, "item 4: two-tail t(2, df=29) = 94.51%")
        XCTAssertEqual(floored, a, "item 4: df floor is max(n_eff - 1, 3)")
        XCTAssertNil(LongitudinalBaseline.howUnusualPct(z: nil, nEff: 10),
                     "item 4: no tonight value, no HOW OFF")
    }

    /// Item 4 proof case 1: a full week in band - TRUST high, HOW OFF low.
    func test_gauntlet_item4_fullWeekInBandHasHighTrustAndLowHowOff() {
        let obs = flatTape(end: T, nights: 90, base: 60, amp: 0.4)
        let ev = eval(obs, .sleepRHR, asOf: iso(T))
        print("ITEM4 inBand trust7=\(ev.usualTrustPct7) howOff7=\(ev.howUnusualPct7 ?? -1) "
              + "trustLong=\(ev.usualTrustPctLong) howOffLong=\(ev.howUnusualPctLong ?? -1)")
        XCTAssertGreaterThanOrEqual(ev.usualTrustPct7, 70, "item 4: a full clean week trusts its usual")
        XCTAssertLessThanOrEqual(ev.howUnusualPct7 ?? 100, 25, "item 4: in-band night, low HOW OFF")
        XCTAssertFalse(LongitudinalBaseline.isOffUsual(z: ev.zLong, k: 2.0))
    }

    /// Item 4 proof case 2: a full week at 72 vs a 60 usual - TRUST high, HOW OFF high.
    func test_gauntlet_item4_fullWeekOffHasHighTrustAndHighHowOff() {
        var obs = flatTape(end: T, nights: 90, base: 60, amp: 0.4)
        var over: [Int: Double] = [:]
        for e in (T - 7)...T { over[e] = 72 }
        obs = withValues(obs, over)
        let ev = eval(obs, .sleepRHR, asOf: iso(T))
        print("ITEM4 weekOff trustLong=\(ev.usualTrustPctLong) howOffLong=\(ev.howUnusualPctLong ?? -1) "
              + "zLong=\(ev.zLong ?? .nan) howOff7=\(ev.howUnusualPct7 ?? -1)")
        XCTAssertGreaterThanOrEqual(ev.usualTrustPctLong, 35,
                                    "item 4: a week of data is enough to trust the longer usual")
        XCTAssertGreaterThanOrEqual(ev.howUnusualPctLong ?? 0, 80,
                                    "item 4: a week far off the longer usual is high HOW OFF")
        XCTAssertTrue(LongitudinalBaseline.isOffUsual(z: ev.zLong, k: 2.0))
        XCTAssertNotNil(ev.howUnusualPctLong,
                        "item 4: the engine must expose HOW OFF for the longer box; hiding it is the UI's job")
    }

    /// Item 4 proof case 3: three nights at 72 vs usual 60 - TRUST low, HOW OFF never a confident OFF.
    func test_gauntlet_item4_threeNightsHasLowTrust() {
        var obs = flatTape(end: T, nights: 60, base: 60, amp: 0.4)
        var over: [Int: Double] = [:]
        for e in (T - 2)...T { over[e] = 72 }
        obs = withValues(obs, over)
        let ev = eval(obs, .sleepRHR, asOf: iso(T))
        print("ITEM4 threeNights trust7=\(ev.usualTrustPct7) show7=\(ev.show7) n7=\(ev.n7) "
              + "howOff7=\(ev.howUnusualPct7 ?? -1) zLong=\(ev.zLong ?? .nan)")
        XCTAssertLessThan(ev.usualTrustPct7, 35,
                          "item 4: three nights cannot trust a usual enough to call a red OFF "
                          + "(trust=\(ev.usualTrustPct7))")
        XCTAssertNotNil(ev.howUnusualPct7,
                        "item 4: the engine still computes HOW OFF; the card must hide it below 35")
        let store = appSource("Strand/Data/BaselineStore.swift") ?? ""
        XCTAssertTrue(store.contains("shortHowOff"),
                      "item 4: the display layer owns the 35% hide rule for HOW OFF")
        XCTAssertTrue(store.contains("trustHideThreshold"))
    }

    /// Item 4 proof case 4: HRV TRUST < RHR TRUST on the same calendar coverage (n_eff and k differ).
    func test_gauntlet_item4_hrvTrustIsLowerThanRhrTrustOnTheSameCoverage() {
        // Same 18 nights present for both series. HRV carries a serially correlated wobble, RHR an
        // alternating one, so n_eff differs the way the review says it does.
        var hrv: [LBDailyObservation] = []
        var rhr: [LBDailyObservation] = []
        for off in 0..<18 {
            let block = (off / 6) % 2 == 0 ? 0.15 : -0.15
            hrv.append(ok(iso(T - off), 65.0 + block))
            rhr.append(ok(iso(T - off), 60.0 + altern(off, 0.4)))
        }
        let evH = eval(hrv, .sleepHRVLn, asOf: iso(T))
        let evR = eval(rhr, .sleepRHR, asOf: iso(T))
        print("ITEM4 hrvTrust=\(evH.usualTrustPctLong) (nEff=\(evH.nEffLong)) "
              + "rhrTrust=\(evR.usualTrustPctLong) (nEff=\(evR.nEffLong))")
        XCTAssertEqual(evH.nLong, evR.nLong, "same calendar coverage for both series")
        XCTAssertLessThan(evH.usualTrustPctLong, evR.usualTrustPctLong,
                          "item 4: HRV TRUST < RHR TRUST on the same calendar coverage")
    }

    /// Item 4: TRUST must move for the reasons the formula names - tonight quality, staleness,
    /// a failed freeze (x0.4), and a patient-entered confounder (x0.5).
    func test_gauntlet_item4_trustMovesForTonightQualityStalenessFreezeAndConfounder() {
        func trust(_ tonight: LBQualityStatus?, age: Int?, freeze: Double, confound: Bool) -> Int {
            LongitudinalBaseline.usualTrustPct(LBTrustInputs(
                nOk: 40, nWindow: 53, nLowQuality: 0, nEff: 40, nEstablish: 14, ageLastOk: age,
                staleDays: 14, slopeUsable: true, freezeOk: freeze, confoundToday: confound,
                tonightStatus: tonight))
        }
        let okTrust = trust(.ok, age: 0, freeze: 1.0, confound: false)
        let lowTrust = trust(.lowQuality, age: 0, freeze: 1.0, confound: false)
        let missingTrust = trust(.missing, age: 0, freeze: 1.0, confound: false)
        let staleTrust = trust(.ok, age: 20, freeze: 1.0, confound: false)
        let freezeFail = trust(.ok, age: 0, freeze: 0.4, confound: false)
        let chipped = trust(.ok, age: 0, freeze: 1.0, confound: true)
        print("ITEM4 trust moves: ok=\(okTrust) lowQ=\(lowTrust) missing=\(missingTrust) "
              + "stale=\(staleTrust) freezeFail=\(freezeFail) chipped=\(chipped)")
        XCTAssertGreaterThan(okTrust, lowTrust, "item 4: a low-quality tonight lowers TRUST")
        XCTAssertGreaterThan(lowTrust, missingTrust, "item 4: a missing tonight lowers TRUST more")
        XCTAssertEqual(staleTrust, 0, "item 4: freshness decays to 0 at the stale horizon")
        XCTAssertEqual(Double(freezeFail), Double(okTrust) * 0.4, accuracy: 1.0,
                       "item 4: a failed freeze multiplies TRUST by 0.4")
        XCTAssertEqual(Double(chipped), Double(okTrust) * 0.5, accuracy: 1.0,
                       "item 4: a chipped day halves TRUST")

        // And the same two effects must be reachable through evaluate(), not only the formula.
        var obs = flatTape(end: T, nights: 90, base: 60, amp: 0.4)
        obs = withValues(obs, [T: 66])
        let events = startEvent(day: iso(T - 30), primaries: [.sleepRHR])
        let clean = eval(obs, .sleepRHR, asOf: iso(T),
                         trial: LBTrialRequest(events: events, provenanceNow: LBProvenance()))
        let chippedEv = eval(obs, .sleepRHR, asOf: iso(T),
                             trial: LBTrialRequest(events: events, provenanceNow: LBProvenance(),
                                                   confoundersByDay: [iso(T): [.dietChange]]))
        print("ITEM4 evaluate confounder: clean=\(clean.usualTrustPctLong) "
              + "chipped=\(chippedEv.usualTrustPctLong)")
        XCTAssertEqual(Double(chippedEv.usualTrustPctLong), Double(clean.usualTrustPctLong) * 0.5,
                       accuracy: 1.0,
                       "item 4: a patient-entered chip on the scored day must halve TRUST in evaluate")
    }

    // MARK: - Item 5: a freeze is not proof the drug caused the change

    func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // StrandAnalyticsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // StrandAnalytics
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repo root
    }

    func appSource(_ relative: String) -> String? {
        try? String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    /// Item 5: the confounder list must include diet change and a concomitant medication, and the
    /// non-causal sentence must exist and be rendered in the app.
    func test_gauntlet_item5_confounderListAndNonCausalSentence() {
        let required: Set<LBConfounder> = [.illness, .hospitalization, .travel, .sleepDisruption,
                                           .exerciseChange, .dietChange, .concomitantMed]
        XCTAssertTrue(required.isSubset(of: Set(LBConfounder.allCases)),
                      "item 5: chips must include diet change and concomitant medication")
        let sentence = "This is the difference from what this series was doing before the start, "
            + "including any slow trend. Sleep, activity, illness, diet, another medication, or the "
            + "disease itself can move the same number. It is not proof the treatment caused the change."
        XCTAssertEqual(LongitudinalBaseline.reviewDisclaimer, sentence,
                       "item 5: the exact non-causal sentence is required copy")
        let view = appSource("Strand/Screens/BaselineMonitorView.swift") ?? ""
        XCTAssertTrue(view.contains("disclaimer"),
                      "item 5: the trial block must render the non-causal sentence")
        XCTAssertTrue(LongitudinalBaseline.reviewDisclaimer
            .contains("not proof the treatment caused the change"))
    }

    /// Item 5 fixture `confounded_start`: a chip on the scored day makes the primary contrast
    /// ineligible, keeps the day visible, and blocks the summary.
    func test_gauntlet_item5_chippedDayIsIneligibleButStillVisible() {
        var obs = flatTape(end: T, nights: 130, base: 60, amp: 0.4)
        obs = withValues(obs, [T: 70])
        let events = startEvent(day: iso(T - 40), primaries: [.sleepRHR])
        let confounders: [String: [LBConfounder]] = [iso(T): [.dietChange]]
        let clean = eval(obs, .sleepRHR, asOf: iso(T),
                         trial: LBTrialRequest(events: events, provenanceNow: LBProvenance()))
        let chipped = eval(obs, .sleepRHR, asOf: iso(T),
                           trial: LBTrialRequest(events: events, provenanceNow: LBProvenance(),
                                                 confoundersByDay: confounders))
        print("ITEM5 chip: cleanEligible=\(clean.trial.primaryContrastEligible) "
              + "chippedEligible=\(chipped.trial.primaryContrastEligible) "
              + "chips=\(chipped.trial.confoundersToday) summary=\(String(describing: chipped.trial.summarySentence))")
        XCTAssertTrue(clean.trial.primaryContrastEligible, "fixture sanity: clean day is eligible")
        XCTAssertFalse(chipped.trial.primaryContrastEligible,
                       "item 5: a chipped day is not eligible for the primary contrast")
        XCTAssertFalse(chipped.trial.judgingResponse, "item 5: a chipped day cannot write the summary")
        XCTAssertEqual(chipped.trial.confoundersToday, [.dietChange], "item 5: the chip stays visible")
        XCTAssertNotNil(chipped.todayNative, "item 5: a chipped night stays on the graph, not hidden")
        XCTAssertFalse(LongitudinalBaseline.shadowPoints(from: chipped).isEmpty,
                       "item 5: a chipped night is still plotted (grey), not dropped")
    }

    /// Item 5 fixture `provenance_break_after_start`: a device/math change after t0 is not scored as
    /// a change since start.
    ///
    /// The freeze is a persisted bundle (as the app stores it), so the check is: evaluate with the
    /// provenance the freeze was built under, then evaluate the same freeze under a new firmware.
    func test_gauntlet_item5_provenanceBreakAfterStartIsNotScoredAsChange() {
        var obs = flatTape(end: T, nights: 130, base: 60, amp: 0.4)
        obs = withValues(obs, [T: 74])
        let events = startEvent(day: iso(T - 40), primaries: [.sleepRHR])
        let build = eval(obs, .sleepRHR, asOf: iso(T),
                         trial: LBTrialRequest(events: events,
                                               provenanceNow: LBProvenance(firmware: "1.0")))
        let bundle = try! XCTUnwrap(build.trial.freeze)
        XCTAssertEqual(bundle.provenance.firmware, "1.0", "item 5: provenance travels with the freeze")

        let same = eval(obs, .sleepRHR, asOf: iso(T),
                        trial: LBTrialRequest(events: events, freeze: bundle,
                                              provenanceNow: LBProvenance(firmware: "1.0")))
        let changed = eval(obs, .sleepRHR, asOf: iso(T),
                           trial: LBTrialRequest(events: events, freeze: bundle,
                                                 provenanceNow: LBProvenance(firmware: "2.0")))
        print("ITEM5 provenance: sameBreak=\(same.trial.provenanceBreak) "
              + "changedBreak=\(changed.trial.provenanceBreak) "
              + "sameEligible=\(same.trial.primaryContrastEligible) "
              + "changedEligible=\(changed.trial.primaryContrastEligible) "
              + "summary=\(String(describing: changed.trial.summarySentence))")
        XCTAssertFalse(same.trial.provenanceBreak, "fixture sanity: identical provenance is not a break")
        XCTAssertTrue(changed.trial.provenanceBreak, "item 5: firmware change after t0 is a break")
        XCTAssertFalse(changed.trial.primaryContrastEligible,
                       "item 5: a provenance break is ineligible; do not paint it as physiology")
        XCTAssertNil(changed.trial.summarySentence,
                     "item 5: no change-since-start sentence across a provenance break")
        XCTAssertTrue(same.trial.primaryContrastEligible, "fixture sanity: the same day is eligible")

        // App wiring: the store must supply provenance. Without it the break cannot ever fire,
        // because the freeze was built under the same default provenance.
        let store = appSource("Strand/Data/BaselineStore.swift") ?? ""
        XCTAssertTrue(store.contains("provenanceNow"),
                      "item 5: the app must feed LBProvenance into the trial request, or the "
                      + "provenance break is structurally undetectable (BaselineStore.rescore)")
    }

    /// Item 5 fixture `preexisting_recovery`: the patient was already improving before t0.
    /// "Path gap small, flat gap large; summary follows the path."
    func test_gauntlet_item5_preexistingRecoveryPathGapBeatsFlatGap() {
        // Falls 0.25 bpm/day for 100 nights; t0 is 40 nights before today; the fall continues after t0.
        var obs: [LBDailyObservation] = []
        for off in 0..<140 {
            obs.append(ok(iso(T - off), 78.0 - 0.25 * Double(139 - off) + altern(off, 0.4)))
        }
        let events = startEvent(day: iso(T - 40), primaries: [.sleepRHR])
        let ev = eval(obs, .sleepRHR, asOf: iso(T),
                      trial: LBTrialRequest(events: events, provenanceNow: LBProvenance()))
        let tr = ev.trial
        print("ITEM5 recovery: L0=\(tr.freeze?.centerLong ?? .nan) G0=\(tr.freeze?.slopeLong ?? .nan) "
              + "expected=\(tr.expectedUntreatedDisplay ?? .nan) today=\(ev.todayNative ?? .nan) "
              + "gapPath=\(tr.gapVsPathDisplay ?? .nan) gapFlat=\(tr.gapVsFlatDisplay ?? .nan) "
              + "zPath=\(tr.zTrialTraj ?? .nan) zFlat=\(tr.zTrialLevel ?? .nan) "
              + "summary=\(String(describing: tr.summarySentence))")
        XCTAssertTrue(tr.trialFreezeOk, "fixture sanity: qualify must pass so a freeze exists")
        XCTAssertLessThan(tr.freeze?.slopeLong ?? 0, -0.1, "item 6: G0 is the pre-start slow slope")
        XCTAssertLessThan(abs(tr.gapVsPathDisplay ?? 99), abs(tr.gapVsFlatDisplay ?? 0),
                          "item 5: the path gap is smaller than the flat gap when they were already improving")
        XCTAssertLessThan(abs(tr.zTrialTraj ?? 99), abs(tr.zTrialLevel ?? 0),
                          "item 6: primary z vs the path is not the flat z")
        XCTAssertNotEqual(tr.expectedUntreatedDisplay ?? 0, tr.freeze?.centerLong ?? 0,
                          "item 6: expected_untreated is not the frozen level")
    }

    /// Item 5: t0 is never inferred from physiology. No start event means no trial block, however
    /// extreme the nightly values are; post-start physiology cannot move the freeze.
    func test_gauntlet_item5_startTimeIsNeverInferredFromHeartRate() {
        var extreme = flatTape(end: T, nights: 90, base: 60, amp: 0.4)
        extreme = withValues(extreme, [T: 110])
        let noEvent = eval(extreme, .sleepRHR, asOf: iso(T))
        print("ITEM5 t0: phase without a start event = \(noEvent.trial.phase)")
        XCTAssertEqual(noEvent.trial.phase, .none,
                       "item 5: an off-the-charts night must not create a treatment clock")
        XCTAssertNil(noEvent.trial.freeze, "item 5: no start event, no freeze")

        // Same pre-start tape, two different post-start tapes: the freeze must be identical.
        var a = flatTape(end: T, nights: 130, base: 60, amp: 0.4)
        var b = a
        var post: [Int: Double] = [:]
        for e in (T - 39)...T { post[e] = 80 }
        b = withValues(b, post)
        a = withValues(a, [T - 2: 61, T - 1: 59, T: 63])
        let events = startEvent(day: iso(T - 40), primaries: [.sleepRHR])
        let evA = eval(a, .sleepRHR, asOf: iso(T),
                       trial: LBTrialRequest(events: events, provenanceNow: LBProvenance()))
        let evB = eval(b, .sleepRHR, asOf: iso(T),
                       trial: LBTrialRequest(events: events, provenanceNow: LBProvenance()))
        print("ITEM5 t0 freeze A=\(evA.trial.freeze?.centerLong ?? .nan)/"
              + "\(evA.trial.freeze?.slopeLong ?? .nan) B=\(evB.trial.freeze?.centerLong ?? .nan)/"
              + "\(evB.trial.freeze?.slopeLong ?? .nan)")
        XCTAssertEqual(evA.trial.freeze, evB.trial.freeze,
                       "item 5/6: post-start nights must never edit the frozen control")
        XCTAssertNotEqual(evA.trial.deltaTrialTraj, evB.trial.deltaTrialTraj,
                          "sanity: the two post-start tapes do differ in what happened since t0")
    }

    /// Item 5: no causal treatment language on the trial block.
    func test_gauntlet_item5_noCausalLanguageInTrialCopy() {
        var obs = flatTape(end: T, nights: 130, base: 60, amp: 0.4)
        obs = withValues(obs, [T: 70])
        let events = startEvent(day: iso(T - 40), primaries: [.sleepRHR], notes: "Lisinopril")
        let ev = eval(obs, .sleepRHR, asOf: iso(T),
                      trial: LBTrialRequest(events: events, provenanceNow: LBProvenance()))
        let surface = [ev.trial.summarySentence ?? "", ev.trial.card.banner ?? "",
                       ev.trial.card.freezeTitle ?? "", ev.trial.card.slowTitle,
                       ev.trial.card.thisWeekTitle].joined(separator: " | ")
        print("ITEM5 copy: \(surface)")
        XCTAssertFalse(surface.lowercased().contains("caused"),
                       "item 5: no card or summary string may claim causation:\n\(surface)")
        XCTAssertTrue(ev.trial.disclaimer.contains("not proof the treatment caused the change"),
                      "item 5: the non-causal sentence is always on the trial block")
    }

    // MARK: - Item 6: freeze a no-treatment model and keep comparing

    func trendingTape(amplitude: Double = 0.4) -> [LBDailyObservation] {
        // 0.25 bpm/day fall for 140 nights; today's level is about 60.
        (0..<140).map { off in
            ok(iso(T - off), 78.0 - 0.25 * Double(139 - off) + altern(off, amplitude))
        }
    }

    /// Item 6: the freeze is a model (level + slope + spread + r1 + sigma + provenance), built only
    /// from nights strictly before t0, with the documented 30-day cap.
    func test_gauntlet_item6_freezeStoresTheModelNotJustALevel() {
        let obs = trendingTape()
        let events = startEvent(day: iso(T - 40), primaries: [.sleepRHR])
        let ev = eval(obs, .sleepRHR, asOf: iso(T),
                      trial: LBTrialRequest(events: events, provenanceNow: LBProvenance()))
        let f = try! XCTUnwrap(ev.trial.freeze)
        print("ITEM6 freeze: L0=\(f.centerLong) G0=\(f.slopeLong) spread=\(f.spreadLong) "
              + "sigmaMeas=\(f.sigmaMeas) mdc95=\(f.mdc95) r1=\(f.r1) nEff=\(f.nEff) "
              + "dLast=\(f.dLast) t0=\(f.t0CivilDay) usable=\(f.slopeUsable) prov=\(f.provenance.firmware)")
        XCTAssertEqual(f.t0CivilDay, iso(T - 40), "item 6: t0 comes from the event")
        XCTAssertLessThan(f.dLast, f.t0CivilDay,
                          "item 6: the freeze only uses nights strictly before the start")
        XCTAssertNotEqual(f.slopeLong, 0, "item 6: G0 is stored")
        XCTAssertTrue(f.slopeUsable, "item 6: a clean 100-night fall is usable")
        XCTAssertGreaterThan(f.spreadLong, 0)
        XCTAssertGreaterThanOrEqual(f.sigmaMeas, 0, "item 6: sigma_meas is stored")
        XCTAssertEqual(f.mdc95, 2.77 * f.sigmaMeas, accuracy: 1e-9,
                       "item 6: MDC_95 = 2.77 x sigma_meas")
        XCTAssertEqual(f.provenance.firmware, LBProvenance().firmware,
                       "item 6: provenance is frozen with the model")
        // expected_untreated = L0 + G0 * dt, and it must differ from the frozen level.
        let fEpoch = LongitudinalBaseline.isoEpochDay(f.tFreeze)!
        let at10 = LongitudinalBaseline.expectedUntreated(level0: f.centerLong, slopeG0: f.slopeLong,
                                                          usable: f.slopeUsable,
                                                          asOfEpoch: fEpoch + 10, freezeEpoch: fEpoch)
        XCTAssertEqual(at10, f.centerLong + f.slopeLong * 10, accuracy: 1e-9)
        XCTAssertNotEqual(at10, f.centerLong, accuracy: 1e-9,
                          "item 6: with G0 != 0 the no-treatment path is not L0")
        XCTAssertNotEqual(ev.trial.expectedUntreatedDisplay ?? .nan, f.centerLong, accuracy: 1e-9,
                          "item 6: the card leads with the expected path, not the souvenir level")
    }

    /// Item 6: a thin pre-start trend freezes a flat model and says so.
    func test_gauntlet_item6_thinSlopeFreezesAFlatModelAndSaysSo() {
        let obs = flatTape(end: T, nights: 130, base: 60, amp: 0.4)
        let events = startEvent(day: iso(T - 40), primaries: [.sleepRHR])
        let ev = eval(obs, .sleepRHR, asOf: iso(T),
                      trial: LBTrialRequest(events: events, provenanceNow: LBProvenance()))
        let tr = ev.trial
        print("ITEM6 flat: usable=\(tr.freeze?.slopeUsable ?? false) "
              + "expected=\(tr.expectedUntreatedDisplay ?? .nan) L0=\(tr.freeze?.centerLong ?? .nan) "
              + "flatModelOnly=\(tr.flatModelOnly) title=\(tr.card.freezeTitle ?? "none")")
        XCTAssertEqual(tr.freeze?.slopeUsable, false, "item 6: no trend, no projection")
        XCTAssertEqual(tr.flatModelOnly, true, "item 6: the copy must say the model is flat")
        XCTAssertEqual(tr.expectedUntreatedDisplay ?? .nan, tr.freeze?.centerLong ?? 0, accuracy: 1e-9,
                       "item 6: a flat model compares to the usual level")
        let view = appSource("Strand/Screens/BaselineMonitorView.swift") ?? ""
        XCTAssertTrue(view.contains("Not enough pre-start trend to project"),
                      "item 6: the flat-model sentence must be shown")
    }

    /// Item 6: after t0 the comparison keeps updating - this week and On {name} move, the frozen
    /// control does not, and the post-start long epoch never mixes with pre-start nights.
    func test_gauntlet_item6_postStartComparisonUpdatesEveryNight() {
        var obs: [LBDailyObservation] = []
        for off in 0..<140 {
            let pre = 70.0 + altern(off, 0.4)
            let post = 70.0 + 0.25 * Double(max(0, 40 - off)) + altern(off, 0.4)
            obs.append(ok(iso(T - off), off < 40 ? post : pre))
        }
        let events = startEvent(day: iso(T - 40), primaries: [.sleepRHR])
        let request = LBTrialRequest(events: events, provenanceNow: LBProvenance())
        let early = eval(obs, .sleepRHR, asOf: iso(T - 20), trial: request)
        let late = eval(obs, .sleepRHR, asOf: iso(T), trial: request)
        print("ITEM6 onRx: early nLong=\(early.nLong) live=\(early.copyLong?.center ?? .nan) "
              + "late nLong=\(late.nLong) live=\(late.copyLong?.center ?? .nan) "
              + "titles=[\(late.trial.card.thisWeekTitle) | \(late.trial.card.slowTitle) | "
              + "\(late.trial.card.freezeTitle ?? "none")]")
        XCTAssertEqual(early.trial.freeze, late.trial.freeze,
                       "item 6: the freeze is immutable after t0")
        XCTAssertLessThan(early.nLong, 25,
                          "item 6: the post-start long epoch starts at t0, it does not inherit 140 nights")
        XCTAssertGreaterThan(late.nLong, early.nLong, "the on-treatment usual keeps building")
        XCTAssertGreaterThan(late.copyLong?.center ?? 0, early.copyLong?.center ?? 0,
                             "item 6: On {name} usual updates every night while the control is frozen")
        XCTAssertEqual(late.trial.card.freezeTitle, "Expected without treatment",
                       "item 6: the third column is the no-treatment model")
        XCTAssertEqual(late.trial.card.slowTitle, "On Drug X usual",
                       "item 6/7: the middle column is the live on-treatment usual")
        XCTAssertEqual(late.trial.card.thisWeekTitle, "This week's usual")
    }

    /// Item 6 phase-aware behavior: settling in cannot declare a response; washing out keeps the
    /// frozen path; ended renames the live copy.
    func test_gauntlet_item6_phaseAwareSummaryAndTitles() {
        // 200 flat nights at 70 (+-0.4). From t0 (T-95) the level rises smoothly at 0.2 bpm/day.
        // Pre-start is flat on purpose, so the frozen model is the flat fallback with a clean freeze.
        var obs: [LBDailyObservation] = []
        for off in 0..<200 {
            let rise = off >= 95 ? 0.0 : 0.2 * Double(95 - off)
            obs.append(ok(iso(T - off), 70.0 + rise + altern(off, 0.4)))
        }
        let settling = eval(obs, .sleepRHR, asOf: iso(T - 90),
                            trial: LBTrialRequest(events: startEvent(day: iso(T - 95), onset: 30,
                                                                     primaries: [.sleepRHR])))
        let onRx = eval(obs, .sleepRHR, asOf: iso(T - 60),
                        trial: LBTrialRequest(events: startEvent(day: iso(T - 95), onset: 7,
                                                                 primaries: [.sleepRHR])))
        let washing = eval(obs, .sleepRHR, asOf: iso(T),
                           trial: LBTrialRequest(events: startEvent(day: iso(T - 95), onset: 7,
                                                                    primaries: [.sleepRHR], stop: true,
                                                                    lastDose: iso(T - 50),
                                                                    stopDay: iso(T - 20),
                                                                    washout: 60)))
        let ended = eval(obs, .sleepRHR, asOf: iso(T),
                         trial: LBTrialRequest(events: startEvent(day: iso(T - 95), onset: 7,
                                                                  primaries: [.sleepRHR], stop: true,
                                                                  lastDose: iso(T - 90),
                                                                  stopDay: iso(T - 20), washout: 3)))
        print("ITEM6 phases: settling=\(settling.trial.phase)/"
              + "\(String(describing: settling.trial.summarySentence)) "
              + "onRx=\(onRx.trial.phase)/\(String(describing: onRx.trial.summarySentence)) "
              + "freezeOk=\(onRx.trial.trialFreezeOk) trust=\(onRx.usualTrustPctLong) "
              + "aboveMdc=\(String(describing: onRx.trial.aboveMdc)) "
              + "dTraj=\(onRx.trial.deltaTrialTraj ?? .nan) "
              + "washing=\(washing.trial.phase) ended=\(ended.trial.phase)/\(ended.trial.card.slowTitle)")
        XCTAssertEqual(settling.trial.phase, .settlingIn)
        XCTAssertEqual(settling.trial.summarySentence, "Too early to judge a response.")
        XCTAssertEqual(onRx.trial.phase, .onTreatment)
        XCTAssertNotNil(onRx.trial.summarySentence,
                        "item 6: on treatment, an eligible primary with a big path gap may fire")
        XCTAssertTrue((onRx.trial.summarySentence ?? "").contains("no-treatment path"),
                      "item 6: the summary is in units vs the no-treatment path")
        XCTAssertEqual(onRx.trial.expectedUntreatedDisplay ?? .nan,
                       onRx.trial.freeze?.centerLong ?? 0, accuracy: 1e-9,
                       "item 6: a flat pre-start model compares to the usual level")
        XCTAssertEqual(washing.trial.phase, .washingOut)
        XCTAssertEqual(washing.trial.expectedT, ended.trial.expectedT,
                       "item 6: washing out keeps the frozen expected path")
        XCTAssertEqual(ended.trial.phase, .ended)
        XCTAssertEqual(ended.trial.card.slowTitle, "After Drug X usual",
                       "item 6: ended shows the live slow copy as After {name}")
    }

    // MARK: - Item 7: patient-entered settling / washout clocks

    /// Item 7: the same physiology with washout 3 vs 14 ends on different days while every
    /// physiological comparison stays identical.
    func test_gauntlet_item7_washoutClocksChangeLabelsOnly() {
        let obs = trendingTape()
        func run(washout: Int?, saysClear: Bool) -> LBEvaluation {
            let events = startEvent(day: iso(T - 60), primaries: [.sleepRHR], stop: true,
                                    patientSaysClear: saysClear, lastDose: iso(T - 10),
                                    washout: washout)
            return eval(obs, .sleepRHR, asOf: iso(T),
                        trial: LBTrialRequest(events: events, provenanceNow: LBProvenance()))
        }
        let short = run(washout: 3, saysClear: false)
        let long = run(washout: 14, saysClear: false)
        print("ITEM7 washout: 3d=\(short.trial.phase) 14d=\(long.trial.phase) "
              + "expectedEqual=\(short.trial.expectedT == long.trial.expectedT) "
              + "zEqual=\(short.trial.zTrialTraj == long.trial.zTrialTraj)")
        XCTAssertEqual(short.trial.phase, .ended, "item 7: a 3-day washout has ended by now")
        XCTAssertEqual(long.trial.phase, .washingOut, "item 7: a 14-day washout is still running")
        XCTAssertEqual(short.trial.expectedT, long.trial.expectedT,
                       "item 7: the washout length must not move expected_untreated")
        XCTAssertEqual(short.trial.zTrialTraj, long.trial.zTrialTraj,
                       "item 7: the washout length must not move z")
        XCTAssertEqual(short.trial.deltaTrialTraj, long.trial.deltaTrialTraj)
        XCTAssertEqual(short.trial.freeze, long.trial.freeze,
                       "item 7: the clocks never edit L0/G0")

        let clear = run(washout: 14, saysClear: true)
        print("ITEM7 saysClear: phase=\(clear.trial.phase) z=\(clear.trial.zTrialTraj ?? .nan)")
        XCTAssertEqual(clear.trial.phase, .ended,
                       "item 7: 'I already feel it's out of my system' ends the label now")
        XCTAssertEqual(clear.trial.zTrialTraj, long.trial.zTrialTraj,
                       "item 7: patient says clear must not edit z")
    }

    /// Item 7: settle-in length comes from the start form, and the extra 10 nights never edit z.
    func test_gauntlet_item7_onsetDaysDriveSettlingInOnly() {
        let obs = trendingTape()
        func run(onset: Int) -> LBEvaluation {
            let events = startEvent(day: iso(T - 5), onset: onset, primaries: [.sleepRHR])
            return eval(obs, .sleepRHR, asOf: iso(T),
                        trial: LBTrialRequest(events: events, provenanceNow: LBProvenance()))
        }
        let short = run(onset: 3)
        let long = run(onset: 10)
        print("ITEM7 onset: 3d=\(short.trial.phase) 10d=\(long.trial.phase) "
              + "expected=\(short.trial.expectedT ?? .nan) vs \(long.trial.expectedT ?? .nan)")
        XCTAssertEqual(short.trial.phase, .onTreatment, "item 7: settle-in ended at day 3")
        XCTAssertEqual(long.trial.phase, .settlingIn, "item 7: settle-in still running at day 10")
        XCTAssertEqual(short.trial.expectedT, long.trial.expectedT,
                       "item 7: onset days must not move expected_untreated")
        XCTAssertEqual(short.trial.freeze, long.trial.freeze)
        XCTAssertEqual(long.trial.washInDaysUsed, 10)
        XCTAssertEqual(short.trial.washInDaysUsed, 3)
    }

    /// Item 7: free-text clinic notes are shown, never an engine input.
    func test_gauntlet_item7_clinicNotesAreNotAnEngineInput() {
        let obs = trendingTape()
        func run(note: String?) -> LBEvaluation {
            let events = startEvent(day: iso(T - 40), primaries: [.sleepRHR], notes: note)
            return eval(obs, .sleepRHR, asOf: iso(T),
                        trial: LBTrialRequest(events: events, provenanceNow: LBProvenance()))
        }
        let none = run(note: nil)
        let expect = run(note: "Expect RHR to fall; HRV should rise. Watch for a drop.")
        print("ITEM7 notes: expected=\(none.trial.expectedT ?? .nan) vs \(expect.trial.expectedT ?? .nan)")
        XCTAssertEqual(none.trial.expectedT, expect.trial.expectedT,
                       "item 7: 'expect RHR to fall' must not be an engine input")
        XCTAssertEqual(none.trial.zTrialTraj, expect.trial.zTrialTraj)
        XCTAssertEqual(none.trial.summarySentence, expect.trial.summarySentence,
                       "item 7: notes must not change what is judged")
    }

    /// Item 7: the washout clock starts at the last dose when that is later than the end date.
    func test_gauntlet_item7_washoutStartsAtLastDoseWhenLaterThanStop() {
        let obs = trendingTape()
        func run(lastDose: String?) -> LBEvaluation {
            let events = startEvent(day: iso(T - 60), primaries: [.sleepRHR], stop: true,
                                    lastDose: lastDose, stopDay: iso(T - 20), washout: 10)
            return eval(obs, .sleepRHR, asOf: iso(T),
                        trial: LBTrialRequest(events: events, provenanceNow: LBProvenance()))
        }
        let atStop = run(lastDose: nil)
        let later = run(lastDose: iso(T - 3))
        print("ITEM7 lastDose: atStop=\(atStop.trial.phase) later=\(later.trial.phase)")
        XCTAssertEqual(atStop.trial.phase, .ended, "fixture: 10-day washout from the stop day is over")
        XCTAssertEqual(later.trial.phase, .washingOut,
                       "item 7: the washout clock starts at the last dose when that is later")
        XCTAssertEqual(atStop.trial.expectedT, later.trial.expectedT,
                       "item 7: the clock start never moves expected_untreated")
    }

    // MARK: - Item 8: predeclared primaries, no post-treatment fishing

    struct SeriesFixture {
        let series: LBSeries
        let base: Double
        let amp: Double
        let coverage: Double?
        let post: Double
    }

    /// Twelve series in the catalog, one predeclared primary. Several exploratory series move after
    /// the start; the summary must ignore every one of them.
    func test_gauntlet_item8_twelveSeriesOnePrimaryAndMovingExploratorySeries() {
        let primary: LBSeries = .sleepRHR
        let spec: [SeriesFixture] = [
            SeriesFixture(series: .sleepRHR, base: 60, amp: 0.4, coverage: nil, post: 70),
            SeriesFixture(series: .sleepHRVLn, base: 65, amp: 0.6, coverage: nil, post: 52),
            SeriesFixture(series: .sleepTemp, base: 36.5, amp: 0.05, coverage: nil, post: 37.4),
            SeriesFixture(series: .sleepResp, base: 15, amp: 0.1, coverage: nil, post: 18),
            SeriesFixture(series: .sleepSpO2Mean, base: 96, amp: 0.2, coverage: 20, post: 93),
            SeriesFixture(series: .sleepSpO2Nadir, base: 92, amp: 0.2, coverage: 20, post: 88),
            SeriesFixture(series: .awakeRestHR, base: 70, amp: 0.5, coverage: 60, post: 78),
            SeriesFixture(series: .awakeRestHRVLn, base: 45, amp: 0.4, coverage: 60, post: 36),
            SeriesFixture(series: .awakeRestSpO2Mean, base: 97, amp: 0.2, coverage: 20, post: 94),
            SeriesFixture(series: .awakeActiveHR, base: 100, amp: 1.0, coverage: 60, post: 112),
            SeriesFixture(series: .continuousHR, base: 80, amp: 0.8, coverage: 400, post: 88),
            SeriesFixture(series: .wakingSteps, base: 8_000, amp: 100, coverage: nil, post: 14_000),
        ]
        XCTAssertEqual(spec.count, 12, "item 8: the proof fixture is 12 series")
        let events = startEvent(day: iso(T - 40), primaries: [primary])
        let request = LBTrialRequest(events: events, provenanceNow: LBProvenance())
        var summaries = 0
        var exploratoryMoved: [LBSeries] = []
        for row in spec {
            var obs = flatTape(end: T, nights: 140, base: row.base, amp: row.amp,
                               coverage: row.coverage)
            var over: [Int: Double] = [:]
            for off in 0...39 { over[T - off] = row.post }
            obs = withValues(obs, over)
            let ev = eval(obs, row.series, asOf: iso(T), trial: request)
            let tr = ev.trial
            if let s = tr.summarySentence {
                summaries += 1
                print("ITEM8 summary [\(row.series.rawValue)] \(s)")
            }
            if row.series == primary {
                XCTAssertTrue(tr.isPrimarySeries, "item 8: the predeclared series is primary")
                XCTAssertTrue(tr.trialFreezeOk, "fixture sanity: the primary must freeze")
                XCTAssertTrue(tr.judgingResponse, "item 8: an eligible primary can judge a response")
                XCTAssertNotNil(tr.summarySentence, "item 8: the primary writes the sentence")
            } else {
                XCTAssertFalse(tr.isPrimarySeries, "item 8: \(row.series.rawValue) is exploratory")
                XCTAssertFalse(tr.judgingResponse,
                               "item 8: exploratory series never judge a response")
                XCTAssertNil(tr.summarySentence,
                             "item 8: \(row.series.rawValue) must not write the summary")
                if tr.aboveMdc == true { exploratoryMoved.append(row.series) }
            }
        }
        print("ITEM8 summaries=\(summaries) exploratoryMoved=\(exploratoryMoved.map(\.rawValue))")
        XCTAssertGreaterThanOrEqual(exploratoryMoved.count, 3,
                                    "item 8: several exploratory series must actually move, "
                                    + "or the fixture proves nothing")
        XCTAssertEqual(summaries, 1, "item 8: only the primary may write the summary sentence")
    }

    /// Item 8: no primaries chosen means no judgement, however many series moved.
    func test_gauntlet_item8_emptyPrimariesDoNotJudge() {
        var obs = flatTape(end: T, nights: 140, base: 60, amp: 0.4)
        for off in 0...39 { obs = withValues(obs, [T - off: 70]) }
        let events = startEvent(day: iso(T - 40), primaries: [])
        let ev = eval(obs, .sleepRHR, asOf: iso(T),
                      trial: LBTrialRequest(events: events, provenanceNow: LBProvenance()))
        print("ITEM8 empty: phase=\(ev.trial.phase) summary=\(String(describing: ev.trial.summarySentence)) "
              + "judging=\(ev.trial.judgingResponse) aboveMdc=\(String(describing: ev.trial.aboveMdc))")
        XCTAssertEqual(ev.trial.summarySentence,
                       "No primary series chosen — not judging a treatment response.",
                       "item 8: refusing to pick primaries must not produce a response claim")
        XCTAssertFalse(ev.trial.judgingResponse, "item 8: nothing is judged without primaries")
        XCTAssertEqual(ev.trial.aboveMdc, true,
                       "item 8: the number may still be off the path, but it writes nothing")
    }

    /// Item 8: the list is stored at t0. Once a freeze exists, an edited start event cannot re-pick
    /// which series may write the summary.
    func test_gauntlet_item8_frozenPrimaryListWinsOverAnEditedStartEvent() {
        var obs = flatTape(end: T, nights: 140, base: 60, amp: 0.4)
        for off in 0...39 { obs = withValues(obs, [T - off: 70]) }
        let request = LBTrialRequest(events: startEvent(day: iso(T - 40), primaries: [.sleepRHR]),
                                     provenanceNow: LBProvenance())
        let frozen = eval(obs, .sleepRHR, asOf: iso(T - 20), trial: request)
        let bundle = try! XCTUnwrap(frozen.trial.freeze)
        XCTAssertEqual(bundle.primarySeries, [.sleepRHR], "item 8: the list is stored on t0")

        // Later, someone edits the start event to pin a series that moved. The stored freeze wins.
        let edited = LBTrialRequest(events: startEvent(day: iso(T - 40), primaries: [.wakingSteps]),
                                    freeze: bundle, provenanceNow: LBProvenance())
        let afterEdit = eval(obs, .wakingSteps, asOf: iso(T), trial: edited)
        print("ITEM8 fishing: edited primary judging=\(afterEdit.trial.judgingResponse) "
              + "summary=\(String(describing: afterEdit.trial.summarySentence))")
        XCTAssertFalse(afterEdit.trial.isPrimarySeries,
                       "item 8: a post-start edit must not promote a series to primary")
        XCTAssertNil(afterEdit.trial.summarySentence,
                     "item 8: editing primaries after t0 is fishing; the frozen list decides")
    }

    // MARK: - Missing nights, late samples, thin / stale / low-quality histories

    func metric(_ day: String, rhr: Int? = nil, hrv: Double? = nil, resp: Double? = nil,
                steps: Int? = nil, spo2: Double? = nil, temp: Double? = nil,
                sleepHrOnly: Bool? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil,
                    strain: nil, exerciseCount: nil, spo2Pct: spo2, skinTempDevC: nil,
                    respRateBpm: resp, steps: steps, activeKcalEst: nil, skinTempC: temp,
                    sleepHrOnly: sleepHrOnly)
    }

    func dailyMetricTape(nights: Int, end: Int? = nil) -> [DailyMetric] {
        let last = end ?? T
        return (0..<nights).reversed().map { i -> DailyMetric in
            metric(iso(last - i), rhr: 60 + Int((altern(i, 0.4)).rounded()),
                   hrv: 65 + altern(i, 0.5), resp: 15 + altern(i, 0.1),
                   steps: 8_000 + Int(altern(i, 200).rounded()), spo2: 96 + altern(i, 0.2),
                   temp: 36.5 + altern(i, 0.05))
        }
    }

    /// Missing nights stay missing and are never written as 0. A short gap leaves the remaining
    /// week nights in play; a full week gap removes the copy instead of inventing values.
    func test_gauntlet_missingNightsAreGapsNotZeros() {
        // Three missing nights: the week still has four usable nights, so a copy may be shown,
        // but tonight has no value and no z.
        var short = flatTape(end: T, nights: 90, base: 60, amp: 0.4)
        short = short.map { o in
            guard let e = LongitudinalBaseline.isoEpochDay(o.day), e >= T - 3 else { return o }
            return missing(o.day)
        }
        let evShort = eval(short, .sleepRHR, asOf: iso(T))
        print("MISSING short: today=\(String(describing: evShort.todayNative)) n7=\(evShort.n7) "
              + "show7=\(evShort.show7) z7=\(String(describing: evShort.z7)) "
              + "zLong=\(String(describing: evShort.zLong)) trust7=\(evShort.usualTrustPct7) "
              + "center7=\(evShort.copy7?.center ?? .nan)")
        XCTAssertNil(evShort.todayNative, "missing tonight must not be stored as a number")
        XCTAssertEqual(evShort.n7, 4, "only the four present nights are data")
        XCTAssertNil(evShort.z7, "no tonight value means no z")
        XCTAssertNil(evShort.zLong)
        XCTAssertLessThan(evShort.usualTrustPct7, 60, "a missing tonight lowers TRUST")
        XCTAssertEqual(evShort.copy7?.center ?? .nan, 60, accuracy: 0.5,
                       "the gap is a hole in the average, not a 0 bpm night")
        XCTAssertEqual(evShort.copy7?.n, 4)

        // A full week of gaps: no week copy at all, and still no zero anywhere.
        var full = flatTape(end: T, nights: 90, base: 60, amp: 0.4)
        full = full.map { o in
            guard let e = LongitudinalBaseline.isoEpochDay(o.day), e >= T - 7 else { return o }
            return missing(o.day)
        }
        let evFull = eval(full, .sleepRHR, asOf: iso(T))
        print("MISSING full week: n7=\(evFull.n7) show7=\(evFull.show7) copy7=\(String(describing: evFull.copy7)) "
              + "trust7=\(evFull.usualTrustPct7)")
        XCTAssertEqual(evFull.n7, 0)
        XCTAssertFalse(evFull.show7, "four nights is the floor for showing this week")
        XCTAssertNil(evFull.copy7, "no week of data, no week usual")
        XCTAssertNil(evFull.todayNative)
        XCTAssertEqual(evFull.usualTrustPct7, 0)
    }

    /// A late-arriving sample must be able to change the score, and must never be back-filled as 0.
    func test_gauntlet_lateArrivingSampleChangesTheScore() {
        var late = flatTape(end: T, nights: 90, base: 60, amp: 0.4)
        late = late.map { o in
            LongitudinalBaseline.isoEpochDay(o.day) == T - 1 ? missing(o.day) : o
        }
        var withLate = late
        withLate = withValues(withLate.map { o in
            LongitudinalBaseline.isoEpochDay(o.day) == T - 1 ? ok(o.day, 60.4) : o
        }, [:])
        let before = eval(late, .sleepRHR, asOf: iso(T))
        let after = eval(withLate, .sleepRHR, asOf: iso(T))
        print("LATE: before n7=\(before.n7) trust=\(before.usualTrustPct7) z=\(String(describing: before.z7)) | "
              + "after n7=\(after.n7) trust=\(after.usualTrustPct7) z=\(String(describing: after.z7))")
        XCTAssertEqual(before.n7, 6, "the late night is a gap until it arrives")
        XCTAssertEqual(after.n7, 7, "the late night counts once it arrives")
        XCTAssertNotEqual(before.usualTrustPct7, after.usualTrustPct7,
                          "a late night must be able to move TRUST")
        XCTAssertEqual(after.todayNative, 60.4, "today's own value is untouched by the gap")
    }

    /// Empty, thin and stale histories stay quiet: no OFF claim without enough nights.
    func test_gauntlet_emptyThinAndStaleHistoriesStayQuiet() {
        let empty = eval([], .sleepRHR, asOf: iso(T))
        print("EMPTY: n7=\(empty.n7) nLong=\(empty.nLong) trust7=\(empty.usualTrustPct7) "
              + "show7=\(empty.show7) stale=\(empty.stale) alertEligible=\(empty.alertEligible)")
        XCTAssertNil(empty.todayNative)
        XCTAssertFalse(empty.establishedLong, "no history, no established usual")
        XCTAssertFalse(empty.alertEligible)
        XCTAssertEqual(empty.usualTrustPct7, 0)
        XCTAssertEqual(empty.usualTrustPctLong, 0)
        XCTAssertNil(empty.z7); XCTAssertNil(empty.zLong)

        let thin = eval(flatTape(end: T, nights: 5, base: 60, amp: 0.4), .sleepRHR, asOf: iso(T))
        print("THIN: n7=\(thin.n7) show7=\(thin.show7) showLong=\(thin.showLong) "
              + "established=\(thin.establishedLong) alertEligible=\(thin.alertEligible)")
        XCTAssertTrue(thin.show7, "four or more nights may show this week")
        XCTAssertFalse(thin.showLong, "five nights is not a longer usual")
        XCTAssertFalse(thin.establishedLong)
        XCTAssertFalse(thin.alertEligible, "a thin history may not raise an alert")
        XCTAssertNil(thin.zLong)

        var staleObs = flatTape(end: T - 20, nights: 60, base: 60, amp: 0.4)
        staleObs.append(missing(iso(T - 19)))
        let stale = eval(staleObs, .sleepRHR, asOf: iso(T))
        print("STALE: stale=\(stale.stale) trust7=\(stale.usualTrustPct7) "
              + "trustLong=\(stale.usualTrustPctLong) z=\(String(describing: stale.zLong))")
        XCTAssertTrue(stale.stale, "20 nights without a usable night is stale at 14 days")
        XCTAssertEqual(stale.usualTrustPctLong, 0, "freshness decays to 0, TRUST follows")
        XCTAssertFalse(stale.alertEligible)
    }

    /// Low-quality nights train nothing, out-of-range values are not data, and SpO2 slot gates hold.
    func test_gauntlet_lowQualityOutOfRangeAndSlotGates() {
        // 31 low-quality nights out of a 53-night window cannot establish a usual.
        var lowQ = flatTape(end: T, nights: 90, base: 60, amp: 0.4)
        lowQ = lowQ.map { o in
            guard let e = LongitudinalBaseline.isoEpochDay(o.day), e >= T - 53, e <= T - 9 else {
                return o
            }
            return low(o.day, nil, reason: .poorSignal)
        }
        let evLow = eval(lowQ, .sleepRHR, asOf: iso(T))
        let clean = eval(flatTape(end: T, nights: 90, base: 60, amp: 0.4), .sleepRHR, asOf: iso(T))
        print("LOWQ: nLong=\(evLow.nLong) established=\(evLow.establishedLong) "
              + "trustLong=\(evLow.usualTrustPctLong) vs clean \(clean.usualTrustPctLong)")
        XCTAssertLessThan(evLow.nLong, 14, "low-quality nights are not usable nights")
        XCTAssertFalse(evLow.establishedLong)
        XCTAssertLessThan(evLow.usualTrustPctLong, clean.usualTrustPctLong)

        // Out of range (200 bpm) is not an observation that trains, and is never read as 0.
        var outOfRange = flatTape(end: T, nights: 90, base: 60, amp: 0.4)
        outOfRange = withValues(outOfRange, [T: 200])
        let evRange = eval(outOfRange, .sleepRHR, asOf: iso(T))
        print("RANGE: today=\(String(describing: evRange.todayNative)) center7=\(evRange.copy7?.center ?? .nan)")
        XCTAssertNil(evRange.todayNative, "200 bpm is out of range for sleep RHR, so it is not data")
        XCTAssertEqual(evRange.copy7?.center ?? .nan, clean.copy7?.center ?? 0, accuracy: 0.01,
                       "an out-of-range night must not move the band")

        // SpO2 needs 8 slots. Below that the night is missing, never 0.
        var thinSlots = flatTape(end: T, nights: 90, base: 96, amp: 0.2, coverage: 5)
        thinSlots = withValues(thinSlots, [T: 96])
        let evSlots = eval(thinSlots, .sleepSpO2Mean, asOf: iso(T))
        let okSlots = flatTape(end: T, nights: 90, base: 96, amp: 0.2, coverage: 20)
        let evOk = eval(okSlots, .sleepSpO2Mean, asOf: iso(T))
        print("SPO2: 5-slot nLong=\(evSlots.nLong) today=\(String(describing: evSlots.todayNative)) | "
              + "20-slot nLong=\(evOk.nLong) today=\(String(describing: evOk.todayNative))")
        XCTAssertNil(evSlots.todayNative, "a 5-slot SpO2 night is missing, not 0%")
        XCTAssertEqual(evSlots.nLong, 0, "no SpO2 night with <8 slots may train")
        XCTAssertGreaterThan(evOk.nLong, 40, "20-slot nights train normally")

        // Steps: 0 with a stream present is a real 0; no stream is missing.
        let days = [metric(iso(T - 1), steps: 0), metric(iso(T - 2), steps: nil)]
        let stepsObs = LongitudinalBaseline.observations(from: days, series: .wakingSteps)
        print("STEPS: \(stepsObs.map { "\($0.day)=\(String(describing: $0.value))/\($0.qualityStatus.rawValue)" })")
        XCTAssertEqual(stepsObs.first?.value, 0, "0 steps with a stream present is a real 0")
        XCTAssertEqual(stepsObs.first?.qualityStatus, .ok)
        XCTAssertNil(stepsObs.last?.value, "no step stream on the second day stays missing")
        XCTAssertEqual(stepsObs.last?.qualityStatus, .missing)
    }

    /// Sparse-sleep flag: a night staged from HR alone is low quality for sleep series.
    func test_gauntlet_sleepHrOnlyNightIsLowQuality() {
        let days = [metric(iso(T), rhr: 60, hrv: 65, sleepHrOnly: true),
                    metric(iso(T - 1), rhr: 60, hrv: 65, sleepHrOnly: false)]
        let obs = LongitudinalBaseline.observations(from: days, series: .sleepRHR)
        print("SLEEPHRONLY: \(obs.map { "\($0.day)=\($0.qualityStatus.rawValue)/\($0.qualityReason?.rawValue ?? "-")" })")
        XCTAssertEqual(obs.first?.qualityStatus, .lowQuality)
        XCTAssertEqual(obs.first?.qualityReason, .sparseSleep)
        XCTAssertEqual(obs.last?.qualityStatus, .ok)
    }

    /// Determinism and carry threading: replay must equal a hand-walked carry chain, and repeated
    /// evaluations of the same tape must be identical.
    func test_gauntlet_repeatedEvaluationsAreDeterministicAndCarryThreaded() {
        let obs = flatTape(end: T, nights: 90, base: 60, amp: 0.4)
        let a = eval(obs, .sleepRHR, asOf: iso(T))
        let b = eval(obs, .sleepRHR, asOf: iso(T))
        XCTAssertEqual(a, b, "scoring a tape twice must give the same answer")

        var carry = LBCarry.empty
        for e in (T - 20)...T {
            carry = LongitudinalBaseline.evaluate(asOf: iso(e), series: .sleepRHR,
                                                 observations: obs, carry: carry,
                                                 replay: false).carry
        }
        let walk = LongitudinalBaseline.evaluate(asOf: iso(T), series: .sleepRHR, observations: obs,
                                                 carry: carry, replay: false)
        print("CARRY: replay center7=\(a.copy7?.center ?? .nan) walk center7=\(walk.copy7?.center ?? .nan) "
              + "S replay=\(a.cusumS) walk=\(walk.cusumS)")
        XCTAssertEqual(a.cusumS, walk.cusumS, accuracy: 1e-9,
                       "a hand-threaded carry chain must match the replay walk")
    }

    // MARK: - Performance / memory stress

    /// Measurement (not a pass/fail): one year of rows, full re-score of every wired series.
    func test_gauntlet_performance_measureOneYearRescore() {
        let days = dailyMetricTape(nights: 365)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            _ = LongitudinalBaseline.shadowPoints(asOf: days.last!.day, days: days)
        }
    }

    /// Hard bound: three years of rows must not blow up time or memory on a phone-class engine.
    func test_gauntlet_stress_threeYearTapeStaysBounded() {
        let days = dailyMetricTape(nights: 1_095)
        let wired = LBSeries.allCases.filter { $0.hasDailyMetricColumn }
        let started = Date()
        var evaluations: [LBEvaluation] = []
        for series in wired {
            let obs = LongitudinalBaseline.observations(from: days, series: series)
            evaluations.append(LongitudinalBaseline.evaluate(asOf: days.last!.day, series: series,
                                                             observations: obs))
        }
        let elapsed = Date().timeIntervalSince(started)
        let perDay = elapsed / Double(days.count)
        print("STRESS 3-year tape: \(wired.count) wired series in "
              + String(format: "%.3f", elapsed) + " s (" + String(format: "%.3f", perDay * 1_000)
              + " ms per tape night per series)")
        XCTAssertEqual(evaluations.count, wired.count)
        XCTAssertTrue(evaluations.allSatisfy { $0.establishedLong },
                      "a 3-year tape must establish every wired series")
        XCTAssertLessThan(elapsed, 60.0,
                          "three years of rows must not take a minute to re-score once")
    }

    // MARK: - App-surface wiring that items 4 and 6 require

    /// Item 4 acceptance: the card shows TRUST and HOW OFF, and the old CONFIDENCE label is gone.
    func test_gauntlet_item4_cardShowsTrustAndHowOffWithoutLegacyConfidence() {
        let view = appSource("Strand/Screens/BaselineMonitorView.swift") ?? ""
        XCTAssertFalse(view.isEmpty, "app view must be readable from the package test")
        XCTAssertTrue(view.contains("TRUST \\(trust)%"), "item 4: the usual boxes are labelled TRUST")
        XCTAssertTrue(view.contains("HOW OFF \\(howOff)%"), "item 4: the call line shows HOW OFF")
        for literal in view.components(separatedBy: "Text(").dropFirst() {
            XCTAssertFalse(literal.prefix(60).contains("onfidence"),
                           "item 4: no user-visible Confidence label may remain on the card")
        }
        XCTAssertTrue(view.contains("NOT ENOUGH NIGHTS"),
                      "item 4: TRUST below the threshold must say not enough nights")
        XCTAssertFalse(view.contains("CONFIDENCE"),
                       "item 4: the CONFIDENCE label must be gone from the card")
        let store = appSource("Strand/Data/BaselineStore.swift") ?? ""
        XCTAssertTrue(store.contains("trustHideThreshold"),
                      "item 4: the hide rule uses the single 35% threshold")
        XCTAssertFalse(store.contains("longHowOff: Int? { nil }"),
                       "item 4 required layout: the longer box shows TRUST and IN RANGE / OFF *and* "
                       + "HOW OFF (OFF - HOW OFF 86% or NOT ENOUGH NIGHTS). Hard-nil removes a "
                       + "required display; FRWHOOP_BASELINE_CHANGE_SUMMARY_16_SEP.md:43 admits the "
                       + "change but no doc reconciles it with the acceptance row.")
    }
}
