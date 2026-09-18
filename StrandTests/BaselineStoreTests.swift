import XCTest
@testable import Strand
import StrandAnalytics
import WhoopStore

/// Baseline tab scores real `DailyMetric` rows. No in-app test mode; fixtures are test-only.
final class BaselineStoreTests: XCTestCase {

    @MainActor
    func isolatedStore() -> BaselineStore {
        let suite = "baseline.store.tests.\(UUID().uuidString)"
        return BaselineStore(defaults: UserDefaults(suiteName: suite)!, asOf: "2026-04-29")
    }

    @MainActor
    func tape(pre: Int, post: Int, asOf: String = "2026-04-29") -> [DailyMetric] {
        let t0 = LongitudinalBaseline.isoEpochDay("2026-04-01")!
        let end = LongitudinalBaseline.isoEpochDay(asOf)!
        return (t0 - 70...end).map { e in
            let v = e < t0 ? pre : post
            return BaselineStore.daily(day: LongitudinalBaseline.isoFromEpochDay(e),
                                       rhr: v, hrv: 48, temp: 33.1, resp: 14, spo2: 97, steps: 7500)
        }
    }

    @MainActor
    func testQuietTapeIsInRangeOnSleepRHR() {
        let store = isolatedStore()
        store.rescore(days: tape(pre: 60, post: 60))
        let ev = try! XCTUnwrap(store.evaluation)
        XCTAssertEqual(ev.series, .sleepRHR)
        XCTAssertEqual(ev.todayNative, 60)
        XCTAssertEqual(ev.trial.card.slowTitle, "Longer usual")
        XCTAssertTrue(ev.show7)
        XCTAssertTrue(ev.showLong)
        XCTAssertLessThan(abs(ev.zLong ?? 99), 2, ev.consoleReport)
        XCTAssertFalse(ev.contextPrompt.shouldAsk)
        XCTAssertEqual(store.weekPoints.count, 8)
        XCTAssertEqual(store.longPoints.count, 61)
        XCTAssertEqual(store.weekPoints.last?.day, "2026-04-29")
        XCTAssertEqual(store.longPoints.last?.day, "2026-04-29")
        XCTAssertNotEqual(store.weekPoints.first?.day, store.longPoints.first?.day)
        XCTAssertTrue(store.weekPoints.contains { $0.day == "2026-04-29" && $0.isScoredNight })
        XCTAssertFalse(store.showContextSheet)
        XCTAssertGreaterThan(store.longPoints.filter { $0.value != nil }.count, 20)
        XCTAssertEqual(store.calendarSlots.count, 61)
        XCTAssertEqual(store.calendarSlots.last?.fill, .today)
    }

    @MainActor
    func testChangingSeriesJumpsToNewestNight() {
        let store = isolatedStore()
        let days = tape(pre: 60, post: 60)
        store.rescore(days: days)
        store.shiftDay(-3, days: days)
        XCTAssertNotEqual(store.asOf, "2026-04-29")
        store.selectSeries(.sleepHRVLn, days: days)
        XCTAssertEqual(store.asOf, "2026-04-29")
        XCTAssertEqual(store.longAsOf, "2026-04-29")
        XCTAssertEqual(store.series, .sleepHRVLn)
        store.shiftDay(-2, days: days)
        store.selectContext(.allDay, days: days)
        XCTAssertEqual(store.asOf, "2026-04-29")
    }

    @MainActor
    func testFeverWeekDoesNotWriteZeroAndKeepsTwoCopies() {
        let store = isolatedStore()
        let t = LongitudinalBaseline.isoEpochDay("2026-04-29")!
        var days = (t - 70...t - 8).map {
            BaselineStore.daily(day: LongitudinalBaseline.isoFromEpochDay($0), rhr: 60)
        }
        days += (t - 7...t).map {
            BaselineStore.daily(day: LongitudinalBaseline.isoFromEpochDay($0), rhr: 72)
        }
        store.rescore(days: days)
        let ev = try! XCTUnwrap(store.evaluation)
        XCTAssertEqual(ev.todayNative, 72)
        XCTAssertEqual(ev.copyLong?.centerDisplay ?? 0, 60, accuracy: 2, ev.consoleReport)
        XCTAssertNotEqual(ev.copy7?.center, ev.todayNative)
        XCTAssertTrue(store.weekPoints.contains { $0.missing == false && $0.value == 72 })
        XCTAssertTrue(store.weekPoints.contains { $0.day == "2026-04-29" })
        XCTAssertFalse(store.calendarSlots.contains { $0.fill == .missing && $0.day == "2026-04-29" })
        XCTAssertFalse(store.showContextSheet)
        XCTAssertNil(store.longHowOff)
    }

