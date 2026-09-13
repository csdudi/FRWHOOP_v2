import XCTest
@testable import WhoopProtocol

final class CharacteristicReassemblerTests: XCTestCase {
    func testInterleavedCharacteristicFragmentsCannotSpliceFrames() {
        let first = puffinCommandFrame(cmd: 81, seq: 1, payload: [0x01])
        let second = puffinCommandFrame(cmd: 106, seq: 2, payload: [0x01, 0x01])
        let sut = CharacteristicReassembler(family: .whoop5)

        XCTAssertTrue(sut.feed(Array(first.prefix(7)), characteristicID: "fd4b0003").isEmpty)
        XCTAssertTrue(sut.feed(Array(second.prefix(9)), characteristicID: "fd4b0005").isEmpty)
        XCTAssertEqual(sut.feed(Array(first.dropFirst(7)), characteristicID: "fd4b0003"), [first])
        XCTAssertEqual(sut.feed(Array(second.dropFirst(9)), characteristicID: "fd4b0005"), [second])
    }

    func testResetDropsEveryPartialLane() {
        let frame = puffinCommandFrame(cmd: 81, seq: 1, payload: [0x01])
        let sut = CharacteristicReassembler(family: .whoop5)
        _ = sut.feed(Array(frame.prefix(8)), characteristicID: "fd4b0003")
        sut.reset()
        XCTAssertTrue(sut.feed(Array(frame.dropFirst(8)), characteristicID: "fd4b0003").isEmpty)
        XCTAssertEqual(sut.feed(frame, characteristicID: "fd4b0003"), [frame])
    }

    func testFreshPuffinHeaderReplacesTruncatedV21PrefixOnSameCharacteristic() {
        let full = Whoop5RawImuTests.realFrameBytes
        let firstPrefix = Array(full.prefix(244))
        var secondPrefix = firstPrefix
        secondPrefix[11] &+= 1
        let sut = CharacteristicReassembler(family: .whoop5)

        XCTAssertTrue(sut.feed(firstPrefix, characteristicID: "fd4b0005").isEmpty)
        XCTAssertTrue(sut.feed(secondPrefix, characteristicID: "fd4b0005").isEmpty,
                      "two valid headers must not be concatenated into a fake 1244-byte frame")
        var expected = secondPrefix
        expected.append(contentsOf: full.dropFirst(244))
        XCTAssertEqual(sut.feed(Array(full.dropFirst(244)), characteristicID: "fd4b0005"), [expected])
    }

    func testCompletePuffinNotificationIsNotSplicedIntoOlderPartialFrame() {
        let large = Whoop5RawImuTests.realFrameBytes
        let short = puffinCommandFrame(cmd: 81, seq: 9, payload: [1])
        let sut = CharacteristicReassembler(family: .whoop5)

        XCTAssertTrue(sut.feed(Array(large.prefix(244)), characteristicID: "fd4b0005").isEmpty)
        XCTAssertEqual(sut.feed(short, characteristicID: "fd4b0005"), [short])
        XCTAssertEqual(sut.feed(Array(large.dropFirst(244)), characteristicID: "fd4b0005"), [large])
    }
}
