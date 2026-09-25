import Foundation
import WhoopProtocol

/// 20-column minute activity block. Core ML may consume this; effort lookup is not the physiology.
public enum WatchdogActivityFeatures: Sendable {
    public static let width = 20

    public static func build(window: WatchdogWindow, imu: [WatchdogIMUSample] = [],
                             steps: [StepSample] = [], lastWorkoutEndUnix: Int = 0) -> [[Double]] {
        let n = window.seqLen
        guard n > 0 else { return [] }
        let span = max(window.nowUnix - window.startUnix, 1)
        func minuteIndex(_ ts: Int) -> Int {
            min(n - 1, max(0, ((ts - window.startUnix) * n) / span))
        }
        var dynSum = Array(repeating: 0.0, count: n)
        var dynSq = Array(repeating: 0.0, count: n)
        var dynN = Array(repeating: 0, count: n)
        var grav = Array(repeating: 0.0, count: n)
        var gravN = Array(repeating: 0, count: n)
        for g in imu where g.ts >= window.startUnix && g.ts < window.nowUnix {
            let i = minuteIndex(g.ts)
            let mag = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            grav[i] += abs(mag - 1)
            gravN[i] += 1
            if let d = g.dynAccel {
                dynSum[i] += d
                dynSq[i] += d * d
                dynN[i] += 1
            }
        }
        var still = Array(repeating: 0.0, count: n)
        var walk = Array(repeating: 0.0, count: n)
        var run = Array(repeating: 0.0, count: n)
        var stepN = Array(repeating: 0.0, count: n)
        for s in steps where s.ts >= window.startUnix && s.ts < window.nowUnix {
            let i = minuteIndex(s.ts)
            stepN[i] += 1
            switch s.activityClass {
            case 0: still[i] += 1
            case 1: walk[i] += 1
            case 2: run[i] += 1
            default: break
            }
        }
        let cal = Calendar.current
        let hour = Double(cal.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(window.nowUnix))))
        let ang = 2 * Double.pi * hour / 24
        return (0..<n).map { i in
            var row = Array(repeating: 0.0, count: width)
            let logits = i < window.activityLogits.count ? window.activityLogits[i] : []
            for k in 0..<min(8, logits.count) { row[k] = logits[k] }
            let mag = max(0, min(1, window.motion[i] ?? 0))
            row[8] = mag
            let dn = Double(max(dynN[i], 0))
            let dMean = dn > 0 ? dynSum[i] / dn : mag * 0.4
            row[9] = min(4, max(0, dMean))
            if dn > 1 {
                let v = max(0, dynSq[i] / dn - dMean * dMean)
                row[10] = min(4, sqrt(v))
            }
            row[11] = gravN[i] > 0 ? min(1, grav[i] / Double(gravN[i])) : mag
            let sn = max(stepN[i], 1)
            row[12] = still[i] / sn
            row[13] = walk[i] / sn
            row[14] = run[i] / sn
            row[15] = i < window.autoWorkoutOverlap.count ? (window.autoWorkoutOverlap[i] >= 0.5 ? 1 : 0) : 0
            if lastWorkoutEndUnix > 0 {
                row[16] = min(2, max(0, Double(window.nowUnix - lastWorkoutEndUnix) / 3600.0))
            }
            row[17] = sin(ang)
            row[18] = cos(ang)
            let cls = WatchdogActivityClass.labels(logits: [row]).first
            row[19] = (hour < 5 || cls == WatchdogActivityClass.still.rawValue && hour < 7) ? 0 : 0
            if hour >= 0 && hour < 5 { row[19] = 1 }
            return row
        }
    }

    public static func occupancyDebug(from features: [[Double]]) -> [Double] {
        features.map { row in
            guard row.count > 8 else { return 0 }
            return max(0, min(1, row[8]))
        }
    }
}
