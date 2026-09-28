import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Locks Prime Agent 24 Sep leaks (A–G) without loosening still-tachycardia or quality gates.
final class WatchdogV26PrimeFixTests: XCTestCase {

    private let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)

    func testAStillHighHRStillFiresSafety() throws {
        XCTAssertTrue(WatchdogSafety.fired(try window(hr: 132, motion: 0)))
        XCTAssertFalse(WatchdogSafety.fired(try window(hr: 132, motion: 1)))
    }

    func testAMissingMotionDoesNotTreatWorkoutHRAsStill() throws {
        let now = 70_000_000
        var feed = Watchdog.syntheticFeed(now: now, hr: 140, hrv: 40, temp: 33.1, resp: 18, motion: 0.7)
        feed.motion = []
        feed.imu = []
        feed.steps = []
        let w = try unwrapWindow(WatchdogWindowBuilder.build(feed))
        XCTAssertFalse(WatchdogSafety.fired(w), "no-IMU run/cycle must not page via rest-HR")
    }

    func testANewestHRNotWindowMax() throws {
        let now = 70_100_000
        var feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let start = now - WatchdogConfig.contextSeconds
        let mid = start + 5 * 60
        feed.hr = feed.hr.map { s in
            s.ts >= mid && s.ts < mid + 60 ? HRSample(ts: s.ts, bpm: 132) : s
        }
        let w = try unwrapWindow(WatchdogWindowBuilder.build(feed))
        XCTAssertFalse(WatchdogSafety.fired(w), "mid-window HR spike is not rest-HR safety")
    }

    func testBExplainedExerciseBeatsSafetyLabel() {
        XCTAssertEqual(WatchdogEventGeometry.what(cls: .run, reconJ: 0.3, forecastJ: 0.1,
                                                 safety: true, artifact: false, postWorkout: false,
                                                 sleep: false, hrHot: true, breadth: 0.1),
                       .workoutRun)
        XCTAssertEqual(WatchdogEventGeometry.what(cls: .still, reconJ: 0.3, forecastJ: 0.1,
                                                 safety: true, artifact: false, postWorkout: false,
                                                 sleep: false, hrHot: true, breadth: 0.1),
                       .safetyBound)
    }

    func testCLiftSetRestIsResistanceNotCycle() throws {
        let now = 70_200_000
        let w = try liftWindow(now: now)
        let last = WatchdogActivityClass.labels(logits: w.activityLogits).suffix(8)
        XCTAssertTrue(last.contains(WatchdogActivityClass.resistance.rawValue),
                      "lift logits=\(last)")
    }

    func testDArtifactNotBlendedToWorkout() throws {
        let now = 70_300_000
        let w = try artifactWindow(now: now)
        XCTAssertTrue(WatchdogActivityRuntime.isArtifact(w.activityLogits),
                      "labels=\(WatchdogActivityClass.labels(logits: w.activityLogits).suffix(8))")
        let lab = WatchdogEventGeometry.what(cls: .artifact, reconJ: 0.4, forecastJ: 0.2,
                                            safety: false, artifact: true, postWorkout: false,
                                            sleep: false, hrHot: false, breadth: 0.2)
        XCTAssertEqual(lab, .artifactSpike)
    }

    func testEPostWorkoutUsesActiveCeiling() {
        XCTAssertEqual(WatchdogEventGeometry.what(cls: .still, reconJ: 1.2, forecastJ: 0.3,
                                                 safety: false, artifact: false, postWorkout: true,
                                                 sleep: false, hrHot: false, breadth: 0.25,
                                                 maxAbsR: 1.4),
                       .postWorkout)
        XCTAssertEqual(WatchdogEventGeometry.what(cls: .still, reconJ: 1.8, forecastJ: 0.3,
                                                 safety: false, artifact: false, postWorkout: true,
                                                 sleep: false, hrHot: true, breadth: 0.5,
                                                 maxAbsR: 2.8),
                       .abnormalMultiDirection)
    }

    func testFTwoRungNormalDoesNotHideTachycardia() {
        XCTAssertEqual(WatchdogEventGeometry.what(cls: .still, reconJ: 1.2, forecastJ: 0.2,
                                                 safety: false, artifact: false, postWorkout: false,
                                                 sleep: false, hrHot: false, breadth: 0.20,
                                                 maxAbsR: 1.6),
                       .normalStillAwake)
        XCTAssertEqual(WatchdogEventGeometry.what(cls: .still, reconJ: 1.2, forecastJ: 0.1,
                                                 safety: false, artifact: false, postWorkout: false,
                                                 sleep: false, hrHot: true, breadth: 0.16,
                                                 maxAbsR: 1.8),
                       .abnormalStillTachycardia)
        XCTAssertEqual(WatchdogEventGeometry.what(cls: .still, reconJ: 0.2, forecastJ: 1.3,
                                                 safety: false, artifact: false, postWorkout: false,
                                                 sleep: false, hrHot: false, breadth: 0.1),
                       .forecastDriftOnly)
    }

    func testGWhoop5WalkUsesSparseSteps() throws {
        let now = 70_400_000
        let w = try walkWindow(now: now, family: .whoop5, cadence: 30)
        let last = WatchdogActivityClass.labels(logits: w.activityLogits).last
        XCTAssertEqual(last, WatchdogActivityClass.walk.rawValue, "whoop5 walk last=\(last ?? "nil")")
    }

    func testGWhoop4WalkUnchanged() throws {
        let now = 70_500_000
        let w = try walkWindow(now: now, family: .whoop4, cadence: 1)
        let last = WatchdogActivityClass.labels(logits: w.activityLogits).last
        XCTAssertEqual(last, WatchdogActivityClass.walk.rawValue)
    }

    func testANoImuRunDoesNotNotify() throws {
        let now = 70_600_000
        var feed = Watchdog.syntheticFeed(now: now, hr: 140, hrv: 35, temp: 33.0, resp: 20, motion: 0.7)
        feed.motion = []
        feed.imu = []
        feed.steps = []
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: prompt, nowUnix: now)
        XCTAssertFalse(r.shouldNotify)
        XCTAssertNotEqual(r.eventLabel, WatchdogEventLabel.safetyBound.rawValue)
    }

    func testWristOffAndEmptyStillUnavailable() {
        let empty = Watchdog.evaluate(window: .failure(.empty), prompt: prompt, nowUnix: 71_000_000)
        XCTAssertEqual(empty.severity, .dataUnavailable)
        let off = Watchdog.evaluate(window: .failure(.wristOff), prompt: prompt, nowUnix: 71_000_000)
        XCTAssertEqual(off.eventLabel, WatchdogEventLabel.wristOff.rawValue)
        XCTAssertFalse(off.shouldNotify)
    }

    // MARK: - tapes

    private func window(hr: Int, motion: Double) throws -> WatchdogWindow {
        let feed = Watchdog.syntheticFeed(now: 19_000_000, hr: Double(hr), hrv: 48, temp: 33.1,
                                          resp: 14, motion: motion)
        return try unwrapWindow(WatchdogWindowBuilder.build(feed))
    }

    private func unwrapWindow(_ r: Result<WatchdogWindow, WatchdogUnavailable>) throws -> WatchdogWindow {
        switch r {
        case .success(let w): return w
        case .failure(let e): throw NSError(domain: "wd26", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "\(e)"])
        }
    }

    private func walkWindow(now: Int, family: DeviceFamily, cadence: Int) throws -> WatchdogWindow {
        try unwrapWindow(WatchdogWindowBuilder.build(
            sportFeed(now: now, family: family, cadence: cadence, hr: 95, motion: 0.42,
                      stepClass: 1, dyn: { _ in 0.12 })))
    }

    private func liftWindow(now: Int) throws -> WatchdogWindow {
        try unwrapWindow(WatchdogWindowBuilder.build(
            sportFeed(now: now, family: .whoop4, cadence: 1, hr: 105, motion: 0.32,
                      stepClass: 3, dyn: { m in (m % 2 == 0) ? 0.48 : 0.06 })))
    }

    private func artifactWindow(now: Int) throws -> WatchdogWindow {
        try unwrapWindow(WatchdogWindowBuilder.build(
            sportFeed(now: now, family: .whoop4, cadence: 1, hr: 72, motion: 0.52,
                      stepClass: nil, dyn: { m in (m % 2 == 0) ? 0.9 : 0.05 })))
    }

    private func sportFeed(now: Int, family: DeviceFamily, cadence: Int, hr: Int,
                           motion: Double, stepClass: Int?, dyn: (Int) -> Double) -> WatchdogFeed {
        let start = now - WatchdogConfig.contextSeconds
        var hrs: [HRSample] = []
        var rrs: [RRInterval] = []
        var temps: [WatchdogScalarSample] = []
        var resps: [WatchdogScalarSample] = []
        var mots: [WatchdogScalarSample] = []
        var spo2: [WatchdogScalarSample] = []
        var steps: [StepSample] = []
        var imu: [WatchdogIMUSample] = []
        for m in 0..<WatchdogConfig.seqLen {
            let mStart = start + m * 60
            for t in stride(from: mStart, to: mStart + 60, by: cadence) {
                hrs.append(HRSample(ts: t, bpm: hr + (m % 4) - 2))
                temps.append(WatchdogScalarSample(ts: t, value: 33.1))
                resps.append(WatchdogScalarSample(ts: t, value: 16))
                mots.append(WatchdogScalarSample(ts: t, value: motion))
                spo2.append(WatchdogScalarSample(ts: t, value: 97))
                if let cls = stepClass {
                    steps.append(StepSample(ts: t, counter: 1, activityClass: cls))
                }
                imu.append(WatchdogIMUSample(ts: t, x: 1, y: 0, z: 0, dynAccel: dyn(m)))
                let base = Int((60000.0 / Double(max(hr, 30))).rounded())
                rrs.append(RRInterval(ts: t, rrMs: max(300, base)))
            }
        }
        return WatchdogFeed(family: family, hrSource: .v18, nowUnix: now,
                            hr: hrs, rr: rrs, skinTempC: temps, respPerMin: resps,
                            motion: mots, spo2Pct: spo2, imu: imu, steps: steps)
    }
}
