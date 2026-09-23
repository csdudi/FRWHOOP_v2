import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class WatchdogWindowTests: XCTestCase {

    func testWhoop4OneHzThirtyMinutesIsAvailable() {
        let now = 1_800_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 60, hrv: 48, temp: 33, resp: 14, motion: 0, family: .whoop4)
        switch WatchdogWindowBuilder.build(feed) {
        case .failure(let r): XCTFail("\(r)")
        case .success(let w):
            XCTAssertEqual(w.seqLen, 30)
            XCTAssertGreaterThanOrEqual(w.coverage, 0.80)
            XCTAssertEqual(w.hr.compactMap { $0 }.count, 30)
        }
    }

    func testWhoop5ThirtySecondCadenceIsAvailable() {
        let now = 2_000_000
        let start = now - 1800
        var hr: [HRSample] = []
        var t = start
        while t < now {
            hr.append(HRSample(ts: t, bpm: 62))
            t += 30
        }
        let feed = WatchdogFeed(family: .whoop5, hrSource: .liveType40, nowUnix: now, hr: hr)
        switch WatchdogWindowBuilder.build(feed) {
        case .failure(let r): XCTFail("whoop5 sparse live should pass 60s coverage, got \(r)")
        case .success(let w):
            XCTAssertGreaterThanOrEqual(w.coverage, 0.80)
        }
    }

    func testSparseWhoop4CadenceStillDisplays() {
        let now = 2_000_000
        let start = now - 1800
        var hr: [HRSample] = []
        var t = start
        while t < now {
            hr.append(HRSample(ts: t, bpm: 62))
            t += 30
        }
        let as4 = WatchdogWindowBuilder.build(
            WatchdogFeed(family: .whoop4, hrSource: .live2A37, nowUnix: now, hr: hr))
        switch as4 {
        case .failure(let r): XCTFail("sparse live 4.0 must still display, got \(r)")
        case .success(let w):
            XCTAssertFalse(w.hr.compactMap { $0 }.isEmpty)
        }
    }

    func testRestingHRUsesLastTenStillMinutesOnly() {
        let now = 3_100_000
        let start = now - 1800
        var hr: [HRSample] = []
        var motion: [WatchdogScalarSample] = []
        for t in start..<now {
            let minute = (t - start) / 60
            hr.append(HRSample(ts: t, bpm: minute < 20 ? 90 : 58))
            motion.append(WatchdogScalarSample(ts: t, value: minute < 20 ? 0.8 : 0))
        }
        let feed = WatchdogFeed(family: .whoop4, hrSource: .v18, nowUnix: now, hr: hr, motion: motion)
        switch WatchdogWindowBuilder.build(feed) {
        case .failure(let r): XCTFail("\(r)")
        case .success(let w):
            let rest = w.rhr.compactMap { $0 }
            XCTAssertEqual(rest.count, 30)
            XCTAssertTrue(rest.allSatisfy { abs($0 - 58) < 1 })
        }
    }

    func testSpo2KeepsPercentAndDropsOpticalADC() {
        let now = 3_200_000
        let start = now - 1800
        let hr = (start..<now).map { HRSample(ts: $0, bpm: 60) }
        let spo2 = [
            WatchdogScalarSample(ts: now - 60, value: 97),
            WatchdogScalarSample(ts: now - 120, value: 12_450)
        ]
        let feed = WatchdogFeed(family: .whoop4, hrSource: .v18, nowUnix: now, hr: hr, spo2Pct: spo2)
        switch WatchdogWindowBuilder.build(feed) {
        case .failure(let r): XCTFail("\(r)")
        case .success(let w):
            let kept = w.spo2.compactMap { $0 }
            XCTAssertEqual(kept.count, 1)
            XCTAssertEqual(kept[0], 97, accuracy: 0.01)
        }
    }

    func testPPGRecordIndexKeepsTwoRecordsInTheSameSecond() {
        let rows = [
            WatchdogPPGIdentity(ts: 10, recordIndex: 2),
            WatchdogPPGIdentity(ts: 10, recordIndex: 1),
            WatchdogPPGIdentity(ts: 10, recordIndex: 1)
        ]
        let uniq = WatchdogWindowBuilder.uniquePPGIdentities(rows)
        XCTAssertEqual(uniq.map(\.recordIndex), [1, 2])
        XCTAssertEqual(uniq.count, 2, "GROUP BY ts would have dropped one PR15 record")
    }

    func testCarryForwardSameTimestampIsNotANewObservation() {
        let now = 3_000_000
        let start = now - 1800
        var hr: [HRSample] = []
        for t in start..<now {
            hr.append(HRSample(ts: t, bpm: 60))
            hr.append(HRSample(ts: t, bpm: 60))
        }
        let collapsed = WatchdogWindowBuilder.collapseCarryForward(hr)
        XCTAssertEqual(collapsed.count, 1800)
    }

    func testEmptyHRIsUnavailable() {
        let feed = WatchdogFeed(family: .whoop4, hrSource: .v18, nowUnix: 100)
        if case .failure(let r) = WatchdogWindowBuilder.build(feed) {
            XCTAssertTrue(r == .empty || r == .coverage || r == .stale || r == .gap)
        } else {
            XCTFail("empty feed must be unavailable")
        }
    }

    func testHoldForwardFillsBreathingGapsWhileOnWrist() {
        let now = 3_300_000
        let start = now - 1800
        let hr = (start..<now).map { HRSample(ts: $0, bpm: 60) }
        var resp: [WatchdogScalarSample] = []
        for t in start..<(start + 300) {
            resp.append(WatchdogScalarSample(ts: t, value: 14))
        }
        let feed = WatchdogFeed(family: .whoop4, hrSource: .v18, nowUnix: now, hr: hr, respPerMin: resp)
        switch WatchdogWindowBuilder.build(feed) {
        case .failure(let r): XCTFail("\(r)")
        case .success(let w):
            XCTAssertEqual(w.resp.compactMap { $0 }.count, 30)
            XCTAssertTrue(w.resp.compactMap { $0 }.allSatisfy { abs($0 - 14) < 0.01 })
        }
    }

    func testHoldForwardUsesSeedWhenWindowHasAGap() {
        let held = WatchdogWindowBuilder.holdForward([14, nil, nil, 16, nil], seed: 13)
        XCTAssertEqual(held[0], 14)
        XCTAssertEqual(held[1], 14)
        XCTAssertEqual(held[2], 14)
        XCTAssertEqual(held[3], 16)
        XCTAssertEqual(held[4], 16)
    }

    func testMotionGapsAreInterpolatedNotZeroed() {
        let series: [Double?] = [0.0, nil, nil, 0.9, nil]
        let filled = WatchdogWindowBuilder.interpolateGaps(series)
        XCTAssertEqual(filled[0] ?? -1, 0, accuracy: 0.001)
        XCTAssertGreaterThan(filled[1] ?? 0, 0.2)
        XCTAssertLessThan(filled[1] ?? 1, 0.7)
        XCTAssertEqual(filled[3] ?? 0, 0.9, accuracy: 0.001)
        XCTAssertEqual(filled[4] ?? 0, 0.9, accuracy: 0.001)
    }

    func testRmssdGridDropsEctopicJumps() {
        let now = 4_500_000
        let start = now - 1800
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for t in start..<now {
            hr.append(HRSample(ts: t, bpm: 60))
            let phys = t % 2 == 0 ? 1020 : 980
            rr.append(RRInterval(ts: t, rrMs: t % 17 == 0 ? 400 : phys))
        }
        let feed = WatchdogFeed(family: .whoop4, hrSource: .v18, nowUnix: now, hr: hr, rr: rr)
        switch WatchdogWindowBuilder.build(feed) {
        case .failure(let r): XCTFail("\(r)")
        case .success(let w):
            let hrv = w.hrv.compactMap { $0 }
            XCTAssertFalse(hrv.isEmpty)
            XCTAssertTrue(hrv.allSatisfy { $0 < 80 }, "cleaned 5-min RMSSD must not follow RR artifacts, got \(hrv)")
        }
    }

    func testWristOffIsUnavailableNotRecovered() {
        let feed = Watchdog.syntheticFeed(now: 1_800_000, hr: 60, hrv: 40, temp: 33, resp: 14, motion: 0)
        var off = feed
        off.wristOff = true
        if case .failure(let r) = WatchdogWindowBuilder.build(off) {
            XCTAssertEqual(r, .wristOff)
        } else { XCTFail() }
        let result = Watchdog.evaluate(window: .failure(.wristOff), prompt: UniTSPrompt(), nowUnix: 1_800_000)
        XCTAssertEqual(result.severity, .dataUnavailable)
        XCTAssertEqual(result.episodeState, .dataUnavailable)
        XCTAssertFalse(result.shouldNotify)
        XCTAssertFalse(result.episodeLine.contains("recovered") && result.headline.contains("like you"))
        XCTAssertTrue(result.episodeLine.contains("not recovered"))
        XCTAssertNotEqual(result.episodeState, .resolved)
        XCTAssertNotEqual(result.episodeState, .recovering)
        XCTAssertFalse(result.headline.contains("looks like you"))
        XCTAssertFalse(result.episodeLine.contains("no current deviation"))
        XCTAssertNil(result.carry.lastHeldResp)
    }
}

