import Foundation
@testable import StrandAnalytics
import WhoopProtocol

enum WatchdogTuneReplay {
    static func run(recipes: [WatchdogTuneRecipe] = WatchdogTuneBuilder.catalog()) -> WatchdogTuneReport {
        WatchdogForecastRuntime.testPredict = .some(nil)
        defer { WatchdogForecastRuntime.testPredict = nil }
        var rows: [WatchdogTuneWindowRow] = []
        for recipe in recipes {
            rows.append(replay(recipe).row)
        }
        let rates = score(rows)
        var failures: [String] = []
        if rates.fprSevereOrNotify != 0 {
            failures.append("FPR severe/notify on normal∪workout∪post∪artifact = \(rates.fprSevereOrNotify)")
        }
        if rates.forecastSevereOrNotify != 0 {
            failures.append("forecast_drift severe/notify = \(rates.forecastSevereOrNotify)")
        }
        if rates.missSafety != 0 { failures.append("miss safety = \(rates.missSafety)") }
        if rates.missEarly != 0 { failures.append("miss Early = \(rates.missEarly)") }
        if rates.missAbnormalTach > 1 { failures.append("miss tach = \(rates.missAbnormalTach)") }
        if rates.missAbnormalMulti > 1 { failures.append("miss multi = \(rates.missAbnormalMulti)") }
        if rates.missAbnormalSpo2 > 1 { failures.append("miss spo2 = \(rates.missAbnormalSpo2)") }
        if rates.missWristOff != 0 { failures.append("miss wrist_off = \(rates.missWristOff)") }
        var notes = failures
        notes.append("thresholds remain prior-untuned; this report does not edit WatchdogCalibration.json")
        return WatchdogTuneReport(
            calibrationSource: WatchdogCalibration.version,
            realWhoop5: "not_run",
            generatedUnix: Int(Date().timeIntervalSince1970),
            recipes: recipes.count,
            rates: rates,
            rows: rows,
            constraintsOk: failures.isEmpty,
            constraintNotes: notes
        )
    }

    static func markdown(_ report: WatchdogTuneReport) -> String {
        let r = report.rates
        var md = """
        # Watchdog tune report (self-label, prior-untuned)

        Generated unix \(report.generatedUnix). Replay is `Watchdog.evaluate` only.
        `calibration_source`: **\(report.calibrationSource)**. `real_whoop5`: **\(report.realWhoop5)**.
        Human review: forbidden. Thresholds were **not** rewritten.

        ## Counts

        | | n |
        |---|---|
        | Recipes | \(report.recipes) |
        | Windows kept | \(r.windowsKept) |
        | Mixed dropped | \(r.windowsDroppedMixed) |
        | Name agree (kept) | \(r.nameAgree) |

        ## Alert / miss / cover

        | Rate | n | Meaning |
        |---|---|---|
        | FPR severe or notify | \(r.fprSevereOrNotify) | normal / workout / post / artifact |
        | Forecast leak | \(r.forecastSevereOrNotify) | drift + severe or notify |
        | Miss safety | \(r.missSafety) | safety recipe, no page |
        | Miss Early | \(r.missEarly) | drift recipe, no Early |
        | Miss still-tach | \(r.missAbnormalTach) | HR in-range and safety silent |
        | Miss multi | \(r.missAbnormalMulti) | J below note |
        | Miss SpO₂ | \(r.missAbnormalSpo2) | not named / strip quiet |
        | Miss wrist-off | \(r.missWristOff) | not unavailable |
        | Band minutes learned | \(r.bandMinutesLearned) | key n > 0 |
        | Band ready windows | \(r.bandReadyWindows) | PhaseKey ready |
        | Residual sidecar writes | \(r.residualSidecarWrites) | honesty miss |
        | Confounded band n | \(r.confoundedBandN) | felt-ill must stay 0 |

        Constraints ok: **\(report.constraintsOk)**.

        """
        for note in report.constraintNotes {
            md += "- \(note)\n"
        }
        md += """

        ## Windows

        | event | intended | actual | drop | notify | sev | Early | J | J_fc | band n | key |
        |---|---|---|---|---|---|---|---|---|---|---|

        """
        for row in report.rows {
            md += "| \(row.eventId) | \(row.intended.rawValue) | \(row.actual.rawValue) | \(row.mixedDropped) | \(row.shouldNotify) | \(row.severity.rawValue) | \(row.earlyFlag) | \(String(format: "%.2f", row.jointEnergy)) | \(String(format: "%.2f", row.forecastEnergy)) | \(row.bandN) | \(row.bandKey) |\n"
        }
        md += """

        ## WHOOP 5

        `real_whoop5` rates are empty. Synthetic `family=whoop5` rows above are **cadence recipes**, not a worn-night validation.
        """
        return md
    }

    @discardableResult
    static func writeReport(_ report: WatchdogTuneReport) throws -> URL {
        let url = unitsDir().appendingPathComponent("WatchdogTuneReport.md")
        try markdown(report).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func unitsDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Baseline/units")
    }

