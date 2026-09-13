import CryptoKit
import Foundation

/// Durable Level-A evidence for bytes delivered by CoreBluetooth.
///
/// This type intentionally knows nothing about WHOOP packet framing or sensor semantics. The caller
/// hands it the exact notification payload before reassembly/decoding, and it appends that payload to
/// a bounded binary segment. Each record is self-describing and independently hashed; each cleanly
/// closed segment is also hashed and then renamed in place from `.open` to `.whoopwire`. File contents
/// are synchronized before the rename; the parent directory is not fsynced, so this is not presented as
/// a proven power-loss publication guarantee.
///
/// Storage is bounded in two dimensions:
/// - `maxSegmentBytes` reserves room for the clean-close footer before accepting a record.
/// - `maxRetainedSegments` counts both sealed files and crash-left `.open` files. The journal refuses
///   a new segment instead of deleting unuploaded evidence.
///
/// The journal does not upload, decode, or send BLE commands. A caller that needs cloud archival must
/// build that separately and must not treat this bounded local retention window as a B2 guarantee.
public final class WireEvidenceJournal {
    public struct Configuration: Equatable, Sendable {
        public var maxSegmentBytes: Int
        public var maxRetainedSegments: Int
        public var maxPayloadBytes: Int

        public static let `default` = Configuration()

        public init(
            maxSegmentBytes: Int = 4 * 1024 * 1024,
            maxRetainedSegments: Int = 64,
            maxPayloadBytes: Int = 1024 * 1024
        ) {
            self.maxSegmentBytes = maxSegmentBytes
            self.maxRetainedSegments = maxRetainedSegments
            self.maxPayloadBytes = maxPayloadBytes
        }
    }

    public struct Connection: Hashable, Sendable {
        public let epoch: UUID
        public let peripheralID: String
        public let deviceID: String
        public let firmware: String?
        public let family: String

        fileprivate init(epoch: UUID, peripheralID: String, deviceID: String,
                         firmware: String?, family: String) {
            self.epoch = epoch
            self.peripheralID = peripheralID
            self.deviceID = deviceID
            self.firmware = firmware
            self.family = family
        }
    }

    public struct Receipt: Equatable, Sendable {
        public let segmentID: UUID
        public let connectionEpoch: UUID
        public let sequence: UInt64
        public let payloadSHA256: Data
        /// Stable identity for linking later interpretations back to this exact Level-A record.
        public let recordSHA256: Data
    }

    public struct Record: Equatable, Sendable {
        public let segmentID: UUID
        public let connectionEpoch: UUID
        public let sequence: UInt64
        public let wallTimeNanoseconds: UInt64
        public let monotonicTimeNanoseconds: UInt64
        public let serviceUUID: String
        public let characteristicUUID: String
        /// CoreBluetooth's stable peripheral UUID, independent of mutable logical-device attribution.
        public let peripheralID: String
        public let deviceID: String
        public let firmware: String?
        public let family: String
        public let payload: Data
        /// The encoded u32 payload length, validated against `payload.count` during strict replay.
        public var payloadLength: Int { payload.count }
        public let payloadSHA256: Data
        public let recordSHA256: Data
    }

    /// Result of a crash-recovery pass. A complete synchronized `.open` segment is sealed and renamed;
    /// a malformed or partial tail is retained byte-for-byte in `unrecoverable` for forensic handling.
    public struct OpenRecoveryReport: Equatable, Sendable {
        public let recovered: [URL]
        public let unrecoverable: [URL]

        public init(recovered: [URL], unrecoverable: [URL]) {
            self.recovered = recovered
            self.unrecoverable = unrecoverable
        }
    }

    public enum JournalError: Swift.Error, Equatable, CustomStringConvertible {
        case invalidConfiguration
        case invalidMetadata(field: String)
        case metadataTooLarge(field: String)
        case duplicateConnectionEpoch(UUID)
        case unknownConnectionEpoch(UUID)
        case payloadTooLarge(actual: Int, maximum: Int)
        case recordExceedsSegmentLimit(actual: Int, maximum: Int)
        case retentionCapacityReached(maximumSegments: Int)
        case journalFaulted
        case cannotCreateFile(URL)
        case malformedHeader
        case invalidHeaderMagic
        case unsupportedVersion(UInt16)
        case headerDigestMismatch
        case declaredSegmentLimitExceeded(actual: Int, maximum: Int)
        case invalidRecordMagic(offset: Int)
        case invalidRecordLength(offset: Int, length: Int)
        case truncatedRecord(offset: Int)
        case recordDigestMismatch(offset: Int)
        case payloadDigestMismatch(sequence: UInt64)
        case invalidUTF8(field: String, sequence: UInt64)
        case invalidRecordMetadata(field: String, sequence: UInt64)
        case missingFooter
        case truncatedFooter(offset: Int)
        case malformedFooter
        case footerDigestMismatch
        case segmentDigestMismatch
        case recordCountMismatch(expected: UInt64, actual: UInt64)
        case trailingBytes(offset: Int)
        case integerOverflow

