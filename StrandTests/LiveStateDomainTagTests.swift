import XCTest
import Combine
import StrandAnalytics
@testable import Strand

@MainActor
final class LiveStateDomainTagTests: XCTestCase {

    func testLogBurstKeepsEveryLineButCoalescesViewInvalidations() async {
        let live = LiveState()
        var invalidations = 0
        let subscription = live.objectWillChange.sink { invalidations += 1 }
        for i in 0..<64 { live.append(log: "chunk diagnostic \(i)") }
        XCTAssertEqual(live.log, (0..<64).map { "chunk diagnostic \($0)" })
        XCTAssertEqual(invalidations, 0, "Log-only changes should not rebuild the whole UI per line")
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(invalidations, 1)
        live.append(log: "next burst")
        live.connected = true
        XCTAssertEqual(invalidations, 2, "Connection state must still publish immediately")
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(invalidations, 3)
        XCTAssertEqual(live.log.last, "next burst")
        withExtendedLifetime(subscription) {}
    }

    // No domain => byte-identical to today's behaviour (no tag prefix).
    func testNilDomainLeavesLineUntagged() {
        let live = LiveState()
        live.append(log: "connected ok")
        XCTAssertEqual(live.log.last, "connected ok")
    }

    // A domain => a compact, parseable "[<id>] " marker is prefixed.
    func testDomainPrefixesCompactMarker() {
        let live = LiveState()
        live.append(log: "gate run kept", domain: .sleep)
        XCTAssertEqual(live.log.last, "[sleep] gate run kept")
    }

    // dataImport uses the wire id, not the rawValue.
    func testDataImportUsesWireId() {
        let live = LiveState()
        live.append(log: "parsed 10 rows", domain: .dataImport)
        XCTAssertEqual(live.log.last, "[import] parsed 10 rows")
    }

    // Redaction STILL runs, and it runs over the already-tagged text (the serial in the body is masked,
    // the tag is untouched).
    func testRedactionRunsAfterTagging() {
        let live = LiveState()
        live.append(log: "saw WHOOP 4C1594026 advertise", domain: .connection)
        XCTAssertEqual(live.log.last, "[connection] saw WHOOP <serial> advertise")
    }
}