    private struct Step {
        var row: WatchdogTuneWindowRow
        var carry: WatchdogCarry
    }

    private static func replay(_ recipe: WatchdogTuneRecipe) -> Step {
        let now = recipe.event.t1 - 1
        let family = recipe.family
        switch recipe.kind {
        case .wristOff:
            var feed = WatchdogTuneBuilder.stillFeed(now: now, family: family)
            feed.wristOff = true
            return tick(recipe, window: WatchdogWindowBuilder.build(feed), now: now)
        case .gap:
            return tick(recipe, window: WatchdogWindowBuilder.build(
                WatchdogTuneBuilder.gapFeed(now: now, family: family)), now: now)
        case .still:
            return quietStill(recipe, now: now, previous: .empty)
        case .sleep:
            return sleep(recipe, now: now)
        case .walk:
            return heldSport(recipe, now: now) {
                WatchdogTuneBuilder.walkFeed(now: $0, family: family, hr: 62, classCode: 1)
            }
        case .run:
            return heldSport(recipe, now: now) {
                WatchdogTuneBuilder.walkFeed(now: $0, family: family, hr: 118, classCode: 2)
            }
        case .cycle:
            return heldSport(recipe, now: now) {
                WatchdogTuneBuilder.cycleFeed(now: $0, family: family)
            }
        case .lift:
            return heldSport(recipe, now: now) {
                WatchdogTuneBuilder.liftFeed(now: $0, family: family)
            }
        case .post:
            var carry = WatchdogCarry.empty
            carry.lastWorkoutEndUnix = now - 4 * 60
            return tick(recipe, window: WatchdogWindowBuilder.build(
                WatchdogTuneBuilder.stillFeed(now: now, family: family)), now: now, previous: carry)
        case .artifact:
            return tick(recipe, window: WatchdogWindowBuilder.build(
                WatchdogTuneBuilder.artifactFeed(now: now, family: family)), now: now)
        case .forecastDrift:
            return drift(recipe, now: now)
        case .stillTachycardia:
            return tick(recipe, window: WatchdogWindowBuilder.build(
                WatchdogTuneBuilder.stillFeed(now: now, family: family, hr: 96)), now: now)
        case .multiDirection:
            return tick(recipe, window: WatchdogWindowBuilder.build(
                WatchdogTuneBuilder.stillFeed(now: now, family: family, hr: 96, temp: 34.3, resp: 22)), now: now)
        case .spo2Still:
            return tick(recipe, window: WatchdogWindowBuilder.build(
                WatchdogTuneBuilder.stillFeed(now: now, family: family, spo2: 88)), now: now)
        case .safety:
            return tick(recipe, window: WatchdogWindowBuilder.build(
                WatchdogTuneBuilder.stillFeed(now: now, family: family, hr: 132, hrv: 16)), now: now)
        case .mixedWalk:
            let still = quietStill(recipe, now: now - 40, previous: .empty)
            let mid = tick(recipe, window: WatchdogWindowBuilder.build(
                WatchdogTuneBuilder.walkFeed(now: now - 20, family: family, hr: 88, classCode: 1)),
                           now: now - 20, previous: still.carry)
            return tick(recipe, window: WatchdogWindowBuilder.build(
                WatchdogTuneBuilder.walkFeed(now: now, family: family, hr: 88, classCode: 1)),
                        now: now, previous: mid.carry)
        case .stillCoverMinutes:
            var carry = WatchdogCarry.empty
            var last = tick(recipe, window: WatchdogWindowBuilder.build(
                WatchdogTuneBuilder.stillFeed(now: now, family: family)), now: now, previous: carry)
            for i in 0..<16 {
                last = quietStill(recipe, now: now - (15 - i) * 60, previous: carry)
                carry = last.carry
            }
            return last
        case .feltIll:
            return tick(recipe, window: WatchdogWindowBuilder.build(
                WatchdogTuneBuilder.stillFeed(now: now, family: family)),
                        now: now, dayLog: LBDayLog(feltIll: true))
        }
    }

    private static func quietStill(_ recipe: WatchdogTuneRecipe, now: Int,
                                   previous: WatchdogCarry) -> Step {
        WatchdogForecastRuntime.testPredict = .some(nil)
        return tick(recipe, window: WatchdogWindowBuilder.build(
            WatchdogTuneBuilder.stillFeed(now: now, family: recipe.family)), now: now, previous: previous)
    }

    private static func sleep(_ recipe: WatchdogTuneRecipe, now: Int) -> Step {
        WatchdogForecastRuntime.testPredict = .some(nil)
        let night = WatchdogSleepInterval(startUnix: now - 40 * 60, endUnix: now + 3 * 3600)
        return tick(recipe, window: WatchdogWindowBuilder.build(
            WatchdogTuneBuilder.stillFeed(now: now, family: recipe.family)),
                    now: now, sleep: [night])
    }