        public var description: String {
            switch self {
            case .invalidConfiguration: return "invalid journal configuration"
            case .invalidMetadata(let field): return "invalid metadata: \(field)"
            case .metadataTooLarge(let field): return "metadata is too large: \(field)"
            case .duplicateConnectionEpoch(let epoch): return "duplicate connection epoch: \(epoch)"
            case .unknownConnectionEpoch(let epoch): return "unknown connection epoch: \(epoch)"
            case .payloadTooLarge(let actual, let maximum):
                return "payload is \(actual) bytes; maximum is \(maximum)"
            case .recordExceedsSegmentLimit(let actual, let maximum):
                return "record requires \(actual) bytes; segment maximum is \(maximum)"
            case .retentionCapacityReached(let maximum):
                return "wire-evidence retention capacity reached at \(maximum) retained segments"
            case .journalFaulted: return "journal is faulted after an incomplete I/O operation"
            case .cannotCreateFile(let url): return "could not create journal file at \(url.path)"
            case .malformedHeader: return "malformed segment header"
            case .invalidHeaderMagic: return "invalid segment header magic"
            case .unsupportedVersion(let version): return "unsupported segment version \(version)"
            case .headerDigestMismatch: return "segment header digest mismatch"
            case .declaredSegmentLimitExceeded(let actual, let maximum):
                return "segment is \(actual) bytes; declared maximum is \(maximum)"
            case .invalidRecordMagic(let offset): return "invalid record magic at byte \(offset)"
            case .invalidRecordLength(let offset, let length):
                return "invalid record length \(length) at byte \(offset)"
            case .truncatedRecord(let offset): return "truncated record at byte \(offset)"
            case .recordDigestMismatch(let offset): return "record digest mismatch at byte \(offset)"
            case .payloadDigestMismatch(let sequence):
                return "payload digest mismatch for sequence \(sequence)"
            case .invalidUTF8(let field, let sequence):
                return "invalid UTF-8 in \(field) for sequence \(sequence)"
            case .invalidRecordMetadata(let field, let sequence):
                return "invalid \(field) for sequence \(sequence)"
            case .missingFooter: return "segment has no clean-close footer"
            case .truncatedFooter(let offset): return "truncated footer at byte \(offset)"
            case .malformedFooter: return "malformed segment footer"
            case .footerDigestMismatch: return "segment footer digest mismatch"
            case .segmentDigestMismatch: return "segment content digest mismatch"
            case .recordCountMismatch(let expected, let actual):
                return "footer declares \(expected) records; decoded \(actual)"
            case .trailingBytes(let offset): return "bytes remain after footer at byte \(offset)"
            case .integerOverflow: return "binary length does not fit this platform"
            }
        }
    }

    private struct ActiveSegment {
        let id: UUID
        let openURL: URL
        let sealedURL: URL
        let handle: FileHandle
        var bytes: Int
        var records: UInt64
    }

    private struct ParsedHeader {
        let segmentID: UUID
        let maximumSegmentBytes: Int
        let maximumPayloadBytes: Int
    }

    private static let version: UInt16 = 1
    private static let headerMagic = Data("FWWIRE01".utf8)
    private static let recordMagic = Data("WREC".utf8)
    private static let footerMagic = Data("FWEND001".utf8)
    private static let digestBytes = 32
    private static let headerBytes = 84
    private static let footerBytes = 84
    private static let minimumRecordBytes = 133

    private let directory: URL
    private let configuration: Configuration
    private let fileManager: FileManager
    private let wallClock: () -> UInt64
    private let monotonicClock: () -> UInt64
    private let segmentIDFactory: () -> UUID
    private let lock = NSLock()
    private var active: ActiveSegment?
    private var nextSequence: [UUID: UInt64] = [:]
    private var faulted = false

    public convenience init(
        directory: URL? = nil,
        configuration: Configuration = .default
    ) throws {
        try self.init(
            directory: directory,
            configuration: configuration,
            fileManager: .default,
            wallClock: Self.systemWallTimeNanoseconds,
            monotonicClock: { DispatchTime.now().uptimeNanoseconds },
            segmentIDFactory: UUID.init
        )
    }

