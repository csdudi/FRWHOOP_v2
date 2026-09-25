import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Hybrid event geometry (24 Sep night): UniTS = what, TimesFM = when.
final class WatchdogV24DynamicTests: XCTestCase {

    func testUnitsExplainsQuietWorkout() {
        let lab = WatchdogEventGeometry.what(cls: .walk, reconJ: 0.2, forecastJ: 0.1,
                                            safety: false, artifact: false, postWorkout: false,
                                            sleep: false, hrHot: false, breadth: 0.1)
        XCTAssertEqual(lab, .workoutWalk)
        XCTAssertTrue(WatchdogEventGeometry.explainedByUnits(reconJ: 0.2))
    }

    func testUnitsRejectsWalkThatDoesNotMatchHat() {
        let lab = WatchdogEventGeometry.what(cls: .walk, reconJ: 1.4, forecastJ: 0.2,
                                            safety: false, artifact: false, postWorkout: false,
                                            sleep: false, hrHot: true, breadth: 0.5)
        XCTAssertEqual(lab, .abnormalMultiDirection)
        XCTAssertFalse(WatchdogEventGeometry.explainedByUnits(reconJ: 1.4))
    }

    func testTimesFMNamesForecastDriftWhenReconQuiet() {
        let lab = WatchdogEventGeometry.what(cls: .still, reconJ: 0.2, forecastJ: 1.3,
                                            safety: false, artifact: false, postWorkout: false,
                                            sleep: false, hrHot: false, breadth: 0.1)
        XCTAssertEqual(lab, .forecastDriftOnly)
    }

    func testStillTachycardiaIsNotAWorkout() {
        let lab = WatchdogEventGeometry.what(cls: .still, reconJ: 1.2, forecastJ: 0.1,
                                            safety: false, artifact: false, postWorkout: false,
                                            sleep: false, hrHot: true, breadth: 0.16)
        XCTAssertEqual(lab, .abnormalStillTachycardia)
    }

    func testSafetyAndArtifactStayRules() {
        XCTAssertEqual(WatchdogEventGeometry.what(cls: .walk, reconJ: 0.1, forecastJ: 0,
                                                 safety: true, artifact: false, postWorkout: false,
                                                 sleep: false, hrHot: true, breadth: 0), .safetyBound)
        XCTAssertEqual(WatchdogEventGeometry.what(cls: .still, reconJ: 0.1, forecastJ: 0,
                                                 safety: false, artifact: true, postWorkout: false,
                                                 sleep: false, hrHot: false, breadth: 0), .artifactSpike)
    }

    func testTimesFMOnsetNeedsPersist() {
        XCTAssertFalse(WatchdogEventGeometry.forecastOnset(forecastJ: 1.2, previousForecastJ: 0.2, aboveTicks: 1))
        XCTAssertTrue(WatchdogEventGeometry.forecastOnset(forecastJ: 1.2, previousForecastJ: 0.2, aboveTicks: 2))
        XCTAssertFalse(WatchdogEventGeometry.forecastOnset(forecastJ: 1.2, previousForecastJ: 1.1, aboveTicks: 4))
    }

    func testUnitsRegimeOnset() {
        XCTAssertTrue(WatchdogEventGeometry.unitsRegimeOnset(reconJ: 1.1, previousReconJ: 0.3, aboveTicks: 2))
        XCTAssertFalse(WatchdogEventGeometry.unitsRegimeOnset(reconJ: 0.4, previousReconJ: 0.3, aboveTicks: 2))
    }

    func testClassHoldCutAfterTwoMinutesNewFamily() {
        let d = WatchdogEventGeometry.resolve(cls: .walk, familyStableTicks: 2, previousFamily: "still",
                                              reconJ: 0.2, forecastJ: 0.1, previousReconJ: 0.2,
                                              previousForecastJ: 0.1, reconAboveTicks: 0, forecastAboveTicks: 0,
                                              safety: false, artifact: false, postWorkout: false, sleep: false,
                                              hrHot: false, breadth: 0.1, eventAgeSeconds: 120)
        XCTAssertTrue(d.cut)
        XCTAssertEqual(d.cutReason, "class-hold")
        XCTAssertEqual(d.label, .workoutWalk)
    }

    func testOneMinuteFamilyBlipDoesNotCut() {
        let d = WatchdogEventGeometry.resolve(cls: .walk, familyStableTicks: 1, previousFamily: "still",
                                              reconJ: 0.2, forecastJ: 0.1, previousReconJ: 0.2,
                                              previousForecastJ: 0.1, reconAboveTicks: 0, forecastAboveTicks: 0,
                                              safety: false, artifact: false, postWorkout: false, sleep: false,
                                              hrHot: false, breadth: 0.1, eventAgeSeconds: 60)
        XCTAssertFalse(d.cut)
    }

    func testTimesFMCutReason() {
        let d = WatchdogEventGeometry.resolve(cls: .still, familyStableTicks: 10, previousFamily: "still",
                                              reconJ: 0.2, forecastJ: 1.3, previousReconJ: 0.2,
                                              previousForecastJ: 0.2, reconAboveTicks: 0, forecastAboveTicks: 2,
                                              safety: false, artifact: false, postWorkout: false, sleep: false,
                                              hrHot: false, breadth: 0.1, eventAgeSeconds: 300)
        XCTAssertTrue(d.cut)
        XCTAssertEqual(d.cutReason, "timesfm-onset")
        XCTAssertEqual(d.label, .forecastDriftOnly)
    }

    func testUnitsCutReason() {
        let d = WatchdogEventGeometry.resolve(cls: .still, familyStableTicks: 10, previousFamily: "still",
                                              reconJ: 1.2, forecastJ: 0.2, previousReconJ: 0.2,
                                              previousForecastJ: 0.2, reconAboveTicks: 2, forecastAboveTicks: 0,
                                              safety: false, artifact: false, postWorkout: false, sleep: false,
                                              hrHot: true, breadth: 0.16, eventAgeSeconds: 300)
        XCTAssertTrue(d.cut)
        XCTAssertEqual(d.cutReason, "units-regime")
    }

    func testWristOffNeverUsesModels() {
        let r = Watchdog.evaluate(window: .failure(.wristOff), prompt: UniTSPrompt(), nowUnix: 50_000_000)
        XCTAssertEqual(r.eventLabel, WatchdogEventLabel.wristOff.rawValue)
        XCTAssertEqual(r.cutReason, "quality")
        XCTAssertEqual(r.severity, .dataUnavailable)
    }

    func testQuietStillIsNormalAndExplained() {
        let now = 51_000_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97),
                                  nowUnix: now)
        XCTAssertTrue(r.eventExplained)
        XCTAssertTrue(r.eventLabel == WatchdogEventLabel.normalStillAwake.rawValue
                      || r.eventLabel == WatchdogEventLabel.normalSleep.rawValue
                      || r.eventLabel == WatchdogEventLabel.forecastDriftOnly.rawValue)
        XCTAssertFalse(r.shouldNotify)
    }

    func testGeometryVersionIsDynamic() {
        XCTAssertEqual(WatchdogEventGeometry.version, "geometry-v2-selflabel")
        XCTAssertEqual(WatchdogConfig.configVersion, "watchdog-v2.5")
    }

    func testCatalogLabelerStillExclusive() {
        let lab = WatchdogEventLabeler.labelMinute(wristOff: true, gap: true, artifact: true,
                                                   cls: .run, postWorkout: true, sleep: true,
                                                   safety: true, explainedWorkout: true)
        XCTAssertEqual(lab, .wristOff)
    }
}