    private static func heldSport(_ recipe: WatchdogTuneRecipe, now: Int,
                                  feed: (Int) -> WatchdogFeed) -> Step {
        WatchdogForecastRuntime.testPredict = .some(nil)
        var step = quietStill(recipe, now: now - WatchdogEventLabeler.familyHoldSeconds - 40,
                              previous: .empty)
        let t0 = now - WatchdogEventLabeler.familyHoldSeconds
        for i in 0...6 {
            step = tick(recipe, window: WatchdogWindowBuilder.build(feed(t0 + i * 20)),
                        now: t0 + i * 20, previous: step.carry)
        }
        return step
    }

    private static func drift(_ recipe: WatchdogTuneRecipe, now: Int) -> Step {
        WatchdogForecastRuntime.testPredict = .some(WatchdogTuneBuilder.leavingCube())
        defer { WatchdogForecastRuntime.testPredict = .some(nil) }
        let feed0 = WatchdogTuneBuilder.stillFeed(now: now - 20, family: recipe.family)
        let first = tick(recipe, window: WatchdogWindowBuilder.build(feed0), now: now - 20)
        return tick(recipe, window: WatchdogWindowBuilder.build(
            WatchdogTuneBuilder.stillFeed(now: now, family: recipe.family)),
                    now: now, previous: first.carry)
    }

    private static func tick(_ recipe: WatchdogTuneRecipe,
                             window: Result<WatchdogWindow, WatchdogUnavailable>,
                             now: Int,
                             previous: WatchdogCarry = .empty,
                             sleep: [WatchdogSleepInterval] = [],
                             dayLog: LBDayLog? = nil) -> Step {
        let r = Watchdog.evaluate(window: window, prompt: WatchdogTuneBuilder.prompt,
                                  dayLog: dayLog, nowUnix: now, previous: previous,
                                  sleepIntervals: sleep)
        let actual = WatchdogEventLabel(rawValue: r.eventLabel) ?? .gap
        let row = WatchdogTuneWindowRow(
            eventId: recipe.event.eventId,
            intended: recipe.event.label,
            actual: actual,
            family: recipe.family.rawValue,
            mixedDropped: actual == .mixedRejected,
            usedEvaluate: true,
            usedInjectedJoint: false,
            qualityGate: r.qualityGate,
            severity: r.severity,
            shouldNotify: r.shouldNotify,
            earlyFlag: r.earlyFlag,
            jointEnergy: r.jointEnergy,
            forecastEnergy: r.forecastEnergy,
            bandN: r.carry.bandN,
            bandReady: r.sigmaAdaptive,
            bandKey: r.carry.lastBandKey,
            sidecarEntries: r.carry.phaseUsual.entries.count,
            calibrationSource: r.calibrationSource
        )
        return Step(row: row, carry: r.carry)
    }

    private static func score(_ rows: [WatchdogTuneWindowRow]) -> WatchdogTuneRates {
        var rates = WatchdogTuneRates(
            windowsKept: 0, windowsDroppedMixed: 0, nameAgree: 0, fprSevereOrNotify: 0,
            forecastSevereOrNotify: 0, missSafety: 0, missEarly: 0, missAbnormalTach: 0,
            missAbnormalMulti: 0, missAbnormalSpo2: 0, missWristOff: 0,
            bandMinutesLearned: 0, bandReadyWindows: 0, residualSidecarWrites: 0,
            confoundedBandN: 0
        )
        for row in rows {
            if row.eventId.contains("felt-ill") {
                rates.confoundedBandN += row.bandN
            }
            if row.mixedDropped || row.intended == .mixedRejected {
                rates.windowsDroppedMixed += 1
                continue
            }
            rates.windowsKept += 1
            if row.actual == row.intended { rates.nameAgree += 1 }
            let page = row.shouldNotify || row.severity == .severe
            switch row.intended {
            case .normalSleep, .normalStillAwake, .workoutWalk, .workoutRun,
                 .workoutCycle, .workoutLift, .postWorkout, .artifactSpike:
                if page { rates.fprSevereOrNotify += 1 }
            case .forecastDriftOnly:
                if page { rates.forecastSevereOrNotify += 1 }
                if !row.earlyFlag { rates.missEarly += 1 }
            case .safetyBound:
                if !row.shouldNotify { rates.missSafety += 1 }
            case .abnormalStillTachycardia:
                if row.severity == .withinLimits && !row.shouldNotify { rates.missAbnormalTach += 1 }
            case .abnormalMultiDirection:
                if row.jointEnergy < WatchdogCalibration.tNote { rates.missAbnormalMulti += 1 }
            case .abnormalSpo2Still:
                if row.actual != .abnormalSpo2Still && row.severity == .withinLimits {
                    rates.missAbnormalSpo2 += 1
                }
            case .wristOff:
                if row.actual != .wristOff { rates.missWristOff += 1 }
            case .gap, .mixedRejected:
                break
            }
            if row.bandN > 0 { rates.bandMinutesLearned += 1 }
            if row.bandReady { rates.bandReadyWindows += 1 }
            if row.sidecarEntries > 0 { rates.residualSidecarWrites += 1 }
        }
        return rates
    }
}