    init(
        directory: URL? = nil,
        configuration: Configuration = .default,
        fileManager: FileManager = .default,
        wallClock: @escaping () -> UInt64,
        monotonicClock: @escaping () -> UInt64,
        segmentIDFactory: @escaping () -> UUID
    ) throws {
        guard configuration.maxSegmentBytes >= Self.headerBytes + Self.footerBytes + Self.minimumRecordBytes,
              configuration.maxRetainedSegments > 0,
              configuration.maxPayloadBytes > 0,
              configuration.maxPayloadBytes <= Int(UInt32.max),
              configuration.maxSegmentBytes <= Int.max else {
            throw JournalError.invalidConfiguration
        }
        self.configuration = configuration
        self.fileManager = fileManager
        self.wallClock = wallClock
        self.monotonicClock = monotonicClock
        self.segmentIDFactory = segmentIDFactory
        if let directory {
            self.directory = directory
        } else {
            let base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.directory = base
                .appendingPathComponent("OpenWhoop", isDirectory: true)
                .appendingPathComponent("WireEvidence", isDirectory: true)
        }
        try Self.prepareDirectory(self.directory, fileManager: fileManager)
        // A previous process may have died after fsyncing complete records but before writing the footer
        // or renaming the segment. Recover only fully validated records; retain partial/corrupt sources
        // untouched and let the normal hard-cap policy account for them.
        _ = try? Self.recoverOpenSegments(in: self.directory, fileManager: fileManager)
    }

    deinit {
        _ = try? close()
    }

    /// Declare a new BLE connection epoch. Sequence numbers start at zero inside each epoch.
    /// Supplying `epoch` is useful when a connection owner has already allocated its stable UUID.
    public func beginConnection(
        epoch: UUID = UUID(),
        peripheralID: String,
        deviceID: String,
        firmware: String?,
        family: String
    ) throws -> Connection {
        try validateRequired(peripheralID, field: "peripheralID")
        try validateRequired(deviceID, field: "deviceID")
        try validateRequired(family, field: "family")
        if let firmware { try validateOptional(firmware, field: "firmware") }

        lock.lock()
        defer { lock.unlock() }
        guard !faulted else { throw JournalError.journalFaulted }
        guard nextSequence[epoch] == nil else { throw JournalError.duplicateConnectionEpoch(epoch) }
        nextSequence[epoch] = 0
        return Connection(epoch: epoch, peripheralID: peripheralID, deviceID: deviceID,
                          firmware: firmware, family: family)
    }

    /// Reserve durable segment capacity for the first notification of an explicit acquisition before
    /// its producer command is sent. This writes and fsyncs only an empty segment header; it does not
    /// consume a capture sequence or invent a notification. If the active segment cannot fit a record of
    /// this exact metadata/payload size, it is sealed and a fresh segment is allocated now, so a full
    /// retention set fails before hardware state changes rather than on the first sensor byte.
    public func reserveCapacityForNotification(
        payloadByteCount: Int,
        connection: Connection,
        serviceUUID: String,
        characteristicUUID: String
    ) throws {
        try validateRequired(serviceUUID, field: "serviceUUID")
        try validateRequired(characteristicUUID, field: "characteristicUUID")
        guard payloadByteCount >= 0, payloadByteCount <= configuration.maxPayloadBytes else {
            throw JournalError.payloadTooLarge(actual: payloadByteCount,
                                               maximum: configuration.maxPayloadBytes)
        }

        lock.lock()
        defer { lock.unlock() }
        guard !faulted else { throw JournalError.journalFaulted }
        guard let sequence = nextSequence[connection.epoch] else {
            throw JournalError.unknownConnectionEpoch(connection.epoch)
        }
        let encoded = try Self.encodeRecord(
            connection: connection,
            sequence: sequence,
            wallTimeNanoseconds: 0,
            monotonicTimeNanoseconds: 0,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            payload: Data(count: payloadByteCount)
        )
        let required = Self.headerBytes + encoded.data.count + Self.footerBytes
        guard required <= configuration.maxSegmentBytes else {
            throw JournalError.recordExceedsSegmentLimit(actual: required,
                                                         maximum: configuration.maxSegmentBytes)
        }
        if active == nil {
            active = try createSegmentLocked()
        } else if let current = active,
                  current.bytes + encoded.data.count + Self.footerBytes > configuration.maxSegmentBytes {
            _ = try sealActiveLocked()
            active = try createSegmentLocked()
        }
    }

    /// Forget sequence state for a disconnected epoch. Already-written records are unaffected.
    public func endConnection(_ connection: Connection) {
        lock.lock()
        nextSequence.removeValue(forKey: connection.epoch)
        lock.unlock()
    }

