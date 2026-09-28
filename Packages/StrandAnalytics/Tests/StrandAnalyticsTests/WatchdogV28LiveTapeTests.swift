import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Feedback 2: leftover displayed BPM is not a new sample; same-bpm packets still advance the tape.
final class WatchdogV28LiveTapeTests: XCTestCase {

    func testLeftoverBpmDoesNotRestamp() {
        var ring: [HRSample] = [HRSample(ts: 1_000, bpm: 72)]
        for wall in [1_020, 1_040, 1_060, 1_180] {
            _ = wall
            if let s = WatchdogLiveTape.hrSample(lastRingTs: ring.last?.ts,
                                                 packetUnix: 1_000,
                                                 packetBpm: 72) {
                ring.append(s)
            }
        }
        XCTAssertEqual(ring.count, 1)
        XCTAssertEqual(ring.last?.ts, 1_000)
        XCTAssertFalse(WatchdogLiveTape.isFresh(packetUnix: 1_000, now: 1_180,
                                               freshnessSeconds: WatchdogConfig.whoop4FreshnessSeconds))
    }

    func testSameBpmPacketsDoNotDrag() {
        var ring: [HRSample] = []
        var lastPacket = 10_000
        for i in 0..<20 {
            lastPacket = 10_000 + i
            if let s = WatchdogLiveTape.hrSample(lastRingTs: ring.last?.ts,
                                                 packetUnix: lastPacket,
                                                 packetBpm: 72) {
                ring.append(s)
            }
        }
        XCTAssertEqual(ring.count, 20)
        XCTAssertEqual(ring.last?.ts, 10_019)
        XCTAssertEqual(Set(ring.map(\.bpm)), [72])
        let now = 10_019
        XCTAssertTrue(WatchdogLiveTape.isFresh(packetUnix: lastPacket, now: now,
                                              freshnessSeconds: WatchdogConfig.whoop4FreshnessSeconds))
        XCTAssertEqual(now - (ring.last?.ts ?? 0), 0)
    }

    func testTickCaptureOfSteadyPacketsStaysFresh() {
        var lastRingTs: Int?
        var lastPacket = 20_000
        for tick in stride(from: 20_000, through: 20_080, by: 20) {
            lastPacket = tick + 19
            if let s = WatchdogLiveTape.hrSample(lastRingTs: lastRingTs,
                                                 packetUnix: lastPacket,
                                                 packetBpm: 68) {
                lastRingTs = s.ts
            }
        }
        XCTAssertEqual(lastRingTs, 20_099)
        XCTAssertTrue(WatchdogLiveTape.isFresh(packetUnix: lastPacket, now: 20_100,
                                              freshnessSeconds: WatchdogConfig.whoop4FreshnessSeconds))
    }

    func testWristOffWinsWhenLeftoverIsStale() {
        let fresh = WatchdogLiveTape.isFresh(packetUnix: 1_000, now: 1_200,
                                            freshnessSeconds: 60)
        XCTAssertFalse(fresh)
        XCTAssertTrue(WatchdogLiveTape.wristOff(deviceOff: true, freshLiveHR: fresh))
        XCTAssertFalse(WatchdogLiveTape.wristOff(deviceOff: true, freshLiveHR: true))
        XCTAssertFalse(WatchdogLiveTape.wristOff(deviceOff: false, freshLiveHR: false))
    }

    func testRRDoesNotRestampWithoutNewSeq() {
        let first = WatchdogLiveTape.rrSample(lastSeq: -1, currentSeq: 1,
                                              lastRingTs: nil, packetUnix: 50, rrMs: 800)
        XCTAssertEqual(first?.ts, 50)
        let leftover = WatchdogLiveTape.rrSample(lastSeq: 1, currentSeq: 1,
                                                 lastRingTs: 50, packetUnix: 50, rrMs: 800)
        XCTAssertNil(leftover)
        let next = WatchdogLiveTape.rrSample(lastSeq: 1, currentSeq: 2,
                                             lastRingTs: 50, packetUnix: 51, rrMs: 790)
        XCTAssertEqual(next?.ts, 51)
    }

    func testOutOfRangePacketIsIgnored() {
        XCTAssertNil(WatchdogLiveTape.hrSample(lastRingTs: nil, packetUnix: 1, packetBpm: 12))
        XCTAssertNil(WatchdogLiveTape.hrSample(lastRingTs: nil, packetUnix: 1, packetBpm: nil))
    }
}
