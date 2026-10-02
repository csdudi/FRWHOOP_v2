import XCTest
@testable import StrandAnalytics

final class WatchdogV40CloseoutTests: XCTestCase {
    func testDayTapeHRVIsMillisecondsNotLn() throws {
        let now = 97_000_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 62, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        guard case .success(let win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        var tape = LBDayTape(day: "2026-10-01")
        XCTAssertTrue(tape.ingest(window: win, nowUnix: now))
        XCTAssertGreaterThan(tape.restHRV.n, 0)
        let mean = try XCTUnwrap(tape.restHRV.mean)
        XCTAssertGreaterThan(mean, 8)
        XCTAssertLessThan(mean, 250)
        let math = try XCTUnwrap(LongitudinalBaseline.toMath(mean, series: .awakeRestHRVLn))
        XCTAssertEqual(math, log(mean), accuracy: 1e-9)
        XCTAssertNotEqual(math, log(log(mean)), accuracy: 1e-6)
        XCTAssertNil(tape.observation(series: .awakeRestHRVLn), "floor is 8 unique minutes")
    }

    func testOverlappingWindowDoesNotRaiseHRVCount() {
        let now = 97_100_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 62, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        guard case .success(let win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        var tape = LBDayTape(day: "2026-10-01")
        XCTAssertTrue(tape.ingest(window: win, nowUnix: now))
        let n = tape.restHRV.n
        XCTAssertFalse(tape.ingest(window: win, nowUnix: now + 20))
        XCTAssertEqual(tape.restHRV.n, n)
    }

    func testSleepMinuteDoesNotEnterAwakeRest() {
        let now = 97_200_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        guard case .success(var win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        win.activityFeatures = (0..<30).map { _ in
            var row = Array(repeating: 0.0, count: 20)
            row[19] = 1
            return row
        }
        var tape = LBDayTape(day: "2026-10-01")
        _ = tape.ingest(window: win, nowUnix: now)
        XCTAssertEqual(tape.restHR.n, 0)
        XCTAssertGreaterThan(tape.allHR.n, 0)
    }

    func testFirstSevereNotifiesOnce() {
        let lab = WatchdogEventLabel.abnormalMultiDirection
        let (first, r1) = WatchdogNotifyPolicy.decision(
            severity: .severe, openedEpisode: false, safety: false, previousSafety: false,
            fused: 2.5, previousFused: 1.7, recon: 2.5, previousRecon: 1.7,
            eventLabel: lab, episodeId: "wd-1", notifiedSevereEpisodeId: "")
        XCTAssertTrue(first)
        XCTAssertEqual(r1, "first-severe")
        let (second, r2) = WatchdogNotifyPolicy.decision(
            severity: .severe, openedEpisode: false, safety: false, previousSafety: false,
            fused: 2.5, previousFused: 2.5, recon: 2.5, previousRecon: 2.5,
            eventLabel: lab, episodeId: "wd-1", notifiedSevereEpisodeId: "wd-1")
        XCTAssertFalse(second)
        XCTAssertEqual(r2, "stable-episode")
    }

    func testStudentForecastIsNotWearerEarly() {
        XCTAssertFalse(WatchdogForecastRuntime.wearerEarly(
            pathJ: 1.4, allowed: true, severity: .withinLimits, trustPct: 80, persistTicks: 2,
            forecastSource: "student"))
        XCTAssertEqual(WatchdogForecastStep.horizonUnix(nowUnix: 1_000).count, 5)
        XCTAssertEqual(WatchdogForecastStep.horizonUnix(nowUnix: 1_000)[0], 1_060)
        XCTAssertEqual(WatchdogForecastStep.horizonUnix(nowUnix: 1_000)[4], 1_300)
        XCTAssertNotEqual(WatchdogForecastSource.student.rawValue, "official")
    }

    func testSleepIntervalBlocksAwakeRestEvenIfLastRowIsAwake() {
        let now = 97_250_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        guard case .success(var win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        win.activityFeatures = (0..<30).map { _ in Array(repeating: 0.0, count: 20) }
        var tape = LBDayTape(day: "2026-10-01")
        let interval = WatchdogSleepInterval(startUnix: now - 3600, endUnix: now + 60)
        _ = tape.ingest(window: win, nowUnix: now, sleepIntervals: [interval])
        XCTAssertEqual(tape.restHR.n, 0)
        XCTAssertGreaterThan(tape.allHR.n, 0)
    }

    func testBandDoesNotCountSameCivilMinuteTwice() {
        var q = Array(repeating: 0.25, count: 6)
        var anchor = Array(repeating: 1.0, count: 6)
        var n = 0
        var ready = false
        var scale = Array(repeating: 1.0, count: 6)
        var last = 1_000_020
        var nPresent = Array(repeating: 0, count: 6)
        _ = WatchdogBand.update(absResidual: q, eligible: true, q: &q, anchor: &anchor,
                                n: &n, initialized: &ready, scale: &scale,
                                nowUnix: 1_000_050, lastUnix: &last, nPresent: &nPresent)
        XCTAssertEqual(n, 0)
        _ = WatchdogBand.update(absResidual: q, eligible: true, q: &q, anchor: &anchor,
                                n: &n, initialized: &ready, scale: &scale,
                                nowUnix: 1_000_080, lastUnix: &last, nPresent: &nPresent)
        XCTAssertEqual(n, 1)
    }

    func testSparseCoverageIsNotOneFromASinglePair() {
        var series = Array<Double?>(repeating: nil, count: 30)
        series[29] = 33.1
        let c = Watchdog.sparseCoverage(series, startUnix: 1_000_000, nowUnix: 1_001_740,
                                        channel: 3, family: .whoop4)
        XCTAssertLessThan(c, 0.1)
        XCTAssertGreaterThan(c, 0)
    }

    func testThinWindowRestHR135IsSafetySevere() throws {
        let now = 97_300_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 135, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        guard case .success(var win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        if win.hr.count > 4 {
            for i in 0..<(win.hr.count - 3) { win.hr[i] = nil }
        }
        XCTAssertNotNil(WatchdogQuality.gate(win))
        XCTAssertTrue(Watchdog.safetyCap(window: win))
        let r = Watchdog.evaluate(window: .success(win), prompt: UniTSPrompt(), nowUnix: now)
        XCTAssertEqual(r.severity, .severe)
        XCTAssertEqual(r.qualityGate, "safety-during-quality-fail")
        XCTAssertTrue(r.shouldNotify)
        let silent = Watchdog.evaluate(window: .success(win), prompt: UniTSPrompt(),
                                       nowUnix: now, liveAlerts: false)
        XCTAssertFalse(silent.shouldNotify)
    }

    func testPersonalNativeOffIndependentOfHat() {
        let asOf = "2026-06-15"
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var rows: [LBDailyObservation] = []
        for e in (t - 60)...(t - 1) {
            rows.append(LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(e),
                                           value: 50, qualityStatus: .ok, coverage: 40))
        }
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .awakeRestHRVLn,
                                               observations: rows, replay: false)
        XCTAssertTrue(ev.establishedLong, ev.consoleReport)
        XCTAssertTrue(Watchdog.personalNativeOff(hrvMs: 12, evaluations: [ev]))
        XCTAssertFalse(Watchdog.personalNativeOff(hrvMs: 50, evaluations: [ev]))
    }

    func testBackfillInjectDoesNotNotify() {
        let r = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                  nowUnix: 97_400_000, inject: .severe, liveAlerts: false)
        XCTAssertFalse(r.shouldNotify)
    }

    func testMigrateLnHRVBucket() {
        var tape = LBDayTape(day: "2026-10-01")
        tape.restHRV = LBMinuteBucket(sum: log(44), n: 1, lastMinuteUnix: 100)
        tape.migrateHrvFromLnIfNeeded()
        XCTAssertEqual(tape.restHRV.mean ?? 0, 44, accuracy: 1e-6)
    }
}
