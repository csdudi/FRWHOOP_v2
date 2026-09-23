import Foundation
import Combine
import WhoopProtocol
import WhoopStore
import StrandAnalytics

@MainActor
final class WatchdogService {
    weak var model: AppModel?
    private var loop: Task<Void, Never>?
    private var carry = WatchdogCarry.empty
    private var liveHRRing: [HRSample] = []
    private var liveRRRing: [RRInterval] = []
    private var cancellables = Set<AnyCancellable>()

    func start(on model: AppModel) {
        self.model = model
        carry = loadCarry()
        WatchdogNotifier.requestAuthorization()
        bindLive(model)
        loop?.cancel()
        loop = Task { [weak self] in
            await self?.tick()
            while !Task.isCancelled {
                let ns = UInt64(WatchdogConfig.tickSeconds) * 1_000_000_000
                try? await Task.sleep(nanoseconds: ns)
                await self?.tick()
            }
        }
    }

    func tick(inject: Watchdog.WatchdogInject? = nil) async {
        guard let model else { return }
        captureLive(model)
        let now = Int(Date().timeIntervalSince1970)
        let days = model.repo.days
        let promptEvals = model.baseline.watchdogPromptEvaluations(days: days)
        let prompt = UniTSPrompt.from(evaluations: promptEvals)
        let log = model.baseline.dayLogsByDay[model.baseline.asOf]
        let window: Result<WatchdogWindow, WatchdogUnavailable>
        if inject == nil {
            window = await loadWindow(model: model, now: now)
        } else {
            window = .failure(.empty)
        }
        let result = Watchdog.evaluate(window: window,
                                       prompt: prompt,
                                       evaluations: promptEvals,
                                       dayLog: log,
                                       nowUnix: now,
                                       liveIntervalMinutes: WatchdogConfig.defaultLiveIntervalMinutes,
                                       previous: carry,
                                       inject: inject)
        carry = result.carry
        persistCarry()
        model.baseline.applyWatchdog(result)
        if result.shouldNotify {
            WatchdogNotifier.post(result)
        }
    }

    private func bindLive(_ model: AppModel) {
        cancellables.removeAll()
        model.live.$heartRate
            .sink { [weak self] _ in self?.captureLive(model) }
            .store(in: &cancellables)
        model.live.$rr
            .sink { [weak self] _ in self?.captureLive(model) }
            .store(in: &cancellables)
    }

    private func captureLive(_ model: AppModel) {
        let ts = Int(Date().timeIntervalSince1970)
        let cut = ts - WatchdogConfig.contextSeconds
        if let bpm = model.bpm ?? model.live.heartRate, (30...220).contains(bpm) {
            if liveHRRing.last?.ts != ts {
                liveHRRing.append(HRSample(ts: ts, bpm: bpm))
            }
        }
        if let rrMs = model.live.rr.last, rrMs > 250, rrMs < 3000 {
            liveRRRing.append(RRInterval(ts: ts, rrMs: rrMs))
        }
        liveHRRing.removeAll { $0.ts < cut }
        liveRRRing.removeAll { $0.ts < cut }
    }