    @MainActor
    func testStartFreezesNonTreatmentUsualOnRealDailies() {
        let store = isolatedStore()
        let days = tape(pre: 68, post: 61)
        store.rescore(days: days)
        store.logStart(name: "Lisinopril", dose: "10 mg", civilDay: "2026-04-01",
                       clockTime: "07:00", enteredBy: .patient, days: days)
        let ev = try! XCTUnwrap(store.evaluation)
        XCTAssertTrue(ev.trial.trialFreezeOk, ev.consoleReport)
        XCTAssertEqual(ev.trial.freeze?.centerLong ?? 0, 68, accuracy: 0.6)
        XCTAssertEqual(ev.trial.card.freezeTitle, "Expected without treatment")
        XCTAssertTrue(ev.trial.card.slowTitle.contains("Lisinopril"))
        XCTAssertEqual(ev.todayNative, 61)
        XCTAssertNotNil(ev.trial.zTrialTraj)
        XCTAssertEqual(store.calendarSlots.first { $0.isStart }?.day, "2026-04-01")
        XCTAssertGreaterThan(abs(ev.trial.deltaTrialLevel ?? 0), 5)
    }

    @MainActor
    func testHrvAndStepsUseOwnUsualNotRHR() {
        let store = isolatedStore()
        let days = tape(pre: 68, post: 61)
        store.series = .sleepHRVLn
        store.rescore(days: days)
        XCTAssertEqual(store.evaluation?.todayNative, 48)
        XCTAssertEqual(store.evaluation?.series, .sleepHRVLn)
    }

    @MainActor
    func testPlotDomainFollowsBaselineBandNotPhysiologicalExtremes() {
        let store = isolatedStore()
        store.rescore(days: tape(pre: 60, post: 60))
        let lo = store.evaluation?.copyLong?.bandLoDisplay ?? 0
        let hi = store.evaluation?.copyLong?.bandHiDisplay ?? 0
        XCTAssertGreaterThan(lo, 30, "axis should not use the 30–120 physiological floor")
        XCTAssertLessThan(hi, 120)
        XCTAssertLessThan(hi - lo, 25)
        let domain = BaselinePlotScale.yDomain(
            values: store.weekPoints.compactMap(\.value),
            bandLo: lo, bandHi: hi)
        XCTAssertGreaterThan(domain.lowerBound, 40)
        XCTAssertLessThan(domain.upperBound, 90)
        XCTAssertLessThan(domain.upperBound - domain.lowerBound, 20)
        let tempDomain = BaselinePlotScale.yDomain(values: [33.0, 33.2], bandLo: 32.8, bandHi: 33.4)
        XCTAssertLessThan(tempDomain.upperBound - tempDomain.lowerBound, 3)
        XCTAssertEqual(BaselinePlotScale.formatTick(33.1, domain: tempDomain), "33.1")
    }

    @MainActor
    func testMissingNightBreaksTheWeekLine() {
        let store = isolatedStore()
        var days = tape(pre: 60, post: 60)
        days.removeAll { $0.day == "2026-04-26" }
        store.rescore(days: days)
        let hole = store.weekPoints.first { $0.day == "2026-04-26" }
        XCTAssertEqual(hole?.missing, true)
        XCTAssertNil(hole?.value)
        let before = store.weekPoints.first { $0.day == "2026-04-25" }?.segment
        let after = store.weekPoints.first { $0.day == "2026-04-27" }?.segment
        XCTAssertNotEqual(before, after)
    }

    @MainActor
    func testMissingNightIsAHole() {
        let store = isolatedStore()
        var days = tape(pre: 60, post: 60, asOf: "2026-04-28")
        days.append(BaselineStore.daily(day: "2026-04-29", rhr: nil))
        store.rescore(days: days)
        XCTAssertNil(store.evaluation?.todayNative)
        XCTAssertEqual(store.calendarSlots.last?.fill, .today)
        XCTAssertTrue(store.calendarSlots.contains { $0.day == "2026-04-29" })
    }

