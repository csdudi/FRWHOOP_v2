import XCTest
@testable import StrandAnalytics

/// No human labels. Memory + UniTS teach event names.
final class WatchdogV25SelfLabelTests: XCTestCase {

    func testUnexplainedWalkClassIsNeverWorkoutFromPriorityTable() {
        let lab = WatchdogEventLabeler.labelMinute(wristOff: false, gap: false, artifact: false,
                                                   cls: .walk, postWorkout: false, sleep: false,
                                                   safety: false, explainedWorkout: false)
        XCTAssertNotEqual(lab, .workoutWalk)
        XCTAssertEqual(lab, .normalStillAwake)
    }

    func testSpo2TeacherWithoutHR() {
        let lab = WatchdogEventGeometry.what(cls: .still, reconJ: 1.3, forecastJ: 0.1,
                                            safety: false, artifact: false, postWorkout: false,
                                            sleep: false, hrHot: false, breadth: 0.2, spo2Hot: true)
        XCTAssertEqual(lab, .abnormalSpo2Still)
    }

    func testMemoryRenamesUnknownStillToLearnedWalk() {
        var mem = WatchdogEventMemory.empty
        let walk = WatchdogEventMemory.signature(d: [0.1, 0, 0, 0, 0, 0], reconJ: 0.2,
                                                 forecastJ: 0.1, cls: .walk, spo2Abs: 0)
        for _ in 0..<6 {
            _ = mem.observe(teacher: .workoutWalk, explained: true, sig: walk)
        }
        let unknown = WatchdogEventMemory.signature(d: [0.1, 0, 0, 0, 0, 0], reconJ: 0.2,
                                                    forecastJ: 0.1, cls: .unknown, spo2Abs: 0)
        let named = mem.observe(teacher: .normalStillAwake, explained: true, sig: unknown)
        XCTAssertEqual(named, .workoutWalk)
    }

    func testMemoryCannotTurnLoudReconIntoWorkout() {
        var mem = WatchdogEventMemory.empty
        let walk = WatchdogEventMemory.signature(d: [0.1, 0, 0, 0, 0, 0], reconJ: 0.2,
                                                 forecastJ: 0.1, cls: .walk, spo2Abs: 0)
        for _ in 0..<6 {
            _ = mem.observe(teacher: .workoutWalk, explained: true, sig: walk)
        }
        let loud = WatchdogEventMemory.signature(d: [0.9, 0, 0, 0, 0, 0], reconJ: 1.5,
                                                 forecastJ: 0.2, cls: .walk, spo2Abs: 0)
        let named = mem.observe(teacher: .abnormalStillTachycardia, explained: false, sig: loud)
        XCTAssertNotEqual(named, .workoutWalk)
        XCTAssertTrue(WatchdogEventMemory.isAbnormal(named))
    }

    func testMemoryRefinesAbnormalFamily() {
        var mem = WatchdogEventMemory.empty
        let spo2 = WatchdogEventMemory.signature(d: [0, 0, 0, 0, 0, -0.8], reconJ: 1.2,
                                                 forecastJ: 0.1, cls: .still, spo2Abs: 2.2)
        for _ in 0..<6 {
            _ = mem.observe(teacher: .abnormalSpo2Still, explained: false, sig: spo2)
        }
        let again = WatchdogEventMemory.signature(d: [0.05, 0, 0, 0, 0, -0.75], reconJ: 1.15,
                                                  forecastJ: 0.1, cls: .still, spo2Abs: 2.0)
        let named = mem.observe(teacher: .abnormalMultiDirection, explained: false, sig: again)
        XCTAssertEqual(named, .abnormalSpo2Still)
    }

    func testQualityNeverLearned() {
        var mem = WatchdogEventMemory.empty
        let sig = WatchdogEventMemory.signature(d: [0, 0, 0, 0, 0, 0], reconJ: 0,
                                                forecastJ: 0, cls: .still, spo2Abs: 0)
        _ = mem.observe(teacher: .wristOff, explained: false, sig: sig)
        XCTAssertTrue(mem.prototypes.isEmpty)
    }

    func testCarryDecodesWithoutEventMemory() throws {
        let data = #"{"consecutiveMismatchTicks":0,"lastJointEnergy":0,"lastSafety":false,"consecutiveInRangeTicks":0,"quietAbsHR":0,"quietAbsRHR":0,"quietAbsHRV":0,"quietAbsTemp":0,"quietAbsResp":0,"quietAbsSpO2":0,"quietN":0,"lastForecastUnix":0,"quietJointEma":0,"lastReconEnergy":0}"#.data(using: .utf8)!
        let carry = try JSONDecoder().decode(WatchdogCarry.self, from: data)
        XCTAssertEqual(carry.eventMemory.prototypes.count, 0)
    }

