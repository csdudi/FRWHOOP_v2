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
    private var lastRRSeq: Int = -1
    private var boundDeviceId: String = ""
    private var cancellables = Set<AnyCancellable>()

    func start(on model: AppModel) {
        self.model = model
        boundDeviceId = model.deviceId
        carry = loadCarry(deviceId: model.deviceId)
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

    func tick(inject: Watchdog.WatchdogInject? = nil, skipForecast: Bool = false) async {
        guard let model else { return }
        if model.deviceId != boundDeviceId {
            liveHRRing = []
            liveRRRing = []
            lastRRSeq = -1
            boundDeviceId = model.deviceId
            carry = loadCarry(deviceId: model.deviceId)
        }
        captureLive(model)
        let now = Int(Date().timeIntervalSince1970)
        let liveAlerts = !model.live.backfilling
        let days = model.repo.days
        let promptEvals = model.baseline.watchdogPromptEvaluations(days: days)
        let prompt = UniTSPrompt.from(evaluations: promptEvals)
        let window: Result<WatchdogWindow, WatchdogUnavailable>
        if inject == nil {
            window = await loadWindow(model: model, now: now)
        } else {
            window = .failure(.empty)
        }
        let sessions = await model.repo.watchdogSleepSessions(from: now - 20 * 3600, to: now + 3600, limit: 40)
        let sleepIntervals = sessions.map {
            WatchdogSleepInterval(startUnix: $0.effectiveStartTs, endUnix: $0.endTs)
        }
        let sleepOpen = sleepIntervals.contains { $0.contains(now) }
        let todayLog = model.baseline.calendarTodayLog
        let yesterdayLog = model.baseline.dayLogsByDay[BaselineStore.yesterdayKey()]
        let log = Watchdog.liveDayLog(today: todayLog, yesterday: yesterdayLog, sleepOpen: sleepOpen)
        let result = Watchdog.evaluate(window: window,
                                       prompt: prompt,
                                       evaluations: promptEvals,
                                       dayLog: log,
                                       nowUnix: now,
                                       liveIntervalMinutes: WatchdogConfig.defaultLiveIntervalMinutes,
                                       previous: carry,
                                       inject: inject,
                                       sleepSessionOpen: sleepOpen,
                                       sleepIntervals: sleepIntervals,
                                       skipForecast: skipForecast,
                                       liveAlerts: liveAlerts)
        carry = result.carry
        persistCarry(deviceId: model.deviceId)
        if case .success(let built) = window,
           Watchdog.shouldTrainUsual(result: result, dayLog: log) {
            model.baseline.ingestImu(samples: built.imu, nowUnix: now)
            model.baseline.ingestWatchdogTape(window: built, nowUnix: now,
                                              lastWorkoutEndUnix: carry.lastWorkoutEndUnix,
                                              sleepIntervals: sleepIntervals)
        }
        model.baseline.applyWatchdog(result)
        if result.shouldNotify {
            WatchdogNotifier.post(result) { [weak self] delivery in
                guard let self else { return }
                self.carry.notifyDelivery = delivery
                self.persistCarry(deviceId: model.deviceId)
            }
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
        let now = Int(Date().timeIntervalSince1970)
        let cut = now - WatchdogConfig.contextSeconds
        if let sample = WatchdogLiveTape.hrSample(
            lastRingTs: liveHRRing.last?.ts,
            packetUnix: model.live.lastHeartRatePacketUnix,
            packetBpm: model.live.lastHeartRatePacketBpm
        ) {
            liveHRRing.append(sample)
        }
        if let beat = WatchdogLiveTape.rrSample(
            lastSeq: lastRRSeq,
            currentSeq: model.live.rrSeq,
            lastRingTs: liveRRRing.last?.ts,
            packetUnix: model.live.lastHeartRatePacketUnix,
            rrMs: model.live.rr.last
        ) {
            lastRRSeq = model.live.rrSeq
            liveRRRing.append(beat)
        }
        liveHRRing.removeAll { $0.ts < cut }
        liveRRRing.removeAll { $0.ts < cut }
    }

    private func loadWindow(model: AppModel, now: Int) async -> Result<WatchdogWindow, WatchdogUnavailable> {
        guard let store = await model.repo.storeHandle() else {
            return windowFromLiveOnly(model: model, now: now)
        }
        let from = now - WatchdogConfig.contextSeconds
        let id = model.deviceId
        let family: DeviceFamily = UserDefaults.standard.string(forKey: "selectedWhoopModel") == WhoopModel.whoop5mg.rawValue
            ? .whoop5 : .whoop4
        let limit = family == .whoop5 ? 8_000 : 4_000

        let hrStored = (try? await store.hrSamples(deviceId: id, from: from, to: now, limit: limit)) ?? []
        let rrStored = (try? await store.rrIntervals(deviceId: id, from: from, to: now, limit: 8_000)) ?? []
        let tempLists = (try? await store.skinTempSamples(deviceId: id, from: from, to: now, limit: limit)) ?? []
        let spo2Lists = (try? await store.spo2Samples(deviceId: id, from: from, to: now, limit: limit)) ?? []
        let respRows = (try? await store.respSamples(deviceId: id, from: from, to: now, limit: limit)) ?? []
        let respPerMin = WatchdogWindowBuilder.respPerMin(
            rawRows: respRows.map { (ts: $0.ts, raw: $0.raw) },
            ringRate: OuraRespScale.isRingRateStream(deviceId: id),
            start: from, end: now)
        let eventLists = (try? await store.events(deviceId: id, from: from, to: now, limit: 400)) ?? []
        let stepLists = (try? await store.stepSamples(deviceId: id, from: from, to: now, limit: limit)) ?? []
        var hr = hrStored
        hr.append(contentsOf: liveHRRing.filter { sample in
            sample.ts >= from && sample.ts <= now && !hr.contains(where: { $0.ts == sample.ts })
        })
        var rr = rrStored
        rr.append(contentsOf: liveRRRing.filter { beat in
            beat.ts >= from && beat.ts <= now
        })
        let tempsRaw = tempLists.sorted { $0.ts < $1.ts }
        let temps = tempsRaw.map {
            WatchdogScalarSample(ts: $0.ts, value: skinTempCelsius(raw: $0.raw, family: family))
        }
        let gravity = (try? await store.gravitySamples(deviceId: id, from: from, to: now, limit: limit)) ?? []
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
        let events = eventLists.sorted { $0.ts < $1.ts }
        let liveBeating = WatchdogLiveTape.isFresh(
            packetUnix: model.live.lastHeartRatePacketUnix,
            now: now,
            freshnessSeconds: WatchdogQuality.freshnessLimit(family)
        )
        let wristOff = WatchdogLiveTape.wristOff(deviceOff: lastWristOff(events), freshLiveHR: liveBeating)
        let spo2Pct = spo2Lists.sorted { $0.ts < $1.ts }.compactMap { sample -> WatchdogScalarSample? in
            guard let pct = WatchdogWindowBuilder.percentFromOptical(red: sample.red, ir: sample.ir) else {
                return nil
            }
            return WatchdogScalarSample(ts: sample.ts, value: pct)
        }
        let usedLive = liveHRRing.contains { $0.ts >= from }
        let hrSource: WatchdogHRSource = usedLive ? .live2A37 : (family == .whoop5 ? .ppgHr : .v18)
        let steps = stepLists.sorted { $0.ts < $1.ts }
        let feed = WatchdogFeed(family: family, hrSource: hrSource, nowUnix: now,
                                hr: hr, rr: rr, skinTempC: temps, respPerMin: respPerMin,
                                motion: motion,
                                spo2Pct: spo2Pct, wristOff: wristOff,
                                holdSeeds: .empty,
                                imu: imu, steps: steps)
        return WatchdogWindowBuilder.build(feed)
    }

    private func windowFromLiveOnly(model: AppModel, now: Int) -> Result<WatchdogWindow, WatchdogUnavailable> {
        captureLive(model)
        let from = now - WatchdogConfig.contextSeconds
        let hr = liveHRRing.filter { $0.ts >= from }
        let liveBeating = WatchdogLiveTape.isFresh(
            packetUnix: model.live.lastHeartRatePacketUnix,
            now: now,
            freshnessSeconds: WatchdogQuality.freshnessLimit(.whoop4)
        )
        if hr.isEmpty && !liveBeating { return .failure(.empty) }
        let feed = WatchdogFeed(family: .whoop4, hrSource: .live2A37, nowUnix: now,
                                hr: hr, rr: liveRRRing.filter { $0.ts >= from },
                                wristOff: false,
                                holdSeeds: .empty)
        return WatchdogWindowBuilder.build(feed)
    }

    private func lastWristOff(_ events: [WhoopEvent]) -> Bool {
        var off = false
        for e in events.sorted(by: { $0.ts < $1.ts }) {
            if e.kind.hasPrefix("WRIST_OFF") { off = true }
            if e.kind.hasPrefix("WRIST_ON") { off = false }
        }
        return off
    }

    private static let carryKeyPrefix = "noop.watchdog.carry.v2."
    private static let legacyCarryKey = "noop.watchdog.carry.v1"
    private static let legacyMigratedKey = "noop.watchdog.carry.v1.migratedTo"

    private static func carryKey(deviceId: String) -> String {
        carryKeyPrefix + deviceId
    }

    private func loadCarry(deviceId: String) -> WatchdogCarry {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.carryKey(deviceId: deviceId)),
           let decoded = try? JSONDecoder().decode(WatchdogCarry.self, from: data) {
            return decoded
        }
        // v1 was one blob. Copy it once onto the first strap that needs a v2 key.
        // Do not stamp that episode / band onto every later deviceId.
        if defaults.string(forKey: Self.legacyMigratedKey) == nil,
           let legacy = defaults.data(forKey: Self.legacyCarryKey),
           let decoded = try? JSONDecoder().decode(WatchdogCarry.self, from: legacy) {
            defaults.set(deviceId, forKey: Self.legacyMigratedKey)
            defaults.set(legacy, forKey: Self.carryKey(deviceId: deviceId))
            return decoded
        }
        return .empty
    }

    private func persistCarry(deviceId: String) {
        if let data = try? JSONEncoder().encode(carry) {
            UserDefaults.standard.set(data, forKey: Self.carryKey(deviceId: deviceId))
        }
    }
}