    @MainActor
    func testClampsAsOfToLastNightInTheTape() {
        let suite = "baseline.store.tests.\(UUID().uuidString)"
        let store = BaselineStore(defaults: UserDefaults(suiteName: suite)!, asOf: "2026-09-11")
        store.rescore(days: tape(pre: 60, post: 60))
        XCTAssertEqual(store.asOf, "2026-04-29")
        XCTAssertEqual(store.evaluation?.todayNative, 60)
        XCTAssertGreaterThan(store.weekPoints.compactMap(\.value).count, 4)
        XCTAssertGreaterThan(store.longPoints.compactMap(\.value).count, 20)
    }

    @MainActor
    func testAllDayRestAndActiveShowDemonstrationSeries() {
        let store = isolatedStore()
        XCTAssertEqual(store.context, .sleep)
        XCTAssertEqual(BaselineStore.ContextFilter.allCases.first, .sleep)
        let days = tape(pre: 60, post: 61)
        store.rescore(days: days)
        XCTAssertEqual(store.displayedSeries, [
            .sleepRHR, .sleepHRVLn, .sleepTemp, .sleepResp, .sleepSpO2Mean
        ])
        store.context = .allDay
        XCTAssertEqual(store.displayedSeries, [
            .continuousHR, .continuousHRVLn, .continuousSpO2Mean
        ])
        store.series = .continuousHR
        store.rescore(days: days)
        XCTAssertEqual(store.evaluation?.series, .continuousHR)
        XCTAssertEqual(store.evaluation?.todayNative ?? -1, 75, accuracy: 0.01)
        XCTAssertGreaterThan(store.weekPoints.compactMap(\.value).count, 4)

        store.context = .rest
        store.series = .awakeRestHR
        store.rescore(days: days)
        XCTAssertEqual(store.evaluation?.todayNative ?? -1, 67, accuracy: 0.01)

        store.context = .active
        store.series = .awakeActiveHR
        store.rescore(days: days)
        XCTAssertEqual(store.evaluation?.todayNative ?? -1, 93, accuracy: 0.01)

        store.context = .sleep
        let expected: [(LBSeries, Double)] = [
            (.sleepRHR, 61),
            (.sleepHRVLn, 48),
            (.sleepTemp, 33.1),
            (.sleepResp, 14),
            (.sleepSpO2Mean, 97),
        ]
        for (series, native) in expected {
            store.selectSeries(series, days: days)
            XCTAssertEqual(store.evaluation?.series, series, series.rawValue)
            XCTAssertEqual(store.evaluation?.todayNative ?? -1, native, accuracy: 0.01, series.rawValue)
            XCTAssertGreaterThan(store.nightCount(days: days, series: series), 20, series.rawValue)
            XCTAssertGreaterThan(store.weekPoints.compactMap(\.value).count, 4, series.rawValue)
        }

        store.selectContext(.allDay, days: days)
        XCTAssertEqual(store.series, .continuousHR)
        XCTAssertEqual(store.evaluation?.series, .continuousHR)
        store.selectSeries(.continuousHRVLn, days: days)
        XCTAssertEqual(store.evaluation?.series, .continuousHRVLn)
        store.selectSeries(.continuousSpO2Mean, days: days)
        XCTAssertEqual(store.evaluation?.series, .continuousSpO2Mean)
        XCTAssertEqual(store.evaluation?.todayNative ?? -1, 96.7, accuracy: 0.05)

        store.selectContext(.rest, days: days)
        XCTAssertEqual(store.series, .awakeRestHR)
        store.selectSeries(.awakeRestHRVLn, days: days)
        XCTAssertEqual(store.evaluation?.series, .awakeRestHRVLn)
        store.selectSeries(.awakeRestSpO2Mean, days: days)
        XCTAssertEqual(store.evaluation?.series, .awakeRestSpO2Mean)

        store.selectContext(.active, days: days)
        XCTAssertEqual(store.series, .awakeActiveHR)
        store.selectSeries(.awakeActiveHRVLn, days: days)
        XCTAssertEqual(store.evaluation?.series, .awakeActiveHRVLn)
        store.selectSeries(.awakeActiveSpO2Mean, days: days)
        XCTAssertEqual(store.evaluation?.series, .awakeActiveSpO2Mean)
        XCTAssertEqual(store.evaluation?.todayNative ?? -1, 96.3, accuracy: 0.05)
    }

