import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Feedback 4: model severe uses a clipped sum that can pass tSevere 2.4.
/// The tanh label fold stays capped at 2.0 and is not the severe door.
final class WatchdogV30SeverityJointTests: XCTestCase {

    private let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)

    // MARK: - Fold (no window)

    func testCalibrationBarStaysPriorUntuned() {
        XCTAssertEqual(WatchdogCalibration.tNote, 1.0)
        XCTAssertEqual(WatchdogCalibration.tActive, 1.6)
        XCTAssertEqual(WatchdogCalibration.tSevere, 2.4)
        XCTAssertEqual(WatchdogCalibration.persistTicks, 2)
        XCTAssertEqual(WatchdogCalibration.version, "prior-untuned")
        XCTAssertEqual(WatchdogScores.severityChannelCap, 1.0)
    }

    func testTanhLabelFoldStillCannotReachSevere() {
        var ema = Array(repeating: 0.0, count: 6)
        var dir = WatchdogDirectionResult.empty
        for _ in 0..<6 {
            dir = WatchdogDirection.compute(
                rawR: [3, 3, 3, 3, 3, 3],
                rhrAllowed: true, artifact: false, dirEma: &ema)
        }
        XCTAssertLessThanOrEqual(dir.joint, 2.0 + 1e-9)
        XCTAssertLessThan(dir.joint, WatchdogCalibration.tSevere)
    }

    func testOneChannelClipsToOneAndCannotModelSevere() {
        let j = WatchdogScores.severityJoint(
            absR: [3.0, 0, 0, 0, 0, 0],
            mask: [true, false, false, false, false, false],
            artifact: false)
        XCTAssertEqual(j, 1.0, accuracy: 1e-12)
        let sev = WatchdogScores.severity(recon: j, persistTicks: 4, safety: false,
                                          confounded: false, personalOff: false)
        XCTAssertNotEqual(sev, .severe)
        XCTAssertNotEqual(sev, .active)
    }

    func testRHRDoesNotCountAsASecondMetric() {
        let hrOnly = WatchdogScores.severityJoint(
            absR: [1.2, 0, 0, 0, 0, 0],
            mask: [true, false, false, false, false, false],
            artifact: false)
        let hrPlusRhr = WatchdogScores.severityJoint(
            absR: [1.2, 1.2, 0, 0, 0, 0],
            mask: [true, true, false, false, false, false],
            artifact: false)
        XCTAssertEqual(hrOnly, 1.0, accuracy: 1e-12)
        XCTAssertEqual(hrPlusRhr, hrOnly, accuracy: 1e-12)
    }

    func testTwoChannelsReachActiveNotSevere() {
        let j = WatchdogScores.severityJoint(
            absR: [1.0, 0, 1.0, 0, 0, 0],
            mask: [true, false, true, false, false, false],
            artifact: false)
        XCTAssertEqual(j, 2.0, accuracy: 1e-12)
        XCTAssertLessThan(j, WatchdogCalibration.tSevere)
        let sev = WatchdogScores.severity(recon: j, persistTicks: 2, safety: false,
                                          confounded: false, personalOff: false)
        XCTAssertEqual(sev, .active)
    }

    func testThreeChannelsCrossSevereAfterPersist() {
        let j = WatchdogScores.severityJoint(
            absR: [1.0, 0, 1.0, 1.0, 0, 0],
            mask: [true, false, true, true, false, false],
            artifact: false)
        XCTAssertEqual(j, 3.0, accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(j, WatchdogCalibration.tSevere)
        let oneTick = WatchdogScores.severity(recon: j, persistTicks: 1, safety: false,
                                              confounded: false, personalOff: false)
        XCTAssertNotEqual(oneTick, .severe)
        let twoTicks = WatchdogScores.severity(recon: j, persistTicks: 2, safety: false,
                                               confounded: false, personalOff: false)
        XCTAssertEqual(twoTicks, .severe)
    }

    func testPartialsAddWithoutThreeSaturatedFlags() {
        let j = WatchdogScores.severityJoint(
            absR: [0.9, 0, 0.9, 0.7, 0, 0],
            mask: [true, false, true, true, false, false],
            artifact: false)
        XCTAssertEqual(j, 2.5, accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(j, WatchdogCalibration.tSevere)
    }

    func testManyModerateChannelsAlsoAdd() {
        let j = WatchdogScores.severityJoint(
            absR: [0.5, 0, 0.5, 0.5, 0.5, 0.5],
            mask: [true, false, true, true, true, true],
            artifact: false)
        XCTAssertEqual(j, 2.5, accuracy: 1e-12)
    }

    func testArtifactDampsTheSum() {
        let loud = WatchdogScores.severityJoint(
            absR: [1, 0, 1, 1, 0, 0],
            mask: [true, false, true, true, false, false],
            artifact: false)
        let art = WatchdogScores.severityJoint(
            absR: [1, 0, 1, 1, 0, 0],
            mask: [true, false, true, true, false, false],
            artifact: true)
        XCTAssertEqual(art, loud * WatchdogScores.severityArtifactGain, accuracy: 1e-12)
        XCTAssertLessThan(art, WatchdogCalibration.tSevere)
    }

    func testForecastCannotSevereOnTheModelDoor() {
        let s = WatchdogScores.severity(recon: 0.2, forecast: 8, persistTicks: 4,
                                        safety: false, confounded: false, personalOff: false)
        XCTAssertNotEqual(s, .severe)
    }

    func testSafetyDoorStillIgnoresTheSum() {
        let s = WatchdogScores.severity(recon: 0.1, persistTicks: 0, safety: true,
                                        confounded: false, personalOff: false)
        XCTAssertEqual(s, .severe)
    }

    func testDirectionComputeWritesBothJoints() {
        var ema = Array(repeating: 0.0, count: 6)
        let dir = WatchdogDirection.compute(
            rawR: [1.2, 1.2, 1.1, 1.0, nil, nil],
            rhrAllowed: true, artifact: false, dirEma: &ema)
        XCTAssertEqual(dir.severityJoint, 3.0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(dir.joint, 2.0 + 1e-9)
        XCTAssertTrue(dir.mask[1], "RHR stays in the label fold")
    }

    // MARK: - Live evaluate

    func testOneStillHRShiftIsNotModelSevere() {
        let now = 40_300_000
        var carry = WatchdogCarry.empty
        carry.consecutiveMismatchTicks = 4
        let feed = Watchdog.syntheticFeed(now: now, hr: 96, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let win = WatchdogWindowBuilder.build(feed)
        if case .success(let w) = win {
            XCTAssertFalse(WatchdogSafety.fired(w), "96 bpm is not the safety cap")
        } else {
            XCTFail("window")
        }
        let r = Watchdog.evaluate(window: win, prompt: prompt, nowUnix: now, previous: carry)
        XCTAssertLessThan(r.jointEnergy, WatchdogCalibration.tActive,
                          "HR + leftover jitter must stay below two clipped vitals")
        XCTAssertNotEqual(r.severity, .severe)
        XCTAssertNotEqual(r.severity, .active)
        XCTAssertFalse(r.shouldNotify)
    }

    func testTwoDistinctVitalsAreActiveNotSevere() {
        let now = 40_310_000
        var carry = WatchdogCarry.empty
        carry.consecutiveMismatchTicks = 4
        let feed = Watchdog.syntheticFeed(now: now, hr: 96, hrv: 48, temp: 34.3, resp: 14, motion: 0)
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: prompt, nowUnix: now, previous: carry)
        XCTAssertGreaterThanOrEqual(r.jointEnergy, WatchdogCalibration.tActive)
        XCTAssertLessThan(r.jointEnergy, WatchdogCalibration.tSevere)
        XCTAssertEqual(r.severity, .active)
        XCTAssertFalse(r.shouldNotify)
    }

    func testThreeDistinctVitalsModelSevereOnSecondTickWithoutSafety() {
        let now = 40_320_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 96, hrv: 48, temp: 34.3, resp: 22, motion: 0)
        let win = WatchdogWindowBuilder.build(feed)
        guard case .success(let w) = win else {
            XCTFail("window"); return
        }
        XCTAssertFalse(WatchdogSafety.fired(w), "must be the model door, not HR>120 / temp / resp caps")
        let first = Watchdog.evaluate(window: .success(w), prompt: prompt, nowUnix: now)
        XCTAssertGreaterThanOrEqual(first.jointEnergy, WatchdogCalibration.tSevere, first.episodeLine)
        XCTAssertNotEqual(first.severity, .severe, "persist needs two ticks")
        let second = Watchdog.evaluate(window: .success(w), prompt: prompt, nowUnix: now + 60,
                                       previous: first.carry)
        XCTAssertEqual(second.severity, .severe, second.episodeLine)
        XCTAssertGreaterThanOrEqual(second.jointEnergy, WatchdogCalibration.tSevere)
        XCTAssertFalse(WatchdogSafety.fired(w), "safety must stay dark")
    }

    func testSafetyStillHRStillSeversWithoutThreeVitals() {
        let now = 40_330_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 132, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: prompt, nowUnix: now)
        XCTAssertEqual(r.severity, .severe)
        XCTAssertTrue(r.shouldNotify)
    }

    func testIllnessLogStillCapsModelSevere() {
        let now = 40_340_000
        var carry = WatchdogCarry.empty
        carry.consecutiveMismatchTicks = 4
        let feed = Watchdog.syntheticFeed(now: now, hr: 96, hrv: 16, temp: 34.3, resp: 22, motion: 0)
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: prompt,
                                  dayLog: LBDayLog(feltIll: true),
                                  nowUnix: now, previous: carry)
        XCTAssertGreaterThanOrEqual(r.jointEnergy, WatchdogCalibration.tSevere)
        XCTAssertEqual(r.severity, .candidate)
        XCTAssertFalse(r.shouldNotify)
    }

    func testStableSevereInjectDoesNotEscalateFromScaleMix() {
        let t = 40_360_000
        let first = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                      nowUnix: t, inject: .severe)
        XCTAssertTrue(first.shouldNotify)
        let second = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                       nowUnix: t + 60, previous: first.carry, inject: .severe)
        XCTAssertEqual(second.severity, .severe)
        XCTAssertFalse(second.shouldNotify)
        XCTAssertEqual(second.notifyReason, "stable-episode")
    }

    func testQuietWindowStaysBelowNote() {
        let now = 40_350_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: prompt, nowUnix: now)
        XCTAssertLessThan(r.jointEnergy, WatchdogCalibration.tNote)
        XCTAssertEqual(r.severity, .withinLimits)
    }
}
