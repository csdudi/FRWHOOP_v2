import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Boss 6: 20-col activity block is built from raw IMU / steps / workout / sleep interval.
final class WatchdogV34ActivityConnectTests: XCTestCase {

    private let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)

    func testBuildReceivesImuStepsWorkoutSleep() throws {
        let now = 90_000_000
        var feed = Watchdog.syntheticFeed(now: now, hr: 72, hrv: 42, temp: 33.4, resp: 16, motion: 0.4)
        let start = now - WatchdogConfig.contextSeconds
        feed.imu = (0..<WatchdogConfig.seqLen).map { i in
            let ts = start + i * WatchdogConfig.gridSeconds + 10
            return WatchdogIMUSample(ts: ts, x: 0.2, y: 0.1, z: 1.1, dynAccel: 1.6)
        }
        feed.steps = (0..<WatchdogConfig.seqLen).map { i in
            StepSample(ts: start + i * WatchdogConfig.gridSeconds + 5, counter: i, activityClass: 1)
        }
        var window = try unwrap(WatchdogWindowBuilder.build(feed))
        XCTAssertFalse(window.imu.isEmpty)
        XCTAssertFalse(window.steps.isEmpty)
        window.bindActivityContext(lastWorkoutEndUnix: now - 1800,
                                   sleepIntervals: [WatchdogSleepInterval(startUnix: start, endUnix: now)])
        let last = window.activityFeatures.last ?? []
        XCTAssertEqual(last.count, 20)
        XCTAssertGreaterThan(last[9], 1.0, "dynAccel mean from IMU")
        XCTAssertGreaterThan(last[11], 0, "gravity residual from IMU")
        XCTAssertGreaterThan(last[13], 0.8, "step walk fraction")
        XCTAssertEqual(last[14], 0, accuracy: 1e-9)
        XCTAssertEqual(last[16], 0.5, accuracy: 0.05)
        XCTAssertEqual(last[19], 1, accuracy: 1e-9, "sleep interval, not clock")
    }

    func testMissingImuDoesNotInventDyn() throws {
        let now = 90_100_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 64, hrv: 46, temp: 33.1, resp: 14, motion: 0.8)
        let window = try unwrap(WatchdogWindowBuilder.build(feed))
        XCTAssertTrue(window.imu.isEmpty)
        let row = window.activityFeatures.last ?? []
        XCTAssertEqual(row[8], 0.8, accuracy: 0.05)
        XCTAssertEqual(row[9], 0, accuracy: 1e-9, "must not invent mag * 0.4")
        XCTAssertEqual(row[10], 0, accuracy: 1e-9)
        XCTAssertEqual(row[11], 0, accuracy: 1e-9, "must not copy occupancy mag")
    }

    func testSleepBitFromIntervalNotClock() throws {
        let twoAm = dateUnix(hour: 2)
        let tenAm = dateUnix(hour: 10)
        let night = try features(now: twoAm, sleep: [])
        XCTAssertEqual(night.last?[19] ?? -1, 0, accuracy: 1e-9, "02:00 without a session is not asleep")
        let lateSleep = try features(now: tenAm, sleep: [
            WatchdogSleepInterval(startUnix: tenAm - WatchdogConfig.contextSeconds, endUnix: tenAm + 60)
        ])
        XCTAssertEqual(lateSleep.last?[19] ?? 0, 1, accuracy: 1e-9, "10:00 overlapping a session is asleep")
        XCTAssertTrue(lateSleep.dropLast().allSatisfy { ($0[19] - 1).magnitude < 1e-9 })
    }

    func testReconstructUsesSameFeaturesAsBuilder() throws {
        let now = 90_200_000
        var feed = Watchdog.syntheticFeed(now: now, hr: 70, hrv: 44, temp: 33.2, resp: 15, motion: 0.3)
        let start = now - WatchdogConfig.contextSeconds
        feed.imu = [WatchdogIMUSample(ts: now - 30, x: 0, y: 0, z: 1.2, dynAccel: 2.0)]
        feed.steps = [StepSample(ts: now - 20, counter: 4, activityClass: 2)]
        var window = try unwrap(WatchdogWindowBuilder.build(feed))
        window.bindActivityContext(lastWorkoutEndUnix: now - 3600,
                                   sleepIntervals: [WatchdogSleepInterval(startUnix: start, endUnix: start + 120)])
        let built = window.activityFeatures
        let resolved = window.resolvedActivityFeatures()
        XCTAssertEqual(built.count, resolved.count)
        XCTAssertEqual(built.last, resolved.last)
        _ = try UniTSRuntime().reconstruct(window, prompt: prompt)
        XCTAssertEqual(window.resolvedActivityFeatures().last, built.last)
    }

    func testPriorUsesFeatureRowNotOccupancyLookup() throws {
        let now = 90_300_000
        let base = try unwrap(WatchdogWindowBuilder.build(
            Watchdog.syntheticFeed(now: now, hr: 72, hrv: 42, temp: 33.3, resp: 16, motion: 0.2)))
        var highDyn = base
        let start = now - WatchdogConfig.contextSeconds
        highDyn.imu = (0..<WatchdogConfig.seqLen).map { i in
            WatchdogIMUSample(ts: start + i * WatchdogConfig.gridSeconds + 8,
                              x: 0.4, y: 0.3, z: 1.3, dynAccel: 3.0)
        }
        highDyn.bindActivityContext(lastWorkoutEndUnix: 0, sleepIntervals: [])
        var asleep = base
        asleep.imu = []
        asleep.bindActivityContext(
            lastWorkoutEndUnix: 0,
            sleepIntervals: [WatchdogSleepInterval(startUnix: start, endUnix: now)])
        let featDyn = highDyn.resolvedActivityFeatures()
        let featSleep = asleep.resolvedActivityFeatures()
        XCTAssertTrue(WatchdogActivityFeatures.usesRawActivity(featDyn))
        XCTAssertTrue(WatchdogActivityFeatures.usesRawActivity(featSleep))
        let occLookup = WatchdogActivityRuntime.effortOccupancy(motion: base.motion,
                                                                logits: base.activityLogits)
        let occDyn = UniTSRuntime.physiologyOccupancy(highDyn, features: featDyn)
        let occSleep = UniTSRuntime.physiologyOccupancy(asleep, features: featSleep)
        XCTAssertEqual(occLookup.last ?? -1, occLookup.first ?? -2, accuracy: 1)
        XCTAssertGreaterThan(occDyn.last ?? 0, occSleep.last ?? 1)
        let hatDyn = UniTSRuntime.priorResidual(window: highDyn, prompt: prompt, occupancy: occDyn)
        let hatSleep = UniTSRuntime.priorResidual(window: asleep, prompt: prompt, occupancy: occSleep)
        let hrDyn = hatDyn.reconstructedHR.compactMap { $0 }.last ?? 0
        let hrSleep = hatSleep.reconstructedHR.compactMap { $0 }.last ?? 0
        XCTAssertGreaterThan(hrDyn, hrSleep + 1)
    }

    func testV2PackageDoesNotClaimActivityInput() {
        XCTAssertEqual(WatchdogConfig.modelVersion, "units-ad-coreml-v2")
        XCTAssertEqual(WatchdogConfig.forecastModelVersion, "timesfm3-student-v2")
        if UniTSCoreMLSession.shared.isLoaded {
            XCTAssertFalse(UniTSCoreMLSession.shared.declaresActivityInput,
                           "v2 occupancy package must not require activity (1,30,20)")
        }
    }

    func testStepLocomotionMarksLiveTailEffort() throws {
        let now = 90_400_000
        var feed = Watchdog.syntheticFeed(now: now, hr: 80, hrv: 40, temp: 33.5, resp: 18, motion: 0.05)
        let start = now - WatchdogConfig.contextSeconds
        feed.steps = (0..<WatchdogConfig.seqLen).map { i in
            StepSample(ts: start + i * WatchdogConfig.gridSeconds + 3, counter: i, activityClass: 2)
        }
        let window = try unwrap(WatchdogWindowBuilder.build(feed))
        XCTAssertGreaterThanOrEqual(WatchdogActivityFeatures.stepLocomotion(window.activityFeatures.last ?? []), 0.5)
        XCTAssertEqual(WatchdogLiveTail.resolve(window).period, .effort)
        XCTAssertTrue(window.rhr.compactMap { $0 }.isEmpty, "run steps must not enter RHR")
    }

    func testEvaluateSleepIntervalMasksFeatures() throws {
        let now = 90_500_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let start = now - WatchdogConfig.contextSeconds
        let r = Watchdog.evaluate(
            window: WatchdogWindowBuilder.build(feed),
            prompt: prompt,
            nowUnix: now,
            sleepSessionOpen: true,
            sleepIntervals: [WatchdogSleepInterval(startUnix: start, endUnix: now + 60)])
        XCTAssertEqual(r.qualityGate, "bucket-v1")
        let rebuilt = try unwrap(WatchdogWindowBuilder.build(feed))
        var bound = rebuilt
        bound.bindActivityContext(lastWorkoutEndUnix: r.carry.lastWorkoutEndUnix,
                                  sleepIntervals: [WatchdogSleepInterval(startUnix: start, endUnix: now + 60)])
        XCTAssertEqual(bound.activityFeatures.last?[19] ?? 0, 1, accuracy: 1e-9)
    }

    private func features(now: Int, sleep: [WatchdogSleepInterval]) throws -> [[Double]] {
        var w = try unwrap(WatchdogWindowBuilder.build(
            Watchdog.syntheticFeed(now: now, hr: 60, hrv: 46, temp: 33.0, resp: 14, motion: 0.02)))
        w.bindActivityContext(lastWorkoutEndUnix: 0, sleepIntervals: sleep)
        return w.activityFeatures
    }

    private func dateUnix(hour: Int) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 15; c.hour = hour; c.minute = 0
        return Int(cal.date(from: c)?.timeIntervalSince1970 ?? 1_781_500_000)
    }

    private func unwrap(_ r: Result<WatchdogWindow, WatchdogUnavailable>) throws -> WatchdogWindow {
        switch r {
        case .success(let w): return w
        case .failure(let e): throw NSError(domain: "wd34", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "\(e)"])
        }
    }
}