    @MainActor
    func testDemoTapeDrawsBothCopies() throws {
        let suite = "baseline.store.tests.\(UUID().uuidString)"
        let days = BaselineStore.demoTape()
        XCTAssertEqual(days.count, 81)
        let asOf = try XCTUnwrap(days.last?.day)
        let store = BaselineStore(defaults: UserDefaults(suiteName: suite)!, asOf: asOf)
        store.rescore(days: days)
        XCTAssertGreaterThan(store.weekPoints.compactMap(\.value).count, 5)
        XCTAssertEqual(store.weekPoints.count, 8)
        XCTAssertEqual(store.longPoints.count, 61)
        XCTAssertNotEqual(store.weekPoints.first?.day, store.longPoints.first?.day)
        XCTAssertEqual(store.weekPoints.last?.day, store.longPoints.last?.day)
        XCTAssertNotNil(store.evaluation?.todayNative)
        XCTAssertNotNil(store.evaluation?.copy7)
        XCTAssertNotNil(store.evaluation?.copyLong)
        let center = store.evaluation?.copyLong?.centerDisplay ?? 0
        XCTAssertGreaterThan(store.longPoints.compactMap(\.value).max() ?? 0, center + 8)
    }

    @MainActor
    func testEndingTreatmentRecordsStopAndKeepsFreeze() {
        let store = isolatedStore()
        let days = tape(pre: 68, post: 61)
        store.logStart(name: "Lisinopril", dose: "10 mg", civilDay: "2026-04-01",
                       clockTime: "07:00", enteredBy: .patient, days: days)
        XCTAssertTrue(store.evaluation?.trial.trialFreezeOk ?? false)
        let frozen = store.evaluation?.trial.freeze?.centerLong
        store.logEnd(civilDay: "2026-04-29", clockTime: "08:00", reason: .completed, days: days)
        XCTAssertEqual(store.events.last?.type, .stop)
        XCTAssertEqual(store.events.first?.trialId, store.events.last?.trialId)
        XCTAssertEqual(store.evaluation?.trial.phase, LBTrialPhase.washingOut)
        XCTAssertTrue(store.evaluation?.trial.trialFreezeOk ?? false)
        XCTAssertEqual(store.evaluation?.trial.freeze?.centerLong ?? 0, frozen ?? -1, accuracy: 0.01)
        XCTAssertFalse(store.canEndTreatment)
        XCTAssertFalse(store.canLogDose)
    }

