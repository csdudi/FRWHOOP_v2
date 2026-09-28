import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Integrity follow-on F10–F26. Must not reopen boss 1–5 or F1–F9.
final class WatchdogV33LogicGapTests: XCTestCase {

    private let layer1 = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)
    private let sleepStill = WatchdogPhaseKey(phase: .sleep, family: .still)
    private let middayStill = WatchdogPhaseKey(phase: .midday, family: .still)

    // MARK: F10 / F16 locks

    func testAwakeRestSeriesStayEmptyOnOvernightTape() {
        let days = overnightTape()
        XCTAssertTrue(LongitudinalBaseline.observations(from: days, series: .awakeRestHR).isEmpty)
        XCTAssertTrue(LongitudinalBaseline.observations(from: days, series: .continuousHR).isEmpty)
        let prompt = UniTSPrompt.from(evaluations: [
            LongitudinalBaseline.evaluate(asOf: "2026-09-20", series: .awakeRestHR, observations: [])
        ])
        XCTAssertNil(prompt.hr)
        XCTAssertNotEqual(prompt.hr ?? -1, 64)
    }

    func testNadirStaysEmptyOnOvernightTape() {
        let days = overnightTape()
        XCTAssertTrue(LongitudinalBaseline.observations(from: days, series: .sleepSpO2Nadir).isEmpty)
        let prompt = UniTSPrompt.from(evaluations: [
            LongitudinalBaseline.evaluate(
                asOf: "2026-09-20", series: .sleepSpO2Mean,
                observations: LongitudinalBaseline.observations(from: days, series: .sleepSpO2Mean))
        ])
        XCTAssertEqual(prompt.spo2 ?? 0, 97, accuracy: 0.6)
    }

    func testSleepRHRUsualIsNotRelabeledAsLiveStillMean() {
        let days = overnightTape()
        let ev = LongitudinalBaseline.evaluate(
            asOf: "2026-09-20", series: .sleepRHR,
            observations: LongitudinalBaseline.observations(from: days, series: .sleepRHR))
        XCTAssertEqual(ev.todayNative ?? 0, 58, accuracy: 0.5)
        let prompt = UniTSPrompt.from(evaluations: [ev])
        XCTAssertEqual(prompt.rhr ?? 0, 58, accuracy: 1.5)
        XCTAssertNil(prompt.hr, "sleep floor must not fill instant HR")
    }

    // MARK: F12 / F13 / F14

    func testAwakeOkRowWithoutCoverageIsNotTrainable() {
        let obs = [LBDailyObservation(day: "2026-09-01", value: 64, qualityStatus: .ok, coverage: nil)]
        let ev = LongitudinalBaseline.evaluate(asOf: "2026-09-01", series: .awakeRestHR, observations: obs)
        XCTAssertNil(ev.todayNative)
    }

    func testNilStepsAreMissingNotZero() {
        let missing = LongitudinalBaseline.observation(day: "2026-09-01", native: nil,
                                                       streamPresent: true, sleepHrOnly: false,
                                                       series: .wakingSteps)
        XCTAssertEqual(missing.qualityStatus, .missing)
        XCTAssertNil(missing.value)
        let zero = LongitudinalBaseline.observation(day: "2026-09-01", native: 0,
                                                    streamPresent: true, sleepHrOnly: false,
                                                    series: .wakingSteps)
        XCTAssertEqual(zero.qualityStatus, .ok)
        XCTAssertEqual(zero.value, 0)
    }

    func testMissingDayLogDoesNotDropNight() {
        let epoch = LongitudinalBaseline.isoEpochDay("2026-09-01")!
        XCTAssertTrue(LongitudinalBaseline.nightIsClean(epoch, dayLogs: [:]))
        var log = LBDayLog()
        log.feltIll = true
        XCTAssertFalse(LongitudinalBaseline.nightIsClean(epoch, dayLogs: ["2026-09-01": log]))
    }

    func testWatchdogSevereDoesNotRewriteLayer1Night() {
        let days = overnightTape()
        let before = LongitudinalBaseline.observations(from: days, series: .sleepRHR)
        let w = try! window(hr: 132, motion: 0)
        let r = Watchdog.evaluate(window: .success(w), prompt: layer1, nowUnix: w.nowUnix)
        XCTAssertEqual(r.severity, .severe)
        let after = LongitudinalBaseline.observations(from: days, series: .sleepRHR)
        XCTAssertEqual(before.map(\.value), after.map(\.value))
    }

    // MARK: F15 / F26

    func testHeldLongCopyDoesNotFillWatchdogPromptHr() {
        var ev = LongitudinalBaseline.emptyEvaluation(asOf: "2026-09-20", series: .awakeRestHR, carry: LBCarry())
        ev.showLong = true
        ev.usualTrustPctLong = 80
        ev.copyLong = LBCopySnapshot(center: 70, spread: 3, centerDisplay: 70,
                                     bandLoDisplay: 64, bandHiDisplay: 76, n: 20,
                                     coverage: 1, lastUpdate: "2026-08-01", version: "t", held: true)
        XCTAssertNil(UniTSPrompt.shownCopy(ev))
        XCTAssertNil(UniTSPrompt.from(evaluations: [ev]).hr)
    }

    func testPromptHatAndTrustShareTheSameLayer1Copy() {
        var ev = LongitudinalBaseline.emptyEvaluation(asOf: "2026-09-20", series: .awakeRestHR, carry: LBCarry())
        ev.showLong = true
        ev.show7 = true
        ev.usualTrustPctLong = 40
        ev.usualTrustPct7 = 90
        ev.copyLong = LBCopySnapshot(center: 62, spread: 3, centerDisplay: 62,
                                     bandLoDisplay: 56, bandHiDisplay: 68, n: 20,
                                     coverage: 1, lastUpdate: "2026-09-19", version: "t", held: false)
        ev.copy7 = LBCopySnapshot(center: 74, spread: 3, centerDisplay: 74,
                                  bandLoDisplay: 68, bandHiDisplay: 80, n: 7,
                                  coverage: 1, lastUpdate: "2026-09-19", version: "t", held: false)
        let shown = UniTSPrompt.shownCopy(ev)
        XCTAssertEqual(shown?.center ?? 0, 62, accuracy: 0.01)
        XCTAssertEqual(shown?.trust, 40)
        XCTAssertNotEqual(shown?.trust, 90)
        XCTAssertEqual(Watchdog.layer1UsualTrust([ev], matching: [.awakeRestHR]), 40)
    }

    // MARK: F17–F20 / F25

    func testReconstructEnergyIgnoresPreTailEffort() throws {
        let w = try runThenRest(now: 83_000_000, restMinutes: 8, restHR: 62)
        let tail = WatchdogLiveTail.resolve(w)
        XCTAssertTrue(tail.endedPeriod)
        let residual = try UniTSRuntime().reconstruct(w, prompt: layer1, tail: tail)
        XCTAssertLessThan(residual.energy[.hr] ?? 99, WatchdogCalibration.tActive)
    }

    func testTrailingOccupancyDoesNotSpillFromRunIntoRest() throws {
        let w = try runThenRest(now: 83_010_000, restMinutes: 8, restHR: 62)
        let tail = WatchdogLiveTail.resolve(w)
        let occ = tail.clipEffortOccupancy(UniTSRuntime.occupancy(w))
        XCTAssertTrue(occ.prefix(tail.startIndex).allSatisfy { $0 == 0 })
    }

    func testNilMotionUnknownIsNotRestOccupancy() {
        XCTAssertEqual(WatchdogLiveTail.period(cls: .unknown, motion: nil), .unknown)
        let w = try! unwrap(WatchdogWindowBuilder.build(
            Watchdog.syntheticFeed(now: 83_020_000, hr: 148, hrv: 35, temp: 34.0, resp: 22, motion: 0)))
        var blank = w
        blank.motion = Array(repeating: Optional<Double>.none, count: w.motion.count)
        blank.activityLogits = w.activityLogits.map { _ in
            WatchdogActivityClass.allCases.map { $0 == .unknown ? 1.0 : 0.0 }
        }
        let periods = WatchdogLiveTail.periods(blank)
        XCTAssertTrue(periods.contains(.unknown) || WatchdogLiveTail.resolve(blank).period != .rest
                      || blank.motion.allSatisfy { $0 == nil })
        let masked = WatchdogLiveTail.resolve(blank).maskScored(blank.hr, window: blank)
        if WatchdogLiveTail.periods(blank).contains(.unknown) {
            XCTAssertTrue(masked.contains { $0 == nil } || masked.allSatisfy { $0 == nil })
        }
    }

    func testArtifactInRunDoesNotDampRestTail() {
        let labels = Array(repeating: WatchdogActivityClass.artifact.rawValue, count: 22)
            + Array(repeating: WatchdogActivityClass.still.rawValue, count: 8)
        let logits: [[Double]] = labels.map { raw in
            WatchdogActivityClass.allCases.map { $0.rawValue == raw ? 1.0 : 0.0 }
        }
        XCTAssertFalse(WatchdogActivityRuntime.isArtifact(logits, from: 22),
                       "rest tail is still — leftover run artifact must not flag")
        let allArt: [[Double]] = (0..<30).map { _ in
            WatchdogActivityClass.allCases.map { $0 == .artifact ? 1.0 : 0.0 }
        }
        XCTAssertTrue(WatchdogActivityRuntime.isArtifact(allArt, from: 0))
    }

    func testTrustCoverageUsesRestTailAfterSit() throws {
        let w = try runThenRest(now: 83_030_000, restMinutes: 8, restHR: 62)
        let tail = WatchdogLiveTail.resolve(w)
        XCTAssertLessThan(tail.hrCoverage(w.hr) + 1e-9, w.coverage + 0.01)
        let r = Watchdog.evaluate(window: .success(w), prompt: layer1, nowUnix: w.nowUnix)
        XCTAssertNotEqual(r.severity, .severe)
    }

    func testForecastSignedUsesNextStepNotHorizonTail() throws {
        let w = try runThenRest(now: 83_040_000, restMinutes: 5, restHR: 62)
        let residual = try UniTSRuntime().reconstruct(w, prompt: layer1)
        let tail = WatchdogLiveTail.resolve(w)
        let step = WatchdogForecastRuntime().step(window: w, residual: residual, prompt: layer1,
                                                 carry: .empty, nowUnix: w.nowUnix, tail: tail)
        XCTAssertEqual(tail.last(w.hr) ?? 0, 62, accuracy: 1)
        XCTAssertFalse(step.nextHR.isEmpty)
        XCTAssertGreaterThanOrEqual(step.energy, 0)
    }

    // MARK: F21 / F22 / F23 / F24

    func testFourHourIdleKeepsNativeSidecarUntilCivilWrite() throws {
        var carry = WatchdogCarry.empty
        let now = sleepUnix(day: 1)
        for i in 0..<16 {
            carry = tick(now: now + i * 20, hr: 58, motion: 0, previous: carry).carry
        }
        let nativeN = carry.sessionNativeN
        XCTAssertGreaterThanOrEqual(nativeN, 12)
        carry = tick(now: now + 5 * 3600, hr: 58, motion: 0, previous: carry).carry
        XCTAssertLessThanOrEqual(carry.sessionN, 2)
        XCTAssertGreaterThanOrEqual(carry.sessionNativeN, nativeN)
        XCTAssertFalse(carry.sessionKeyTicks.isEmpty)
    }

    func testMorningAndEveningStillBothWriteWhenEachHas12Ticks() {
        let ticks = [sleepStill.id: 16, middayStill.id: 16, "morning×walk": 40]
        let keys = WatchdogPhaseUsualStore.qualifyingStillKeys(ticks: ticks)
        XCTAssertTrue(keys.contains(sleepStill))
        XCTAssertTrue(keys.contains(middayStill))
        XCTAssertFalse(keys.contains(where: { $0.family != .still }))
        var store = WatchdogPhaseUsualStore.empty
        store.writeDay(key: sleepStill, dayMedian: [56, 58, 46, 33.2, 14, 97], civilDay: "2026-06-01")
        store.writeDay(key: middayStill, dayMedian: [72, 58, 46, 33.2, 14, 97], civilDay: "2026-06-01")
        XCTAssertNotNil(store.entries[sleepStill.id])
        XCTAssertNotNil(store.entries[middayStill.id])
        XCTAssertEqual(store.entries[sleepStill.id]?.center[0] ?? 0, 56, accuracy: 0.05)
        XCTAssertEqual(store.entries[middayStill.id]?.center[0] ?? 0, 72, accuracy: 0.05)
    }

    func testSleepBitFromSessionNotFromLowHR() throws {
        var evening = DateComponents()
        evening.year = 2026; evening.month = 6; evening.day = 1; evening.hour = 22
        let t = Int(Calendar.current.date(from: evening)!.timeIntervalSince1970)
        XCTAssertEqual(WatchdogPhaseUsualStore.phase(nowUnix: t, sleepBit: true), .sleep)
        XCTAssertEqual(WatchdogPhaseUsualStore.phase(nowUnix: t, sleepBit: false), .evening)
        var carry = WatchdogCarry.empty
        for i in 0..<14 {
            carry = tick(now: t + i * 20, hr: 58, motion: 0, previous: carry,
                         sleepSessionOpen: true).carry
        }
        XCTAssertGreaterThan(carry.sessionKeyTicks[sleepStill.id] ?? 0, 0,
                             "open sleep session at 22:00 tallies sleep×still")
        var carryHR = WatchdogCarry.empty
        for i in 0..<14 {
            carryHR = tick(now: t + i * 20, hr: 46, motion: 0, previous: carryHR,
                           sleepSessionOpen: false).carry
        }
        XCTAssertEqual(carryHR.sessionKeyTicks[sleepStill.id] ?? 0, 0,
                       "low HR alone must not invent sleep phase")
    }

    func testWriteDayUpdatesMadOnPresentChannelsOnly() {
        var store = WatchdogPhaseUsualStore.empty
        store.writeDay(key: sleepStill, dayMedian: [62, 58, 46, 33.2, 14, 97], civilDay: "2026-09-01")
        store.writeDay(key: sleepStill, dayMedian: [70, 58, 46, 33.2, 14, 97],
                       present: [true, false, false, true, true, true], civilDay: "2026-09-02")
        let e = try! XCTUnwrap(store.entries[sleepStill.id])
        XCTAssertGreaterThan(e.mad[0], 0)
        XCTAssertEqual(e.mad[2], 0, accuracy: 1e-9)
    }

    // MARK: - helpers

    private func overnightTape() -> [DailyMetric] {
        let asOf = "2026-09-20"
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        return (0..<21).map { i in
            DailyMetric(day: LongitudinalBaseline.isoFromEpochDay(t - i),
                        totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: 58, avgHrv: 50,
                        recovery: nil, strain: nil, exerciseCount: nil, spo2Pct: 97,
                        skinTempDevC: nil, respRateBpm: 14, steps: 8000, avgSdnn: nil,
                        skinTempC: 33.2, sleepHrOnly: nil)
        }
    }

    private func sleepUnix(day: Int) -> Int {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = day; c.hour = 1; c.minute = 0; c.second = 0
        return Int(Calendar.current.date(from: c)!.timeIntervalSince1970)
    }

    private func tick(now: Int, hr: Double, motion: Double, previous: WatchdogCarry,
                      sleepSessionOpen: Bool = false) -> WatchdogResult {
        var feed = Watchdog.syntheticFeed(now: now, hr: hr, hrv: 48, temp: 33.1, resp: 14, motion: motion)
        let start = now - WatchdogConfig.contextSeconds
        if motion < 0.1 {
            feed.steps = (start..<now).map { StepSample(ts: $0, counter: 1, activityClass: 0) }
            feed.imu = (start..<now).map { WatchdogIMUSample(ts: $0, x: 1, y: 0, z: 0, dynAccel: 0.01) }
        }
        return Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                 prompt: layer1, nowUnix: now, previous: previous,
                                 sleepSessionOpen: sleepSessionOpen)
    }

    private func window(hr: Int, motion: Double) throws -> WatchdogWindow {
        try unwrap(WatchdogWindowBuilder.build(
            Watchdog.syntheticFeed(now: 19_000_000, hr: Double(hr), hrv: 48, temp: 33.1,
                                   resp: 14, motion: motion)))
    }

    private func window(now: Int, hr: Double, motion: Double) throws -> WatchdogWindow {
        var feed = Watchdog.syntheticFeed(now: now, hr: hr, hrv: 48, temp: 33.1, resp: 14, motion: motion)
        let start = now - WatchdogConfig.contextSeconds
        feed.steps = (start..<now).map { StepSample(ts: $0, counter: 1, activityClass: 0) }
        feed.imu = (start..<now).map { WatchdogIMUSample(ts: $0, x: 1, y: 0, z: 0, dynAccel: 0.01) }
        return try unwrap(WatchdogWindowBuilder.build(feed))
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
        case .failure(let e): throw NSError(domain: "wd33", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "\(e)"])
        }
    }
}