final class WatchdogUniTSTests: XCTestCase {

    func testQuietWindowEnergyBelowTau() throws {
        let now = 4_000_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let win = try XCTUnwrap(WatchdogWindowBuilder.build(feed).success)
        let residual = try UniTSRuntime().reconstruct(win, prompt: UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97))
        XCTAssertLessThan(residual.energy(for: .hr), WatchdogConfig.tau)
        XCTAssertLessThan(residual.energy(for: .rhr), WatchdogConfig.tau)
        XCTAssertLessThan(residual.energy(for: .spo2), WatchdogConfig.tau)
        XCTAssertLessThan(residual.energy(for: .temp), WatchdogConfig.tau)
        XCTAssertLessThan(residual.energy(for: .resp), WatchdogConfig.tau)
        XCTAssertEqual(residual.modelVersion, WatchdogConfig.modelVersion)
        XCTAssertTrue(UniTSCoreMLSession.shared.isLoaded)
    }

    func testCoreMLHatAndSigmaMatchPhysicsDecoder() throws {
        XCTAssertTrue(UniTSCoreMLSession.shared.isLoaded, "UniTS_AD.mlpackage must load for reconstruct")
        XCTAssertTrue(TimesFMStudentSession.shared.isLoaded, "TimesFM3_Student.mlpackage must load for forecast")
        let now = 4_010_000
        let restFeed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let restWin = try XCTUnwrap(WatchdogWindowBuilder.build(restFeed).success)
        let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)
        let restOcc = UniTSRuntime.occupancy(restWin.motion)
        let rest = try XCTUnwrap(UniTSRuntime.coreMLResidual(window: restWin, prompt: prompt, occupancy: restOcc))
        XCTAssertEqual(rest.reconstructedHR.compactMap { $0 }.last ?? 0, 58, accuracy: 3.0)
        XCTAssertEqual(rest.modelVersion, WatchdogConfig.modelVersion)

        let moveFeed = Watchdog.syntheticFeed(now: now, hr: 70, hrv: 48, temp: 33.1, resp: 14, motion: 0.8)
        let moveWin = try XCTUnwrap(WatchdogWindowBuilder.build(moveFeed).success)
        let move = try XCTUnwrap(UniTSRuntime.coreMLResidual(
            window: moveWin, prompt: prompt, occupancy: UniTSRuntime.occupancy(moveWin.motion)))
        XCTAssertGreaterThan(move.reconstructedHR.compactMap { $0 }.last ?? 0,
                             rest.reconstructedHR.compactMap { $0 }.last ?? 0)

        var spikeFeed = Watchdog.syntheticFeed(now: now, hr: 96, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let spikeWin = try XCTUnwrap(WatchdogWindowBuilder.build(spikeFeed).success)
        let spike = try XCTUnwrap(UniTSRuntime.coreMLResidual(
            window: spikeWin, prompt: prompt, occupancy: UniTSRuntime.occupancy(spikeWin.motion)))
        XCTAssertLessThan(spike.reconstructedHR.compactMap { $0 }.last ?? 99, 80)
        XCTAssertEqual(spike.reconstructedHR.compactMap { $0 }.last ?? 0, 58, accuracy: 8)

        let step = WatchdogForecastRuntime().step(window: restWin, residual: rest, prompt: prompt, carry: .empty)
        XCTAssertEqual(step.nextHR.count, 5)
        XCTAssertEqual(step.nextHR.last ?? 0, 58, accuracy: 6)
    }

    func testLiveEndOutsideTheBandIsHotEvenIfMedianIsQuiet() {
        let hat: [Double?] = Array(repeating: 80, count: 30)
        var observed: [Double?] = Array(repeating: 80, count: 29)
        observed.append(120)
        let scored = UniTSRuntime.score(observed, hat, floor: 8, personal: 8)
        XCTAssertGreaterThanOrEqual(scored.energy, WatchdogConfig.tau)
        XCTAssertEqual(scored.rangeHalf, 8, accuracy: 0.01)
    }

    func testTrailingHatWithoutLiveSampleIsNotAFalseOff() {
        var observed: [Double?] = Array(repeating: 58, count: 29)
        observed.append(nil)
        var hat: [Double?] = Array(repeating: 58, count: 29)
        hat.append(90)
        let scored = UniTSRuntime.score(observed, hat, floor: 5, personal: 5)
        XCTAssertLessThan(scored.energy, WatchdogConfig.tau)
        let paired = UniTSRuntime.lastPaired(observed, hat)
        XCTAssertEqual(paired?.obs ?? 0, 58, accuracy: 0.01)
        XCTAssertEqual(paired?.hat ?? 0, 58, accuracy: 0.01)
    }

    func testFlatShiftStaysHotEvenWhenEveryMinuteIsTheSame() {
        let hat: [Double?] = Array(repeating: 80, count: 30)
        let observed: [Double?] = Array(repeating: 120, count: 30)
        let scored = UniTSRuntime.score(observed, hat, floor: 8, personal: 8)
        XCTAssertGreaterThan(scored.energy, WatchdogConfig.tauSevere)
    }

    func testWidePersonalMADRaisesTheOffThreshold() {
        let hat: [Double?] = Array(repeating: 80, count: 30)
        let observed: [Double?] = Array(repeating: 92, count: 30)
        XCTAssertGreaterThan(UniTSRuntime.score(observed, hat, floor: 5, personal: 5).energy, WatchdogConfig.tau)
        XCTAssertLessThan(UniTSRuntime.score(observed, hat, floor: 5, personal: 20).energy, WatchdogConfig.tau)
    }

    func testPredictedScaleIsNotThisWindowScatter() {
        let hat: [Double?] = Array(repeating: 70, count: 30)
        let coupling = Array(repeating: 0.0, count: 30)
        let quiet = UniTSRuntime.predictedScale(hat: hat, floor: 5, personal: 5,
                                                reconFraction: 0.12, coupling: coupling)
        XCTAssertEqual(quiet.last ?? 0, max(5, 0.12 * 70), accuracy: 0.01)
        var spikeHat = hat
        spikeHat[29] = 70
        let still = UniTSRuntime.predictedScale(hat: spikeHat, floor: 5, personal: 5,
                                                reconFraction: 0.12, coupling: coupling)
        XCTAssertEqual(quiet, still)
    }

    func testHRVBandUsesReconstructionSNRNotEightMsFloor() throws {
        let now = 6_200_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 60, hrv: 94, temp: 33.1, resp: 14, motion: 0)
        let win = try XCTUnwrap(WatchdogWindowBuilder.build(feed).success)
        let residual = try UniTSRuntime().reconstruct(win, prompt: UniTSPrompt(hr: 60, rhr: 60, hrv: 94, temp: 33.1, resp: 14, spo2: 97))
        let half = residual.rangeHalf(for: .hrv)
        let hat = residual.reconstructedHRV.compactMap { $0 }.last ?? 0
        XCTAssertGreaterThan(half, WatchdogConfig.hrvScale)
        XCTAssertGreaterThan(hat, 80)
    }

    func testOccupancyWidensHRBandFromTheModelNotFromLiveScatter() {
        let restOcc = Array(repeating: 0.0, count: 30)
        let walkOcc = Array(repeating: 1.0, count: 30)
        let observed: [Double?] = Array(repeating: 58, count: 30)
        let restHat = UniTSRuntime.reconstructHR(observed: observed, prompt: 58, occupancy: restOcc)
        let walkHat = UniTSRuntime.reconstructHR(observed: observed, prompt: 58, occupancy: walkOcc)
        let restScale = UniTSRuntime.predictedScale(
            hat: restHat, floor: 5, personal: 5, reconFraction: WatchdogConfig.hrReconFraction,
            coupling: restOcc.map { WatchdogConfig.hrEffortUncert * 58 * $0 })
        let walkScale = UniTSRuntime.predictedScale(
            hat: walkHat, floor: 5, personal: 5, reconFraction: WatchdogConfig.hrReconFraction,
            coupling: walkOcc.map { WatchdogConfig.hrEffortUncert * 58 * $0 })
        XCTAssertGreaterThan(walkScale.last ?? 0, restScale.last ?? 0)
        XCTAssertGreaterThan((walkHat.last ?? 0) ?? 0, (restHat.last ?? 0) ?? 0)
    }

    func testFlatRestShiftStaysHotWithPredictedScale() throws {
        let now = 6_300_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 96, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let win = try XCTUnwrap(WatchdogWindowBuilder.build(feed).success)
        let residual = try UniTSRuntime().reconstruct(win, prompt: UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97))
        XCTAssertGreaterThan(residual.energy(for: .hr), WatchdogConfig.tau)
        XCTAssertGreaterThan(residual.rangeHalf(for: .hr), WatchdogConfig.hrScale - 0.01)
    }

    func testCombinedVignetteExceedsTauSevereOnThreeVitals() throws {
        let now = 5_000_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 96, hrv: 16, temp: 34.3, resp: 22, motion: 0)
        let win = try XCTUnwrap(WatchdogWindowBuilder.build(feed).success)
        let residual = try UniTSRuntime().reconstruct(win, prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14))
        let severe = [WatchdogWindow.Channel.hr, .hrv, .temp, .resp]
            .filter { residual.energy(for: $0) >= WatchdogConfig.tauSevere }
        XCTAssertGreaterThanOrEqual(severe.count, 3, "\(residual.energy)")
        XCTAssertEqual(residual.modelVersion, WatchdogConfig.modelVersion)
    }

    func testMotionExplainsHighHRSoWorkoutIsNotARestMiss() throws {
        let now = 6_000_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 58 + WatchdogConfig.motionHrGain, hrv: 48,
                                          temp: 33.1, resp: 14, motion: 1)
        let win = try XCTUnwrap(WatchdogWindowBuilder.build(feed).success)
        let residual = try UniTSRuntime().reconstruct(win, prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14))
        XCTAssertLessThan(residual.energy(for: .hr), WatchdogConfig.tauSevere)
    }

    func testEachVitalHasItsOwnReconstructionShape() throws {
        let now = 6_100_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 90, hrv: 40, temp: 33.2, resp: 20, motion: 0.8)
        let win = try XCTUnwrap(WatchdogWindowBuilder.build(feed).success)
        let residual = try UniTSRuntime().reconstruct(
            win, prompt: UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97))
        let hr = residual.reconstructedHR.compactMap { $0 }
        let rhr = residual.reconstructedRHR.compactMap { $0 }
        let hrv = residual.reconstructedHRV.compactMap { $0 }
        let resp = residual.reconstructedResp.compactMap { $0 }
        XCTAssertGreaterThan(hr.last ?? 0, 70, "HR dotted line should sit above rest when occupancy is high")
        XCTAssertGreaterThan((hr.last ?? 0) - 58, 10)
        XCTAssertEqual(rhr.max() ?? 0, rhr.min() ?? 1, accuracy: 0.5, "RHR expected stays flat")
        XCTAssertEqual(rhr.last ?? 0, 58, accuracy: 0.5)
        XCTAssertLessThan(hrv.last ?? 99, 48, "HRV expected falls with motion")
        XCTAssertGreaterThan(resp.last ?? 0, 16, "breathing expected rises with motion")
    }

    func testHRDottedLineRisesWhenOccupancyRamps() {
        var occ = Array(repeating: 0.0, count: 30)
        for i in 15..<30 { occ[i] = Double(i - 14) / 15.0 }
        let observed: [Double?] = Array(repeating: 70, count: 30)
        let hat = UniTSRuntime.reconstructHR(observed: observed, prompt: 58, occupancy: occ)
        let first = hat.compactMap { $0 }.first ?? 0
        let last = hat.compactMap { $0 }.last ?? 0
        XCTAssertEqual(first, 58, accuracy: 1.5)
        XCTAssertGreaterThan(last, first + 8)
    }

    func testHRHatDoesNotChaseARestingSpike() {
        let occ = Array(repeating: 0.0, count: 30)
        let observed: [Double?] = Array(repeating: 96, count: 30)
        let hat = UniTSRuntime.reconstructHR(observed: observed, prompt: 58, occupancy: occ)
        XCTAssertEqual(hat.compactMap { $0 }.last ?? 0, 58, accuracy: 0.5)
        let scored = UniTSRuntime.score(observed, hat, floor: 5, personal: 5)
        XCTAssertGreaterThan(scored.energy, WatchdogConfig.tau)
        XCTAssertEqual(scored.rangeHalf, 5, accuracy: 0.01)
    }

    func testMissingUsualUsesPopulationPriorAndWideBand() {
        let occ = Array(repeating: 0.0, count: 30)
        let observed: [Double?] = Array(repeating: 96, count: 30)
        let hat = UniTSRuntime.reconstructHR(observed: observed, prompt: nil, occupancy: occ)
        XCTAssertEqual(hat.compactMap { $0 }.last ?? 0, WatchdogPopulationPriors.hr, accuracy: 0.5)
        XCTAssertNotEqual(hat.compactMap { $0 }.last ?? 0, 96, accuracy: 0.5)
    }

    func testSleepHRVStaysPersonalUntilAwakeUsualExists() throws {
        let occ = Array(repeating: 0.0, count: 30)
        let observed: [Double?] = Array(repeating: 126, count: 30)
        let sleepOnly = UniTSRuntime.reconstructHRV(
            observed: observed,
            prompt: UniTSPrompt(hrv: 177, hrvAnchoredInSleep: true),
            occupancy: occ)
        XCTAssertEqual(try XCTUnwrap(sleepOnly.last ?? nil), 177, accuracy: 0.5)
        let withAwake = UniTSRuntime.reconstructHRV(
            observed: observed,
            prompt: UniTSPrompt(hrv: 177, hrvAwake: 120),
            occupancy: occ)
        XCTAssertEqual(try XCTUnwrap(withAwake.last ?? nil), 120, accuracy: 0.5)
        let moving = UniTSRuntime.reconstructHRV(
            observed: observed,
            prompt: UniTSPrompt(hrv: 50),
            occupancy: Array(repeating: 1.0, count: 30))
        let moved = try XCTUnwrap(moving.last ?? nil)
        XCTAssertEqual(moved, 50 - WatchdogConfig.hrvExerciseDropMs, accuracy: 0.2)
    }

    func testOneMinuteSpikeIsNotSevere() throws {
        let now = 7_000_000
        var feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        if let last = feed.hr.last {
            feed.hr[feed.hr.count - 1] = HRSample(ts: last.ts, bpm: 95)
        }
        let r1 = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                   prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14),
                                   nowUnix: now)
        XCTAssertNotEqual(r1.severity, .severe)
        XCTAssertFalse(r1.shouldNotify)
    }

    func testOneChannelShiftIsNoteNotNotify() throws {
        let now = 7_100_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 34.0, resp: 14, motion: 0)
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97),
                                  nowUnix: now)
        XCTAssertEqual(r.severity, .note, r.episodeLine)
        XCTAssertFalse(r.shouldNotify)
        XCTAssertEqual(r.contributing, ["Temp"])
    }

    func testV26WindowWithoutRRStillBuilds() {
        let now = 7_200_000
        let start = now - 1800
        let hr = (start..<now).map { HRSample(ts: $0, bpm: 60) }
        let feed = WatchdogFeed(family: .whoop4, hrSource: .v18, nowUnix: now, hr: hr)
        switch WatchdogWindowBuilder.build(feed) {
        case .failure(let r): XCTFail("HR-only v26-style window must build, got \(r)")
        case .success(let w):
            XCTAssertTrue(w.hrv.compactMap { $0 }.isEmpty)
            XCTAssertGreaterThanOrEqual(w.coverage, 0.80)
        }
    }
}