    @MainActor
    func testLogDoseStaysOnTheSameTrial() {
        let store = isolatedStore()
        let days = tape(pre: 68, post: 61)
        store.logStart(name: "Lisinopril", dose: "10 mg", civilDay: "2026-04-01",
                       clockTime: "07:00", enteredBy: .patient, days: days)
        let trialId = store.events.first?.trialId
        store.logDose(civilDay: "2026-04-10", clockTime: "08:00", dose: "10 mg", days: days)
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.events.last?.type, .dose)
        XCTAssertEqual(store.events.last?.trialId, trialId)
        XCTAssertEqual(store.evaluation?.trial.phase, LBTrialPhase.onTreatment)
    }

    @MainActor
    func testLongWeekNavDoesNotMoveScoredNight() {
        let store = isolatedStore()
        let days = tape(pre: 60, post: 60)
        store.rescore(days: days)
        let scored = store.asOf
        XCTAssertEqual(store.longAsOf, scored)
        XCTAssertEqual(store.longEvaluation?.asOf, scored)
        store.shiftLongWeek(-1, days: days)
        XCTAssertEqual(store.asOf, scored)
        XCTAssertNotEqual(store.longAsOf, scored)
        XCTAssertEqual(store.longEvaluation?.asOf, store.longAsOf)
        XCTAssertEqual(store.longPoints.count, 61)
        XCTAssertEqual(store.weekPoints.count, 8)
    }

    @MainActor
    func testLongWeekNavRebuildsSixtyDayMedian() {
        let suite = "baseline.store.tests.\(UUID().uuidString)"
        let days = BaselineStore.demoTape()
        let asOf = days.last!.day
        let store = BaselineStore(defaults: UserDefaults(suiteName: suite)!, asOf: asOf)
        store.rescore(days: days)
        let latest = try! XCTUnwrap(store.longCopyForPlot()?.center)
        XCTAssertNotNil(store.longConfidence)
        store.shiftLongWeek(-4, days: days)
        XCTAssertEqual(store.asOf, asOf)
        XCTAssertEqual(store.longEvaluation?.asOf, store.longAsOf)
        let earlier = try! XCTUnwrap(store.longCopyForPlot()?.center)
        XCTAssertGreaterThan(abs(latest - earlier), 0.05)
    }

    @MainActor
    func testConfidenceScoresWhenRangesShow() {
        let store = isolatedStore()
        store.rescore(days: tape(pre: 60, post: 60))
        XCTAssertTrue(store.evaluation?.show7 ?? false)
        XCTAssertTrue(store.longEvaluation?.showLong ?? false)
        XCTAssertNotNil(store.shortConfidence)
        XCTAssertNotNil(store.longConfidence)
        XCTAssertGreaterThan(store.shortConfidence ?? 0, 0)
        XCTAssertGreaterThan(store.longConfidence ?? 0, 0)
    }

    @MainActor
    func testAllDayAndActiveHaveASixtyDayRange() {
        let suite = "baseline.store.tests.\(UUID().uuidString)"
        let days = BaselineStore.demoTape()
        let asOf = days.last!.day
        let store = BaselineStore(defaults: UserDefaults(suiteName: suite)!, asOf: asOf)
        store.selectContext(.allDay, days: days)
        XCTAssertNotNil(store.longCopyForPlot(), "All day should draw a 60-day range")
        XCTAssertGreaterThan(store.longPoints.compactMap(\.value).count, 20)
        store.selectContext(.active, days: days)
        XCTAssertNotNil(store.longCopyForPlot(), "Active should draw a 60-day range")
        store.selectContext(.rest, days: days)
        XCTAssertNotNil(store.longCopyForPlot())
    }

    @MainActor
    func testTreatmentFreezeSuppliesLongRangeOnOtherPeriods() {
        let suite = "baseline.store.tests.\(UUID().uuidString)"
        let days = BaselineStore.demoTape()
        let asOf = days.last!.day
        let store = BaselineStore(defaults: UserDefaults(suiteName: suite)!, asOf: asOf)
        store.logStart(name: "Medication 1", dose: "40 mg", civilDay: "2026-07-01",
                       clockTime: "07:00", enteredBy: .caregiver, days: days)
        XCTAssertNotNil(store.longCopyForPlot())
        store.selectContext(.allDay, days: days)
        XCTAssertNotNil(store.longCopyForPlot())
        store.selectContext(.active, days: days)
        XCTAssertNotNil(store.longCopyForPlot())
    }

    @MainActor
    func testScoredValueLabelFollowsPeriod() {
        XCTAssertEqual(BaselineStore.ContextFilter.sleep.scoredValueLabel, "SCORED NIGHT")
        XCTAssertEqual(BaselineStore.ContextFilter.allDay.scoredValueLabel, "SCORED DAY")
        XCTAssertEqual(BaselineStore.ContextFilter.rest.scoredValueLabel, "SCORED REST")
        XCTAssertEqual(BaselineStore.ContextFilter.active.scoredValueLabel, "SCORED ACTIVE")
    }

    @MainActor
    func testNewTreatmentCanStartAfterACourseEnds() {
        let store = isolatedStore()
        let days = tape(pre: 68, post: 61)
        store.logStart(name: "Lisinopril", dose: "10 mg", civilDay: "2026-04-01",
                       clockTime: "07:00", enteredBy: .patient, days: days)
        store.logEnd(civilDay: "2026-04-10", clockTime: "08:00", reason: .completed, days: days)
        XCTAssertNil(store.activeStart)
        store.logStart(name: "Metoprolol", dose: "25 mg", civilDay: "2026-04-20",
                       clockTime: "07:00", enteredBy: .caregiver, days: days)
        XCTAssertEqual(store.activeStart?.displayName, "Metoprolol")
        XCTAssertEqual(store.events.filter { $0.type == .start }.count, 2)
        XCTAssertTrue(store.canEndTreatment)
    }

    @MainActor
    func testCaregiverCanEditAndDeleteAPastStart() {
        let store = isolatedStore()
        let days = tape(pre: 68, post: 61)
        store.logStart(name: "Lisinopril", dose: "10 mg", civilDay: "2026-04-01",
                       clockTime: "07:00", enteredBy: .patient, days: days)
        store.updateEvent(at: 0, name: "Lisinopril", dose: "20 mg", civilDay: "2026-03-20",
                          clockTime: "06:30", enteredBy: .caregiver, kind: .medication, days: days)
        XCTAssertEqual(store.events[0].civilDay, "2026-03-20")
        XCTAssertEqual(store.events[0].doseText, "20 mg")
        XCTAssertEqual(store.events[0].enteredBy, .caregiver)
        store.deleteEvent(at: 0, days: days)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertNil(store.activeStart)
    }

    @MainActor
    func testDayLogIsManualAndWorkoutDoesNotGreyThePoint() {
        let store = isolatedStore()
        let t = LongitudinalBaseline.isoEpochDay("2026-04-29")!
        var days = (t - 70...t - 1).map {
            BaselineStore.daily(day: LongitudinalBaseline.isoFromEpochDay($0), rhr: 60)
        }
        days.append(BaselineStore.daily(day: "2026-04-29", rhr: 90))
        store.rescore(days: days)
        XCTAssertTrue(store.evaluation?.contextPrompt.shouldAsk ?? false)
        XCTAssertFalse(store.showContextSheet)
        XCTAssertNil(store.longHowOff)
        store.setDayLog(LBDayLog(workout: .hard), on: "2026-04-29", days: days)
        XCTAssertEqual(store.todayLog?.workout, .hard)
        XCTAssertEqual(store.weekPoints.last?.explained, false)
        XCTAssertEqual(store.weekPoints.last?.isScoredNight, true)
        store.setDayLog(LBDayLog(workout: .none, travel: true), on: "2026-04-29", days: days)
        XCTAssertEqual(store.weekPoints.last?.explained, true)
        XCTAssertEqual(store.labeledEventsToday, [.travel])
        store.rescore(days: days)
        XCTAssertFalse(store.showContextSheet)
    }

    @MainActor
    func testBlankStartAutoWatchesSolidUsualsNotAGuessedVitalSign() {
        let store = isolatedStore()
        let days = tape(pre: 60, post: 60)
        store.logStart(name: "Lisinopril", dose: "10 mg", civilDay: "2026-04-01",
                       clockTime: "07:00", enteredBy: .patient, days: days)
        let pins = try! XCTUnwrap(store.activeStart?.primarySeries)
        XCTAssertEqual(pins.count, 3)
        XCTAssertTrue(pins.contains(.sleepRHR))
        XCTAssertFalse(store.watchCandidates.isEmpty)
        XCTAssertEqual(store.watchCandidates.filter(\.pinned).count, 3)
        store.toggleWatch(pins[0], days: days)
        XCTAssertEqual(store.activeStart?.primarySeries.count, 2)
    }

    func testOffPaintStrengthIsNilInsideBandAndRampsOutside() {
        XCTAssertNil(BaselineOffPaint.strength(value: 64, lo: 56, hi: 72))
        XCTAssertEqual(BaselineOffPaint.strength(value: 72, lo: 56, hi: 72), nil)
        XCTAssertEqual(BaselineOffPaint.strength(value: 56, lo: 56, hi: 72), nil)
        let halfBand = (72.0 - 56.0) / 2.0
        XCTAssertEqual(BaselineOffPaint.strength(value: 72 + halfBand, lo: 56, hi: 72)!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(BaselineOffPaint.strength(value: 56 - halfBand / 2, lo: 56, hi: 72)!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(BaselineOffPaint.strength(value: 200, lo: 56, hi: 72)!, 1.0, accuracy: 1e-9)
    }
}
