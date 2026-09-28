import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Integrity follow-on F1–F9. Same clock as boss 5 (`WatchdogLiveTail`); native sidecar as boss 1.
final class WatchdogV32FollowOnTests: XCTestCase {

    private let layer1 = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)
    private let sleepStill = WatchdogPhaseKey(phase: .sleep, family: .still)
    private let morningStill = WatchdogPhaseKey(phase: .morning, family: .still)

    // MARK: F1 / F4

    func testPromptHrIsNotPopulationWhenStillSidecarMature() {
        var store = WatchdogPhaseUsualStore.empty
        seed(store: &store, key: morningStill, days: 7, median: [68, 0, 44, 33.0, 13, 96])
        let emptyHR = UniTSPrompt(hr: nil, rhr: 52, hrv: 48, temp: 33.1, resp: 14, spo2: 97)
        let blended = store.blendPrompt(emptyHR, key: morningStill)
        XCTAssertEqual(blended.hr ?? 0, 68, accuracy: 0.05)
        XCTAssertNotEqual(blended.hr ?? 0, WatchdogPopulationPriors.hr, accuracy: 0.5)
        XCTAssertNotEqual(blended.hr ?? 0, 52 + 6, accuracy: 0.5, "must not invent RHR+6")
    }

    func testBlendFillsAwakeHrFromStillSidecarWhenLayer1Nil() {
        var store = WatchdogPhaseUsualStore.empty
        seed(store: &store, key: morningStill, days: 7, median: [70, 0, 42, 32.8, 13, 96])
        let p = UniTSPrompt(hr: nil, rhr: 54, hrv: 50, hrvAwake: nil, hrvAnchoredInSleep: true,
                            temp: 33.2, resp: 14, spo2: 97)
        let blended = store.blendPrompt(p, key: morningStill)
        XCTAssertEqual(blended.hr ?? 0, 70, accuracy: 0.05)
        XCTAssertEqual(blended.rhr ?? 0, 54, accuracy: 1e-9, "daytime still must not replace sleep RHR")
        XCTAssertEqual(blended.hrv ?? 0, 50, accuracy: 1e-9, "do not mix afternoon HRV into sleep hrv")
        XCTAssertTrue(blended.hrvAnchoredInSleep)
    }

    func testBlendDoesNotMoveSleepHRVFromAfternoonStill() {
        var store = WatchdogPhaseUsualStore.empty
        seed(store: &store, key: morningStill, days: 7, median: [64, 0, 30, 33.0, 12, 95])
        let p = UniTSPrompt(hr: 58, rhr: 52, hrv: 48, hrvAwake: nil, hrvAnchoredInSleep: true,
                            temp: 33.1, resp: 14, spo2: 97)
        let blended = store.blendPrompt(p, key: morningStill)
        XCTAssertEqual(blended.hrv ?? 0, 48, accuracy: 1e-9)
        XCTAssertEqual(blended.rhr ?? 0, 52, accuracy: 1e-9)
        XCTAssertEqual(blended.hr ?? 0, 0.3 * 58 + 0.7 * 64, accuracy: 0.05)
        XCTAssertEqual(blended.temp ?? 0, 33.1, accuracy: 1e-9, "Layer 1 temp stays; daytime only fills if nil")
    }

    func testOvernightTapeStillHasEmptyAwakeRestSeries() {
        let p = UniTSPrompt.from(evaluations: [])
        XCTAssertNil(p.hr)
        XCTAssertNil(p.hrvAwake)
    }

    // MARK: F2 / F3

    func testRolloverWritesDominantStillKeyNotMidnightWalk() throws {
        var carry = WatchdogCarry.empty
        let day1 = sleepUnix(day: 1)
        for i in 0..<16 {
            carry = tick(now: day1 + i * 60, hr: 58, motion: 0, previous: carry).carry
        }
        let stillTicks = carry.sessionKeyTicks.filter { $0.key.contains("still") }.values.reduce(0, +)
        XCTAssertGreaterThanOrEqual(stillTicks, 12)
        carry.lastCivilDay = "2020-01-01"
        let walkNow = day1 + 16 * 60
        carry = tick(now: walkNow, hr: 110, motion: 0.9, previous: carry).carry
        let walkKeys = carry.phaseUsual.entries.keys.filter { $0.contains("walk") || $0.contains("endurance") }
        XCTAssertTrue(walkKeys.isEmpty, "walk leftover at midnight must not own the day: \(walkKeys)")
        let stillId = carry.phaseUsual.entries.keys.first(where: { $0.contains("still") })
        XCTAssertNotNil(stillId, "expected a still sidecar, got \(carry.phaseUsual.entries.keys)")
        if let id = stillId, let c = carry.phaseUsual.entries[id]?.center {
            XCTAssertGreaterThan(c[0], 40)
            XCTAssertLessThan(c[0], 90)
        }
    }

    func testPartialHRVDoesNotWriteZeroHRVUsual() {
        var store = WatchdogPhaseUsualStore.empty
        let presentHR: [Bool] = [true, false, false, true, false, false]
        for i in 1...7 {
            store.writeDay(key: sleepStill,
                           dayMedian: [62, 0, 0, 33.2, 0, 0],
                           present: presentHR,
                           civilDay: String(format: "2026-09-%02d", i))
        }
        let e = try! XCTUnwrap(store.entries[sleepStill.id])
        XCTAssertEqual(e.center[2], 0, accuracy: 1e-9)
        let blended = store.blendPrompt(layer1, key: sleepStill)
        XCTAssertEqual(blended.hrv ?? 0, 48, accuracy: 1e-9, "missing HRV must not mix a 0 usual")
        store.writeDay(key: sleepStill, dayMedian: [63, 57, 0, 33.3, 14, 97],
                       present: [true, true, false, true, true, true],
                       civilDay: "2026-09-08")
        XCTAssertEqual(store.entries[sleepStill.id]?.center[2] ?? -1, 0, accuracy: 1e-9)
    }

    func testWriteDaySkipsWhenHRAndTempMissing() {
        var store = WatchdogPhaseUsualStore.empty
        store.writeDay(key: sleepStill, dayMedian: [0, 58, 46, 0, 14, 97],
                       present: [false, true, true, false, true, true],
                       civilDay: "2026-09-01")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testDominantStillKeyIgnoresWorkoutFamilies() {
        let ticks = [
            "morning×walk": 40,
            "morning×still": 14,
            "evening×still": 13
        ]
        let key = WatchdogPhaseUsualStore.dominantStillKey(ticks: ticks)
        XCTAssertEqual(key, morningStill)
    }

    // MARK: F5 / F6 / F7 / F9

    func testAdaptiveQuietGateIgnoresRunMedianAfterSit() throws {
        let w = try runThenRest(now: 82_000_000, restMinutes: 8, restHR: 62)
        let residual = try UniTSRuntime().reconstruct(w, prompt: layer1)
        var carry = WatchdogCarry.empty
        let tail = WatchdogLiveTail.resolve(w)
        XCTAssertTrue(tail.endedPeriod)
        XCTAssertTrue(tail.stillNow)
        XCTAssertLessThan(residual.jointEnergy, WatchdogCalibration.tActive,
                          "F17: residual energy is the rest tail, not the run")
        _ = WatchdogAdaptive.apply(residual, window: w,
                                   lastHR: (62, 58), lastRHR: nil, lastHRV: (48, 48),
                                   lastTemp: (33.1, 33.1), lastResp: (14, 14), lastSpO2: (97, 97),
                                   carry: &carry, tail: tail)
        XCTAssertGreaterThan(carry.quietN, 0, "quiet EMA must run on the rest tail")
    }

    func testForecastLastObsStaysInRestTail() throws {
        let w = try runThenRest(now: 82_010_000, restMinutes: 3, restHR: 62)
        let residual = try UniTSRuntime().reconstruct(w, prompt: layer1)
        let tail = WatchdogLiveTail.resolve(w)
        XCTAssertGreaterThan(tail.startIndex, 0)
        let from = tail.startIndex
        var pairs: [Double] = []
        for i in from..<w.hr.count {
            if let o = w.hr[i] { pairs.append(o) }
        }
        XCTAssertFalse(pairs.contains(where: { $0 > 120 }), "forecast lastObs must not include 148")
        XCTAssertEqual(pairs.last ?? 0, 62, accuracy: 1)
        let step = WatchdogForecastRuntime().step(window: w, residual: residual, prompt: layer1,
                                                 carry: .empty, nowUnix: w.nowUnix, tail: tail)
        XCTAssertGreaterThanOrEqual(step.energy, 0)
    }

    func testRHRStripDropsPreRunStillWhenTailIsPostRun() throws {
        let w = try runThenRest(now: 82_020_000, restMinutes: 6, restHR: 62)
        let tail = WatchdogLiveTail.resolve(w)
        let clipped = tail.applyLookbacks(w)
        for i in 0..<tail.startIndex {
            XCTAssertNil(clipped.rhr[i], "pre-run still RHR must not stay in the strip")
            XCTAssertNil(clipped.spo2[i], "run SpO2 must not stay in the lookback")
        }
        XCTAssertNotNil(clipped.rhr[clipped.rhr.count - 1] ?? clipped.hr.last ?? nil)
    }

    func testSpo2LookbackStaysInsideRestTail() throws {
        let w = try runThenRest(now: 82_030_000, restMinutes: 5, restHR: 62)
        let tail = WatchdogLiveTail.resolve(w)
        let (rhr, spo2) = tail.clipLookbacks(rhr: w.rhr, spo2: w.spo2)
        XCTAssertTrue(spo2.prefix(tail.startIndex).allSatisfy { $0 == nil })
        XCTAssertTrue(rhr.prefix(tail.startIndex).allSatisfy { $0 == nil })
    }

    func testThinRestTailWithoutHRIsCoverageNotQuiet() throws {
        let w = try runThenRest(now: 82_040_000, restMinutes: 4, restHR: nil)
        let tail = WatchdogLiveTail.resolve(w)
        XCTAssertTrue(tail.thinRestCoverage(w.hr))
        let reason = WatchdogQuality.gate(w, tail: tail)
        XCTAssertTrue(reason == .coverage || reason == .stale,
                      "thin rest tail must be unavailable, got \(String(describing: reason))")
        let r = Watchdog.evaluate(window: .success(w), prompt: layer1, nowUnix: w.nowUnix)
        XCTAssertEqual(r.severity, .dataUnavailable)
    }

    func testAllStillWindowCoverageUnchanged() throws {
        let w = try unwrap(WatchdogWindowBuilder.build(
            Watchdog.syntheticFeed(now: 82_050_000, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)))
        let tail = WatchdogLiveTail.resolve(w)
        XCTAssertEqual(tail.startIndex, 0)
        XCTAssertFalse(tail.thinRestCoverage(w.hr))
        XCTAssertNil(WatchdogQuality.gate(w, tail: tail))
    }

    // MARK: F8

    func testSafetyStillBeatsPostWorkoutOnCurrent132() throws {
        let w = try runThenRest(now: 82_060_000, restMinutes: 8, restHR: 132)
        XCTAssertTrue(WatchdogSafety.fired(w), "current 132 still must page")
        let r = Watchdog.evaluate(window: .success(w), prompt: layer1, nowUnix: w.nowUnix)
        XCTAssertEqual(r.severity, .severe)
        XCTAssertTrue(r.shouldNotify)
        XCTAssertEqual(r.eventLabel, WatchdogEventLabel.safetyBound.rawValue)
    }

    func testRecoveredRestIsNotSafetyBound() throws {
        let w = try runThenRest(now: 82_070_000, restMinutes: 8, restHR: 62)
        XCTAssertFalse(WatchdogSafety.fired(w))
        let r = Watchdog.evaluate(window: .success(w), prompt: layer1, nowUnix: w.nowUnix)
        XCTAssertNotEqual(r.eventLabel, WatchdogEventLabel.safetyBound.rawValue)
        XCTAssertTrue(r.eventLabel == WatchdogEventLabel.postWorkout.rawValue
                      || r.eventLabel == WatchdogEventLabel.normalStillAwake.rawValue
                      || r.eventLabel == WatchdogEventLabel.forecastDriftOnly.rawValue,
                      r.eventLabel)
    }

    // MARK: - helpers

    private func seed(store: inout WatchdogPhaseUsualStore, key: WatchdogPhaseKey,
                      days: Int, median: [Double]) {
        for i in 1...days {
            store.writeDay(key: key, dayMedian: median,
                           civilDay: String(format: "2026-09-%02d", i))
        }
    }

    private func sleepUnix(day: Int) -> Int {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = day; c.hour = 1; c.minute = 0; c.second = 0
        return Int(Calendar.current.date(from: c)!.timeIntervalSince1970)
    }

    private func tick(now: Int, hr: Double, motion: Double, previous: WatchdogCarry) -> WatchdogResult {
        var feed = Watchdog.syntheticFeed(now: now, hr: hr, hrv: 48, temp: 33.1, resp: 14, motion: motion)
        let start = now - WatchdogConfig.contextSeconds
        if motion < 0.1 {
            feed.steps = (start..<now).map { StepSample(ts: $0, counter: 1, activityClass: 0) }
            feed.imu = (start..<now).map { WatchdogIMUSample(ts: $0, x: 1, y: 0, z: 0, dynAccel: 0.01) }
        }
        return Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                 prompt: layer1, nowUnix: now, previous: previous)
    }

    private func runThenRest(now: Int, restMinutes: Int, restHR: Double?) throws -> WatchdogWindow {
        var feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let runEnd = now - restMinutes * 60
        feed.hr = feed.hr.compactMap { s in
            if s.ts < runEnd { return HRSample(ts: s.ts, bpm: 148) }
            if let restHR { return HRSample(ts: s.ts, bpm: Int(restHR.rounded())) }
            return nil
        }
        feed.motion = feed.motion.map {
            WatchdogScalarSample(ts: $0.ts, value: $0.ts < runEnd ? 0.85 : 0.02)
        }
        feed.respPerMin = feed.respPerMin.map {
            WatchdogScalarSample(ts: $0.ts, value: $0.ts < runEnd ? 28 : 14)
        }
        feed.skinTempC = feed.skinTempC.map {
            WatchdogScalarSample(ts: $0.ts, value: $0.ts < runEnd ? 34.8 : 33.1)
        }
        return try unwrap(WatchdogWindowBuilder.build(feed))
    }

    private func unwrap(_ r: Result<WatchdogWindow, WatchdogUnavailable>) throws -> WatchdogWindow {
        switch r {
        case .success(let w): return w
        case .failure(let e): throw NSError(domain: "wd32", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "\(e)"])
        }
    }
}