final class WatchdogEpisodeTests: XCTestCase {

    func testQuietInjectDoesNotNotify() {
        let r = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                  nowUnix: 10, inject: .quiet)
        XCTAssertNotEqual(r.severity, .severe)
        XCTAssertFalse(r.shouldNotify)
    }

    func testSevereInjectNotifiesOnSecondTickOnlyOncePerCooldown() {
        let t = 8_000_000
        let first = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                      nowUnix: t, previous: .empty, inject: .severe)
        XCTAssertEqual(first.severity, .severe, first.episodeLine)
        XCTAssertTrue(first.shouldNotify)
        let second = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                       nowUnix: t + 60, previous: first.carry, inject: .severe)
        XCTAssertEqual(second.severity, .severe)
        XCTAssertFalse(second.shouldNotify, "stable episode does not re-page")
        XCTAssertEqual(first.episodeId, second.episodeId)
    }

    func testIllnessLogCapsAtCandidate() {
        let now = 9_000_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 96, hrv: 16, temp: 34.3, resp: 22, motion: 0)
        var carry = WatchdogCarry.empty
        carry.consecutiveMismatchTicks = 4
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14),
                                  dayLog: LBDayLog(feltIll: true),
                                  nowUnix: now,
                                  previous: carry)
        XCTAssertNotEqual(r.severity, .severe)
        XCTAssertFalse(r.shouldNotify)
        XCTAssertEqual(r.severity, .candidate)
    }

    func testReplayDoesNotUseFutureSamples() {
        let now = 10_000_000
        var early = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        early.hr.append(HRSample(ts: now + 120, bpm: 140))
        let win = WatchdogWindowBuilder.build(early)
        if case .success(let w) = win {
            XCTAssertTrue(w.hr.compactMap { $0 }.allSatisfy { abs($0 - 58) < 1 })
        } else { XCTFail() }
    }

    func testSafetyCapStillRestTachycardiaNotifies() {
        let now = 10_100_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 132, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14),
                                  nowUnix: now)
        XCTAssertEqual(r.severity, .severe)
        XCTAssertTrue(r.shouldNotify)
    }

    func testWorkoutHighHRIsNotSafetyCap() {
        let now = 10_200_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 132, hrv: 48, temp: 33.1, resp: 14, motion: 1)
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14),
                                  nowUnix: now)
        XCTAssertNotEqual(r.severity, .severe)
        XCTAssertFalse(r.shouldNotify)
    }

    func testQuietAfterSevereGoesRecoveringThenResolved() {
        let t = 10_300_000
        let severe = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                       nowUnix: t, inject: .severe)
        XCTAssertEqual(severe.episodeState, .active)
        let q1 = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                   nowUnix: t + 300, previous: severe.carry, inject: .quiet)
        XCTAssertEqual(q1.episodeState, .recovering, q1.episodeLine)
        XCTAssertFalse(q1.shouldNotify)
        XCTAssertFalse(q1.episodeLine.contains("no current deviation"))
        let q2 = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                   nowUnix: t + 600, previous: q1.carry, inject: .quiet)
        XCTAssertEqual(q2.episodeState, .resolved)
        XCTAssertFalse(q2.shouldNotify)
    }

    func testUnavailableAfterActiveIsNotRecovery() {
        var carry = WatchdogCarry.empty
        carry.priorState = .active
        carry.episodeId = "wd-keep"
        let r = Watchdog.evaluate(window: .failure(.coverage), prompt: UniTSPrompt(),
                                  nowUnix: 10_400_000, previous: carry)
        XCTAssertEqual(r.episodeState, .dataUnavailable)
        XCTAssertNotEqual(r.episodeState, .recovering)
        XCTAssertNotEqual(r.episodeState, .resolved)
        XCTAssertTrue(r.episodeLine.contains("not recovered"))
        XCTAssertFalse(r.shouldNotify)
        XCTAssertEqual(r.episodeId, "wd-keep")
    }

    func testFourteenQuietWindowsNeverSevere() throws {
        let now = 10_500_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let win = WatchdogWindowBuilder.build(feed)
        var carry = WatchdogCarry.empty
        for i in 0..<(14 * 24) {
            let r = Watchdog.evaluate(window: win, prompt: UniTSPrompt(hr: 58, hrv: 48, temp: 33.1, resp: 14),
                                      nowUnix: now + i * 300, previous: carry)
            XCTAssertNotEqual(r.severity, .severe, "tick \(i)")
            XCTAssertFalse(r.shouldNotify)
            carry = r.carry
        }
    }

    func testLiveIntervalClamp() {
        XCTAssertEqual(WatchdogConfig.clampInterval(5), 5)
        XCTAssertEqual(WatchdogConfig.clampInterval(1), 1)
        XCTAssertEqual(WatchdogConfig.clampInterval(7), 5)
        XCTAssertEqual(WatchdogConfig.tickSeconds, 20)
        XCTAssertEqual(WatchdogConfig.modelVersion, "units-ad-coreml-v2")
        XCTAssertEqual(WatchdogConfig.configVersion, "watchdog-v2.2")
        XCTAssertEqual(WatchdogForecastRuntime.modelVersion, "timesfm3-student-v2")
        XCTAssertEqual(WatchdogConfig.coreMLCheckpoint, "UniTS_AD.mlpackage")
        // v2: 50×0.80 + 35×0.90 + 15×1.00 = 86.5 → 87 (shown usual, full coverage, clear off)
        XCTAssertEqual(Watchdog.predictionTrust(energy: 2.4, usual: 58, coverage: 0.9,
                                                usualTrust: 80, persistTicks: 3, hot: true), 87)
        // No prompt → cap 18 even if coverage is complete
        XCTAssertEqual(Watchdog.predictionTrust(energy: 0, usual: nil, coverage: 1,
                                                usualTrust: 80, persistTicks: 0, hot: false), 18)
        // Prompt exists but Layer 1 TRUST is below the 35 hide bar → cap 28
        let weakUsual = Watchdog.predictionTrust(energy: 0.2, usual: 120, coverage: 0.9,
                                                 usualTrust: 20, persistTicks: 0, hot: false)
        XCTAssertLessThanOrEqual(weakUsual, 28)
        XCTAssertGreaterThan(weakUsual, 10)
        // In-range with a shown usual: 50×0.80 + 35×0.90 + 15×1.00 = 87
        XCTAssertEqual(Watchdog.predictionTrust(energy: 0, usual: 58, coverage: 0.9,
                                                usualTrust: 80, persistTicks: 0, hot: false), 87)
    }

    func testLiveHRVPromptUsesSleepDisplayMillisecondsNotDemoAwakeRest() {
        let asOf = "2026-09-01"
        let te = LongitudinalBaseline.isoEpochDay(asOf)!
        func tape(_ native: Double) -> [LBDailyObservation] {
            (1...40).map {
                LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(te - $0),
                                   value: native, qualityStatus: .ok)
            } + [LBDailyObservation(day: asOf, value: native, qualityStatus: .ok)]
        }
        let sleep = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepHRVLn, observations: tape(80))
        let awake = LongitudinalBaseline.evaluate(asOf: asOf, series: .awakeRestHRVLn, observations: tape(20))
        let prompt = UniTSPrompt.from(evaluations: [awake, sleep])
        XCTAssertEqual(prompt.hrv ?? -1, sleep.copyLong?.centerDisplay ?? sleep.copy7?.centerDisplay ?? -2,
                       accuracy: 0.5)
        XCTAssertGreaterThan(prompt.hrv ?? 0, 50)
    }

    func testPromptNeverFillsInstantHRFromSleepRHR() {
        let asOf = "2026-09-01"
        let te = LongitudinalBaseline.isoEpochDay(asOf)!
        func tape(_ native: Double) -> [LBDailyObservation] {
            (1...40).map {
                LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(te - $0),
                                   value: native, qualityStatus: .ok)
            } + [LBDailyObservation(day: asOf, value: native, qualityStatus: .ok)]
        }
        let sleep = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: tape(52))
        let awake = LongitudinalBaseline.evaluate(asOf: asOf, series: .awakeRestHR, observations: tape(74))
        let split = UniTSPrompt.from(evaluations: [sleep, awake])
        XCTAssertEqual(split.hr ?? -1, awake.copyLong?.centerDisplay ?? awake.copy7?.centerDisplay ?? -2,
                       accuracy: 0.8)
        XCTAssertEqual(split.rhr ?? -1, sleep.copyLong?.centerDisplay ?? sleep.copy7?.centerDisplay ?? -2,
                       accuracy: 0.8)
        XCTAssertGreaterThan((split.hr ?? 0) - (split.rhr ?? 0), 10)
        let sleepOnly = UniTSPrompt.from(evaluations: [sleep])
        XCTAssertNil(sleepOnly.hr)
        XCTAssertEqual(sleepOnly.rhr ?? -1, sleep.copyLong?.centerDisplay ?? sleep.copy7?.centerDisplay ?? -2,
                       accuracy: 0.8)
        XCTAssertEqual(sleepOnly.source, .sleep)
    }

    func testWalkAndRunShareMotionMagnitudeButSplitEffort() throws {
        let now = 31_000_000
        let start = now - WatchdogConfig.contextSeconds
        let hrWalk = (start..<now).map { HRSample(ts: $0, bpm: 72) }
        let hrRun = (start..<now).map { HRSample(ts: $0, bpm: 118) }
        let motion = (start..<now).map { WatchdogScalarSample(ts: $0, value: 0.40) }
        let walkSteps = (start..<now).map { StepSample(ts: $0, counter: 1, activityClass: 1) }
        let runSteps = (start..<now).map { StepSample(ts: $0, counter: 1, activityClass: 2) }
        let walk = try XCTUnwrap(WatchdogWindowBuilder.build(
            WatchdogFeed(family: .whoop4, hrSource: .v18, nowUnix: now, hr: hrWalk,
                         motion: motion, steps: walkSteps)).success)
        let run = try XCTUnwrap(WatchdogWindowBuilder.build(
            WatchdogFeed(family: .whoop4, hrSource: .v18, nowUnix: now, hr: hrRun,
                         motion: motion, steps: runSteps)).success)
        XCTAssertEqual(WatchdogActivityClass.labels(logits: walk.activityLogits).last, "walk")
        XCTAssertEqual(WatchdogActivityClass.labels(logits: run.activityLogits).last, "run")
        XCTAssertLessThan(try XCTUnwrap(UniTSRuntime.occupancy(walk).last),
                          try XCTUnwrap(UniTSRuntime.occupancy(run).last))
        XCTAssertTrue(walk.rhr.compactMap { $0 }.isEmpty)
        XCTAssertTrue(run.rhr.compactMap { $0 }.isEmpty)
    }

    func testQuietTicksAdaptSigmaFloor() throws {
        let now = 32_000_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let win = WatchdogWindowBuilder.build(feed)
        let carry = WatchdogCarry.empty
        var last = Watchdog.evaluate(window: win, prompt: UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97),
                                     nowUnix: now, previous: carry)
        XCTAssertFalse(last.sigmaAdaptive)
        for i in 1...10 {
            last = Watchdog.evaluate(window: win, prompt: UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97),
                                     nowUnix: now + i * 20, previous: last.carry)
        }
        XCTAssertGreaterThanOrEqual(last.carry.quietN, 8)
        XCTAssertTrue(last.sigmaAdaptive)
        XCTAssertEqual(last.qualityGate, "bucket-v1")
    }
}

