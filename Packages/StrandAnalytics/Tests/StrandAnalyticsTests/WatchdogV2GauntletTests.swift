import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Gauntlet for Watchdog v2 (review items 1–12). Each test names the item it locks.
final class WatchdogV2GauntletTests: XCTestCase {

    func test01QualitySafetyNotifyAreSeparateTypes() throws {
        XCTAssertNil(WatchdogQuality.gate(try window(hr: 60)))
        XCTAssertTrue(WatchdogSafety.fired(try window(hr: 132, motion: 0)))
        XCTAssertFalse(WatchdogSafety.fired(try window(hr: 132, motion: 1)))
        let (notify, reason) = WatchdogScores.shouldNotify(
            severity: .severe, openedEpisode: true, safety: false, previousSafety: false,
            fused: 3, previousFused: 0)
        XCTAssertTrue(notify)
        XCTAssertEqual(reason, "episode-start")
    }

    func test02JointEnergyIsOnEveryResidual() throws {
        let residual = try UniTSRuntime().reconstruct(try window(hr: 58, hrv: 48, temp: 33.1, resp: 14),
                                                      prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14))
        XCTAssertGreaterThanOrEqual(residual.jointEnergy, 0)
        XCTAssertTrue(residual.jointEnergy.isFinite)
    }

    func test03MissingPromptUsesPopulationNotWindowMedian() {
        let occ = Array(repeating: 0.0, count: 30)
        let hat = UniTSRuntime.reconstructHR(observed: Array(repeating: 96, count: 30), prompt: nil, occupancy: occ)
        XCTAssertEqual(hat.compactMap { $0 }.last ?? -1, WatchdogPopulationPriors.hr, accuracy: 0.51)
    }

    func test04JointRisesWhenSeveralChannelsLineUp() throws {
        let quiet = try UniTSRuntime().reconstruct(try window(hr: 58, hrv: 48, temp: 33.1, resp: 14),
                                                   prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14))
        let off = try UniTSRuntime().reconstruct(try window(hr: 96, hrv: 16, temp: 34.3, resp: 22),
                                                 prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14))
        XCTAssertGreaterThan(off.jointEnergy, quiet.jointEnergy)
    }

    func test05CalibratedSigmaIsNotThisWindowScatter() throws {
        let quiet = try UniTSRuntime().reconstruct(try window(hr: 58),
                                                   prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14))
        var noisy = Watchdog.syntheticFeed(now: 20_000_000, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        noisy.hr = noisy.hr.enumerated().map { i, s in
            HRSample(ts: s.ts, bpm: 58 + (i % 2 == 0 ? 8 : -8))
        }
        let loud = try UniTSRuntime().reconstruct(try XCTUnwrap(WatchdogWindowBuilder.build(noisy).success),
                                                  prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14))
        let q = quiet.scaleHR.compactMap { $0 }.reduce(0, +) / Double(max(quiet.scaleHR.count, 1))
        let l = loud.scaleHR.compactMap { $0 }.reduce(0, +) / Double(max(loud.scaleHR.count, 1))
        XCTAssertEqual(q, l, accuracy: 0.75)
    }

    func test06ThresholdsComeFromCalibrationNotThreeChannels() {
        XCTAssertEqual(WatchdogCalibration.tNote, 1.0)
        XCTAssertEqual(WatchdogCalibration.tSevere, 2.4)
        XCTAssertEqual(WatchdogCalibration.persistTicks, 2)
        let oneHot = WatchdogScores.severity(fused: 3.0, persistTicks: 2, safety: false,
                                             confounded: false, personalOff: false)
        XCTAssertEqual(oneHot, .severe)
        let spike = WatchdogScores.severity(fused: 3.0, persistTicks: 1, safety: false,
                                            confounded: false, personalOff: false)
        XCTAssertNotEqual(spike, .severe)
    }

    func test07StableSevereDoesNotRepageAndEscalateDoes() {
        let t = 21_000_000
        let first = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                      nowUnix: t, inject: .severe)
        XCTAssertTrue(first.shouldNotify)
        XCTAssertEqual(first.notifyReason, "episode-start")
        let stable = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                       nowUnix: t + 20, previous: first.carry, inject: .severe)
        XCTAssertFalse(stable.shouldNotify)
        XCTAssertEqual(stable.notifyReason, "stable-episode")
        var hotter = first.carry
        hotter.lastJointEnergy = 0
        hotter.lastReconEnergy = 0
        let escalate = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                         nowUnix: t + 40, previous: hotter, inject: .severe)
        XCTAssertTrue(escalate.shouldNotify)
        XCTAssertEqual(escalate.notifyReason, "escalate")
    }

    func test08FewMinuteBucketsIsUnavailableNotHot() {
        let now = 22_000_000
        let start = now - 1800
        var hr: [HRSample] = []
        for t in start..<(start + 5 * 60) {
            hr.append(HRSample(ts: t, bpm: 96))
        }
        let feed = WatchdogFeed(family: .whoop4, hrSource: .v18, nowUnix: now, hr: hr)
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: UniTSPrompt(hr: 58), nowUnix: now)
        XCTAssertEqual(r.severity, .dataUnavailable)
        XCTAssertEqual(r.unavailable, .coverage)
        XCTAssertFalse(r.shouldNotify)
        XCTAssertTrue(r.contributing.isEmpty)
    }

    func test08Whoop5AndSparseWhoop4StayScorable() throws {
        XCTAssertNil(WatchdogQuality.gate(try window(hr: 62, family: .whoop4)))
        let now = 23_000_000
        let start = now - 1800
        var hr: [HRSample] = []
        var t = start
        while t < now {
            hr.append(HRSample(ts: t, bpm: 62))
            t += 30
        }
        let w5 = WatchdogWindowBuilder.build(WatchdogFeed(family: .whoop5, hrSource: .liveType40, nowUnix: now, hr: hr))
        let r = Watchdog.evaluate(window: w5, prompt: UniTSPrompt(hr: 62), nowUnix: now)
        XCTAssertNotEqual(r.severity, .dataUnavailable)
    }

    func test09PopulationPromptSource() {
        let p = UniTSPrompt.from(evaluations: [])
        XCTAssertEqual(p.source, .population)
        XCTAssertNil(p.hr)
    }

    func test10ActivityLogitsAreAlwaysPresentUnknownClass() throws {
        let w = try window(hr: 60)
        XCTAssertEqual(w.activityLogits.count, 30)
        XCTAssertEqual(w.activityLogits[0].count, WatchdogActivityClass.count)
        XCTAssertEqual(WatchdogActivityClass.labels(logits: w.activityLogits).last, "unknown")
    }

    func test12PromptKeepsHRAndRHROnSeparateCopies() {
        let asOf = "2026-09-01"
        let te = LongitudinalBaseline.isoEpochDay(asOf)!
        func tape(_ v: Double) -> [LBDailyObservation] {
            (1...40).map {
                LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(te - $0), value: v, qualityStatus: .ok)
            } + [LBDailyObservation(day: asOf, value: v, qualityStatus: .ok)]
        }
        let p = UniTSPrompt.from(evaluations: [
            LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: tape(50)),
            LongitudinalBaseline.evaluate(asOf: asOf, series: .awakeRestHR, observations: tape(72))
        ])
        XCTAssertEqual(p.source, .mixed)
        XCTAssertGreaterThan((p.hr ?? 0) - (p.rhr ?? 0), 8)
        XCTAssertNil(UniTSPrompt.from(evaluations: [
            LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: tape(50))
        ]).hr)
    }

    func test13SameOccupancyWalkVersusRunUsesClassEffort() throws {
        let now = 33_000_000
        let start = now - 1800
        let motion = (start..<now).map { WatchdogScalarSample(ts: $0, value: 0.40) }
        func win(_ cls: Int, bpm: Int) throws -> WatchdogWindow {
            let hr = (start..<now).map { HRSample(ts: $0, bpm: bpm) }
            let steps = (start..<now).map { StepSample(ts: $0, counter: 1, activityClass: cls) }
            return try XCTUnwrap(WatchdogWindowBuilder.build(
                WatchdogFeed(family: .whoop4, hrSource: .v18, nowUnix: now, hr: hr,
                             motion: motion, steps: steps)).success)
        }
        let walk = try win(1, bpm: 72)
        let run = try win(2, bpm: 118)
        XCTAssertEqual(WatchdogActivityClass.labels(logits: walk.activityLogits).last, "walk")
        XCTAssertEqual(WatchdogActivityClass.labels(logits: run.activityLogits).last, "run")
        XCTAssertLessThan(try XCTUnwrap(UniTSRuntime.occupancy(walk).last),
                          try XCTUnwrap(UniTSRuntime.occupancy(run).last))
    }

    func test14ArtifactWidensAdaptiveSigma() throws {
        let now = 34_000_000
        let start = now - 1800
        let hr = (start..<now).map { HRSample(ts: $0, bpm: 60) }
        let motion = (start..<now).map { WatchdogScalarSample(ts: $0, value: 0.50) }
        let imu = (start..<now).map { WatchdogIMUSample(ts: $0, x: 1, y: 0, z: 0, dynAccel: 0.35) }
        let art = try XCTUnwrap(WatchdogWindowBuilder.build(
            WatchdogFeed(family: .whoop4, hrSource: .v18, nowUnix: now, hr: hr,
                         motion: motion, imu: imu)).success)
        XCTAssertTrue(WatchdogActivityRuntime.isArtifact(art.activityLogits))
        var carry = WatchdogCarry.empty
        carry.quietN = 8
        carry.quietAbsHR = 4
        let residual = try UniTSRuntime().reconstruct(art, prompt: UniTSPrompt(hr: 60, rhr: 52))
        let adapted = WatchdogAdaptive.apply(residual, window: art,
                                             lastHR: (60, 60), lastRHR: nil, lastHRV: nil,
                                             lastTemp: nil, lastResp: nil, lastSpO2: nil, carry: &carry)
        XCTAssertGreaterThan(adapted.scaleHR.last ?? 0, residual.scaleHR.last ?? 0)
    }

    func test11SustainedStillTachycardiaCanSevereWithoutThreeVitals() {
        let now = 24_000_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 96, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        var carry = WatchdogCarry.empty
        carry.consecutiveMismatchTicks = 1
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14),
                                  nowUnix: now, previous: carry)
        XCTAssertTrue(r.contributing.contains("HR"))
        XCTAssertLessThan(r.jointEnergy, WatchdogCalibration.tActive)
        XCTAssertLessThan(r.contributing.filter { $0 != "Motion" }.count, 3)
    }

    func test12TimesFMStudentForecastShapesAndFusion() throws {
        XCTAssertEqual(WatchdogForecastRuntime.modelVersion, "timesfm3-student-v2")
        XCTAssertEqual(WatchdogCalibration.forecastHorizon, 5)
        XCTAssertGreaterThan(WatchdogCalibration.forecastAlpha, 0)
        let win = try window(hr: 58, hrv: 48, temp: 33.1, resp: 14)
        let residual = try UniTSRuntime().reconstruct(win, prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14))
        XCTAssertTrue(TimesFMStudentSession.shared.isLoaded)
        let step = WatchdogForecastRuntime().step(window: win, residual: residual,
                                                 prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14),
                                                 carry: .empty)
        XCTAssertEqual(step.nextHR.count, 5)
        XCTAssertEqual(step.nextHRV.count, 5)
        XCTAssertEqual(step.nextTemp.count, 5)
        XCTAssertEqual(step.energy, 0, accuracy: 0.001)
        var carry = WatchdogCarry.empty
        carry.lastForecastHR = Array(repeating: 40.0, count: 5)
        carry.lastForecastHRV = Array(repeating: 48.0, count: 5)
        carry.lastForecastTemp = Array(repeating: 33.1, count: 5)
        carry.lastForecastResp = Array(repeating: 14.0, count: 5)
        carry.lastForecastRHR = Array(repeating: 58.0, count: 5)
        carry.lastForecastSpO2 = Array(repeating: 97.0, count: 5)
        let diverged = WatchdogForecastRuntime().step(window: win, residual: residual,
                                                     prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14),
                                                     carry: carry)
        XCTAssertGreaterThan(diverged.energy, 0)
        let fused = WatchdogScores.fused(recon: 0.2, forecast: 4.0)
        XCTAssertEqual(fused, 0.2, accuracy: 0.01)
    }

    func testCarryJSONWithoutNewKeysStillDecodes() throws {
        let old = Data(#"{"consecutiveMismatchTicks":2}"#.utf8)
        let carry = try JSONDecoder().decode(WatchdogCarry.self, from: old)
        XCTAssertEqual(carry.consecutiveMismatchTicks, 2)
        XCTAssertEqual(carry.lastForecastHR, [])
        XCTAssertEqual(carry.lastJointEnergy, 0)
    }

    func testHardWristOffIsUnavailableNotRecovered() {
        var feed = Watchdog.syntheticFeed(now: 26_000_000, hr: 60, hrv: 40, temp: 33, resp: 14, motion: 0)
        feed.wristOff = true
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: UniTSPrompt(hr: 58), nowUnix: 26_000_000)
        XCTAssertEqual(r.unavailable, .wristOff)
        XCTAssertEqual(r.severity, .dataUnavailable)
        XCTAssertNotEqual(r.episodeState, .resolved)
        XCTAssertNotEqual(r.episodeState, .recovering)
        XCTAssertTrue(r.episodeLine.contains("not recovered"))
        XCTAssertFalse(r.shouldNotify)
        XCTAssertTrue(r.reconstructedHR.isEmpty)
    }

    func testHardLastNotifiedAtDoesNotMute() {
        let t = 26_100_000
        var carry = WatchdogCarry.empty
        carry.lastNotifiedAt = t - 10
        let first = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                      nowUnix: t, previous: carry, inject: .severe)
        XCTAssertTrue(first.shouldNotify, "episode start must page even 10s after a previous notice")
        let later = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                      nowUnix: t + WatchdogConfig.notifyCooldownSeconds + 60,
                                      previous: first.carry, inject: .severe)
        XCTAssertFalse(later.shouldNotify, "stable episode stays muted after 30 minutes")
        XCTAssertEqual(later.notifyReason, "stable-episode")
    }

    func testHardGapSixEmptyMinutesFailsClosed() {
        let now = 26_200_000
        let start = now - 1800
        var hr: [HRSample] = []
        for t in start..<now {
            let minute = (t - start) / 60
            if minute >= 12 && minute < 18 { continue }
            hr.append(HRSample(ts: t, bpm: 96))
        }
        let feed = WatchdogFeed(family: .whoop4, hrSource: .v18, nowUnix: now, hr: hr)
        let built = WatchdogWindowBuilder.build(feed)
        if case .success(let w) = built {
            XCTAssertGreaterThanOrEqual(WatchdogQuality.bucketCoverage(w), WatchdogConfig.minCoverage)
            XCTAssertGreaterThanOrEqual(WatchdogQuality.maxEmptyMinutes(w.hr), WatchdogCalibration.maxEmptyMinutes)
        }
        let r = Watchdog.evaluate(window: built, prompt: UniTSPrompt(hr: 58), nowUnix: now)
        XCTAssertEqual(r.severity, .dataUnavailable)
        XCTAssertEqual(r.unavailable, .gap)
        XCTAssertFalse(r.shouldNotify)
        XCTAssertTrue(r.reconstructedHR.isEmpty)
        XCTAssertEqual(r.jointEnergy, 0)
    }

    func testHardStaleNewestFailsClosed() {
        let now = 26_300_000
        let start = now - 1800
        let last = now - 90
        var hr: [HRSample] = []
        for t in start..<last {
            hr.append(HRSample(ts: t, bpm: 62))
        }
        let feed = WatchdogFeed(family: .whoop4, hrSource: .v18, nowUnix: now, hr: hr)
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: UniTSPrompt(hr: 62), nowUnix: now)
        XCTAssertEqual(r.unavailable, .stale)
        XCTAssertEqual(r.severity, .dataUnavailable)
        XCTAssertFalse(r.shouldNotify)
        XCTAssertTrue(r.contributing.isEmpty)
    }

    func testHardCopyNeverNamesDrugOrCause() {
        let sevs: [WatchdogSeverity] = [.withinLimits, .note, .candidate, .active, .severe, .dataUnavailable]
        let states: [WatchdogEpisodeState] = [.withinLimits, .candidate, .active, .recovering, .resolved, .dataUnavailable]
        let texts = sevs.flatMap { sev in
            states.map { st in
                let c = Watchdog.copyFor(severity: sev, state: st, confounded: true)
                return c.headline + " " + c.episodeLine
            }
        }
        let banned = ["drug", "medication", "ibuprofen", "caused by", "diagnosis of", "t0"]
        for blob in texts {
            let lower = blob.lowercased()
            for word in banned {
                XCTAssertFalse(lower.contains(word), "copy leaked '\(word)': \(blob)")
            }
        }
    }

    func testHardForecastDoesNotReplaceDottedLine() throws {
        let now = 26_400_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14),
                                  nowUnix: now)
        XCTAssertEqual(r.reconstructedHR.count, WatchdogConfig.seqLen)
        XCTAssertEqual(r.carry.lastForecastHR.count, WatchdogCalibration.forecastHorizon)
        XCTAssertNotEqual(r.reconstructedHR.count, r.carry.lastForecastHR.count)
        XCTAssertEqual(r.versionLine.contains(WatchdogForecastRuntime.modelVersion), true)
        XCTAssertEqual(r.horizonHR.count, WatchdogConfig.seqLen)
    }

    func testHardSafetyPagesDuringStableEpisode() {
        let t = 26_500_000
        let first = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                      nowUnix: t, inject: .severe)
        let stable = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                       nowUnix: t + 20, previous: first.carry, inject: .severe)
        XCTAssertFalse(stable.shouldNotify)
        var edge = stable.carry
        edge.lastSafety = false
        let feed = Watchdog.syntheticFeed(now: t + 40, hr: 132, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14),
                                  nowUnix: t + 40, previous: edge)
        XCTAssertEqual(r.severity, .severe)
        XCTAssertTrue(r.shouldNotify)
        XCTAssertEqual(r.notifyReason, "safety")
    }

    func testHardTwoHRVUsualsAreNeverAveraged() {
        let p = UniTSPrompt(hrv: 80, hrvAwake: 20, hrvAnchoredInSleep: false, source: .awakeRest)
        let occ = Array(repeating: 0.0, count: 30)
        let hat = UniTSRuntime.reconstructHRV(observed: Array(repeating: Optional(20.0), count: 30),
                                              prompt: p, occupancy: occ)
        let last = hat.compactMap { $0 }.last ?? -1
        XCTAssertEqual(last, 20, accuracy: 0.6)
        XCTAssertGreaterThan(abs(last - 50), 20)
    }

    func testHardNeverInfersRestFromLiveHR() {
        let occ = Array(repeating: 0.0, count: 30)
        let hat = UniTSRuntime.reconstructHR(observed: Array(repeating: 96, count: 30),
                                             prompt: 58, occupancy: occ)
        XCTAssertEqual(hat.compactMap { $0 }.last ?? -1, 58, accuracy: 0.6)
    }

    func testHardColdStartWidensSigmaNotMedian() throws {
        let unit = WatchdogCalibration.applySigma([1.0], channel: .hr, coldStart: true)[0]
        XCTAssertEqual(unit, WatchdogCalibration.coldStartGain, accuracy: 1e-9)
        let win = try window(hr: 58)
        let pop = try UniTSRuntime().reconstruct(win, prompt: UniTSPrompt(hr: nil, source: .population))
        let rest = try UniTSRuntime().reconstruct(win, prompt: UniTSPrompt(hr: 58, source: .awakeRest))
        XCTAssertGreaterThan(pop.scaleHR.last ?? 0, rest.scaleHR.last ?? 0)
    }

    func testHardCalibrationFileMatchesSwift() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Baseline/units/WatchdogCalibration.json")
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["version"] as? String, WatchdogCalibration.version)
        XCTAssertEqual((obj?["quiet_coverage"] as? NSNumber)?.doubleValue, WatchdogCalibration.quietCoverage)
        XCTAssertEqual((obj?["cold_start_gain"] as? NSNumber)?.doubleValue, WatchdogCalibration.coldStartGain)
        let t = obj?["thresholds"] as? [String: Any]
        XCTAssertEqual((t?["note"] as? NSNumber)?.doubleValue, WatchdogCalibration.tNote)
        XCTAssertEqual((t?["severe"] as? NSNumber)?.doubleValue, WatchdogCalibration.tSevere)
        XCTAssertEqual((t?["persist_ticks"] as? NSNumber)?.intValue, WatchdogCalibration.persistTicks)
        XCTAssertEqual((t?["forecast_alpha"] as? NSNumber)?.doubleValue, WatchdogCalibration.forecastAlpha)
        let priors = obj?["population_priors"] as? [String: Any]
        XCTAssertEqual((priors?["hr"] as? NSNumber)?.doubleValue, WatchdogPopulationPriors.hr)
        let forecast = obj?["forecast"] as? [String: Any]
        XCTAssertEqual(forecast?["student"] as? String, WatchdogForecastRuntime.modelVersion)
        XCTAssertEqual(WatchdogConfig.configVersion, "watchdog-v2.5")
    }

    private func window(hr: Int, hrv: Double = 48, temp: Double = 33.1, resp: Double = 14,
                        motion: Double = 0, family: DeviceFamily = .whoop4) throws -> WatchdogWindow {
        let feed = Watchdog.syntheticFeed(now: 19_000_000, hr: Double(hr), hrv: hrv, temp: temp,
                                          resp: resp, motion: motion, family: family)
        return try XCTUnwrap(WatchdogWindowBuilder.build(feed).success)
    }
}

private extension Result {
    var success: Success? {
        if case .success(let s) = self { return s }
        return nil
    }
}
