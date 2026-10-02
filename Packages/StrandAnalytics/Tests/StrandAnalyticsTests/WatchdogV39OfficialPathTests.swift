import XCTest
@testable import StrandAnalytics

final class WatchdogV39OfficialPathTests: XCTestCase {
    private let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)

    func testUnknownEffortDoesNotBecomeWalk() {
        let feed = Watchdog.syntheticFeed(now: 93_000_000, hr: 88, hrv: 40, temp: 33.4, resp: 16, motion: 0.5)
        guard case .success(var win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        win.activityLogits = Array(repeating: Array(repeating: 0.0, count: 8), count: 30)
        win.activityFeatures = Array(repeating: Array(repeating: 0.0, count: 20), count: 30)
        let tail = WatchdogLiveTail(startIndex: 0, period: .effort, previousPeriod: nil,
                                    lastEffortEndUnix: 0, startUnix: win.startUnix, nowUnix: win.nowUnix)
        let cls = WatchdogEventGeometry.evidencedClass(window: win, tail: tail, logitCls: .unknown)
        XCTAssertEqual(cls, .unknown)
    }

    func testSevereNameIsNotNormal() {
        var ema = Array(repeating: 0.0, count: 6)
        let dir = WatchdogDirection.compute(
            rawR: [1.0, nil, 1.0, 1.0, nil, nil],
            rhrAllowed: true, artifact: false, dirEma: &ema)
        XCTAssertGreaterThanOrEqual(dir.severityJoint, WatchdogCalibration.tSevere - 1e-9)
        let lab = WatchdogEventGeometry.what(
            cls: .still, reconJ: dir.severityJoint, forecastJ: 0,
            safety: false, artifact: false, postWorkout: false, sleep: false,
            hrHot: true, breadth: 0.5, spo2Hot: false, maxAbsR: 1.0, familyHeld: true)
        XCTAssertFalse(lab.rawValue.hasPrefix("normal_"))
        let sev = WatchdogScores.severity(recon: dir.severityJoint, persistTicks: 2,
                                          safety: false, confounded: false, personalOff: false)
        XCTAssertEqual(sev, .severe)
        let (notify, _) = WatchdogNotifyPolicy.decision(
            severity: sev, openedEpisode: true, safety: false, previousSafety: false,
            fused: dir.severityJoint, previousFused: 0, recon: dir.severityJoint,
            previousRecon: 0, eventLabel: lab)
        XCTAssertTrue(notify)
        XCTAssertTrue(WatchdogNotifyPolicy.extremeFamily(lab))
    }

    func testWristOffNotClearedByFreshPacket() {
        XCTAssertTrue(WatchdogLiveTape.wristOff(deviceOff: true, freshLiveHR: true))
    }

    func testStaleTempIsMaskedBeforeModels() {
        let now = 94_000_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 60, hrv: 40, temp: 33.2, resp: 14, motion: 0)
        guard case .success(var win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        win.temp = (0..<30).map { $0 == 0 ? 33.2 : nil }
        XCTAssertFalse(WatchdogQuality.channelFresh(win.temp, startUnix: win.startUnix, nowUnix: win.nowUnix,
                                                    channel: 3, family: win.family))
        win.maskStaleChannels()
        XCTAssertTrue(win.temp.allSatisfy { $0 == nil })
        XCTAssertTrue(WatchdogQuality.channelFresh(win.hr, startUnix: win.startUnix, nowUnix: win.nowUnix,
                                                   channel: 0, family: win.family))
        let mask = UniTSRuntime.packPresentMask(win)
        XCTAssertEqual(mask[3].reduce(0, +), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(mask[0].reduce(0, +), 0)
    }

    func testHoldForecastCannotEarly() {
        XCTAssertFalse(WatchdogForecastRuntime.wearerEarly(
            pathJ: 1.4, allowed: true, severity: .withinLimits, trustPct: 80, persistTicks: 2,
            forecastSource: "hold"))
        XCTAssertFalse(WatchdogForecastRuntime.wearerEarly(
            pathJ: 1.4, allowed: true, severity: .withinLimits, trustPct: 80, persistTicks: 2,
            forecastSource: "student"))
        XCTAssertTrue(WatchdogForecastRuntime.wearerEarly(
            pathJ: 1.4, allowed: true, severity: .withinLimits, trustPct: 80, persistTicks: 2,
            forecastSource: "official"))
    }

    func testInjectForecastSourceAndRing() throws {
        WatchdogForecastRuntime.testPredict = .some(Array(repeating: Array(repeating: 90.0, count: 5), count: 6))
        defer { WatchdogForecastRuntime.testPredict = nil }
        let now = 95_000_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let win = WatchdogWindowBuilder.build(feed)
        let result = Watchdog.evaluate(
            window: win,
            prompt: prompt,
            nowUnix: now,
            previous: .empty)
        XCTAssertEqual(result.forecastSource, "inject")
        XCTAssertEqual(result.carry.lastForecastSource, "inject")
        XCTAssertEqual(result.carry.forecastJRing.count, 1)
        XCTAssertNotEqual(result.severity, .severe)
    }

    func testDayTapeUniqueMinuteAndRecovery() {
        let now = 96_000_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 62, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        guard case .success(let win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        var tape = LBDayTape(day: "2026-09-29")
        XCTAssertTrue(tape.ingest(window: win, nowUnix: now))
        let n1 = tape.restHR.n
        XCTAssertFalse(tape.ingest(window: win, nowUnix: now))
        XCTAssertEqual(tape.restHR.n, n1)
        var recovering = LBDayTape(day: "2026-09-29")
        XCTAssertTrue(recovering.ingest(window: win, nowUnix: now, lastWorkoutEndUnix: now - 60))
        XCTAssertEqual(recovering.restHR.n, 0)
        XCTAssertGreaterThan(recovering.allHR.n, 0)
    }

    func testWatchdogSourceIdsStayActiveOnly() {
        XCTAssertEqual(WatchdogConfig.seqLen, 30)
        XCTAssertEqual(WatchdogConfig.forecastModelVersion, "timesfm3-student-v2")
    }
}