final class WatchdogIsolationTests: XCTestCase {

    func testWatchdogDoesNotMoveUsualHashes() {
        let asOf = "2026-09-01"
        let te = LongitudinalBaseline.isoEpochDay(asOf)!
        let obs = (1...40).map {
            LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(te - $0), value: 60, qualityStatus: .ok)
        } + [LBDailyObservation(day: asOf, value: 60, qualityStatus: .ok)]
        let before = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: obs)
        let fingerprint = Self.fp(before)
        var carry = WatchdogCarry.empty
        for i in 0..<100 {
            let now = 11_000_000 + i * 60
            let feed = Watchdog.syntheticFeed(now: now, hr: i % 7 == 0 ? 96 : 60,
                                              hrv: 16, temp: 34.3, resp: 22, motion: 0)
            let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                      prompt: UniTSPrompt.from(evaluations: [before]),
                                      evaluations: [before],
                                      nowUnix: now,
                                      previous: carry)
            carry = r.carry
        }
        let after = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: obs)
        XCTAssertEqual(Self.fp(after), fingerprint)
        XCTAssertEqual(after.copyLong?.centerDisplay, before.copyLong?.centerDisplay)
        XCTAssertEqual(after.kBandUsed, before.kBandUsed)
        XCTAssertEqual(after.nCleanLong, before.nCleanLong)
    }

    static func fp(_ ev: LBEvaluation) -> String {
        "\(ev.copy7?.center ?? -1)|\(ev.copyLong?.center ?? -1)|\(ev.copy7?.spread ?? -1)|\(ev.copyLong?.spread ?? -1)|\(ev.kBandUsed)|\(ev.nCleanLong)|\(ev.nLong)|\(ev.n7)"
    }
}

private extension Result {
    var success: Success? {
        if case .success(let s) = self { return s }
        return nil
    }
}
