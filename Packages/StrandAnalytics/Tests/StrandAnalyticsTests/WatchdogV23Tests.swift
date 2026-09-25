import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class WatchdogV23Tests: XCTestCase {

    func testDirEqualWeightSameAbsOnAnyChannel() {
        var a = Array(repeating: 0.0, count: 6)
        var b = Array(repeating: 0.0, count: 6)
        let hr = WatchdogDirection.compute(rawR: [0.8, nil, nil, nil, nil, nil],
                                           rhrAllowed: true, artifact: false, dirEma: &a)
        let temp = WatchdogDirection.compute(rawR: [nil, nil, nil, 0.8, nil, nil],
                                             rhrAllowed: true, artifact: false, dirEma: &b)
        XCTAssertEqual(hr.rms, temp.rms, accuracy: 1e-9)
        XCTAssertEqual(hr.breadth, temp.breadth, accuracy: 1e-9)
        XCTAssertEqual(hr.joint, temp.joint, accuracy: 1e-9)
    }

    func testDirSixBeatsOne() {
        var one = Array(repeating: 0.0, count: 6)
        var six = Array(repeating: 0.0, count: 6)
        var lone = WatchdogDirectionResult.empty
        var pack = WatchdogDirectionResult.empty
        for _ in 0..<4 {
            lone = WatchdogDirection.compute(rawR: [2.5, 0.05, 0.05, 0.05, 0.05, 0.05],
                                             rhrAllowed: true, artifact: false, dirEma: &one)
            pack = WatchdogDirection.compute(rawR: [0.55, 0.55, 0.55, 0.55, 0.55, 0.55],
                                             rhrAllowed: true, artifact: false, dirEma: &six)
        }
        XCTAssertGreaterThan(pack.joint, lone.joint)
    }

    func testDirNoAutonomicBonus() {
        var a = Array(repeating: 0.0, count: 6)
        var b = Array(repeating: 0.0, count: 6)
        let auto = WatchdogDirection.compute(rawR: [0.7, nil, -0.7, nil, 0.7, nil],
                                             rhrAllowed: true, artifact: false, dirEma: &a)
        let other = WatchdogDirection.compute(rawR: [0.7, nil, nil, 0.7, nil, -0.7],
                                              rhrAllowed: true, artifact: false, dirEma: &b)
        XCTAssertEqual(auto.joint, other.joint, accuracy: 1e-9)
    }

    func testDirRHRMaskRenormalizes() {
        var e = Array(repeating: 0.0, count: 6)
        let d = WatchdogDirection.compute(rawR: [0.5, 0.9, 0.5, 0.5, 0.5, 0.5],
                                          rhrAllowed: false, artifact: false, dirEma: &e)
        XCTAssertFalse(d.mask[1])
        XCTAssertEqual(d.weights.filter { $0 > 0 }.count, 5)
        XCTAssertEqual(d.weights.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testJointHasNoMaxEscape() {
        let one = WatchdogScores.joint(energies: [2.8, 0.1, 0.1, 0.1, 0.1, 0.1])
        let three = WatchdogScores.joint(energies: [0.8, 0.8, 0.8, 0.1, 0.1, 0.1])
        XCTAssertLessThan(one, 2.8)
        XCTAssertGreaterThan(three, 0.5)
    }

    func testForecastCannotSevere() {
        let s = WatchdogScores.severity(recon: 0.2, forecast: 8, persistTicks: 4,
                                        safety: false, confounded: false, personalOff: false)
        XCTAssertNotEqual(s, .severe)
        let (n, _) = WatchdogNotifyPolicy.decision(severity: s, openedEpisode: true,
                                                   safety: false, previousSafety: false,
                                                   fused: 0.2, previousFused: 0, recon: 0.2, previousRecon: 0)
        XCTAssertFalse(n)
    }

    func testFusedIsReconOnly() {
        XCTAssertEqual(WatchdogScores.fused(recon: 0.2, forecast: 4), 0.2, accuracy: 1e-9)
    }

    func testEventPriorityWristBeatsAbnormal() {
        let lab = WatchdogEventLabeler.labelMinute(wristOff: true, gap: false, artifact: false,
                                                   cls: .still, postWorkout: false, sleep: false,
                                                   safety: true, explainedWorkout: false)
        XCTAssertEqual(lab, .wristOff)
    }

    func testOneMinuteWalkDoesNotSplitWhenCuttingSameLabel() {
        let labs: [WatchdogEventLabel] = Array(repeating: .normalStillAwake, count: 10)
        let ev = WatchdogEventLabeler.cutEvents(minuteLabels: labs, startUnix: 0)
        XCTAssertEqual(ev.count, 1)
    }

    func testWindowStraddleRejected() {
        let ev = [
            WatchdogEvent(eventId: "a", label: .normalStillAwake, t0: 0, t1: 600),
            WatchdogEvent(eventId: "b", label: .workoutWalk, t0: 600, t1: 1200)
        ]
        XCTAssertFalse(WatchdogEventLabeler.windowAccepted(events: ev, windowStart: 300, windowEnd: 900))
        XCTAssertTrue(WatchdogEventLabeler.windowAccepted(events: ev, windowStart: 0, windowEnd: 500))
    }

    func testActivityFeaturesWidth20() throws {
        let w = try window()
        let rows = WatchdogActivityFeatures.build(window: w)
        XCTAssertEqual(rows.count, 30)
        XCTAssertEqual(rows[0].count, WatchdogActivityFeatures.width)
    }

    func testEarlyForbiddenOnWorkoutLabel() {
        XCTAssertFalse(WatchdogEventLabeler.earlyAllowed(.workoutRun))
        XCTAssertTrue(WatchdogEventLabeler.earlyAllowed(.normalStillAwake))
    }

    func testMinutesDoNotWritePhaseUsual() {
        var store = WatchdogPhaseUsualStore.empty
        store.writeDay(key: WatchdogPhaseKey(phase: .morning, family: .walk),
                       dayMedian: [72, 60, 40, 33, 14, 97], civilDay: "2026-09-01")
        XCTAssertNil(store.mature(WatchdogPhaseKey(phase: .morning, family: .walk)))
        for i in 2...7 {
            store.writeDay(key: WatchdogPhaseKey(phase: .morning, family: .walk),
                           dayMedian: [72, 60, 40, 33, 14, 97],
                           civilDay: String(format: "2026-09-%02d", i))
        }
        XCTAssertNotNil(store.mature(WatchdogPhaseKey(phase: .morning, family: .walk)))
    }

    func testBandIgnoresIneligibleAndClamps() {
        var q = Array(repeating: 0.0, count: 6)
        var anchor = Array(repeating: 1.0, count: 6)
        var n = 0
        var ready = false
        var scale = Array(repeating: 1.0, count: 6)
        let spike = WatchdogBand.update(absResidual: [4, 0, 0, 0, 0, 0], eligible: true,
                                        q: &q, anchor: &anchor, n: &n, initialized: &ready,
                                        scale: &scale)
        XCTAssertEqual(n, 0)
        XCTAssertEqual(spike[0], 1, accuracy: 0.01)
        for _ in 0..<20 {
            _ = WatchdogBand.update(absResidual: [0.2, 0.2, 0.2, 0.2, 0.2, 0.2], eligible: true,
                                    q: &q, anchor: &anchor, n: &n, initialized: &ready,
                                    scale: &scale)
        }
        XCTAssertTrue(ready)
        XCTAssertGreaterThan(anchor[0], 0)
        XCTAssertLessThanOrEqual(scale[0], WatchdogBand.clampHi)
        XCTAssertGreaterThanOrEqual(scale[0], WatchdogBand.clampLo)
    }

    func testConfigIsV23() {
        XCTAssertEqual(WatchdogConfig.configVersion, "watchdog-v2.5")
        XCTAssertEqual(WatchdogCalibration.version, "prior-untuned")
        XCTAssertEqual(WatchdogConfig.fallbackModelVersion, "units-ad-recon-v4")
    }

    private func window() throws -> WatchdogWindow {
        let now = 40_000_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 60, hrv: 48, temp: 33, resp: 14, motion: 0)
        let built = WatchdogWindowBuilder.build(feed)
        if case .success(let w) = built { return w }
        XCTFail("window build failed")
        throw NSError(domain: "WatchdogV23", code: 1)
    }
}
