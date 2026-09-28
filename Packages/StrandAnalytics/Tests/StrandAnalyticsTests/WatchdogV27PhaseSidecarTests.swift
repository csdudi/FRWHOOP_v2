import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Feedback 1: residuals stay in sessionAbs; sidecar center is native vitals only.
final class WatchdogV27PhaseSidecarTests: XCTestCase {

    private let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)
    private let key = WatchdogPhaseKey(phase: .sleep, family: .still)

    func testWriteDayRejectsResidualScaleMedian() {
        var store = WatchdogPhaseUsualStore.empty
        store.writeDay(key: key, dayMedian: [0.3, 0.3, 0.3, 0.3, 0.3, 0.3], civilDay: "2026-09-01")
        XCTAssertTrue(store.entries.isEmpty)
        store.writeDay(key: key, dayMedian: [62, 58, 46, 33.2, 14.1, 97], civilDay: "2026-09-01")
        XCTAssertEqual(store.entries[key.id]?.center[0] ?? 0, 62, accuracy: 0.01)
    }

    func testBlendIgnoresPoisonedResidualCenter() {
        var store = WatchdogPhaseUsualStore.empty
        for i in 1...7 {
            store.writeDay(key: key, dayMedian: [62, 58, 46, 33.2, 14.1, 97],
                           civilDay: String(format: "2026-09-%02d", i))
        }
        XCTAssertNotNil(store.mature(key))
        store.entries[key.id]?.center = [0.3, 0.3, 0.3, 0.3, 0.3, 0.3]
        let blended = store.blendPrompt(prompt, key: key)
        XCTAssertEqual(blended.hr ?? 0, 58, accuracy: 1e-9)
        XCTAssertEqual(blended.temp ?? 0, 33.1, accuracy: 1e-9)
    }

    func testDropResidualScaleCentersOnDecode() throws {
        var poisoned = WatchdogCarry.empty
        poisoned.phaseUsual.writeDay(key: key, dayMedian: [62, 58, 46, 33.2, 14.1, 97],
                                     civilDay: "2026-09-01")
        poisoned.phaseUsual.entries[key.id]?.center = [0.4, 0.4, 0.4, 0.4, 0.4, 0.4]
        poisoned.phaseUsual.entries[key.id]?.nDays = 8
        let data = try JSONEncoder().encode(poisoned)
        let decoded = try JSONDecoder().decode(WatchdogCarry.self, from: data)
        XCTAssertNil(decoded.phaseUsual.entries[key.id])
        let blended = decoded.phaseUsual.blendPrompt(prompt, key: key)
        XCTAssertEqual(blended.hr ?? 0, 58, accuracy: 1e-9)
    }

    func testSessionAbsIsResidualAndDoesNotMovePrompt() throws {
        var carry = WatchdogCarry.empty
        let now = sleepUnix(day: 1)
        for i in 0..<16 {
            let t = now + i * 60
            let r = tick(now: t, hr: 58, previous: carry)
            carry = r.carry
        }
        XCTAssertGreaterThanOrEqual(carry.sessionN, 8)
        XCTAssertGreaterThan(carry.sessionAbs[0], 0)
        XCTAssertLessThan(carry.sessionAbs[0], 8, "sessionAbs must stay residual-scale")
        XCTAssertGreaterThan(carry.sessionNative[0], 40, "sessionNative must be bpm")
        XCTAssertEqual(carry.sessionNative[3], 33.1, accuracy: 0.6)
        XCTAssertTrue(carry.phaseUsual.entries.isEmpty, "same-day ticks must not write the sidecar")
        let live = carry.phaseUsual.blendPrompt(prompt, key: key)
        XCTAssertEqual(live.hr ?? 0, 58, accuracy: 1e-9)
    }

    func testCivilRolloverWritesNativeNotResidual() throws {
        var carry = WatchdogCarry.empty
        let day1 = sleepUnix(day: 1)
        for i in 0..<16 {
            carry = tick(now: day1 + i * 60, hr: 58, previous: carry).carry
        }
        XCTAssertGreaterThanOrEqual(carry.sessionNativeN, 12)
        XCTAssertLessThan(carry.sessionAbs[0], 8)
        let residualBeforeWrite = carry.sessionAbs[0]
        let nativeBeforeWrite = carry.sessionNative[0]
        XCTAssertGreaterThan(nativeBeforeWrite, 40)
        var store = WatchdogPhaseUsualStore.empty
        store.writeDay(key: key, dayMedian: carry.sessionAbs, civilDay: "2026-06-01")
        XCTAssertTrue(store.entries.isEmpty, "residual sessionAbs must not become a sidecar center")
        store.writeDay(key: key, dayMedian: carry.sessionNative, civilDay: "2026-06-01")
        let center = try XCTUnwrap(store.entries[key.id]?.center)
        XCTAssertGreaterThan(center[0], 40, "sidecar HR is bpm, got \(center[0])")
        XCTAssertLessThan(center[0], 90)
        XCTAssertGreaterThan(center[3], 20, "sidecar temp is °C, got \(center[3])")
        XCTAssertEqual(center[0], nativeBeforeWrite, accuracy: 1.5)
        XCTAssertNotEqual(center[0], residualBeforeWrite, accuracy: 0.5)
        carry.lastCivilDay = "2020-01-01"
        carry = tick(now: day1 + 16 * 60, hr: 58, previous: carry).carry
        if let live = carry.phaseUsual.entries.first?.value.center {
            XCTAssertGreaterThan(live[0], 40)
            XCTAssertGreaterThan(live[3], 20)
        }
    }

    func testSevenNativeDaysBlendStaysOnVitalScale() {
        var store = WatchdogPhaseUsualStore.empty
        for i in 1...7 {
            store.writeDay(key: key, dayMedian: [62, 58, 46, 33.2, 14.1, 97],
                           civilDay: String(format: "2026-09-%02d", i))
        }
        let blended = store.blendPrompt(prompt, key: key)
        let hr = try! XCTUnwrap(blended.hr)
        XCTAssertEqual(hr, 0.3 * 58 + 0.7 * 62, accuracy: 0.05)
        XCTAssertGreaterThan(hr, 40)
        XCTAssertLessThan(hr, 80)
        let temp = try! XCTUnwrap(blended.temp)
        XCTAssertGreaterThan(temp, 30)
        XCTAssertLessThan(temp, 36)
    }

    func testControlledResidualDaysCannotPoisonPrompt() throws {
        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 1; comps.hour = 1
        var t = Int(try XCTUnwrap(cal.date(from: comps)).timeIntervalSince1970)
        var carry = WatchdogCarry.empty
        var day = 0
        var ticksThisDay = 0
        while day < 8 {
            let w = try window(now: t, hr: 58)
            let base = try UniTSRuntime().reconstruct(w, prompt: prompt)
            let res = controlled(base, window: w, r: [0.3, 0.3, 0.3, 0.3, 0.3, 0.3])
            _ = Watchdog.combine(window: w, residual: res, prompt: prompt,
                                 evaluations: [], dayLog: nil, nowUnix: t, interval: 5, carry: &carry)
            t += 20
            ticksThisDay += 1
            let h = cal.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(t)))
            if h >= 5 || ticksThisDay > 40 {
                day += 1
                ticksThisDay = 0
                t = Int(try XCTUnwrap(cal.date(from: comps)).timeIntervalSince1970) + day * 86400
            }
        }
        let blended = carry.phaseUsual.blendPrompt(prompt, key: key)
        XCTAssertGreaterThan(blended.hr ?? 0, 40)
        if let e = carry.phaseUsual.entries[key.id] {
            XCTAssertTrue(WatchdogPhaseUsualStore.isNativeVitalCenter(e.center),
                          "center=\(e.center)")
        }
    }

    func testFourHourIdleResetsBothSessionBuffers() throws {
        var carry = WatchdogCarry.empty
        let now = sleepUnix(day: 1)
        for i in 0..<12 {
            carry = tick(now: now + i * 20, hr: 58, previous: carry).carry
        }
        XCTAssertGreaterThan(carry.sessionN, 0)
        XCTAssertGreaterThan(carry.sessionNativeN, 0)
        let later = now + 5 * 3600
        carry = tick(now: later, hr: 58, previous: carry).carry
        XCTAssertLessThanOrEqual(carry.sessionN, 2)
        XCTAssertLessThan(carry.sessionAbs[0], 8)
        XCTAssertGreaterThan(carry.sessionNativeN, 0, "F21: native sidecar survives 4h idle until civil write")
    }

    // MARK: - helpers

    private func sleepUnix(day: Int) -> Int {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = day; c.hour = 1; c.minute = 0; c.second = 0
        return Int(Calendar.current.date(from: c)!.timeIntervalSince1970)
    }

    private func tick(now: Int, hr: Double, previous: WatchdogCarry) -> WatchdogResult {
        var feed = Watchdog.syntheticFeed(now: now, hr: hr, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let start = now - WatchdogConfig.contextSeconds
        feed.steps = (start..<now).map { StepSample(ts: $0, counter: 1, activityClass: 0) }
        feed.imu = (start..<now).map { WatchdogIMUSample(ts: $0, x: 1, y: 0, z: 0, dynAccel: 0.01) }
        return Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                 prompt: prompt, nowUnix: now, previous: previous)
    }

    private func window(now: Int, hr: Double) throws -> WatchdogWindow {
        let feed = Watchdog.syntheticFeed(now: now, hr: hr, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        switch WatchdogWindowBuilder.build(feed) {
        case .success(let w): return w
        case .failure(let e): throw NSError(domain: "v27", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "\(e)"])
        }
    }

    private func controlled(_ base: UniTSResidual, window: WatchdogWindow, r: [Double]) -> UniTSResidual {
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
}
