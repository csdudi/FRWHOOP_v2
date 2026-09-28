import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Boss 8: 120 s family hold, C4 mixed edge, memory cannot hide Early.
final class WatchdogV36EventTransitionTests: XCTestCase {

    private let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)

    override func tearDown() {
        WatchdogForecastRuntime.testPredict = nil
        super.tearDown()
    }

    func testClassHoldNeedsTwoMinutesNotTwoTicks() {
        var carry = WatchdogCarry.empty
        var now = 92_000_000
        carry = still(now: now, previous: carry).carry
        now += 20
        let t0 = now
        var last = walk(now: now, previous: carry)
        XCTAssertEqual(last.eventLabel, WatchdogEventLabel.mixedRejected.rawValue)
        XCTAssertNotEqual(last.cutReason, "class-hold")
        now += 20
        last = walk(now: now, previous: last.carry)
        XCTAssertEqual(last.eventLabel, WatchdogEventLabel.mixedRejected.rawValue)
        XCTAssertNotEqual(last.cutReason, "class-hold")
        now = t0 + WatchdogEventLabeler.familyHoldSeconds
        last = walk(now: now, previous: last.carry)
        XCTAssertTrue(last.cutReason == "class-hold" || last.eventLabel == WatchdogEventLabel.workoutWalk.rawValue,
                      "label=\(last.eventLabel) cut=\(last.cutReason)")
        XCTAssertEqual(last.eventLabel, WatchdogEventLabel.workoutWalk.rawValue)
        XCTAssertEqual(last.cutReason, "class-hold")
        XCTAssertEqual(last.carry.lastEventStartUnix, t0)
    }

    func testWorkoutNameWaitsForTwoMinuteHold() {
        let carry = still(now: 92_010_000, previous: .empty).carry
        let r = walk(now: 92_010_020, previous: carry)
        XCTAssertEqual(r.eventLabel, WatchdogEventLabel.mixedRejected.rawValue)
        XCTAssertNotEqual(r.eventLabel, WatchdogEventLabel.workoutWalk.rawValue)
    }

    func testHeldWalkIsWorkoutAndBlocksEarly() {
        let carry = still(now: 92_020_000, previous: .empty).carry
        var now = 92_020_020
        var last = walk(now: now, previous: carry)
        for _ in 0..<8 {
            now += 20
            last = walk(now: now, previous: last.carry)
        }
        XCTAssertEqual(last.eventLabel, WatchdogEventLabel.workoutWalk.rawValue)
        XCTAssertFalse(WatchdogEventLabeler.earlyAllowed(.workoutWalk))
        XCTAssertFalse(last.earlyFlag)
    }

    func testUnknownIsNotInferredWalk() {
        var mem = WatchdogEventMemory.empty
        let walkSig = WatchdogEventMemory.signature(d: [0.1, 0, 0, 0, 0, 0], reconJ: 0.2,
                                                    forecastJ: 0.1, cls: .walk, spo2Abs: 0)
        for _ in 0..<6 {
            _ = mem.observe(teacher: .workoutWalk, explained: true, sig: walkSig)
        }
        let unknown = WatchdogEventMemory.signature(d: [0.1, 0, 0, 0, 0, 0], reconJ: 0.2,
                                                    forecastJ: 0.1, cls: .unknown, spo2Abs: 0)
        let named = mem.observe(teacher: .normalStillAwake, explained: true, sig: unknown)
        XCTAssertNotEqual(named, .workoutWalk)
        XCTAssertEqual(named, .normalStillAwake)
    }

    func testMemoryCannotRenameForecastDriftToWorkout() {
        var mem = WatchdogEventMemory.empty
        let walkSig = WatchdogEventMemory.signature(d: [0.1, 0, 0, 0, 0, 0], reconJ: 0.2,
                                                    forecastJ: 1.2, cls: .walk, spo2Abs: 0)
        for _ in 0..<6 {
            _ = mem.observe(teacher: .workoutWalk, explained: true, sig: walkSig)
        }
        let drift = WatchdogEventMemory.signature(d: [0.1, 0, 0, 0, 0, 0], reconJ: 0.2,
                                                  forecastJ: 1.2, cls: .still, spo2Abs: 0)
        let named = mem.observe(teacher: .forecastDriftOnly, explained: true, sig: drift)
        XCTAssertEqual(named, .forecastDriftOnly)
        XCTAssertTrue(WatchdogEventLabeler.earlyAllowed(named))
    }

    func testMemoryStillCannotTurnLoudReconIntoWorkout() {
        var mem = WatchdogEventMemory.empty
        let walkSig = WatchdogEventMemory.signature(d: [0.1, 0, 0, 0, 0, 0], reconJ: 0.2,
                                                    forecastJ: 0.1, cls: .walk, spo2Abs: 0)
        for _ in 0..<6 {
            _ = mem.observe(teacher: .workoutWalk, explained: true, sig: walkSig)
        }
        let loud = WatchdogEventMemory.signature(d: [0.9, 0, 0, 0, 0, 0], reconJ: 1.5,
                                                 forecastJ: 0.2, cls: .walk, spo2Abs: 0)
        let named = mem.observe(teacher: .abnormalStillTachycardia, explained: false, sig: loud)
        XCTAssertNotEqual(named, .workoutWalk)
        XCTAssertTrue(WatchdogEventMemory.isAbnormal(named))
    }

    func testSleepNameFromIntervalNotClock() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let twoAM = cal.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 2))!
        let two = Int(twoAM.timeIntervalSince1970)
        let night = still(now: two, previous: .empty)
        XCTAssertNotEqual(night.eventLabel, WatchdogEventLabel.normalSleep.rawValue)

        let tenAM = cal.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 10))!
        let ten = Int(tenAM.timeIntervalSince1970)
        let session = WatchdogSleepInterval(startUnix: ten - 40 * 60, endUnix: ten + 3 * 3600)
        let asleep = Watchdog.evaluate(window: WatchdogWindowBuilder.build(stillFeed(now: ten)),
                                       prompt: prompt, nowUnix: ten,
                                       sleepIntervals: [session])
        XCTAssertEqual(asleep.eventLabel, WatchdogEventLabel.normalSleep.rawValue)
    }

    func testLiveHintDoesNotDisagreeWithWhat() {
        let now = 92_030_000
        let stillWin = try! unwrap(WatchdogWindowBuilder.build(stillFeed(now: now)))
        let hintStill = WatchdogEventLabeler.liveHint(window: stillWin, lastWorkoutEndUnix: 0)
        XCTAssertEqual(hintStill, .normalStillAwake)

        let walkWin = try! unwrap(WatchdogWindowBuilder.build(walkFeed(now: now)))
        let hintWalk = WatchdogEventLabeler.liveHint(window: walkWin, lastWorkoutEndUnix: 0)
        XCTAssertEqual(hintWalk, .mixedRejected)
        XCTAssertNotEqual(hintWalk, .workoutWalk)

        let session = WatchdogSleepInterval(startUnix: now - 40 * 60, endUnix: now + 3600)
        var sleepWin = stillWin
        sleepWin.bindActivityContext(lastWorkoutEndUnix: 0, sleepIntervals: [session])
        let hintSleep = WatchdogEventLabeler.liveHint(window: sleepWin, lastWorkoutEndUnix: 0)
        XCTAssertEqual(hintSleep, .normalSleep)
        XCTAssertEqual(
            WatchdogEventGeometry.what(cls: .still, reconJ: 0.2, forecastJ: 0, safety: false,
                                       artifact: false, postWorkout: false, sleep: true,
                                       hrHot: false, breadth: 0.1),
            .normalSleep)
    }

    func testPendingWalkDoesNotWriteStillSidecar() {
        var carry = WatchdogCarry.empty
        var now = 92_040_000
        for _ in 0..<20 {
            carry = still(now: now, previous: carry).carry
            now += 20
        }
        let native = carry.sessionNative
        XCTAssertGreaterThan(carry.sessionN, 0)
        let first = walk(now: now, previous: carry)
        XCTAssertEqual(first.eventLabel, WatchdogEventLabel.mixedRejected.rawValue)
        XCTAssertFalse(WatchdogEventLabeler.bandEligible(.mixedRejected))
        now += 20
        let second = walk(now: now, previous: first.carry)
        XCTAssertEqual(second.eventLabel, WatchdogEventLabel.mixedRejected.rawValue)
        XCTAssertEqual(second.carry.sessionN, first.carry.sessionN)
        XCTAssertEqual(second.carry.sessionNative[0], native[0], accuracy: 1e-9)
    }

    func testWearerPhraseHidesMixedToken() {
        XCTAssertEqual(WatchdogEventLabeler.wearerPhrase(.mixedRejected, lastCommitted: "normal_still_awake"),
                       "Still")
        XCTAssertEqual(WatchdogEventLabeler.wearerPhrase(.forecastDriftOnly), "Looking ahead")
        XCTAssertEqual(WatchdogEventLabeler.wearerPhrase(.workoutWalk), "Walking")
        XCTAssertNotEqual(WatchdogEventLabeler.wearerPhrase(.mixedRejected, lastCommitted: ""),
                          WatchdogEventLabel.mixedRejected.rawValue)
    }

    func testPendingWalkDoesNotAllowEarly() {
        WatchdogForecastRuntime.testPredict = .some(leavingCube())
        let carry = still(now: 92_050_000, previous: .empty).carry
        var last = walk(now: 92_050_020, previous: carry)
        last = walk(now: 92_050_040, previous: last.carry)
        XCTAssertEqual(last.eventLabel, WatchdogEventLabel.mixedRejected.rawValue)
        XCTAssertFalse(WatchdogEventLabeler.earlyAllowed(.mixedRejected))
        XCTAssertFalse(last.earlyFlag)
        XCTAssertFalse(last.shouldNotify)
    }

    func testSafety132StillPagesDuringHold() {
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(
            Watchdog.syntheticFeed(now: 92_060_000, hr: 132, hrv: 48, temp: 33.1, resp: 14, motion: 0)),
                                  prompt: prompt, nowUnix: 92_060_000)
        XCTAssertEqual(r.severity, .severe)
        XCTAssertTrue(r.shouldNotify)
        XCTAssertEqual(r.eventLabel, WatchdogEventLabel.safetyBound.rawValue)
    }

    // MARK: - tapes

    private func stillFeed(now: Int) -> WatchdogFeed {
        Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
    }

    private func walkFeed(now: Int, hr: Double = 88) -> WatchdogFeed {
        var feed = Watchdog.syntheticFeed(now: now, hr: hr, hrv: 40, temp: 33.4, resp: 16, motion: 0.40)
        let start = now - WatchdogConfig.contextSeconds
        feed.steps = (start..<now).map { StepSample(ts: $0, counter: 1, activityClass: 1) }
        return feed
    }

    private func still(now: Int, previous: WatchdogCarry) -> WatchdogResult {
        Watchdog.evaluate(window: WatchdogWindowBuilder.build(stillFeed(now: now)),
                          prompt: prompt, nowUnix: now, previous: previous)
    }

    private func walk(now: Int, previous: WatchdogCarry) -> WatchdogResult {
        Watchdog.evaluate(window: WatchdogWindowBuilder.build(walkFeed(now: now)),
                          prompt: prompt, nowUnix: now, previous: previous)
    }

    private func leavingCube() -> [[Double]] {
        var cube = (0..<6).map { k in
            Array(repeating: [58.0, 58.0, 48.0, 33.1, 14.0, 97.0][k], count: 5)
        }
        for t in 0..<5 {
            cube[0][t] = 130
            cube[3][t] = 36.8
            cube[4][t] = 24
        }
        return cube
    }

    private func unwrap(_ r: Result<WatchdogWindow, WatchdogUnavailable>) throws -> WatchdogWindow {
        switch r {
        case .success(let w): return w
        case .failure(let e): throw NSError(domain: "wd36", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "\(e)"])
        }
    }
}