    /// Append exact notification bytes and fsync them before returning.
    ///
    /// The optional timestamps let the BLE callback capture arrival time before crossing an executor.
    /// Defaults are sampled at the start of this call. `sequence` advances only after the record and
    /// its digest have both been written and synchronized successfully.
    @discardableResult
    public func appendNotification(
        payload: Data,
        connection: Connection,
        serviceUUID: String,
        characteristicUUID: String,
        wallTimeNanoseconds: UInt64? = nil,
        monotonicTimeNanoseconds: UInt64? = nil
    ) throws -> Receipt {
        try validateRequired(serviceUUID, field: "serviceUUID")
        try validateRequired(characteristicUUID, field: "characteristicUUID")
        guard payload.count <= configuration.maxPayloadBytes else {
            throw JournalError.payloadTooLarge(actual: payload.count, maximum: configuration.maxPayloadBytes)
        }

        let wall = wallTimeNanoseconds ?? wallClock()
        let monotonic = monotonicTimeNanoseconds ?? monotonicClock()

        lock.lock()
        defer { lock.unlock() }
        guard !faulted else { throw JournalError.journalFaulted }
        guard let sequence = nextSequence[connection.epoch] else {
            throw JournalError.unknownConnectionEpoch(connection.epoch)
        }

        let encoded = try Self.encodeRecord(
            connection: connection,
            sequence: sequence,
            wallTimeNanoseconds: wall,
            monotonicTimeNanoseconds: monotonic,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            payload: payload
        )
        let required = Self.headerBytes + encoded.data.count + Self.footerBytes
        guard required <= configuration.maxSegmentBytes else {
            throw JournalError.recordExceedsSegmentLimit(
                actual: required,
                maximum: configuration.maxSegmentBytes
            )
        }

        if active == nil {
            active = try createSegmentLocked()
        } else if let current = active,
                  current.bytes + encoded.data.count + Self.footerBytes > configuration.maxSegmentBytes {
            _ = try sealActiveLocked()
            active = try createSegmentLocked()
        }

        guard var segment = active else { throw JournalError.journalFaulted }
        do {
            try segment.handle.write(contentsOf: encoded.data)
            try segment.handle.synchronize()
        } catch {
            try? segment.handle.close()
            active = nil
            faulted = true
            throw error
        }
        segment.bytes += encoded.data.count
        segment.records += 1
        active = segment
        nextSequence[connection.epoch] = sequence &+ 1

        return Receipt(
            segmentID: segment.id,
            connectionEpoch: connection.epoch,
            sequence: sequence,
            payloadSHA256: encoded.payloadDigest,
            recordSHA256: encoded.recordDigest
        )
    }

