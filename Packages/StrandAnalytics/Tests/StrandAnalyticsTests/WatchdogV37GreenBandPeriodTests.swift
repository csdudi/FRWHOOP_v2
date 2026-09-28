import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Boss 9: band is keyed by the existing PhaseKey, minutes not ticks.
final class WatchdogV37GreenBandPeriodTests: XCTestCase {

    private let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)

    override func setUp() {
        super.setUp()
        WatchdogForecastRuntime.testPredict = .some(nil)
    }

    override func tearDown() {
        WatchdogForecastRuntime.testPredict = nil
        super.tearDown()
    }

    func testFourteenTicksAreNotFourteenMinutes() {
        var carry = WatchdogCarry.empty
        let t0 = 93_000_000
        var last = still(now: t0, previous: carry)
        carry = last.carry
        for i in 1..<14 {
            last = still(now: t0 + i * 20, previous: carry)
            carry = last.carry
        }
        XCTAssertFalse(carry.bandReady, "14 ticks in ~4.7 min must not mature the band")
        XCTAssertLessThan(carry.bandN, WatchdogBand.firstMinutes)
        for i in 0..<14 {
            last = still(now: t0 + 400 + i * 60, previous: carry)
            carry = last.carry
        }
        XCTAssertTrue(carry.bandReady)
        XCTAssertGreaterThanOrEqual(carry.bandN, WatchdogBand.firstMinutes)
    }

    func testSleepAndStillAwakeDoNotShareQ() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let twoAM = Int(cal.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 2))!
            .timeIntervalSince1970)
        let twoPM = Int(cal.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 14))!
            .timeIntervalSince1970)
        var carry = WatchdogCarry.empty
        let night = WatchdogSleepInterval(startUnix: twoAM - 40 * 60, endUnix: twoAM + 4 * 3600)
        for i in 0..<16 {
            carry = Watchdog.evaluate(window: WatchdogWindowBuilder.build(stillFeed(now: twoAM + i * 60)),
                                      prompt: prompt, nowUnix: twoAM + i * 60, previous: carry,
                                      sleepIntervals: [night]).carry
        }
        let sleepKey = WatchdogPhaseKey(phase: .sleep, family: .still).id
        let sleepN = carry.bandByKey[sleepKey]?.n ?? 0
        let sleepQ = carry.bandByKey[sleepKey]?.q[0] ?? 0
        XCTAssertGreaterThan(sleepN, 0)
        for i in 0..<10 {
            carry = still(now: twoPM + i * 60, previous: carry).carry
        }
        XCTAssertEqual(carry.bandByKey[sleepKey]?.n ?? 0, sleepN)
        XCTAssertEqual(carry.bandByKey[sleepKey]?.q[0] ?? -1, sleepQ, accuracy: 1e-9)
        let dayKey = WatchdogPhaseUsualStore.phase(nowUnix: twoPM, sleepBit: false)
        XCTAssertNotEqual(carry.bandByKey[WatchdogPhaseKey(phase: dayKey, family: .still).id]?.n ?? 0, 0)
    }

    func testMorningWalkDoesNotWriteDeskStill() {
        var carry = still(now: 93_100_000, previous: .empty).carry
        let stillKey = carry.lastBandKey
        let stillN = carry.bandByKey[stillKey]?.n ?? carry.bandN
        var now = 93_100_060
        var last = walk(now: now, previous: carry, hr: 62)
        for _ in 0..<10 {
            now += 60
            last = walk(now: now, previous: last.carry, hr: 62)
        }
        carry = last.carry
        XCTAssertEqual(last.eventLabel, WatchdogEventLabel.workoutWalk.rawValue, last.eventLabel)
        XCTAssertEqual(carry.bandByKey[stillKey]?.n ?? stillN, stillN)
        let walkFam = WatchdogPhaseUsualStore.family(label: .workoutWalk, cls: .walk)
        XCTAssertEqual(walkFam, .walk)
        XCTAssertTrue(carry.bandByKey.keys.contains { $0.contains("walk") },
                      "held walk must address a walk PhaseKey, not the desk still slot")
    }

    func testDeskStillDoesNotPaintWalk() {
        var carry = WatchdogCarry.empty
        let t0 = 93_200_000
        for i in 0..<16 {
            carry = still(now: t0 + i * 60, previous: carry).carry
        }
        XCTAssertTrue(carry.bandReady)
        var now = t0 + 20 * 60
        var last = walk(now: now, previous: carry)
        for _ in 0..<8 {
            now += 20
            last = walk(now: now, previous: last.carry)
        }
        XCTAssertEqual(last.eventLabel, WatchdogEventLabel.workoutWalk.rawValue, last.eventLabel)
        XCTAssertFalse(last.sigmaAdaptive, "unready walk key must paint model σ")
        let walkReady = last.carry.bandByKey.filter { $0.key.contains("walk") }.values.contains { $0.ready }
        XCTAssertFalse(walkReady)
    }

    func testPostWorkoutHasOwnKey() {
        let now = 93_300_000
        var carry = WatchdogCarry.empty
        carry.lastWorkoutEndUnix = now - 4 * 60
        let r = still(now: now, previous: carry)
        XCTAssertEqual(r.eventLabel, WatchdogEventLabel.postWorkout.rawValue, r.eventLabel)
        let n = r.carry.bandByKey.filter { $0.key.contains("post_workout") }.values.map(\.n).max() ?? 0
        XCTAssertGreaterThan(n, 0)
        let stillN = r.carry.bandByKey.filter { $0.key.contains("still") && !$0.key.contains("post") }
            .values.map(\.n).max() ?? 0
        XCTAssertEqual(stillN, 0)
    }

    func testEveningStillDoesNotMoveMorningStill() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let morning = Int(cal.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 9))!
            .timeIntervalSince1970)
        let evening = Int(cal.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 19))!
            .timeIntervalSince1970)
        var carry = WatchdogCarry.empty
        for i in 0..<8 {
            carry = still(now: morning + i * 60, previous: carry).carry
        }
        let mKey = WatchdogPhaseKey(phase: .morning, family: .still).id
        let mN = carry.bandByKey[mKey]?.n ?? 0
        XCTAssertGreaterThan(mN, 0)
        for i in 0..<8 {
            carry = still(now: evening + i * 60, previous: carry).carry
        }
        XCTAssertEqual(carry.bandByKey[mKey]?.n ?? 0, mN)
        XCTAssertGreaterThan(carry.bandByKey[WatchdogPhaseKey(phase: .evening, family: .still).id]?.n ?? 0, 0)
    }

    func testFeltIllDoesNotAdvanceBand() {
        let now = 93_400_000
        var carry = WatchdogCarry.empty
        for i in 0..<8 {
            carry = Watchdog.evaluate(window: WatchdogWindowBuilder.build(stillFeed(now: now + i * 60)),
                                      prompt: prompt, dayLog: LBDayLog(feltIll: true),
                                      nowUnix: now + i * 60, previous: carry).carry
        }
        XCTAssertEqual(carry.bandN, 0)
        XCTAssertTrue(carry.bandByKey.values.allSatisfy { $0.n == 0 } || carry.bandByKey.isEmpty)
    }

    func testForecastDriftDoesNotTrainBand() {
        WatchdogForecastRuntime.testPredict = .some(leavingCube())
        let carry = still(now: 93_500_000, previous: .empty).carry
        let n0 = carry.bandN
        let second = Watchdog.evaluate(window: WatchdogWindowBuilder.build(stillFeed(now: 93_500_020)),
                                       prompt: prompt, nowUnix: 93_500_020, previous: carry)
        XCTAssertTrue(second.eventLabel == WatchdogEventLabel.forecastDriftOnly.rawValue || second.earlyFlag,
                      second.eventLabel)
        if second.eventLabel == WatchdogEventLabel.forecastDriftOnly.rawValue {
            XCTAssertEqual(second.carry.bandN, n0)
        }
    }

    func testMixedWalkDoesNotTrainBand() {
        let carry = still(now: 93_600_000, previous: .empty).carry
        let first = walk(now: 93_600_020, previous: carry)
        let second = walk(now: 93_600_040, previous: first.carry)
        XCTAssertEqual(second.eventLabel, WatchdogEventLabel.mixedRejected.rawValue)
        let walkN = second.carry.bandByKey.filter { $0.key.contains("walk") }.values.map(\.n).max() ?? 0
        XCTAssertEqual(walkN, 0)
    }

    func testAdaptiveFloorDoesNotShrinkJ() {
        let now = 93_700_000
        var carry = WatchdogCarry.empty
        carry.quietN = 20
        carry.quietAbsHR = 8
        let loud = Watchdog.syntheticFeed(now: now, hr: 96, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let seeded = WatchdogCarry.empty
        let a = Watchdog.evaluate(window: WatchdogWindowBuilder.build(loud),
                                  prompt: prompt, nowUnix: now, previous: carry)
        let b = Watchdog.evaluate(window: WatchdogWindowBuilder.build(loud),
                                  prompt: prompt, nowUnix: now, previous: seeded)
        XCTAssertEqual(a.jointEnergy, b.jointEnergy, accuracy: 0.15)
    }

    func testDisplayScaleStaysInsideThatKeyAnchor() {
        var q = Array(repeating: 0.0, count: 6)
        var anchor = Array(repeating: 1.0, count: 6)
        var n = 0
        var ready = false
        var scale = Array(repeating: 1.0, count: 6)
        var last = 0
        for i in 0..<14 {
            _ = WatchdogBand.update(absResidual: [0.25, 0.25, 0.25, 0.25, 0.25, 0.25],
                                    eligible: true, q: &q, anchor: &anchor, n: &n,
                                    initialized: &ready, scale: &scale,
                                    nowUnix: 1_000 + i * 60, lastUnix: &last)
        }
        XCTAssertTrue(ready)
        for i in 0..<200 {
            _ = WatchdogBand.update(absResidual: [1.1, 1.1, 1.1, 1.1, 1.1, 1.1],
                                    eligible: true, q: &q, anchor: &anchor, n: &n,
                                    initialized: &ready, scale: &scale,
                                    nowUnix: 2_000 + i * 60, lastUnix: &last)
        }
        XCTAssertLessThanOrEqual(scale[0], WatchdogBand.clampHi)
        XCTAssertGreaterThanOrEqual(scale[0], WatchdogBand.clampLo)
    }

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

    private func walk(now: Int, previous: WatchdogCarry, hr: Double = 88) -> WatchdogResult {
        Watchdog.evaluate(window: WatchdogWindowBuilder.build(walkFeed(now: now, hr: hr)),
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
}
