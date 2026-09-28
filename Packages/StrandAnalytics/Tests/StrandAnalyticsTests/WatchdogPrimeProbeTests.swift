
import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// AUDIT-ONLY probe suite (Prime Agent benchmark, 2026-09-24).
/// It does not change production behaviour. It records evidence to a file so the
/// report can cite exact numbers.
final class WatchdogPrimeProbeTests: XCTestCase {

    // MARK: - Evidence sink

    static let auditDir: String = ProcessInfo.processInfo.environment["WD_AUDIT_DIR"] ?? "/tmp/wd_audit"
    static var lines: [String] = []

    override class func setUp() {
        try? FileManager.default.createDirectory(atPath: auditDir, withIntermediateDirectories: true)
    }

    static func record(_ s: String) {
        let path = "\(auditDir)/probe_output.txt"
        let line = s + "\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
        print("[PROBE] \(s)")
    }

    // MARK: - Fixtures

    static let quietPrompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)

    /// Chronological HR tape with a per-minute bpm function.
    static func feed(now: Int, family: DeviceFamily = .whoop4, cadence: Int = 1,
                     hr: (Int) -> Int? = { _ in 58 },
                     temp: (Int) -> Double? = { _ in 33.1 },
                     resp: (Int) -> Double? = { _ in 14 },
                     spo2: (Int) -> Double? = { _ in 97 },
                     motion: (Int) -> Double? = { _ in 0 },
                     steps: ((Int) -> Int?)? = nil,
                     imu: ((Int) -> (Double, Double)?)? = nil,
                     rrDelta: (Int) -> Int = { _ in 0 },
                     wristOff: Bool = false) -> WatchdogFeed {
        let start = now - WatchdogConfig.contextSeconds
        var hrs: [HRSample] = []
        var rrs: [RRInterval] = []
        var temps: [WatchdogScalarSample] = []
        var resps: [WatchdogScalarSample] = []
        var mots: [WatchdogScalarSample] = []
        var spo2s: [WatchdogScalarSample] = []
        var stepsOut: [StepSample] = []
        var imuOut: [WatchdogIMUSample] = []
        for m in 0..<WatchdogConfig.seqLen {
            let mStart = start + m * 60
            for t in stride(from: mStart, to: mStart + 60, by: cadence) {
                if let bpm = hr(m) { hrs.append(HRSample(ts: t, bpm: bpm)) }
                if let v = temp(m) { temps.append(WatchdogScalarSample(ts: t, value: v)) }
                if let v = resp(m) { resps.append(WatchdogScalarSample(ts: t, value: v)) }
                if let v = motion(m) { mots.append(WatchdogScalarSample(ts: t, value: v)) }
                if let v = spo2(m) { spo2s.append(WatchdogScalarSample(ts: t, value: v)) }
                if let cls = steps?(m) { stepsOut.append(StepSample(ts: t, counter: 1, activityClass: cls)) }
                if let (x, dyn) = imu?(m) { imuOut.append(WatchdogIMUSample(ts: t, x: x, y: 0, z: 0, dynAccel: dyn)) }
                if let bpm = hr(m) {
                    let base = Int((60000.0 / Double(max(bpm, 30))).rounded())
                    rrs.append(RRInterval(ts: t, rrMs: max(300, base + rrDelta(t))))
                }
            }
        }
        return WatchdogFeed(family: family, hrSource: .v18, nowUnix: now,
                            hr: hrs, rr: rrs, skinTempC: temps, respPerMin: resps,
                            motion: mots, spo2Pct: spo2s, wristOff: wristOff,
                            imu: imuOut, steps: stepsOut)
    }

    static func win(_ feed: WatchdogFeed) throws -> WatchdogWindow {
        switch WatchdogWindowBuilder.build(feed) {
        case .success(let w): return w
        case .failure(let r): throw NSError(domain: "probe", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "window failed \(r)"])
        }
    }

    static func clone(_ w: WatchdogWindow, temp: [Double?]? = nil, resp: [Double?]? = nil,
                      hrv: [Double?]? = nil, spo2: [Double?]? = nil, hr: [Double?]? = nil) -> WatchdogWindow {
        WatchdogWindow(family: w.family, hrSource: w.hrSource, startUnix: w.startUnix, nowUnix: w.nowUnix,
                       hr: hr ?? w.hr, hrv: hrv ?? w.hrv, temp: temp ?? w.temp, resp: resp ?? w.resp,
                       motion: w.motion, rhr: w.rhr, spo2: spo2 ?? w.spo2,
                       hrMin: w.hrMin, hrMax: w.hrMax, coverage: w.coverage,
                       maxGapSeconds: w.maxGapSeconds, newestAgeSeconds: w.newestAgeSeconds,
                       keptPPGIdentities: w.keptPPGIdentities, bucketCoverage: w.bucketCoverage,
                       maxEmptyMinutes: w.maxEmptyMinutes, activityLogits: w.activityLogits,
                       autoWorkoutOverlap: w.autoWorkoutOverlap)
    }

    /// Controlled residual: shift each hat down by `r[k] * scale[k]` so the measured
    /// per-channel residual is exactly `r[k]` sigma. Independent of the model's own magnitudes.
    static func controlled(_ base: UniTSResidual, window: WatchdogWindow, r: [Double]) -> UniTSResidual {
        var out = base
        func shift(_ obs: [Double?], _ scale: [Double], _ k: Double) -> [Double?] {
            obs.enumerated().map { i, o in
                guard let o else { return nil }
                let s = i < scale.count ? scale[i] : 1
                return o - k * s
            }
        }
        out.reconstructedHR = shift(window.hr, base.scaleHR, r[0])
        out.reconstructedRHR = shift(window.rhr, base.scaleRHR, r[1])
        out.reconstructedHRV = shift(window.hrv, base.scaleHRV, r[2])
        out.reconstructedTemp = shift(window.temp, base.scaleTemp, r[3])
        out.reconstructedResp = shift(window.resp, base.scaleResp, r[4])
        out.reconstructedSpO2 = shift(window.spo2, base.scaleSpO2, r[5])
        return out
    }

    // MARK: - P1 activity family hold: ticks vs minutes

    func testProbe01ClassHoldUsesTicksNotMinutes() throws {
        let now = 61_000_000
        let still = try Self.win(Self.feed(now: now))
        let walk = try Self.win(Self.feed(now: now, motion: { _ in 0.40 }, steps: { _ in 1 }))
        let base = try UniTSRuntime().reconstruct(still, prompt: Self.quietPrompt)
        let zeroResidual = Self.controlled(base, window: still, r: [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(WatchdogActivityClass.labels(logits: still.activityLogits).last, "still")
        XCTAssertEqual(WatchdogActivityClass.labels(logits: walk.activityLogits).last, "walk")

        var carry = WatchdogCarry.empty
        var t = now
        // Ten still ticks so the family is established.
        for _ in 0..<10 {
            let w = try Self.win(Self.feed(now: t))
            let res = Self.controlled(base, window: w, r: [0, 0, 0, 0, 0, 0])
            let out = Watchdog.combine(window: w, residual: res, prompt: Self.quietPrompt,
                                       evaluations: [], dayLog: nil, nowUnix: t, interval: 5, carry: &carry)
            XCTAssertEqual(out.eventLabel, "normal_still_awake")
            t += 20
        }
        var cutTick: Int? = nil
        var labels: [String] = []
        var cuts: [String] = []
        // Twelve walk ticks (4 minutes) at 20 s each.
        for i in 1...12 {
            let w = try Self.win(Self.feed(now: t, motion: { _ in 0.40 }, steps: { _ in 1 }))
            let res = Self.controlled(base, window: w, r: [0, 0, 0, 0, 0, 0])
            let out = Watchdog.combine(window: w, residual: res, prompt: Self.quietPrompt,
                                       evaluations: [], dayLog: nil, nowUnix: t, interval: 5, carry: &carry)
            labels.append("\(i):\(out.eventLabel)/\(out.cutReason)")
            if out.cutReason == "class-hold" { cuts.append("tick\(i)"); if cutTick == nil { cutTick = i } }
            t += 20
        }
        Self.record("P1 class-hold: first cut at walk tick \(cutTick.map { String($0) } ?? "none") "
                    + "(20 s ticks => \(Double(cutTick ?? 0) * 20) s after the family change); "
                    + "contract familyHoldMinutes=\(WatchdogEventLabeler.familyHoldMinutes) minutes = "
                    + "\(WatchdogEventLabeler.familyHoldMinutes * 60 / 20) ticks. cuts=\(cuts)")
        Self.record("P1 labels: \(labels.joined(separator: " | "))")
    }

    // MARK: - P2/P3 safety extrema windows

    func testProbe02TempAndRespSafetyInspectLastSampleOnly() throws {
        let now = 62_000_000
        let base = try Self.win(Self.feed(now: now))
        // Transient 39.0 C in minute 5 only, normal afterwards.
        var temp: [Double?] = Array(repeating: 33.1, count: 30)
        temp[5] = 39.0
        let transientTemp = Self.clone(base, temp: temp)
        // Same extreme on the newest minute.
        var tempLast: [Double?] = Array(repeating: 33.1, count: 30)
        tempLast[29] = 39.0
        let lastTemp = Self.clone(base, temp: tempLast)

        var resp: [Double?] = Array(repeating: 14.0, count: 30)
        resp[5] = 44.0
        let transientResp = Self.clone(base, resp: resp)
        var respLast: [Double?] = Array(repeating: 14.0, count: 30)
        respLast[29] = 44.0
        let lastResp = Self.clone(base, resp: respLast)

        Self.record("P2 safety temp 39.0 C at minute 5 of 30 -> fired=\(WatchdogSafety.fired( transientTemp)); "
                    + "at newest minute -> fired=\(WatchdogSafety.fired( lastTemp))")
        Self.record("P2 safety resp 44/min at minute 5 of 30 -> fired=\(WatchdogSafety.fired( transientResp)); "
                    + "at newest minute -> fired=\(WatchdogSafety.fired( lastResp))")
        // And a transient LOW temp / LOW resp.
        var lowTemp: [Double?] = Array(repeating: 33.1, count: 30)
        lowTemp[5] = 27.0
        var lowResp: [Double?] = Array(repeating: 14.0, count: 30)
        lowResp[5] = 4.0
        Self.record("P2 safety temp 27.0 C at minute 5 -> fired=\(WatchdogSafety.fired( Self.clone(base, temp: lowTemp))); "
                    + "resp 4/min at minute 5 -> fired=\(WatchdogSafety.fired( Self.clone(base, resp: lowResp)))")
        // HR (the channel the contract also lists) does read the whole window:
        var hr: [Double?] = Array(repeating: 58.0, count: 30)
        hr[5] = 128.0
        Self.record("P2 safety HR 128 bpm at minute 5 (window extremum path) -> fired=\(WatchdogSafety.fired( Self.clone(base, hr: hr)))")
    }

    func testProbe03HRVSafetyExtremaUnreachableAndLastSampleOnly() throws {
        let now = 63_000_000
        let base = try Self.win(Self.feed(now: now))
        var mid: [Double?] = Array(repeating: 48.0, count: 30)
        mid[10] = 300.0
        var last: [Double?] = Array(repeating: 48.0, count: 30)
        last[29] = 300.0
        Self.record("P3 safety HRV 300 ms at minute 10 -> fired=\(WatchdogSafety.fired( Self.clone(base, hrv: mid))); "
                    + "at newest minute -> fired=\(WatchdogSafety.fired( Self.clone(base, hrv: last)))")

        // Can the builder ever hand an out-of-range RMSSD to safety?
        // Alternating RR around 850/1150 ms: raw RMSSD is far outside the documented cap.
        let alt = try Self.win(Self.feed(now: now, rrDelta: { t in (t % 2 == 0) ? -150 : 150 }))
        let altVals = alt.hrv.compactMap { $0 }
        Self.record("P3 alternating 850/1150 ms RR: window hrv values count=\(altVals.count) "
                    + "min=\(altVals.min() ?? -1) max=\(altVals.max() ?? -1) "
                    + "safetyFired=\(WatchdogSafety.fired( alt))")
        // Raw RMSSD on the same tape, before the Watchdog grid filter.
        let start = now - WatchdogConfig.contextSeconds
        let rr = (start..<now).map { t -> RRInterval in
            RRInterval(ts: t, rrMs: (t % 2 == 0) ? 850 : 1150)
        }
        let raw = HRVAnalyzer.analyze(rr)
        Self.record("P3 raw HRV cleaning on the same tape: rmssd=\(raw.rmssd.map { String(format: "%.2f", $0) } ?? "nil") nClean=\(raw.nClean)")
        Self.record("P3 rmssdLow=\(WatchdogConfig.rmssdLow) rmssdHigh=\(WatchdogConfig.rmssdHigh) "
                    + "(rmssdGrid drops points outside this band before safety can see them)")
    }

    // MARK: - P4 day-log confounder must not train the Watchdog band

    func testProbe04ConfoundedDayLogStillTrainsBand() throws {
        let now = 64_000_000
        let confounded = LBDayLog(feltIll: true)
        XCTAssertTrue(confounded.confoundsUsual)
        var carry = WatchdogCarry.empty
        let w = try Self.win(Self.feed(now: now))
        let base = try UniTSRuntime().reconstruct(w, prompt: Self.quietPrompt)
        // Small but non-zero residual, HR below tNote so the band stays eligible.
        let res = Self.controlled(base, window: w, r: [0.2, 0.2, 0.2, 0.2, 0.2, 0.2])
        var t = now
        var last: WatchdogResult? = nil
        for _ in 0..<20 {
            let ww = try Self.win(Self.feed(now: t))
            let rr = Self.controlled(base, window: ww, r: [0.2, 0.2, 0.2, 0.2, 0.2, 0.2])
            last = Watchdog.combine(window: ww, residual: rr, prompt: Self.quietPrompt,
                                    evaluations: [], dayLog: confounded, nowUnix: t, interval: 5, carry: &carry)
            t += 20
        }
        let out = try XCTUnwrap(last)
        Self.record("P4 confounded day log (feltIll): bandN=\(out.carry.bandN) bandReady=\(out.carry.bandReady) "
                    + "bandQ=\(out.carry.bandQ.map { String(format: "%.3f", $0) }) severity=\(out.severity.rawValue) "
                    + "sessionN=\(out.carry.sessionN)")
        _ = res
    }

    // MARK: - P5 phase sidecar writes residuals, reads them as native units

    func testProbe05PhaseSidecarCentersAreResidualUnits() throws {
        // Drive seven civil days of eligible still ticks and watch the phase store fill.
        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 1; comps.hour = 1; comps.minute = 0; comps.second = 0
        var t = Int(try XCTUnwrap(cal.date(from: comps)).timeIntervalSince1970)
        var carry = WatchdogCarry.empty
        var day = 0
        var ticksThisDay = 0
        var storeAfter: [String: WatchdogPhaseEntry] = [:]
        while day < 8 {
            let w = try Self.win(Self.feed(now: t))
            let base = try UniTSRuntime().reconstruct(w, prompt: Self.quietPrompt)
            let res = Self.controlled(base, window: w, r: [0.3, 0.3, 0.3, 0.3, 0.3, 0.3])
            let out = Watchdog.combine(window: w, residual: res, prompt: Self.quietPrompt,
                                       evaluations: [], dayLog: nil, nowUnix: t, interval: 5, carry: &carry)
            storeAfter = out.carry.phaseUsual.entries
            t += 20
            ticksThisDay += 1
            let h = cal.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(t)))
            if h >= 5 || ticksThisDay > 400 { day += 1; ticksThisDay = 0; comps.hour = 1
                t = Int(try XCTUnwrap(cal.date(from: comps)).timeIntervalSince1970) + day * 86400 }
        }
        for (key, e) in storeAfter.sorted(by: { $0.key < $1.key }) {
            Self.record("P5 phase entry \(key): nDays=\(e.nDays) center=\(e.center.map { String(format: "%.3f", $0) }) "
                        + "updatedDay=\(e.updatedDay)")
        }
        let key = WatchdogPhaseKey(phase: .sleep, family: .still)
        if let mature = carry.phaseUsual.mature(key) {
            let blended = carry.phaseUsual.blendPrompt(Self.quietPrompt, key: key)
            Self.record("P5 mature key \(key.id): center=\(mature.center.map { String(format: "%.3f", $0) }) "
                        + "nDays=\(mature.nDays); blended prompt hr=\(blended.hr.map { String(format: "%.2f", $0) } ?? "nil") "
                        + "temp=\(blended.temp.map { String(format: "%.2f", $0) } ?? "nil") "
                        + "resp=\(blended.resp.map { String(format: "%.2f", $0) } ?? "nil") "
                        + "hrv=\(blended.hrv.map { String(format: "%.2f", $0) } ?? "nil") (Layer 1 hr=58, temp=33.1, resp=14)")
        } else {
            Self.record("P5 no mature phase key after the replay (entries=\(storeAfter.count))")
        }
    }

    // MARK: - P6 severity ramp / escalation policy

    func testProbe06SevereBySlowRampDoesNotPage() throws {
        let now = 65_000_000
        let w0 = try Self.win(Self.feed(now: now))
        let base = try UniTSRuntime().reconstruct(w0, prompt: Self.quietPrompt)
        var carry = WatchdogCarry.empty
        var t = now
        var rows: [String] = []
        var notifies = 0
        // r rises 0.05 per tick on all six channels: J climbs slowly to well past severe.
        for i in 0...60 {
            let k = Double(i) * 0.05
            let w = try Self.win(Self.feed(now: t))
            let res = Self.controlled(base, window: w, r: [k, k, k, k, k, k])
            let out = Watchdog.combine(window: w, residual: res, prompt: Self.quietPrompt,
                                       evaluations: [], dayLog: nil, nowUnix: t, interval: 5, carry: &carry)
            if out.shouldNotify { notifies += 1 }
            if i % 5 == 0 || out.shouldNotify {
                rows.append("i\(i) r=\(String(format: "%.2f", k)) J=\(String(format: "%.2f", out.jointEnergy)) "
                            + "sev=\(out.severity.rawValue) label=\(out.eventLabel) notify=\(out.shouldNotify)/\(out.notifyReason)")
            }
            t += 20
        }
        Self.record("P6 slow ramp: notifications=\(notifies) over 61 ticks reaching severe")
        Self.record("P6 ramp rows: \(rows.joined(separator: " | "))")
    }

    // MARK: - P7 deprecated carry field

    func testProbe07QuietJointEmaIsNotConsumed() throws {
        let now = 66_000_000
        var carry = WatchdogCarry.empty
        carry.quietJointEma = 5.0
        let w = try Self.win(Self.feed(now: now))
        let base = try UniTSRuntime().reconstruct(w, prompt: Self.quietPrompt)
        let res = Self.controlled(base, window: w, r: [0, 0, 0, 0, 0, 0])
        let out = Watchdog.combine(window: w, residual: res, prompt: Self.quietPrompt,
                                   evaluations: [], dayLog: nil, nowUnix: now, interval: 5, carry: &carry)
        Self.record("P7 quietJointEma injected 5.0 -> after tick=\(out.carry.quietJointEma) "
                    + "J=\(out.jointEnergy) severity=\(out.severity.rawValue) notify=\(out.shouldNotify)")
    }

    // MARK: - P8 sleep vs still-awake band state sharing

    func testProbe08SleepAndStillAwakeShareBandState() throws {
        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 10; comps.hour = 2; comps.minute = 0; comps.second = 0
        let sleepStart = Int(try XCTUnwrap(cal.date(from: comps)).timeIntervalSince1970)
        comps.hour = 14
        let dayStart = Int(try XCTUnwrap(cal.date(from: comps)).timeIntervalSince1970)

        var carry = WatchdogCarry.empty
        // 16 quiet sleep ticks, small residual.
        for i in 0..<16 {
            let t = sleepStart + i * 20
            let w = try Self.win(Self.feed(now: t))
            let base = try UniTSRuntime().reconstruct(w, prompt: Self.quietPrompt)
            let res = Self.controlled(base, window: w, r: [0.1, 0.1, 0.1, 0.1, 0.1, 0.1])
            _ = Watchdog.combine(window: w, residual: res, prompt: Self.quietPrompt, evaluations: [],
                                 dayLog: nil, nowUnix: t, interval: 5, carry: &carry)
        }
        let afterSleep = carry.bandN
        let qSleep = carry.bandQ
        let scaleSleep = carry.bandScale
        // Then 40 loud-but-eligible still-awake ticks (daytime, |r| = 1.0, under the 2.5 cap).
        var lastOut: WatchdogResult? = nil
        for i in 0..<40 {
            let t = dayStart + i * 20
            let w = try Self.win(Self.feed(now: t))
            let base = try UniTSRuntime().reconstruct(w, prompt: Self.quietPrompt)
            let res = Self.controlled(base, window: w, r: [1.0, 1.0, 1.0, 1.0, 1.0, 1.0])
            lastOut = Watchdog.combine(window: w, residual: res, prompt: Self.quietPrompt, evaluations: [],
                                       dayLog: nil, nowUnix: t, interval: 5, carry: &carry)
        }
        let out = try XCTUnwrap(lastOut)
        Self.record("P8 band state shared: bandN after 16 sleep ticks=\(afterSleep) "
                    + "q=\(qSleep.map { String(format: "%.3f", $0) }) scale=\(scaleSleep.map { String(format: "%.3f", $0) })")
        Self.record("P8 after 40 daytime still-awake ticks: bandN=\(out.carry.bandN) "
                    + "q=\(out.carry.bandQ.map { String(format: "%.3f", $0) }) "
                    + "scale=\(out.carry.bandScale.map { String(format: "%.3f", $0) }) "
                    + "label=\(out.eventLabel) severity=\(out.severity.rawValue) "
                    + "rangeHR=\(out.rangeHR.last.map { String(format: "%.2f", $0) } ?? "nil")")
    }

    // MARK: - P9 quality boundary

    func testProbe09CoverageBoundaryPercent() throws {
        let now = 67_000_000
        for filled in [0, 23, 24, 25] {
            let w = try Self.win(Self.feed(now: now, hr: { m in m < filled ? 62 : nil }))
            let gate = WatchdogQuality.gate(w)
            Self.record("P9 bucketCoverage=\(filled)/30=\(String(format: "%.4f", WatchdogQuality.bucketCoverage(w))) "
                        + "gate=\(gate.map { $0.rawValue } ?? "pass")")
        }
        for emptyRun in [5, 6, 7] {
            let w = try Self.win(Self.feed(now: now, hr: { m in (m >= 10 && m < 10 + emptyRun) ? nil : 62 }))
            Self.record("P9 emptyRun=\(emptyRun) bucketCoverage=\(String(format: "%.3f", WatchdogQuality.bucketCoverage(w))) "
                        + "gate=\(WatchdogQuality.gate(w).map { $0.rawValue } ?? "pass")")
        }
        // Freshness: newest sample exactly limit, one second stale, far stale.
        for age in [0, 1, 59, 60, 61, 90] {
            let t0 = now - age
            let w = try Self.win(Self.feed(now: t0, hr: { _ in 62 }))
            let wShifted = Self.clone(w)
            let shifted = WatchdogWindow(family: wShifted.family, hrSource: wShifted.hrSource,
                                         startUnix: wShifted.startUnix, nowUnix: now,
                                         hr: wShifted.hr, hrv: wShifted.hrv, temp: wShifted.temp,
                                         resp: wShifted.resp, motion: wShifted.motion, rhr: wShifted.rhr,
                                         spo2: wShifted.spo2, hrMin: wShifted.hrMin, hrMax: wShifted.hrMax,
                                         coverage: wShifted.coverage, maxGapSeconds: wShifted.maxGapSeconds,
                                         newestAgeSeconds: age, keptPPGIdentities: wShifted.keptPPGIdentities,
                                         bucketCoverage: wShifted.bucketCoverage,
                                         maxEmptyMinutes: wShifted.maxEmptyMinutes,
                                         activityLogits: wShifted.activityLogits,
                                         autoWorkoutOverlap: wShifted.autoWorkoutOverlap)
            Self.record("P9 whoop4 newestAge=\(age)s limit=\(WatchdogQuality.freshnessLimit(.whoop4)) "
                        + "gate=\(WatchdogQuality.gate(shifted).map { $0.rawValue } ?? "pass")")
        }
    }

    // MARK: - P10 full-path quiet replay and Layer 1 isolation

    func testProbe10QuietReplayNeverNotifies() throws {
        let now = 68_000_000
        var carry = WatchdogCarry.empty
        var notifications = 0
        var worstSeverity = "withinLimits"
        var worstJ = 0.0
        var t = now
        for _ in 0..<120 {
            let feed = Self.feed(now: t, hr: { m in 58 + (m % 3) })
            let out = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                        prompt: Self.quietPrompt, nowUnix: t, previous: carry)
            carry = out.carry
            if out.shouldNotify { notifications += 1 }
            if out.jointEnergy > worstJ { worstJ = out.jointEnergy; worstSeverity = out.severity.rawValue }
            t += 20
        }
        Self.record("P10 120 quiet ticks: notifications=\(notifications) worstSeverity=\(worstSeverity) "
                    + "worstJ=\(String(format: "%.3f", worstJ)) episode=\(carry.episodeId ?? "nil") "
                    + "bandN=\(carry.bandN)")
    }
}