    /// Seal the current segment. Empty journals do nothing. The return value is retained for API
    /// compatibility and is always empty: this journal never deletes evidence to make space.
    @discardableResult
    public func rotate() throws -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        guard !faulted else { throw JournalError.journalFaulted }
        return try sealActiveLocked()
    }

    /// Fsync, close, and rename the current segment within its directory. Idempotent.
    @discardableResult
    public func close() throws -> [URL] {
        try rotate()
    }

    /// Sealed segments only, in deterministic lexical file-name order. Wall-clock correction can make
    /// that differ from capture order; records carry connection epoch + sequence for exact lane ordering.
    public func sealedSegmentURLs() throws -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return try sealedSegmentURLsLocked()
    }

    /// Strictly replay one cleanly sealed segment. Any header, record, payload, footer, count, length,
    /// truncation, or trailing-byte mismatch rejects the complete segment; callers must never quietly
    /// skip a bad record and present the remainder as authoritative evidence.
    public static func replay(_ url: URL) throws -> [Record] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let header = try parseHeader(data)
        guard data.count <= header.maximumSegmentBytes else {
            throw JournalError.declaredSegmentLimitExceeded(
                actual: data.count,
                maximum: header.maximumSegmentBytes
            )
        }

        var offset = headerBytes
        var records: [Record] = []
        while offset < data.count {
            if hasPrefix(footerMagic, in: data, at: offset) {
                guard data.count - offset >= footerBytes else {
                    throw JournalError.truncatedFooter(offset: offset)
                }
                let footerEnd = offset + footerBytes
                guard footerEnd == data.count else {
                    throw JournalError.trailingBytes(offset: footerEnd)
                }
                try validateFooter(
                    data: data,
                    footerOffset: offset,
                    decodedRecordCount: UInt64(records.count)
                )
                return records
            }
            let decoded = try decodeRecord(
                data,
                offset: offset,
                segmentID: header.segmentID,
                maximumPayloadBytes: header.maximumPayloadBytes
            )
            records.append(decoded.record)
            offset = decoded.nextOffset
        }
        throw JournalError.missingFooter
    }

    /// Replay every sealed segment in deterministic lexical file-name order. One corrupt segment fails
    /// the whole operation instead of silently creating a hole. This API does not claim cross-segment
    /// capture order when wall time moved backward; consumers order each connection epoch by sequence.
    public static func replayDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws -> [Record] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "whoopwire" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var result: [Record] = []
        for url in urls { result.append(contentsOf: try replay(url)) }
        return result
    }

    /// Seal crash-left `.open` files only when their header and every complete record validate. Files
    /// with a partial/corrupt tail are never truncated or deleted; they remain listed as unrecoverable.
    /// This should run before a journal opens a new active segment, as the initializer does.
    public static func recoverOpenSegments(
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> OpenRecoveryReport {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "open" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var recovered: [URL] = []
        var unrecoverable: [URL] = []
        for url in urls {
            do {
                recovered.append(try recoverOpenSegment(url, fileManager: fileManager))
            } catch {
                unrecoverable.append(url)
            }
        }
        return OpenRecoveryReport(recovered: recovered, unrecoverable: unrecoverable)
    }

    private static func systemWallTimeNanoseconds() -> UInt64 {
        let value = Date().timeIntervalSince1970 * 1_000_000_000
        guard value.isFinite, value > 0 else { return 0 }
        return UInt64(value.rounded(.towardZero))
    }

    private static func recoverOpenSegment(_ openURL: URL,
                                           fileManager: FileManager) throws -> URL {
        let data = try Data(contentsOf: openURL, options: .mappedIfSafe)
        let inspection = try inspectOpenContent(data)
        let sealedURL = openURL.deletingPathExtension().appendingPathExtension("whoopwire")
        guard !fileManager.fileExists(atPath: sealedURL.path) else {
            throw JournalError.cannotCreateFile(sealedURL)
        }

        if !inspection.hasFooter {
            guard data.count + footerBytes <= inspection.header.maximumSegmentBytes else {
                throw JournalError.declaredSegmentLimitExceeded(
                    actual: data.count + footerBytes,
                    maximum: inspection.header.maximumSegmentBytes
                )
            }
            let footer = encodeFooter(content: data, recordCount: inspection.recordCount)
            let handle = try FileHandle(forWritingTo: openURL)
            do {
                let end = try handle.seekToEnd()
                guard end == UInt64(data.count) else {
                    try? handle.close()
                    throw JournalError.trailingBytes(offset: data.count)
                }
                try handle.write(contentsOf: footer)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        }

        try fileManager.moveItem(at: openURL, to: sealedURL)
        applyBackgroundProtection(sealedURL, fileManager: fileManager)
        // Re-open through the strict public path before reporting recovery success.
        _ = try replay(sealedURL)
        return sealedURL
    }

    private static func inspectOpenContent(
        _ data: Data
    ) throws -> (header: ParsedHeader, recordCount: UInt64, hasFooter: Bool) {
        let header = try parseHeader(data)
        guard data.count <= header.maximumSegmentBytes else {
            throw JournalError.declaredSegmentLimitExceeded(
                actual: data.count,
                maximum: header.maximumSegmentBytes
            )
        }
        var offset = headerBytes
        var count: UInt64 = 0
        while offset < data.count {
            if hasPrefix(footerMagic, in: data, at: offset) {
                guard data.count - offset >= footerBytes else {
                    throw JournalError.truncatedFooter(offset: offset)
                }
                guard offset + footerBytes == data.count else {
                    throw JournalError.trailingBytes(offset: offset + footerBytes)
                }
                try validateFooter(data: data, footerOffset: offset, decodedRecordCount: count)
                return (header, count, true)
            }
            let decoded = try decodeRecord(
                data,
                offset: offset,
                segmentID: header.segmentID,
                maximumPayloadBytes: header.maximumPayloadBytes
            )
            count &+= 1
            offset = decoded.nextOffset
        }
        return (header, count, false)
    }

    private func createSegmentLocked() throws -> ActiveSegment {
        guard try retainedSegmentCountLocked() < configuration.maxRetainedSegments else {
            throw JournalError.retentionCapacityReached(
                maximumSegments: configuration.maxRetainedSegments)
        }
        let id = segmentIDFactory()
        let created = wallClock()
        let stem = String(format: "wire-%020llu-%@", created, id.uuidString.lowercased())
        let openURL = directory.appendingPathComponent(stem).appendingPathExtension("open")
        let sealedURL = directory.appendingPathComponent(stem).appendingPathExtension("whoopwire")
        // A UUID collision is vanishingly unlikely with the production factory, but evidence storage
        // must fail closed even then. `createFile` replacement semantics must never decide whether an
        // older capture survives.
        guard !fileManager.fileExists(atPath: openURL.path),
              !fileManager.fileExists(atPath: sealedURL.path) else {
            throw JournalError.cannotCreateFile(openURL)
        }
        let header = Self.encodeHeader(
            segmentID: id,
            createdWallTimeNanoseconds: created,
            configuration: configuration
        )
        guard fileManager.createFile(atPath: openURL.path, contents: header) else {
            throw JournalError.cannotCreateFile(openURL)
        }
        Self.applyBackgroundProtection(openURL, fileManager: fileManager)
        do {
            let handle = try FileHandle(forWritingTo: openURL)
            try handle.seekToEnd()
            try handle.synchronize()
            return ActiveSegment(
                id: id,
                openURL: openURL,
                sealedURL: sealedURL,
                handle: handle,
                bytes: header.count,
                records: 0
            )
        } catch {
            try? fileManager.removeItem(at: openURL)
            throw error
        }
    }

    private func sealActiveLocked() throws -> [URL] {
        guard let segment = active else { return [] }
        active = nil
        do {
            try segment.handle.synchronize()
            let content = try Data(contentsOf: segment.openURL, options: .mappedIfSafe)
            guard content.count == segment.bytes else {
                faulted = true
                try? segment.handle.close()
                throw JournalError.truncatedRecord(offset: content.count)
            }
            let footer = Self.encodeFooter(content: content, recordCount: segment.records)
            guard content.count + footer.count <= configuration.maxSegmentBytes else {
                faulted = true
                try? segment.handle.close()
                throw JournalError.declaredSegmentLimitExceeded(
                    actual: content.count + footer.count,
                    maximum: configuration.maxSegmentBytes
                )
            }
            try segment.handle.write(contentsOf: footer)
            try segment.handle.synchronize()
            try segment.handle.close()
            try fileManager.moveItem(at: segment.openURL, to: segment.sealedURL)
            Self.applyBackgroundProtection(segment.sealedURL, fileManager: fileManager)
            return []
        } catch {
            try? segment.handle.close()
            faulted = true
            throw error
        }
    }

    private func sealedSegmentURLsLocked() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "whoopwire" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func retainedSegmentCountLocked() throws -> Int {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "whoopwire" || $0.pathExtension == "open" }
        .count
    }

    private func validateRequired(_ value: String, field: String) throws {
        guard !value.isEmpty else { throw JournalError.invalidMetadata(field: field) }
        try validateOptional(value, field: field)
    }

    private func validateOptional(_ value: String, field: String) throws {
        guard value.utf8.count <= Int(UInt16.max) else {
            throw JournalError.metadataTooLarge(field: field)
        }
    }

    private static func prepareDirectory(_ directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        #endif
    }

    private static func applyBackgroundProtection(_ url: URL, fileManager: FileManager) {
        #if os(iOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private static func encodeHeader(
        segmentID: UUID,
        createdWallTimeNanoseconds: UInt64,
        configuration: Configuration
    ) -> Data {
        var value = Data()
        value.append(headerMagic)
        value.appendLittleEndian(version)
        value.appendLittleEndian(UInt16(headerBytes))
        value.appendUUID(segmentID)
        value.appendLittleEndian(createdWallTimeNanoseconds)
        value.appendLittleEndian(UInt64(configuration.maxSegmentBytes))
        value.appendLittleEndian(UInt32(configuration.maxPayloadBytes))
        value.appendLittleEndian(UInt32(0))
        value.append(Data(SHA256.hash(data: value)))
        precondition(value.count == headerBytes)
        return value
    }

    private static func encodeRecord(
        connection: Connection,
        sequence: UInt64,
        wallTimeNanoseconds: UInt64,
        monotonicTimeNanoseconds: UInt64,
        serviceUUID: String,
        characteristicUUID: String,
        payload: Data
    ) throws -> (data: Data, payloadDigest: Data, recordDigest: Data) {
        let service = Data(serviceUUID.utf8)
        let characteristic = Data(characteristicUUID.utf8)
        let peripheral = Data(connection.peripheralID.utf8)
        let device = Data(connection.deviceID.utf8)
        let firmware = Data((connection.firmware ?? "").utf8)
        let family = Data(connection.family.utf8)
        for (field, bytes) in [
            ("serviceUUID", service),
            ("characteristicUUID", characteristic),
            ("peripheralID", peripheral),
            ("deviceID", device),
            ("firmware", firmware),
            ("family", family),
        ] where bytes.count > Int(UInt16.max) {
            throw JournalError.metadataTooLarge(field: field)
        }

        var value = Data()
        value.append(recordMagic)
        value.appendLittleEndian(UInt32(0)) // replaced after the variable-length body is assembled
        value.appendUUID(connection.epoch)
        value.appendLittleEndian(sequence)
        value.appendLittleEndian(wallTimeNanoseconds)
        value.appendLittleEndian(monotonicTimeNanoseconds)
        value.appendLittleEndian(UInt16(service.count))
        value.appendLittleEndian(UInt16(characteristic.count))
        value.appendLittleEndian(UInt16(peripheral.count))
        value.appendLittleEndian(UInt16(device.count))
        value.appendLittleEndian(UInt16(firmware.count))
        value.appendLittleEndian(UInt16(family.count))
        value.appendLittleEndian(UInt32(payload.count))
        value.append(service)
        value.append(characteristic)
        value.append(peripheral)
        value.append(device)
        value.append(firmware)
        value.append(family)
        value.append(payload)

        let payloadDigest = Data(SHA256.hash(data: payload))
        value.append(payloadDigest)
        let finalLength = value.count + digestBytes
        guard finalLength <= Int(UInt32.max) else { throw JournalError.integerOverflow }
        var lengthBytes = Data()
        lengthBytes.appendLittleEndian(UInt32(finalLength))
        value.replaceSubrange(4..<8, with: lengthBytes)
        let recordDigest = Data(SHA256.hash(data: value))
        value.append(recordDigest)
        return (value, payloadDigest, recordDigest)
    }

    private static func encodeFooter(content: Data, recordCount: UInt64) -> Data {
        var value = Data()
        value.append(footerMagic)
        value.appendLittleEndian(UInt16(footerBytes))
        value.appendLittleEndian(version)
        value.appendLittleEndian(recordCount)
        value.append(Data(SHA256.hash(data: content)))
        value.append(Data(SHA256.hash(data: value)))
        precondition(value.count == footerBytes)
        return value
    }

    private static func parseHeader(_ data: Data) throws -> ParsedHeader {
        guard data.count >= headerBytes else { throw JournalError.malformedHeader }
        var reader = BinaryReader(data: data, limit: headerBytes)
        guard try reader.readData(count: headerMagic.count) == headerMagic else {
            throw JournalError.invalidHeaderMagic
        }
        let fileVersion = try reader.readUInt16()
        guard fileVersion == version else { throw JournalError.unsupportedVersion(fileVersion) }
        guard try reader.readUInt16() == UInt16(headerBytes) else { throw JournalError.malformedHeader }
        let id = try reader.readUUID()
        _ = try reader.readUInt64() // segment creation wall timestamp; encoded in the file name too
        let declaredMaximum = try reader.readUInt64()
        let payloadMaximum = try reader.readUInt32()
        guard try reader.readUInt32() == 0 else { throw JournalError.malformedHeader }
        let storedDigest = try reader.readData(count: digestBytes)
        let calculated = Data(SHA256.hash(data: data.prefix(headerBytes - digestBytes)))
        guard storedDigest == calculated else { throw JournalError.headerDigestMismatch }
        guard declaredMaximum <= UInt64(Int.max), UInt64(payloadMaximum) <= UInt64(Int.max),
              declaredMaximum >= UInt64(headerBytes + footerBytes + minimumRecordBytes),
              payloadMaximum > 0 else {
            throw JournalError.malformedHeader
        }
        return ParsedHeader(
            segmentID: id,
            maximumSegmentBytes: Int(declaredMaximum),
            maximumPayloadBytes: Int(payloadMaximum)
        )
    }

    private static func decodeRecord(
        _ data: Data,
        offset: Int,
        segmentID: UUID,
        maximumPayloadBytes: Int
    ) throws -> (record: Record, nextOffset: Int) {
        guard data.count - offset >= 8 else { throw JournalError.truncatedRecord(offset: offset) }
        guard hasPrefix(recordMagic, in: data, at: offset) else {
            throw JournalError.invalidRecordMagic(offset: offset)
        }
        var lengthReader = BinaryReader(data: data, offset: offset + 4, limit: data.count)
        let encodedLength = try lengthReader.readUInt32()
        guard UInt64(encodedLength) <= UInt64(Int.max) else { throw JournalError.integerOverflow }
        let length = Int(encodedLength)
        guard length >= minimumRecordBytes else {
            throw JournalError.invalidRecordLength(offset: offset, length: length)
        }
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard !overflow else { throw JournalError.integerOverflow }
        guard end <= data.count else { throw JournalError.truncatedRecord(offset: offset) }

        let storedRecordDigest = data.subdata(in: (end - digestBytes)..<end)
        let calculatedRecordDigest = Data(SHA256.hash(data: data[offset..<(end - digestBytes)]))
        guard storedRecordDigest == calculatedRecordDigest else {
            throw JournalError.recordDigestMismatch(offset: offset)
        }

        var reader = BinaryReader(data: data, offset: offset + 8, limit: end - digestBytes)
        let epoch = try reader.readUUID()
        let sequence = try reader.readUInt64()
        let wall = try reader.readUInt64()
        let monotonic = try reader.readUInt64()
        let serviceLength = Int(try reader.readUInt16())
        let characteristicLength = Int(try reader.readUInt16())
        let peripheralLength = Int(try reader.readUInt16())
        let deviceLength = Int(try reader.readUInt16())
        let firmwareLength = Int(try reader.readUInt16())
        let familyLength = Int(try reader.readUInt16())
        let encodedPayloadLength = try reader.readUInt32()
        guard UInt64(encodedPayloadLength) <= UInt64(Int.max) else {
            throw JournalError.integerOverflow
        }
        let payloadLength = Int(encodedPayloadLength)
        guard payloadLength <= maximumPayloadBytes else {
            throw JournalError.payloadTooLarge(actual: payloadLength, maximum: maximumPayloadBytes)
        }

        let service = try decodeString(
            reader.readData(count: serviceLength), field: "serviceUUID", sequence: sequence
        )
        let characteristic = try decodeString(
            reader.readData(count: characteristicLength), field: "characteristicUUID", sequence: sequence
        )
        let peripheral = try decodeString(
            reader.readData(count: peripheralLength), field: "peripheralID", sequence: sequence
        )
        let device = try decodeString(
            reader.readData(count: deviceLength), field: "deviceID", sequence: sequence
        )
        let firmwareValue = try decodeString(
            reader.readData(count: firmwareLength), field: "firmware", sequence: sequence
        )
        let family = try decodeString(
            reader.readData(count: familyLength), field: "family", sequence: sequence
        )
        for (field, value) in [
            ("serviceUUID", service),
            ("characteristicUUID", characteristic),
            ("peripheralID", peripheral),
            ("deviceID", device),
            ("family", family),
        ] where value.isEmpty {
            throw JournalError.invalidRecordMetadata(field: field, sequence: sequence)
        }
        let payload = try reader.readData(count: payloadLength)
        let storedPayloadDigest = try reader.readData(count: digestBytes)
        guard reader.offset == end - digestBytes else {
            throw JournalError.invalidRecordLength(offset: offset, length: length)
        }
        let calculatedPayloadDigest = Data(SHA256.hash(data: payload))
        guard storedPayloadDigest == calculatedPayloadDigest else {
            throw JournalError.payloadDigestMismatch(sequence: sequence)
        }
        return (
            Record(
                segmentID: segmentID,
                connectionEpoch: epoch,
                sequence: sequence,
                wallTimeNanoseconds: wall,
                monotonicTimeNanoseconds: monotonic,
                serviceUUID: service,
                characteristicUUID: characteristic,
                peripheralID: peripheral,
                deviceID: device,
                firmware: firmwareValue.isEmpty ? nil : firmwareValue,
                family: family,
                payload: payload,
                payloadSHA256: storedPayloadDigest,
                recordSHA256: storedRecordDigest
            ),
            end
        )
    }

    private static func validateFooter(
        data: Data,
        footerOffset: Int,
        decodedRecordCount: UInt64
    ) throws {
        var reader = BinaryReader(data: data, offset: footerOffset, limit: data.count)
        guard try reader.readData(count: footerMagic.count) == footerMagic else {
            throw JournalError.malformedFooter
        }
        guard try reader.readUInt16() == UInt16(footerBytes) else {
            throw JournalError.malformedFooter
        }
        let footerVersion = try reader.readUInt16()
        guard footerVersion == version else { throw JournalError.unsupportedVersion(footerVersion) }
        let expectedCount = try reader.readUInt64()
        let contentDigest = try reader.readData(count: digestBytes)
        let footerDigest = try reader.readData(count: digestBytes)
        let calculatedFooterDigest = Data(
            SHA256.hash(data: data[footerOffset..<(footerOffset + footerBytes - digestBytes)])
        )
        guard footerDigest == calculatedFooterDigest else { throw JournalError.footerDigestMismatch }
        let calculatedContentDigest = Data(SHA256.hash(data: data.prefix(footerOffset)))
        guard contentDigest == calculatedContentDigest else { throw JournalError.segmentDigestMismatch }
        guard expectedCount == decodedRecordCount else {
            throw JournalError.recordCountMismatch(expected: expectedCount, actual: decodedRecordCount)
        }
    }

    private static func decodeString(_ data: Data, field: String, sequence: UInt64) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw JournalError.invalidUTF8(field: field, sequence: sequence)
        }
        return value
    }

    private static func hasPrefix(_ prefix: Data, in data: Data, at offset: Int) -> Bool {
        guard offset >= 0, data.count - offset >= prefix.count else { return false }
        return data[offset..<(offset + prefix.count)].elementsEqual(prefix)
    }
}

