import CryptoKit
import XCTest
@testable import WhoopProtocol

final class WireEvidenceJournalTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wire-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeJournal(
        directory: URL,
        configuration: WireEvidenceJournal.Configuration = .default,
        wall: UInt64 = 1_800_000_000_000_000_000,
        segmentIDs: [UUID] = [UUID()]
    ) throws -> WireEvidenceJournal {
        var nextWall = wall
        var ids = segmentIDs
        return try WireEvidenceJournal(
            directory: directory,
            configuration: configuration,
            wallClock: {
                defer { nextWall += 1 }
                return nextWall
            },
            monotonicClock: { 999 },
            segmentIDFactory: {
                if !ids.isEmpty { return ids.removeFirst() }
                return UUID()
            }
        )
    }

    func testExactNotificationRoundTripsWithAllProvenanceAndHashes() throws {
        let directory = try temporaryDirectory()
        let segmentID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let epoch = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let journal = try makeJournal(directory: directory, segmentIDs: [segmentID])
        let connection = try journal.beginConnection(
            epoch: epoch,
            peripheralID: "11111111-aaaa-bbbb-cccc-222222222222",
            deviceID: "strap-01",
            firmware: "50.40.1.0",
            family: "whoop5"
        )
        let firstPayload = Data([0xAA, 0x10, 0x00, 0x7F, 0x80, 0xFF])
        let secondPayload = Data((0..<255).map(UInt8.init))

        let firstReceipt = try journal.appendNotification(
            payload: firstPayload,
            connection: connection,
            serviceUUID: "FD4B0001-93B1-43CD-AF6D-EC1234567890",
            characteristicUUID: "FD4B0005-93B1-43CD-AF6D-EC1234567890",
            wallTimeNanoseconds: 123_456_789,
            monotonicTimeNanoseconds: 987_654_321
        )
        let secondReceipt = try journal.appendNotification(
            payload: secondPayload,
            connection: connection,
            serviceUUID: "fd4b0001",
            characteristicUUID: "fd4b0007",
            wallTimeNanoseconds: 123_456_999,
            monotonicTimeNanoseconds: 987_654_999
        )
        XCTAssertTrue(try journal.close().isEmpty)

        let url = try XCTUnwrap(try journal.sealedSegmentURLs().first)
        let records = try WireEvidenceJournal.replay(url)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.sequence), [0, 1])

        let first = records[0]
        XCTAssertEqual(first.segmentID, segmentID)
        XCTAssertEqual(first.connectionEpoch, epoch)
        XCTAssertEqual(first.wallTimeNanoseconds, 123_456_789)
        XCTAssertEqual(first.monotonicTimeNanoseconds, 987_654_321)
        XCTAssertEqual(first.serviceUUID, "FD4B0001-93B1-43CD-AF6D-EC1234567890")
        XCTAssertEqual(first.characteristicUUID, "FD4B0005-93B1-43CD-AF6D-EC1234567890")
        XCTAssertEqual(first.peripheralID, "11111111-aaaa-bbbb-cccc-222222222222")
        XCTAssertEqual(first.deviceID, "strap-01")
        XCTAssertEqual(first.firmware, "50.40.1.0")
        XCTAssertEqual(first.family, "whoop5")
        XCTAssertEqual(first.payload, firstPayload)
        XCTAssertEqual(first.payloadLength, firstPayload.count)
        XCTAssertEqual(first.payloadSHA256, Data(SHA256.hash(data: firstPayload)))
        XCTAssertEqual(first.payloadSHA256, firstReceipt.payloadSHA256)
        XCTAssertEqual(first.recordSHA256, firstReceipt.recordSHA256)
        XCTAssertEqual(firstReceipt.segmentID, segmentID)
        XCTAssertEqual(secondReceipt.sequence, 1)
        XCTAssertEqual(records[1].payload, secondPayload)
        XCTAssertEqual(records[1].recordSHA256, secondReceipt.recordSHA256)
    }

    func testNilFirmwareRoundTripsWithoutInventingAValue() throws {
        let directory = try temporaryDirectory()
        let journal = try makeJournal(directory: directory)
        let connection = try journal.beginConnection(
            peripheralID: "test-peripheral",
            deviceID: "strap",
            firmware: nil,
            family: "whoop5"
        )
        try journal.appendNotification(
            payload: Data([1, 2, 3]),
            connection: connection,
            serviceUUID: "service",
            characteristicUUID: "characteristic"
        )
        try journal.close()

        let record = try XCTUnwrap(WireEvidenceJournal.replayDirectory(directory).first)
        XCTAssertNil(record.firmware)
        XCTAssertEqual(record.payload, Data([1, 2, 3]))
    }

    func testSealedSegmentIsNotModifiedByLaterAppends() throws {
        let directory = try temporaryDirectory()
        let journal = try makeJournal(directory: directory, segmentIDs: [UUID(), UUID()])
        let connection = try journal.beginConnection(
            peripheralID: "test-peripheral",
            deviceID: "strap", firmware: "fw", family: "whoop5"
        )
        try journal.appendNotification(
            payload: Data(repeating: 0x11, count: 64),
            connection: connection,
            serviceUUID: "service",
            characteristicUUID: "char-a"
        )
        try journal.rotate()
        let sealed = try XCTUnwrap(try journal.sealedSegmentURLs().first)
        let bytesBefore = try Data(contentsOf: sealed)

        try journal.appendNotification(
            payload: Data(repeating: 0x22, count: 64),
            connection: connection,
            serviceUUID: "service",
            characteristicUUID: "char-b"
        )
        XCTAssertEqual(try Data(contentsOf: sealed), bytesBefore,
                       "a sealed segment must never be reopened or appended")
        try journal.close()
    }

    func testRotationBoundsEveryFileAndRefusesCapacityWithoutDeletingEvidence() throws {
        let directory = try temporaryDirectory()
        let configuration = WireEvidenceJournal.Configuration(
            maxSegmentBytes: 430,
            maxRetainedSegments: 2,
            maxPayloadBytes: 128
        )
        let ids = (0..<3).map { _ in UUID() }
        let journal = try makeJournal(
            directory: directory,
            configuration: configuration,
            segmentIDs: ids
        )
        let connection = try journal.beginConnection(
            peripheralID: "test-peripheral",
            deviceID: "d", firmware: "f", family: "w5"
        )

        for marker in UInt8(0)..<2 {
            _ = try journal.appendNotification(
                payload: Data(repeating: marker, count: 100),
                connection: connection,
                serviceUUID: "svc",
                characteristicUUID: "chr"
            )
        }
        let oldest = try XCTUnwrap(try journal.sealedSegmentURLs().first)
        let oldestBytes = try Data(contentsOf: oldest)

        XCTAssertThrowsError(try journal.appendNotification(
            payload: Data(repeating: 2, count: 100),
            connection: connection,
            serviceUUID: "svc",
            characteristicUUID: "chr"
        )) { error in
            XCTAssertEqual(error as? WireEvidenceJournal.JournalError,
                           .retentionCapacityReached(maximumSegments: 2))
        }

        let sealed = try journal.sealedSegmentURLs()
        XCTAssertEqual(sealed.count, 2)
        for url in sealed {
            let size = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            ).intValue
            XCTAssertLessThanOrEqual(size, configuration.maxSegmentBytes)
            XCTAssertEqual(try WireEvidenceJournal.replay(url).count, 1)
        }
        let retained = try WireEvidenceJournal.replayDirectory(directory)
        XCTAssertEqual(retained.map(\.sequence), [0, 1])
        XCTAssertEqual(retained.map { $0.payload.first! }, [0, 1])
        XCTAssertEqual(try Data(contentsOf: oldest), oldestBytes)
        XCTAssertTrue(try journal.close().isEmpty)
    }

    func testCapacityReservationCreatesDurableSegmentWithoutConsumingSequence() throws {
        let directory = try temporaryDirectory()
        let journal = try makeJournal(
            directory: directory,
            configuration: .init(maxSegmentBytes: 430, maxRetainedSegments: 2,
                                 maxPayloadBytes: 128)
        )
        let connection = try journal.beginConnection(
            peripheralID: "test-peripheral", deviceID: "strap",
            firmware: "fw", family: "whoop5"
        )

        try journal.reserveCapacityForNotification(
            payloadByteCount: 100,
            connection: connection,
            serviceUUID: "svc",
            characteristicUUID: "chr"
        )

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".open") }.count, 1)
        let receipt = try journal.appendNotification(
            payload: Data(repeating: 0xA5, count: 100),
            connection: connection,
            serviceUUID: "svc",
            characteristicUUID: "chr"
        )
        XCTAssertEqual(receipt.sequence, 0,
                       "capacity preflight must not invent evidence or consume a capture sequence")
        try journal.close()
    }

    func testCapacityReservationAtHardCapFailsBeforeAppendAndPreservesEvidence() throws {
        let directory = try temporaryDirectory()
        let configuration = WireEvidenceJournal.Configuration(
            maxSegmentBytes: 430,
            maxRetainedSegments: 1,
            maxPayloadBytes: 128
        )
        do {
            let source = try makeJournal(directory: directory, configuration: configuration)
            let sourceConnection = try source.beginConnection(
                peripheralID: "test-peripheral", deviceID: "strap",
                firmware: "fw", family: "whoop5"
            )
            try source.appendNotification(
                payload: Data(repeating: 0x5A, count: 100),
                connection: sourceConnection,
                serviceUUID: "svc",
                characteristicUUID: "chr"
            )
            try source.close()
        }
        let sealed = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "whoopwire" }
        )
        let sealedBytes = try Data(contentsOf: sealed)

        let journal = try makeJournal(directory: directory, configuration: configuration)
        let connection = try journal.beginConnection(
            peripheralID: "test-peripheral", deviceID: "strap",
            firmware: "fw", family: "whoop5"
        )
        XCTAssertThrowsError(try journal.reserveCapacityForNotification(
            payloadByteCount: 100,
            connection: connection,
            serviceUUID: "svc",
            characteristicUUID: "chr"
        )) { error in
            XCTAssertEqual(error as? WireEvidenceJournal.JournalError,
                           .retentionCapacityReached(maximumSegments: 1))
        }
        XCTAssertEqual(try Data(contentsOf: sealed), sealedBytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains { $0.hasSuffix(".open") })
    }

    func testOversizedRecordIsRejectedWithoutConsumingSequenceOrCreatingAFile() throws {
        let directory = try temporaryDirectory()
        let configuration = WireEvidenceJournal.Configuration(
            maxSegmentBytes: 330,
            maxRetainedSegments: 2,
            maxPayloadBytes: 1_024
        )
        let journal = try makeJournal(directory: directory, configuration: configuration)
        let connection = try journal.beginConnection(
            peripheralID: "test-peripheral",
            deviceID: "d", firmware: nil, family: "w5"
        )

        XCTAssertThrowsError(try journal.appendNotification(
            payload: Data(repeating: 0xAA, count: 100),
            connection: connection,
            serviceUUID: "service",
            characteristicUUID: "characteristic"
        )) { error in
            guard case WireEvidenceJournal.JournalError.recordExceedsSegmentLimit = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)

        let receipt = try journal.appendNotification(
            payload: Data(),
            connection: connection,
            serviceUUID: "s",
            characteristicUUID: "c"
        )
        XCTAssertEqual(receipt.sequence, 0)
        try journal.close()
    }

    func testCrashLeftOpenFilesCountAgainstHardRetentionCapacity() throws {
        let directory = try temporaryDirectory()
        let first = directory.appendingPathComponent("crash-a.open")
        let second = directory.appendingPathComponent("crash-b.open")
        try Data([0xAA]).write(to: first)
        try Data([0xBB]).write(to: second)
        let journal = try makeJournal(
            directory: directory,
            configuration: .init(maxSegmentBytes: 430, maxRetainedSegments: 2,
                                 maxPayloadBytes: 128)
        )
        let connection = try journal.beginConnection(
            peripheralID: "test-peripheral", deviceID: "strap",
            firmware: nil, family: "whoop5"
        )

        XCTAssertThrowsError(try journal.appendNotification(
            payload: Data([1]), connection: connection,
            serviceUUID: "service", characteristicUUID: "characteristic"
        )) { error in
            XCTAssertEqual(error as? WireEvidenceJournal.JournalError,
                           .retentionCapacityReached(maximumSegments: 2))
        }
        XCTAssertEqual(try Data(contentsOf: first), Data([0xAA]))
        XCTAssertEqual(try Data(contentsOf: second), Data([0xBB]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testUnknownOrEndedConnectionCannotAppend() throws {
        let directory = try temporaryDirectory()
        let journal = try makeJournal(directory: directory)
        let connection = try journal.beginConnection(
            peripheralID: "test-peripheral",
            deviceID: "strap", firmware: nil, family: "whoop5"
        )
        journal.endConnection(connection)

        XCTAssertThrowsError(try journal.appendNotification(
            payload: Data([1]),
            connection: connection,
            serviceUUID: "service",
            characteristicUUID: "characteristic"
        )) { error in
            XCTAssertEqual(error as? WireEvidenceJournal.JournalError,
                           .unknownConnectionEpoch(connection.epoch))
        }
    }

    func testUnsealedSegmentIsRejectedEvenWhenAllRecordsAreComplete() throws {
        let directory = try temporaryDirectory()
        let journal = try makeJournal(directory: directory)
        let connection = try journal.beginConnection(
            peripheralID: "test-peripheral",
            deviceID: "strap", firmware: "fw", family: "whoop5"
        )
        try journal.appendNotification(
            payload: Data([0xAA, 0xBB]),
            connection: connection,
            serviceUUID: "service",
            characteristicUUID: "characteristic"
        )
        let open = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "open" }
        )

        XCTAssertThrowsError(try WireEvidenceJournal.replay(open)) { error in
            XCTAssertEqual(error as? WireEvidenceJournal.JournalError, .missingFooter)
        }

        let truncatedRecordURL = directory.appendingPathComponent("mid-record.whoopwire")
        try Data(try Data(contentsOf: open).dropLast()).write(to: truncatedRecordURL)
        XCTAssertThrowsError(try WireEvidenceJournal.replay(truncatedRecordURL)) { error in
            guard case WireEvidenceJournal.JournalError.truncatedRecord = error else {
                return XCTFail("mid-record truncation was not rejected: \(error)")
            }
        }
        try journal.close()
    }

    func testInitializerRecoversCompleteCrashLeftOpenSegmentWithoutChangingRecords() throws {
        let sourceDirectory = try temporaryDirectory()
        let recoveryDirectory = try temporaryDirectory()
        let source = try makeJournal(directory: sourceDirectory)
        let connection = try source.beginConnection(
            peripheralID: "test-peripheral",
            deviceID: "strap", firmware: "fw", family: "whoop5"
        )
        let payload = Data([0xAA, 0x01, 0x02, 0x03, 0xFF])
        try source.appendNotification(
            payload: payload,
            connection: connection,
            serviceUUID: "service",
            characteristicUUID: "characteristic"
        )
        let sourceOpen = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: sourceDirectory, includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "open" }
        )
        let crashBytes = try Data(contentsOf: sourceOpen)
        let crashURL = recoveryDirectory.appendingPathComponent(sourceOpen.lastPathComponent)
        try crashBytes.write(to: crashURL)

        let recoveredJournal = try makeJournal(directory: recoveryDirectory)
        let sealed = try XCTUnwrap(try recoveredJournal.sealedSegmentURLs().first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashURL.path))
        XCTAssertEqual(try WireEvidenceJournal.replay(sealed).map(\.payload), [payload])
        XCTAssertEqual(Data(try Data(contentsOf: sealed).prefix(crashBytes.count)), crashBytes)
    }

    func testCrashRecoveryRetainsPartialOpenSegmentByteForByte() throws {
        let sourceDirectory = try temporaryDirectory()
        let recoveryDirectory = try temporaryDirectory()
        let source = try makeJournal(directory: sourceDirectory)
        let connection = try source.beginConnection(
            peripheralID: "test-peripheral",
            deviceID: "strap", firmware: nil, family: "whoop5"
        )
        try source.appendNotification(
            payload: Data([1, 2, 3, 4]), connection: connection,
            serviceUUID: "service", characteristicUUID: "characteristic"
        )
        let sourceOpen = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: sourceDirectory, includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "open" }
        )
        let partial = Data(try Data(contentsOf: sourceOpen).dropLast())
        let partialURL = recoveryDirectory.appendingPathComponent("partial.open")
        try partial.write(to: partialURL)

        let report = try WireEvidenceJournal.recoverOpenSegments(in: recoveryDirectory)
        XCTAssertTrue(report.recovered.isEmpty)
        XCTAssertEqual(report.unrecoverable.map { $0.resolvingSymlinksInPath().path },
                       [partialURL.resolvingSymlinksInPath().path])
        XCTAssertEqual(try Data(contentsOf: partialURL), partial)
    }

    func testSegmentIdentityCollisionFailsWithoutReplacingSealedEvidence() throws {
        let directory = try temporaryDirectory()
        let segmentID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let journal = try WireEvidenceJournal(
            directory: directory,
            configuration: .default,
            wallClock: { 42 },
            monotonicClock: { 43 },
            segmentIDFactory: { segmentID }
        )
        let connection = try journal.beginConnection(
            peripheralID: "test-peripheral",
            deviceID: "strap", firmware: nil, family: "whoop5"
        )
        try journal.appendNotification(
            payload: Data([0xAA]), connection: connection,
            serviceUUID: "service", characteristicUUID: "characteristic"
        )
        try journal.rotate()
        let originalURL = try XCTUnwrap(try journal.sealedSegmentURLs().first)
        let originalBytes = try Data(contentsOf: originalURL)

        XCTAssertThrowsError(try journal.appendNotification(
            payload: Data([0xBB]), connection: connection,
            serviceUUID: "service", characteristicUUID: "characteristic"
        )) { error in
            guard case WireEvidenceJournal.JournalError.cannotCreateFile = error else {
                return XCTFail("identity collision did not fail closed: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        XCTAssertEqual(try WireEvidenceJournal.replay(originalURL).map(\.payload), [Data([0xAA])])
    }

    func testReplayRejectsPayloadCorruptionTruncationAndTrailingBytes() throws {
        let directory = try temporaryDirectory()
        let journal = try makeJournal(directory: directory)
        let connection = try journal.beginConnection(
            peripheralID: "test-peripheral",
            deviceID: "strap", firmware: "fw", family: "whoop5"
        )
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x13, 0x37, 0xC0, 0xDE])
        try journal.appendNotification(
            payload: payload,
            connection: connection,
            serviceUUID: "service",
            characteristicUUID: "characteristic"
        )
        try journal.close()
        let source = try XCTUnwrap(try journal.sealedSegmentURLs().first)
        let original = try Data(contentsOf: source)

        let corruptURL = directory.appendingPathComponent("corrupt.whoopwire")
        var corrupt = original
        let payloadRange = try XCTUnwrap(corrupt.range(of: payload))
        corrupt[payloadRange.lowerBound] ^= 0x01
        try corrupt.write(to: corruptURL)
        XCTAssertThrowsError(try WireEvidenceJournal.replay(corruptURL)) { error in
            guard case WireEvidenceJournal.JournalError.recordDigestMismatch = error else {
                return XCTFail("corruption was not rejected by the record digest: \(error)")
            }
        }

        let truncatedURL = directory.appendingPathComponent("truncated.whoopwire")
        try original.dropLast().write(to: truncatedURL)
        XCTAssertThrowsError(try WireEvidenceJournal.replay(truncatedURL)) { error in
            guard case WireEvidenceJournal.JournalError.truncatedFooter = error else {
                return XCTFail("truncation was not rejected: \(error)")
            }
        }

        let trailingURL = directory.appendingPathComponent("trailing.whoopwire")
        var trailing = original
        trailing.append(0x00)
        try trailing.write(to: trailingURL)
        XCTAssertThrowsError(try WireEvidenceJournal.replay(trailingURL)) { error in
            guard case WireEvidenceJournal.JournalError.trailingBytes = error else {
                return XCTFail("trailing bytes were not rejected: \(error)")
            }
        }
    }

    func testCloseIsIdempotentAndLeavesNoOpenFiles() throws {
        let directory = try temporaryDirectory()
        let journal = try makeJournal(directory: directory)
        let connection = try journal.beginConnection(
            peripheralID: "test-peripheral",
            deviceID: "strap", firmware: "fw", family: "whoop5"
        )
        try journal.appendNotification(
            payload: Data([1]),
            connection: connection,
            serviceUUID: "service",
            characteristicUUID: "characteristic"
        )
        XCTAssertTrue(try journal.close().isEmpty)
        XCTAssertTrue(try journal.close().isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".whoopwire") }.count, 1)
        XCTAssertFalse(names.contains { $0.hasSuffix(".open") })
    }

    #if os(iOS)
    func testJournalFilesRemainAvailableAfterFirstUnlockForBackgroundBLE() throws {
        let directory = try temporaryDirectory()
        let journal = try makeJournal(directory: directory)
        let connection = try journal.beginConnection(
            peripheralID: "test-peripheral",
            deviceID: "strap", firmware: nil, family: "whoop5"
        )
        try journal.appendNotification(
            payload: Data([1]), connection: connection,
            serviceUUID: "service", characteristicUUID: "characteristic"
        )
        try journal.close()
        let file = try XCTUnwrap(try journal.sealedSegmentURLs().first)
        let expected = FileProtectionType.completeUntilFirstUserAuthentication
        let directoryProtection = try FileManager.default.attributesOfItem(atPath: directory.path)[.protectionKey]
            as? FileProtectionType
        let fileProtection = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey]
            as? FileProtectionType
        try XCTSkipIf(directoryProtection == nil && fileProtection == nil,
                      "Data-protection attributes are not reported by this simulator.")
        XCTAssertEqual(directoryProtection, expected)
        XCTAssertEqual(fileProtection, expected)
    }
    #endif
}
