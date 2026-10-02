import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Boss 7: Early only from a real 6×5 path, not a hold or horizon[0] blip.
final class WatchdogV35ForecastEarlyTests: XCTestCase {

    private let usual = [58.0, 58.0, 48.0, 33.1, 14.0, 97.0]
    private let scales = [4.0, 4.0, 8.0, 0.3, 1.5, 1.2]
    private let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)

    override func tearDown() {
        WatchdogForecastRuntime.testPredict = nil
        super.tearDown()
    }

    func testFailedStudentDoesNotSetRanStudent() throws {
        WatchdogForecastRuntime.testPredict = .some(nil)
        let step = try liveStep()
        XCTAssertFalse(step.ranStudent)
        XCTAssertFalse(step.studentOk)
        XCTAssertEqual(WatchdogForecastRuntime.pathScore(step, usual: usual, scales: scales).labelJoint,
                       0, accuracy: 1e-9)
    }

    func testHoldFallbackDoesNotRaiseForecastJ() throws {
        WatchdogForecastRuntime.testPredict = .some(nil)
        let step = try liveStep()
        XCTAssertFalse(step.nextHR.isEmpty, "display hold may still fill five dots")
        let path = WatchdogForecastRuntime.pathScore(step, usual: usual, scales: scales)
        XCTAssertEqual(path.labelJoint, 0, accuracy: 1e-9)
        let r = try evaluate(now: 91_000_000, previous: .empty)
        XCTAssertFalse(r.earlyFlag)
        XCTAssertNotEqual(r.cutReason, "timesfm-onset")
        XCTAssertEqual(r.forecastEnergy, 0, accuracy: 1e-9)
    }

    func testFailedStudentDoesNotStampLastForecastUnix() throws {
        WatchdogForecastRuntime.testPredict = .some(nil)
        let r = try evaluate(now: 91_010_000, previous: .empty)
        XCTAssertFalse(r.carry.forecastStudentOk)
        XCTAssertEqual(r.carry.lastForecastUnix, 0)
        let again = try evaluate(now: 91_010_020, previous: r.carry)
        XCTAssertEqual(again.forecastEnergy, 0, accuracy: 1e-9)
        XCTAssertFalse(again.earlyFlag)
    }

    func testFirstHorizonSpikeAloneIsNotEarly() {
        var cube = onUsual()
        cube[0][0] = 96
        cube[3][0] = 35.8
        let path = WatchdogForecastRuntime.pathScore(cube: cube, usual: usual, scales: scales)
        XCTAssertEqual(path.stepsAboveNote, 1)
        XCTAssertEqual(path.labelJoint, 0, accuracy: 1e-9)
    }

    func testLateHorizonLeaveIsVisible() {
        var cube = onUsual()
        for t in 2..<5 {
            cube[0][t] = 96
            cube[3][t] = 35.8
        }
        let path = WatchdogForecastRuntime.pathScore(cube: cube, usual: usual, scales: scales)
        XCTAssertGreaterThanOrEqual(path.stepsAboveNote, 2)
        XCTAssertGreaterThanOrEqual(path.hotChannels, 2)
        XCTAssertGreaterThanOrEqual(path.labelJoint, WatchdogCalibration.tNote)
    }

    func testSingleChannelPathIsNotEarly() {
        var cube = onUsual()
        for t in 0..<5 { cube[0][t] = 96 }
        let path = WatchdogForecastRuntime.pathScore(cube: cube, usual: usual, scales: scales)
        XCTAssertEqual(path.hotChannels, 1)
        XCTAssertEqual(path.labelJoint, 0, accuracy: 1e-9)
        XCTAssertFalse(WatchdogForecastRuntime.wearerEarly(
            pathJ: path.labelJoint, allowed: true, severity: .withinLimits,
            trustPct: 80, persistTicks: 2, forecastSource: "inject"))
    }

    func testTwoChannelFullPathCanEarly() throws {
        WatchdogForecastRuntime.testPredict = .some(leavingCube())
        let now = 91_020_000
        let first = try evaluate(now: now, previous: .empty)
        XCTAssertTrue(first.carry.forecastStudentOk)
        XCTAssertGreaterThanOrEqual(first.forecastEnergy, 0)
        let second = try evaluate(now: now + 20, previous: first.carry)
        XCTAssertTrue(second.eventLabel == WatchdogEventLabel.forecastDriftOnly.rawValue
                      || second.earlyFlag,
                      "label=\(second.eventLabel) early=\(second.earlyFlag) Jfc=\(second.forecastEnergy)")
        XCTAssertFalse(second.shouldNotify)
        XCTAssertNotEqual(second.severity, .severe)
    }

    func testPartialCubeIsZero() {
        let short = Array(repeating: Array(repeating: 90.0, count: 3), count: 6)
        XCTAssertEqual(WatchdogForecastRuntime.pathScore(cube: short, usual: usual, scales: scales).labelJoint,
                       0, accuracy: 1e-9)
        let five = Array(repeating: Array(repeating: 90.0, count: 5), count: 5)
        XCTAssertEqual(WatchdogForecastRuntime.pathScore(cube: five, usual: usual, scales: scales).labelJoint,
                       0, accuracy: 1e-9)
    }

    func testLowTrustHidesWearerEarly() {
        XCTAssertTrue(WatchdogForecastRuntime.wearerEarly(
            pathJ: 1.4, allowed: true, severity: .withinLimits, trustPct: 80, persistTicks: 2,
            forecastSource: "inject"))
        XCTAssertFalse(WatchdogForecastRuntime.wearerEarly(
            pathJ: 1.4, allowed: true, severity: .withinLimits, trustPct: 20, persistTicks: 2,
            forecastSource: "inject"))
    }

    func testForecastStillCannotSevere() throws {
        WatchdogForecastRuntime.testPredict = .some(leavingCube())
        let now = 91_030_000
        var last = try evaluate(now: now, previous: .empty)
        last = try evaluate(now: now + 20, previous: last.carry)
        XCTAssertNotEqual(last.severity, .severe)
        XCTAssertFalse(last.shouldNotify)
        let fused = WatchdogScores.fused(recon: 0.2, forecast: 8)
        XCTAssertEqual(fused, 0.2, accuracy: 1e-9)
    }

    private func onUsual() -> [[Double]] {
        (0..<6).map { k in Array(repeating: usual[k], count: 5) }
    }

    private func leavingCube() -> [[Double]] {
        var cube = onUsual()
        for t in 0..<5 {
            cube[0][t] = 130
            cube[3][t] = 36.8
            cube[4][t] = 24
        }
        return cube
    }

    private func liveStep() throws -> WatchdogForecastStep {
        let feed = Watchdog.syntheticFeed(now: 91_100_000, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let w = try unwrap(WatchdogWindowBuilder.build(feed))
        let residual = try UniTSRuntime().reconstruct(w, prompt: prompt)
        return WatchdogForecastRuntime().step(window: w, residual: residual, prompt: prompt, carry: .empty)
    }

    private func evaluate(now: Int, previous: WatchdogCarry) throws -> WatchdogResult {
        let feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        return Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                 prompt: prompt, nowUnix: now, previous: previous)
    }

    private func unwrap(_ r: Result<WatchdogWindow, WatchdogUnavailable>) throws -> WatchdogWindow {
        switch r {
        case .success(let w): return w
        case .failure(let e): throw NSError(domain: "wd35", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "\(e)"])
        }
    }
}