private struct BinaryReader {
    let data: Data
    let limit: Int
    var offset: Int

    init(data: Data, offset: Int = 0, limit: Int? = nil) {
        self.data = data
        self.offset = offset
        self.limit = limit ?? data.count
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset >= 0, limit >= offset, count <= limit - offset else {
            throw WireEvidenceJournal.JournalError.integerOverflow
        }
        let result = data.subdata(in: offset..<(offset + count))
        offset += count
        return result
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readData(count: 2)
        return UInt16(bytes[bytes.startIndex])
            | (UInt16(bytes[bytes.startIndex + 1]) << 8)
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return (0..<4).reduce(UInt32(0)) { value, index in
            value | (UInt32(bytes[bytes.startIndex + index]) << UInt32(index * 8))
        }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(count: 8)
        return (0..<8).reduce(UInt64(0)) { value, index in
            value | (UInt64(bytes[bytes.startIndex + index]) << UInt64(index * 8))
        }
    }

    mutating func readUUID() throws -> UUID {
        let bytes = try readData(count: 16)
        let start = bytes.startIndex
        return UUID(uuid: (
            bytes[start], bytes[start + 1], bytes[start + 2], bytes[start + 3],
            bytes[start + 4], bytes[start + 5], bytes[start + 6], bytes[start + 7],
            bytes[start + 8], bytes[start + 9], bytes[start + 10], bytes[start + 11],
            bytes[start + 12], bytes[start + 13], bytes[start + 14], bytes[start + 15]
        ))
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendUUID(_ value: UUID) {
        var uuid = value.uuid
        Swift.withUnsafeBytes(of: &uuid) { bytes in
            append(contentsOf: bytes)
        }
    }
}