    func testLiveQuietDoesNotNeedAHumanLabel() {
        let now = 52_000_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97),
                                  nowUnix: now)
        XCTAssertFalse(r.eventLabel.isEmpty)
        XCTAssertNotEqual(r.eventLabel, WatchdogEventLabel.mixedRejected.rawValue)
        let named = WatchdogEventLabel(rawValue: r.eventLabel)
        XCTAssertNotNil(named)
        XCTAssertNotEqual(named, .mixedRejected)
    }

    func testConfigIsV25() {
        XCTAssertEqual(WatchdogConfig.configVersion, "watchdog-v2.5")
        XCTAssertEqual(WatchdogEventGeometry.version, "geometry-v2-selflabel")
        XCTAssertEqual(WatchdogBand.version, "band-v2-medium")
    }

    func testBandIsNotFrozenAndNotYanked() {
        var q = Array(repeating: 0.0, count: 6)
        var anchor = Array(repeating: 1.0, count: 6)
        var n = 0
        var ready = false
        var scale = Array(repeating: 1.0, count: 6)
        for _ in 0..<14 {
            _ = WatchdogBand.update(absResidual: [0.25, 0.25, 0.25, 0.25, 0.25, 0.25],
                                    eligible: true, q: &q, anchor: &anchor, n: &n,
                                    initialized: &ready, scale: &scale)
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(scale[0], 1, accuracy: 1e-9)
        let afterSeed = scale[0]
        var prev = afterSeed
        for _ in 0..<8 {
            let s = WatchdogBand.update(absResidual: [1.1, 1.1, 1.1, 1.1, 1.1, 1.1],
                                        eligible: true, q: &q, anchor: &anchor, n: &n,
                                        initialized: &ready, scale: &scale)
            XCTAssertLessThanOrEqual(abs(s[0] - prev), WatchdogBand.stepMax + 1e-12)
            prev = s[0]
        }
        XCTAssertGreaterThan(scale[0], afterSeed)
        XCTAssertLessThan(scale[0], 1.25)
        let held = scale[0]
        let qHeld = q[0]
        for _ in 0..<40 {
            _ = WatchdogBand.update(absResidual: [1.1, 1.1, 1.1, 1.1, 1.1, 1.1],
                                    eligible: false, q: &q, anchor: &anchor, n: &n,
                                    initialized: &ready, scale: &scale)
        }
        XCTAssertEqual(scale[0], held, accuracy: 1e-12)
        XCTAssertEqual(q[0], qHeld, accuracy: 1e-12)
        for _ in 0..<500 {
            _ = WatchdogBand.update(absResidual: [1.1, 1.1, 1.1, 1.1, 1.1, 1.1],
                                    eligible: true, q: &q, anchor: &anchor, n: &n,
                                    initialized: &ready, scale: &scale)
        }
        XCTAssertLessThanOrEqual(scale[0], WatchdogBand.clampHi)
        XCTAssertGreaterThanOrEqual(scale[0], WatchdogBand.clampLo)
    }

    func testNotifyDeniedOnForecastAndWorkout() {
        let fc = WatchdogNotifyPolicy.decision(severity: .severe, openedEpisode: true,
                                               safety: false, previousSafety: false,
                                               fused: 4, previousFused: 0, recon: 4, previousRecon: 0,
                                               eventLabel: .forecastDriftOnly)
        XCTAssertFalse(fc.0)
        XCTAssertEqual(fc.1, "not-extreme-family")
        let walk = WatchdogNotifyPolicy.decision(severity: .severe, openedEpisode: true,
                                                 safety: false, previousSafety: false,
                                                 fused: 4, previousFused: 0, recon: 4, previousRecon: 0,
                                                 eventLabel: .workoutRun)
        XCTAssertFalse(walk.0)
        let extreme = WatchdogNotifyPolicy.decision(severity: .severe, openedEpisode: true,
                                                    safety: false, previousSafety: false,
                                                    fused: 4, previousFused: 0, recon: 4, previousRecon: 0,
                                                    eventLabel: .abnormalStillTachycardia)
        XCTAssertTrue(extreme.0)
        XCTAssertEqual(extreme.1, "episode-start")
    }

    func testBandAlphaShrinksSoLateTicksAreSmaller() {
        XCTAssertGreaterThan(WatchdogBand.alpha(nElig: 2), WatchdogBand.alpha(nElig: 80))
        XCTAssertEqual(WatchdogBand.alpha(nElig: WatchdogBand.nCap),
                       WatchdogBand.alpha(nElig: WatchdogBand.nCap + 400), accuracy: 1e-12)
    }
}
