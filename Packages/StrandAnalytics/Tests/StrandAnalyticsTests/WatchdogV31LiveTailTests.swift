import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Feedback 5: live stats use the current period tail after an activity ends.
final class WatchdogV31LiveTailTests: XCTestCase {

    private let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)

    func testTailCutsAtEffortToRest() {
        let w = try! runThenRest(now: 81_000_000, restMinutes: 8, restHR: 62)
        let tail = WatchdogLiveTail.resolve(w)
        XCTAssertEqual(tail.period, .rest)
        XCTAssertEqual(tail.previousPeriod, .effort)
        XCTAssertEqual(tail.startIndex, WatchdogConfig.seqLen - 8)
        XCTAssertGreaterThan(tail.lastEffortEndUnix, 0)
        XCTAssertEqual(tail.last(w.hr) ?? -1, 62, accuracy: 0.5)
        XCTAssertTrue(tail.postWorkout(carryEndUnix: 0, nowUnix: w.nowUnix))
    }

    func testLastDoesNotWalkIntoTheRun() {
        let w = try! runThenRest(now: 81_010_000, restMinutes: 3, restHR: nil)
        let tail = WatchdogLiveTail.resolve(w)
        XCTAssertEqual(tail.period, .rest)
        XCTAssertNil(tail.last(w.hr), "empty rest tail must not inherit 148")
        XCTAssertFalse(WatchdogSafety.fired(w))
    }

    func testRecoveredRestDoesNotSafetyPage() {
        let w = try! runThenRest(now: 81_020_000, restMinutes: 8, restHR: 62)
        XCTAssertFalse(WatchdogSafety.fired(w))
        let r = Watchdog.evaluate(window: .success(w), prompt: prompt, nowUnix: w.nowUnix)
        XCTAssertNotEqual(r.severity, .severe)
        XCTAssertFalse(r.shouldNotify)
        XCTAssertFalse(r.contributing.contains("HR"))
        XCTAssertFalse(r.contributing.contains("Temp"))
        XCTAssertFalse(r.contributing.contains("Resp"))
        XCTAssertTrue(r.eventLabel == WatchdogEventLabel.postWorkout.rawValue
                      || r.eventLabel == WatchdogEventLabel.normalStillAwake.rawValue
                      || r.eventLabel == WatchdogEventLabel.forecastDriftOnly.rawValue,
                      r.eventLabel)
        XCTAssertGreaterThan(r.carry.lastWorkoutEndUnix, 0)
    }

    func testNilRestMinutesUnderFreshnessDoNotUseRunHR() {
        let now = 81_030_000
        var feed = Watchdog.syntheticFeed(now: now, hr: 148, hrv: 35, temp: 34.8, resp: 28, motion: 0.85)
        let cut = now - 50
        feed.hr = feed.hr.filter { $0.ts < cut }
        feed.motion = feed.motion.map {
            WatchdogScalarSample(ts: $0.ts, value: $0.ts < cut ? 0.85 : 0.02)
        }
        let built = WatchdogWindowBuilder.build(feed)
        guard case .success(let w) = built else { XCTFail("\(built)"); return }
        XCTAssertLessThanOrEqual(w.newestAgeSeconds, WatchdogQuality.freshnessLimit(w.family))
        XCTAssertFalse(WatchdogSafety.fired(w), "walk-back 148 must not page a still tail")
    }

    func testLastMinuteStill132StillPages() {
        XCTAssertTrue(WatchdogSafety.fired(try! window(hr: 132, motion: 0)))
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(
            Watchdog.syntheticFeed(now: 81_040_000, hr: 132, hrv: 48, temp: 33.1, resp: 14, motion: 0)),
                                  prompt: prompt, nowUnix: 81_040_000)
        XCTAssertEqual(r.severity, .severe)
        XCTAssertTrue(r.shouldNotify)
    }

    func testMidWindowSpikeStillIgnored() {
        let now = 81_050_000
        var feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let start = now - WatchdogConfig.contextSeconds
        let mid = start + 5 * 60
        feed.hr = feed.hr.map {
            $0.ts >= mid && $0.ts < mid + 60 ? HRSample(ts: $0.ts, bpm: 132) : $0
        }
        let w = try! unwrap(WatchdogWindowBuilder.build(feed))
        XCTAssertFalse(WatchdogSafety.fired(w))
    }

    func testWorkoutMotionDoesNotSafetyPage() {
        XCTAssertFalse(WatchdogSafety.fired(try! window(hr: 132, motion: 1)))
    }

    func testFirstTickInfersPostWorkoutWithoutCarry() {
        let w = try! runThenRest(now: 81_060_000, restMinutes: 4, restHR: 70)
        let tail = WatchdogLiveTail.resolve(w)
        XCTAssertTrue(tail.postWorkout(carryEndUnix: 0, nowUnix: w.nowUnix))
        let r = Watchdog.evaluate(window: .success(w), prompt: prompt, nowUnix: w.nowUnix)
        XCTAssertGreaterThan(r.carry.lastWorkoutEndUnix, 0)
        XCTAssertNotEqual(r.severity, .severe)
    }

    func testLastPairedStaysInsideTail() {
        let w = try! runThenRest(now: 81_070_000, restMinutes: 6, restHR: 62)
        let tail = WatchdogLiveTail.resolve(w)
        let hat = w.hr.map { $0.map { _ in 58.0 } }
        let pair = UniTSRuntime.lastPaired(w.hr, hat, from: tail.startIndex)
        XCTAssertEqual(pair?.obs ?? 0, 62, accuracy: 0.5)
        let walked = UniTSRuntime.lastPaired(Array(repeating: nil, count: 24) + w.hr.suffix(6),
                                             hat, from: tail.startIndex)
        XCTAssertNotNil(walked)
    }

    func testQuietAllStillHasFullWindowTail() {
        let w = try! unwrap(WatchdogWindowBuilder.build(
            Watchdog.syntheticFeed(now: 81_080_000, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)))
        let tail = WatchdogLiveTail.resolve(w)
        XCTAssertEqual(tail.startIndex, 0)
        XCTAssertEqual(tail.period, .rest)
        XCTAssertEqual(tail.lastEffortEndUnix, 0)
    }

    // MARK: - tapes

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

    private func window(hr: Int, motion: Double) throws -> WatchdogWindow {
        try unwrap(WatchdogWindowBuilder.build(
            Watchdog.syntheticFeed(now: 19_000_000, hr: Double(hr), hrv: 48, temp: 33.1,
                                   resp: 14, motion: motion)))
    }

    private func unwrap(_ r: Result<WatchdogWindow, WatchdogUnavailable>) throws -> WatchdogWindow {
        switch r {
        case .success(let w): return w
        case .failure(let e): throw NSError(domain: "wd31", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "\(e)"])
        }
    }
}