    private func loadWindow(model: AppModel, now: Int) async -> Result<WatchdogWindow, WatchdogUnavailable> {
        guard let store = await model.repo.storeHandle() else {
            return windowFromLiveOnly(model: model, now: now)
        }
        let from = now - WatchdogConfig.contextSeconds
        let ids = await model.repo.watchdogSourceIds()
        let family: DeviceFamily = UserDefaults.standard.string(forKey: "selectedWhoopModel") == WhoopModel.whoop5mg.rawValue
            ? .whoop5 : .whoop4
        let limit = family == .whoop5 ? 8_000 : 4_000

        var hrLists: [[HRSample]] = []
        var rrLists: [[RRInterval]] = []
        var tempLists: [[SkinTempSample]] = []
        var spo2Lists: [[SpO2Sample]] = []
        var eventLists: [[WhoopEvent]] = []
        var stepLists: [[StepSample]] = []
        for id in ids {
            hrLists.append((try? await store.hrSamples(deviceId: id, from: from, to: now, limit: limit)) ?? [])
            rrLists.append((try? await store.rrIntervals(deviceId: id, from: from, to: now, limit: 8_000)) ?? [])
            tempLists.append((try? await store.skinTempSamples(deviceId: id, from: from, to: now, limit: limit)) ?? [])
            spo2Lists.append((try? await store.spo2Samples(deviceId: id, from: from, to: now, limit: limit)) ?? [])
            eventLists.append((try? await store.events(deviceId: id, from: from, to: now, limit: 400)) ?? [])
            stepLists.append((try? await store.stepSamples(deviceId: id, from: from, to: now, limit: limit)) ?? [])
        }
        var hr = mergeByTs(hrLists, ts: \.ts)
        hr.append(contentsOf: liveHRRing.filter { sample in
            sample.ts >= from && sample.ts <= now && !hr.contains(where: { $0.ts == sample.ts })
        })
        var rr = Repository.mergeRRByIdentity(rrLists)
        rr.append(contentsOf: liveRRRing.filter { beat in
            beat.ts >= from && beat.ts <= now
        })
        let tempsRaw = mergeByTs(tempLists, ts: \.ts)
        let temps = tempsRaw.map {
            WatchdogScalarSample(ts: $0.ts, value: skinTempCelsius(raw: $0.raw, family: family))
        }
        let gravity = await model.repo.gravitySamplesUnion(from: from, to: now, limit: limit)
        let imu = gravity.map {
            WatchdogIMUSample(ts: $0.ts, x: $0.x, y: $0.y, z: $0.z, dynAccel: $0.dynAccel)
        }
        let motion = gravity.map { g -> WatchdogScalarSample in
            let mag = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            let fromVector = min(1, max(0, abs(mag - 1.0) / 0.4))
            let occ: Double
            if let dyn = g.dynAccel { occ = min(1, max(0, dyn / 0.4)) }
            else { occ = fromVector }
            return WatchdogScalarSample(ts: g.ts, value: occ)
        }
        let events = mergeByTs(eventLists, ts: \.ts)
        let liveBeating = (model.bpm ?? model.live.heartRate).map { (30...220).contains($0) } ?? false
        let wristOff = lastWristOff(events) && !liveBeating
        let spo2Pct = mergeByTs(spo2Lists, ts: \.ts).compactMap { sample -> WatchdogScalarSample? in
            guard sample.ir <= 0,
                  AnalyticsEngine.spo2SingleChannelPlausible.contains(sample.red) else { return nil }
            return WatchdogScalarSample(ts: sample.ts, value: min(Double(sample.red), 100))
        }
        let usedLive = liveHRRing.contains { $0.ts >= from }
        let hrSource: WatchdogHRSource = usedLive ? .live2A37 : (family == .whoop5 ? .ppgHr : .v18)
        let steps = mergeByTs(stepLists, ts: \.ts)
        let feed = WatchdogFeed(family: family, hrSource: hrSource, nowUnix: now,
                                hr: hr, rr: rr, skinTempC: temps, motion: motion,
                                spo2Pct: spo2Pct, wristOff: wristOff,
                                holdSeeds: WatchdogHoldSeeds(resp: carry.lastHeldResp,
                                                             hrv: carry.lastHeldHRV,
                                                             temp: carry.lastHeldTemp,
                                                             spo2: carry.lastHeldSpO2),
                                imu: imu, steps: steps)
        return WatchdogWindowBuilder.build(feed)
    }

    private func windowFromLiveOnly(model: AppModel, now: Int) -> Result<WatchdogWindow, WatchdogUnavailable> {
        captureLive(model)
        let from = now - WatchdogConfig.contextSeconds
        let hr = liveHRRing.filter { $0.ts >= from }
        let liveBeating = (model.bpm ?? model.live.heartRate).map { (30...220).contains($0) } ?? false
        if hr.isEmpty && !liveBeating { return .failure(.empty) }
        var samples = hr
        if let bpm = model.bpm ?? model.live.heartRate, (30...220).contains(bpm) {
            samples.append(HRSample(ts: now, bpm: bpm))
        }
        let feed = WatchdogFeed(family: .whoop4, hrSource: .live2A37, nowUnix: now,
                                hr: samples, rr: liveRRRing.filter { $0.ts >= from },
                                wristOff: false,
                                holdSeeds: WatchdogHoldSeeds(resp: carry.lastHeldResp,
                                                             hrv: carry.lastHeldHRV,
                                                             temp: carry.lastHeldTemp,
                                                             spo2: carry.lastHeldSpO2))
        return WatchdogWindowBuilder.build(feed)
    }

    private func mergeByTs<T>(_ lists: [[T]], ts: (T) -> Int) -> [T] {
        var byTs: [Int: T] = [:]
        for list in lists {
            for row in list where byTs[ts(row)] == nil { byTs[ts(row)] = row }
        }
        return byTs.values.sorted { ts($0) < ts($1) }
    }

    private func lastWristOff(_ events: [WhoopEvent]) -> Bool {
        var off = false
        for e in events.sorted(by: { $0.ts < $1.ts }) {
            if e.kind.hasPrefix("WRIST_OFF") { off = true }
            if e.kind.hasPrefix("WRIST_ON") { off = false }
        }
        return off
    }

    private static let carryKey = "noop.watchdog.carry.v1"

    private func loadCarry() -> WatchdogCarry {
        guard let data = UserDefaults.standard.data(forKey: Self.carryKey),
              let decoded = try? JSONDecoder().decode(WatchdogCarry.self, from: data) else {
            return .empty
        }
        return decoded
    }

    private func persistCarry() {
        if let data = try? JSONEncoder().encode(carry) {
            UserDefaults.standard.set(data, forKey: Self.carryKey)
        }
    }
}
