import XCTest
import WhoopProtocol
@testable import WhoopStore

/// T2-3: batched multi-row inserts land identical rows and insert counts vs the per-row path.
final class StreamBatchInsertTests: XCTestCase {

    func testMixedDuplicateAndNewBatchMatchesCounts() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        let kinds = [SyncJobKind.rescore.rawValue]
        let seed = Streams(
            hr: [HRSample(ts: 1_700_000_100, bpm: 61), HRSample(ts: 1_700_000_101, bpm: 62)],
            spo2: [SpO2Sample(ts: 1_700_000_100, red: 1, ir: 2)],
            skinTemp: [SkinTempSample(ts: 1_700_000_100, raw: 10, aux1Raw: nil, aux2Raw: nil)],
            resp: [RespSample(ts: 1_700_000_100, raw: 5)],
            gravity: [GravitySample(ts: 1_700_000_100, x: 1, y: 2, z: 3, dynAccel: 0.1)])
        _ = try await store.insertAndMarkJobsOwed(seed, deviceId: "dev", postOffloadJobKinds: kinds, note: nil)

        let replay = Streams(
            hr: [HRSample(ts: 1_700_000_100, bpm: 61), HRSample(ts: 1_700_000_102, bpm: 63)],
            spo2: [SpO2Sample(ts: 1_700_000_100, red: 1, ir: 2), SpO2Sample(ts: 1_700_000_102, red: 3, ir: 4)],
            skinTemp: [SkinTempSample(ts: 1_700_000_100, raw: 10, aux1Raw: nil, aux2Raw: nil),
                       SkinTempSample(ts: 1_700_000_102, raw: 11, aux1Raw: nil, aux2Raw: nil)],
            resp: [RespSample(ts: 1_700_000_100, raw: 5), RespSample(ts: 1_700_000_102, raw: 6)],
            gravity: [GravitySample(ts: 1_700_000_100, x: 1, y: 2, z: 3, dynAccel: 0.1),
                      GravitySample(ts: 1_700_000_102, x: 4, y: 5, z: 6, dynAccel: 0.2)])
        let outcome = try await store.insertAndMarkJobsOwed(replay, deviceId: "dev", postOffloadJobKinds: kinds, note: nil)
        XCTAssertEqual(outcome.counts.hr, 1)
        XCTAssertEqual(outcome.counts.gravity, 1)
        XCTAssertEqual(outcome.counts.spo2, 1)
        XCTAssertEqual(outcome.counts.skinTemp, 1)
        XCTAssertEqual(outcome.counts.resp, 1)
        let stats = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(stats.hr, 3)
        XCTAssertEqual(stats.gravity, 2)
        XCTAssertEqual(stats.spo2, 2)
        XCTAssertEqual(stats.skinTemp, 2)
        XCTAssertEqual(stats.resp, 2)
    }
}
