import Foundation
@testable import StrandAnalytics
import WhoopProtocol

enum WatchdogTuneBuilder {
    static let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)

    static func catalog() -> [WatchdogTuneRecipe] {
        var out: [WatchdogTuneRecipe] = []
        var t = 80_000_000
        func add(_ n: Int, _ label: WatchdogEventLabel, _ kind: WatchdogTuneRecipe.Kind,
                 family: DeviceFamily = .whoop4, span: Int = 30 * 60, tag: String? = nil) {
            for i in 0..<n {
                t += 3 * 3600
                let stem = tag ?? label.rawValue
                let id = "syn-\(stem)-\(family.rawValue)-\(i)"
                out.append(WatchdogTuneRecipe(
                    event: WatchdogEvent(eventId: id, label: label, t0: t - span, t1: t,
                                         family: family.rawValue),
                    family: family, kind: kind))
            }
        }
        add(8, .normalStillAwake, .still)
        add(8, .normalSleep, .sleep)
        add(3, .workoutWalk, .walk)
        add(3, .workoutRun, .run)
        add(3, .workoutCycle, .cycle)
        add(3, .workoutLift, .lift)
        add(3, .postWorkout, .post)
        add(3, .artifactSpike, .artifact)
        add(3, .wristOff, .wristOff)
        add(3, .gap, .gap)
        add(4, .forecastDriftOnly, .forecastDrift)
        add(4, .abnormalStillTachycardia, .stillTachycardia)
        add(4, .abnormalMultiDirection, .multiDirection)
        add(2, .abnormalSpo2Still, .spo2Still)
        add(2, .safetyBound, .safety)
        add(2, .mixedRejected, .mixedWalk)
        add(1, .normalStillAwake, .stillCoverMinutes, span: 20 * 60, tag: "still-cover")
        add(1, .normalStillAwake, .feltIll, tag: "felt-ill")
        add(2, .normalStillAwake, .still, family: .whoop5)
        add(2, .normalSleep, .sleep, family: .whoop5)
        add(1, .wristOff, .wristOff, family: .whoop5)
        add(1, .safetyBound, .safety, family: .whoop5)
        return out
    }

    static func minCount(_ label: WatchdogEventLabel) -> Int {
        switch label {
        case .normalSleep, .normalStillAwake: return 8
        case .workoutWalk, .workoutRun, .workoutCycle, .workoutLift, .postWorkout: return 3
        case .artifactSpike, .gap, .wristOff: return 3
        case .abnormalStillTachycardia, .abnormalMultiDirection, .forecastDriftOnly: return 4
        case .abnormalSpo2Still, .safetyBound: return 2
        case .mixedRejected: return 0
        }
    }

    static func stillFeed(now: Int, family: DeviceFamily, hr: Double = 58, hrv: Double = 48,
                          temp: Double = 33.1, resp: Double = 14, spo2: Double = 97,
                          motion: Double = 0) -> WatchdogFeed {
        var feed = Watchdog.syntheticFeed(now: now, hr: hr, hrv: hrv, temp: temp, resp: resp,
                                          motion: motion, family: family)
        if spo2 != 97 {
            feed.spo2Pct = feed.spo2Pct.map { WatchdogScalarSample(ts: $0.ts, value: spo2) }
        }
        return feed
    }

    static func walkFeed(now: Int, family: DeviceFamily, hr: Double, classCode: Int) -> WatchdogFeed {
        var feed = Watchdog.syntheticFeed(now: now, hr: hr, hrv: 40, temp: 33.4, resp: 16,
                                          motion: 0.40, family: family)
        let start = now - WatchdogConfig.contextSeconds
        feed.steps = (start..<now).map { StepSample(ts: $0, counter: 1, activityClass: classCode) }
        return feed
    }

    static func cycleFeed(now: Int, family: DeviceFamily) -> WatchdogFeed {
        var feed = Watchdog.syntheticFeed(now: now, hr: 88, hrv: 40, temp: 33.4, resp: 18,
                                          motion: 0.38, family: family)
        let start = now - WatchdogConfig.contextSeconds
        feed.imu = (start..<now).map { WatchdogIMUSample(ts: $0, x: 0, y: 0, z: 1, dynAccel: 0.12) }
        feed.steps = []
        return feed
    }

    static func liftFeed(now: Int, family: DeviceFamily) -> WatchdogFeed {
        var feed = Watchdog.syntheticFeed(now: now, hr: 80, hrv: 38, temp: 33.5, resp: 17,
                                          motion: 0.28, family: family)
        let start = now - WatchdogConfig.contextSeconds
        feed.imu = (start..<now).enumerated().map { i, _ in
            let dyn = (i % 40 < 12) ? 0.55 : 0.04
            return WatchdogIMUSample(ts: start + i, x: 0, y: 0, z: 1, dynAccel: dyn)
        }
        feed.steps = []
        return feed
    }

    static func artifactFeed(now: Int, family: DeviceFamily) -> WatchdogFeed {
        let start = now - WatchdogConfig.contextSeconds
        let hr = (start..<now).map { HRSample(ts: $0, bpm: 60) }
        let motion = (start..<now).map { WatchdogScalarSample(ts: $0, value: 0.50) }
        let imu = (start..<now).map { WatchdogIMUSample(ts: $0, x: 1, y: 0, z: 0, dynAccel: 0.35) }
        return WatchdogFeed(family: family, hrSource: .v18, nowUnix: now, hr: hr,
                            motion: motion, imu: imu)
    }

    static func gapFeed(now: Int, family: DeviceFamily) -> WatchdogFeed {
        var feed = stillFeed(now: now, family: family)
        let keep = now - 120
        feed.hr = feed.hr.filter { $0.ts >= keep }
        feed.rr = feed.rr.filter { $0.ts >= keep }
        return feed
    }

    static func leavingCube() -> [[Double]] {
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
