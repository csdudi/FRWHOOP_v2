import XCTest
@testable import StrandAnalytics

/// Boss 10: catalog replay on evaluate. Does not retune 1.0 / 1.6 / 2.4.
final class WatchdogV38TuneEvidenceTests: XCTestCase {

    private static var cachedReport: WatchdogTuneReport?

    private func report() -> WatchdogTuneReport {
        if let cached = Self.cachedReport { return cached }
        let r = WatchdogTuneReplay.run()
        Self.cachedReport = r
        return r
    }

    override func tearDown() {
        WatchdogForecastRuntime.testPredict = nil
        super.tearDown()
    }

    func testCalibrationStaysPriorUntuned() {
        XCTAssertEqual(WatchdogCalibration.version, "prior-untuned")
        XCTAssertEqual(WatchdogCalibration.tNote, 1.0)
        XCTAssertEqual(WatchdogCalibration.tActive, 1.6)
        XCTAssertEqual(WatchdogCalibration.tSevere, 2.4)
        XCTAssertEqual(WatchdogCalibration.persistTicks, 2)
    }

    func testCatalogMeetsMinimumEventCounts() {
        let recipes = WatchdogTuneBuilder.catalog()
        for label in WatchdogEventLabel.allCases where WatchdogTuneBuilder.minCount(label) > 0 {
            let n = recipes.filter { $0.event.label == label }.count
            XCTAssertGreaterThanOrEqual(n, WatchdogTuneBuilder.minCount(label), label.rawValue)
        }
        XCTAssertTrue(recipes.contains { $0.family == .whoop5 && $0.event.label == .normalStillAwake })
    }

    func testReplayUsesEvaluateNotInjectedJoint() {
        let report = report()
        XCTAssertFalse(report.rows.isEmpty)
        XCTAssertTrue(report.rows.allSatisfy(\.usedEvaluate))
        XCTAssertTrue(report.rows.allSatisfy { !$0.usedInjectedJoint })
        XCTAssertTrue(report.rows.allSatisfy { $0.calibrationSource == "prior-untuned" })
    }

    func testRealWhoop5RowStaysEmpty() {
        let report = report()
        XCTAssertEqual(report.realWhoop5, "not_run")
        XCTAssertTrue(WatchdogTuneReplay.markdown(report).contains("real_whoop5"))
        XCTAssertTrue(WatchdogTuneReplay.markdown(report).contains("not a worn-night validation"))
    }

    func testMixedRejectedDroppedFromRates() {
        let report = report()
        XCTAssertGreaterThan(report.rates.windowsDroppedMixed, 0)
        let mixedKept = report.rows.filter { $0.intended == .mixedRejected && !$0.mixedDropped }
        XCTAssertTrue(mixedKept.isEmpty || mixedKept.allSatisfy { $0.actual == .mixedRejected })
    }

    func testFeltIllDoesNotAdvanceBandInReplay() {
        let report = report()
        XCTAssertEqual(report.rates.confoundedBandN, 0)
    }

    func testSafetyRecipePagesAndQuietStillDoesNot() {
        let report = report()
        XCTAssertEqual(report.rates.missSafety, 0)
        let stills = report.rows.filter { $0.intended == .normalStillAwake && !$0.mixedDropped }
        XCTAssertFalse(stills.contains { $0.shouldNotify })
    }

    func testReportWrittenAndClassificationListed() throws {
        let report = report()
        let url = try WatchdogTuneReplay.writeReport(report)
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("prior-untuned"))
        XCTAssertTrue(body.contains("Watchdog.evaluate"))
        let classified = WatchdogTuneClassification.suites.map(\.name)
        XCTAssertTrue(classified.contains("WatchdogV38TuneEvidenceTests"))
        XCTAssertTrue(classified.contains("WatchdogV30SeverityJointTests"))
        XCTAssertEqual(WatchdogTuneClassification.suites.first { $0.name == "WatchdogV30SeverityJointTests" }?.kind,
                       .unit)
        try (body + "\n" + WatchdogTuneClassification.markdown())
            .write(to: url, atomically: true, encoding: .utf8)
    }

    func testTuneCatalogPinUnchanged() throws {
        let url = WatchdogTuneReplay.unitsDir().appendingPathComponent("WatchdogTuneCatalog.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(obj?["calibration_source"] as? String, "prior-untuned")
        XCTAssertEqual(obj?["human_review"] as? String, "forbidden")
        XCTAssertEqual(obj?["real_whoop5"] as? String, "not_run")
        XCTAssertEqual(obj?["replay"] as? String, "Watchdog.evaluate")
    }
}
