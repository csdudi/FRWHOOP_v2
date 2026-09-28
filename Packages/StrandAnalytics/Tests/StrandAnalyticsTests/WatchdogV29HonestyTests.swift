import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Feedback 3: no formula usuals, no held minutes, sleep / rest / active / all-day stay separate.
final class WatchdogV29HonestyTests: XCTestCase {

    private let asOf = "2026-09-20"

    private func overnightTape() -> [DailyMetric] {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        return (0..<21).map { i in
            metric(day: LongitudinalBaseline.isoFromEpochDay(t - i),
                   rhr: 58, hrv: 50, spo2: 97, temp: 33.2, resp: 14, steps: 8000)
        }
    }

    private func metric(day: String, rhr: Int?, hrv: Double?, spo2: Double?,
                        temp: Double?, resp: Double?, steps: Int?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv,
                    recovery: nil, strain: nil, exerciseCount: nil, spo2Pct: spo2,
                    skinTempDevC: nil, respRateBpm: resp, steps: steps, avgSdnn: nil,
                    skinTempC: temp, sleepHrOnly: nil)
    }

    func testStubSeriesAreEmptyOnOvernightTape() {
        let days = overnightTape()
        let stubs: [LBSeries] = [
            .awakeRestHR, .awakeActiveHR, .continuousHR,
            .awakeRestHRVLn, .awakeActiveHRVLn, .continuousHRVLn,
            .awakeRestSpO2Mean, .awakeActiveSpO2Mean, .continuousSpO2Mean
        ]
        for series in stubs {
            let obs = LongitudinalBaseline.observations(from: days, series: series)
            XCTAssertTrue(obs.isEmpty, series.rawValue)
            XCTAssertEqual(obs.filter { $0.qualityStatus == .ok }.count, 0, series.rawValue)
        }
    }

    func testSleepSeriesStayOnOwnColumns() {
        let days = overnightTape()
        XCTAssertEqual(LongitudinalBaseline.observations(from: days, series: .sleepRHR).first?.value, 58)
        XCTAssertEqual(LongitudinalBaseline.observations(from: days, series: .sleepHRVLn).first?.value, 50)
        XCTAssertEqual(LongitudinalBaseline.observations(from: days, series: .sleepTemp).first?.value, 33.2)
        XCTAssertEqual(LongitudinalBaseline.observations(from: days, series: .sleepResp).first?.value, 14)
        XCTAssertEqual(LongitudinalBaseline.observations(from: days, series: .sleepSpO2Mean).first?.value, 97)
        XCTAssertEqual(LongitudinalBaseline.observations(from: days, series: .wakingSteps).first?.value, 8000)
    }

    func testPromptDoesNotInferDaytimeFromOvernight() {
        let days = overnightTape()
        let evals = [LBSeries.sleepRHR, .awakeRestHR, .continuousHR, .sleepHRVLn, .awakeRestHRVLn,
                     .sleepTemp, .sleepResp, .sleepSpO2Mean].map { series in
            LongitudinalBaseline.evaluate(asOf: asOf, series: series,
                                          observations: LongitudinalBaseline.observations(from: days, series: series))
        }
        let prompt = UniTSPrompt.from(evaluations: evals)
        XCTAssertNil(prompt.hr)
        XCTAssertNil(prompt.hrvAwake)
        XCTAssertTrue(prompt.hrvAnchoredInSleep)
        XCTAssertNotEqual(prompt.hr ?? -1, 64, "must not be sleep RHR + 6")
        XCTAssertNotEqual(prompt.hrvAwake ?? -1, 44, "must not be sleep HRV × 0.88")
        XCTAssertEqual(prompt.rhr ?? -1, 58, accuracy: 1.5)
        XCTAssertEqual(prompt.hrv ?? -1, 50, accuracy: 2)
        XCTAssertEqual(prompt.temp ?? -1, 33.2, accuracy: 0.3)
        XCTAssertEqual(prompt.resp ?? -1, 14, accuracy: 0.5)
        XCTAssertEqual(prompt.spo2 ?? -1, 97, accuracy: 0.5)
        XCTAssertEqual(prompt.source, .sleep)
    }

    func testDayPeriodsDoNotShareOvernightFormulas() {
        let days = overnightTape()
        let sleep = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR,
            observations: LongitudinalBaseline.observations(from: days, series: .sleepRHR))
        let rest = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .awakeRestHR,
            observations: LongitudinalBaseline.observations(from: days, series: .awakeRestHR))
        let active = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .awakeActiveHR,
            observations: LongitudinalBaseline.observations(from: days, series: .awakeActiveHR))
        let allDay = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .continuousHR,
            observations: LongitudinalBaseline.observations(from: days, series: .continuousHR))
        XCTAssertNotNil(sleep.todayNative)
        XCTAssertNil(rest.todayNative)
        XCTAssertNil(active.todayNative)
        XCTAssertNil(allDay.todayNative)
        XCTAssertNil(rest.copyLong)
        XCTAssertNil(active.copy7)
        XCTAssertNil(allDay.copyLong)
    }

    func testMissingMinutesStayNilForEveryVital() {
        let now = 8_000_000
        let start = now - 1800
        let hr = (start..<now).map { HRSample(ts: $0, bpm: 64) }
        let temp = (start..<(start + 120)).map { WatchdogScalarSample(ts: $0, value: 33.1) }
        let resp = (start..<(start + 120)).map { WatchdogScalarSample(ts: $0, value: 14) }
        let spo2 = (start..<(start + 120)).map { WatchdogScalarSample(ts: $0, value: 97) }
        var rr: [RRInterval] = []
        for t in start..<(start + 300) {
            rr.append(RRInterval(ts: t, rrMs: 900))
        }
        let feed = WatchdogFeed(family: .whoop4, hrSource: .v18, nowUnix: now, hr: hr, rr: rr,
                                skinTempC: temp, respPerMin: resp, spo2Pct: spo2,
                                holdSeeds: WatchdogHoldSeeds(resp: 18, hrv: 80, temp: 35, spo2: 91))
        let win = try! XCTUnwrap(WatchdogWindowBuilder.build(feed).success)
        XCTAssertTrue(win.temp.dropFirst(2).allSatisfy { $0 == nil })
        XCTAssertTrue(win.resp.dropFirst(2).allSatisfy { $0 == nil })
        XCTAssertTrue(win.spo2.dropFirst(2).allSatisfy { $0 == nil })
        XCTAssertFalse(win.hrv.suffix(10).contains { $0 != nil }, "HRV must not hold last RMSSD")
        XCTAssertFalse(win.temp.contains { $0 == 35 })
        XCTAssertFalse(win.resp.contains { $0 == 18 })
        XCTAssertFalse(win.spo2.contains { $0 == 91 })
        XCTAssertFalse(win.hrv.contains { $0 == 80 })
    }

    func testRHRDoesNotFillWalkMinutesFromLastStill() {
        let now = 8_100_000
        let start = now - 1800
        let hr = (start..<now).map { HRSample(ts: $0, bpm: 70) }
        let motion = (start..<now).map { t -> WatchdogScalarSample in
            WatchdogScalarSample(ts: t, value: t < start + 300 ? 0.02 : 0.45)
        }
        let steps = (start..<now).map { t -> StepSample in
            StepSample(ts: t, counter: 1, activityClass: t < start + 300 ? 0 : 1)
        }
        let feed = WatchdogFeed(family: .whoop4, hrSource: .v18, nowUnix: now, hr: hr,
                                motion: motion, steps: steps)
        let win = try! XCTUnwrap(WatchdogWindowBuilder.build(feed).success)
        XCTAssertFalse(win.rhr.compactMap { $0 }.isEmpty)
        XCTAssertTrue(win.rhr.contains { $0 == nil }, "walk minutes must not inherit still RHR")
    }

    func testDaytimeLiveHRVAndSpO2StillExist() {
        let days = overnightTape()
        let evals = [LBSeries.sleepHRVLn, .awakeRestHRVLn, .sleepSpO2Mean, .awakeRestSpO2Mean].map { series in
            LongitudinalBaseline.evaluate(asOf: asOf, series: series,
                                          observations: LongitudinalBaseline.observations(from: days, series: series))
        }
        let prompt = UniTSPrompt.from(evaluations: evals)
        XCTAssertNotNil(prompt.hrv, "overnight HRV usual stays available during the day")
        XCTAssertNotNil(prompt.spo2, "overnight SpO₂ usual stays available during the day")
        XCTAssertNil(prompt.hrvAwake)
        XCTAssertGreaterThan(prompt.hrv ?? 0, 20)
        XCTAssertGreaterThan(prompt.spo2 ?? 0, 90)

        let now = 9_000_000
        let start = now - 1800
        let hr = (start..<now).map { HRSample(ts: $0, bpm: 72) }
        var rr: [RRInterval] = []
        var spo2: [WatchdogScalarSample] = []
        for t in (now - 600)..<now {
            let jitter = (t % 3 == 0) ? 40 : -20
            rr.append(RRInterval(ts: t, rrMs: 850 + jitter))
            spo2.append(WatchdogScalarSample(ts: t, value: 96))
        }
        let feed = WatchdogFeed(family: .whoop4, hrSource: .live2A37, nowUnix: now, hr: hr, rr: rr,
                                spo2Pct: spo2)
        let win = try! XCTUnwrap(WatchdogWindowBuilder.build(feed).success)
        XCTAssertFalse(win.hrv.compactMap { $0 }.isEmpty, "daytime RR must still make RMSSD")
        XCTAssertFalse(win.spo2.compactMap { $0 }.isEmpty, "daytime percent SpO₂ must still enter the window")
        XCTAssertGreaterThan(win.spo2.compactMap { $0 }.last ?? 0, 90)

        let result = Watchdog.evaluate(window: .success(win), prompt: prompt, evaluations: evals,
                                       nowUnix: now)
        let hrv = result.signals.first(where: { $0.name == "HRV" })
        let spo2Sig = result.signals.first(where: { $0.name == "SpO2" })
        XCTAssertNotNil(hrv?.usual)
        XCTAssertNotNil(hrv?.observed)
        XCTAssertNotNil(spo2Sig?.usual)
        XCTAssertNotNil(spo2Sig?.observed)
    }

    func testScoreSkipsNilObservedMinutes() {
        var observed = Array(repeating: Optional(64.0), count: 30)
        var hat = Array(repeating: Optional(64.0), count: 30)
        for i in 5..<30 { observed[i] = nil }
        hat[10] = 90
        let energy = UniTSRuntime.score(observed, hat, floor: 4, personal: 4).energy
        XCTAssertLessThan(energy, 0.5, "later invented hats must not score against missing obs")
    }
}

private extension Result where Success == WatchdogWindow, Failure == WatchdogUnavailable {
    var success: WatchdogWindow? {
        if case .success(let w) = self { return w }
        return nil
    }
}
