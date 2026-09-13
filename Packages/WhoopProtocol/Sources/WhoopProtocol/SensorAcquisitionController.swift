import Foundation

/// Separate cap for automatic recovery across fresh BLE links. Controller stop attempts are bounded
/// within one link; this prevents timeout -> reconnect -> timeout from becoming an endless radio loop.
public struct SensorRecoveryLinkBudget: Equatable, Sendable {
    public let maximumAutomaticLinks: Int
    public private(set) var attemptedLinks = 0

    public init(maximumAutomaticLinks: Int = 3) {
        self.maximumAutomaticLinks = max(1, maximumAutomaticLinks)
    }

    @discardableResult
    public mutating func claimAutomaticLink() -> Bool {
        guard attemptedLinks < maximumAutomaticLinks else { return false }
        attemptedLinks += 1
        return true
    }

    public mutating func reset() { attemptedLinks = 0 }
}

/// Deterministic control-plane policy for bounded stock-firmware sensor acquisition.
///
/// This type does not configure a sensor IC. It emits only the already-observed WHOOP raw-data
/// producer contract and deliberately keeps ATT write acceptance separate from data-plane success.
/// Callers must serialize each returned action and call `writeCompleted(succeeded:)` before sending
/// the next one. A run succeeds only after `noteValidatedImuFrame()` and a completed stop sequence.
public struct SensorAcquisitionController: Sendable {
    public static let maximumStopAttempts = 3
    public static let defaultResearchDurationSeconds: TimeInterval = 5 * 60
    public static let maximumDurationSeconds: TimeInterval = 15 * 60
    public enum Profile: String, CaseIterable, Codable, Sendable {
        case observeOnly
        case normal
        case deepHistory
        case imuBurst
        case opticalBurst
        case researchCapture
    }

    public enum Phase: String, Codable, Sendable {
        case idle
        case starting
        case awaitingValidatedData
        case streaming
        case stopping
        case awaitingQuiescence
        case producerUnknown
        case stopped
        case failed
    }

    public enum Rejection: Equatable, Sendable {
        case passiveProfile
        case unverifiedControlContract
        case alreadyActive
        case notConnected
        case commandChannelUnavailable
        case encryptedBondRequired
        case historyNotReady
        case historyBusy
        case controlPlaneBusy
        case unsupportedFamily
        case explicitUserActionRequired
        case invalidDuration
        case cleanupRequired
    }

    public enum Failure: Equatable, Sendable {
        case writeFailed(opcode: UInt8)
        case noValidatedData
        case disconnected
        case evidencePersistenceFailed
        case stopWriteFailed(opcode: UInt8)
        case firmwareRejected(opcode: UInt8, resultCode: UInt8)
    }

    public enum StopReason: String, Codable, Sendable {
        case deadline
        case user
        case background
        case startupFailure
        case orphanProducer
        case reconnectRecovery
    }

    public enum ActionKind: String, Codable, Sendable {
        case startRawData
        case stopRawData
        case toggleImuOn
        case toggleImuOff
    }

    public struct Action: Equatable, Codable, Sendable {
        public let kind: ActionKind
        public let opcode: UInt8
        public let payload: [UInt8]

        public init(kind: ActionKind, opcode: UInt8, payload: [UInt8]) {
            self.kind = kind
            self.opcode = opcode
            self.payload = payload
        }
    }

    public struct Preconditions: Equatable, Sendable {
        public let family: DeviceFamily
        public let connected: Bool
        public let commandChannelReady: Bool
        public let encryptedBond: Bool
        public let historyReady: Bool
        public let historyInFlight: Bool
        public let controlPlaneIdle: Bool
        public let explicitUserInitiated: Bool

        public init(family: DeviceFamily,
                    connected: Bool,
                    commandChannelReady: Bool,
                    encryptedBond: Bool,
                    historyReady: Bool,
                    historyInFlight: Bool,
                    controlPlaneIdle: Bool = true,
                    explicitUserInitiated: Bool) {
            self.family = family
            self.connected = connected
            self.commandChannelReady = commandChannelReady
            self.encryptedBond = encryptedBond
            self.historyReady = historyReady
            self.historyInFlight = historyInFlight
            self.controlPlaneIdle = controlPlaneIdle
            self.explicitUserInitiated = explicitUserInitiated
        }
    }

    public struct StartDecision: Equatable, Sendable {
        public let action: Action?
        public let rejection: Rejection?
        public var accepted: Bool { rejection == nil }

        public init(action: Action?, rejection: Rejection?) {
            self.action = action
            self.rejection = rejection
        }
    }

    public private(set) var phase: Phase = .idle
    public private(set) var profile: Profile?
    public private(set) var validatedFrameCount = 0
    public private(set) var failure: Failure?
    public private(set) var cleanupRequired = false
    public private(set) var currentWrite: Action?
    public private(set) var stopReason: StopReason?
    public private(set) var stopAttemptCount = 0

    private var queued: [Action] = []
    private var stopRequestedWhileWriting = false
    private var stopWriteFailed: Failure?
    private var stopFirmwareRejected: Failure?

    public init() {}

    public var isActive: Bool {
        switch phase {
        case .starting, .awaitingValidatedData, .streaming, .stopping, .awaitingQuiescence, .producerUnknown:
            return true
        case .idle, .stopped, .failed:
            return false
        }
    }

    /// True while producer state is active or cleanup remains unproved, including orphan/relaunch debt.
    /// `profile` deliberately remains available after completion for diagnostics, so callers must use
    /// this property instead of treating a non-nil profile as an active run.
    public var requiresWireEvidence: Bool {
        isActive || cleanupRequired
    }

    /// Historical control must not start while this controller owns a producer, has a write in flight,
    /// or owes stop-first cleanup. The BLE owner uses this as the reverse half of the history barrier;
    /// `begin` enforces the forward half through `historyInFlight`.
    public var permitsHistoryStart: Bool {
        !isActive && currentWrite == nil && !cleanupRequired
    }

    /// Accept a bounded acquisition run and return only its first serialized write.
    public mutating func begin(profile requested: Profile,
                               durationSeconds: TimeInterval,
                               preconditions p: Preconditions) -> StartDecision {
        if isActive || currentWrite != nil { return StartDecision(action: nil, rejection: .alreadyActive) }
        if cleanupRequired { return StartDecision(action: nil, rejection: .cleanupRequired) }
        switch requested {
        case .observeOnly, .normal, .deepHistory:
            return StartDecision(action: nil, rejection: .passiveProfile)
        case .opticalBurst:
            // No sufficiently evidenced stock-firmware optical write contract exists in this tree.
            return StartDecision(action: nil, rejection: .unverifiedControlContract)
        case .imuBurst, .researchCapture:
            break
        }
        if p.family != .whoop5 {
            return StartDecision(action: nil, rejection: .unsupportedFamily)
        }
        if !durationSeconds.isFinite || durationSeconds < 1
            || durationSeconds > Self.maximumDurationSeconds {
            return StartDecision(action: nil, rejection: .invalidDuration)
        }
        if !p.explicitUserInitiated { return StartDecision(action: nil, rejection: .explicitUserActionRequired) }
        if !p.connected { return StartDecision(action: nil, rejection: .notConnected) }
        if !p.commandChannelReady { return StartDecision(action: nil, rejection: .commandChannelUnavailable) }
        if !p.encryptedBond { return StartDecision(action: nil, rejection: .encryptedBondRequired) }
        if !p.historyReady { return StartDecision(action: nil, rejection: .historyNotReady) }
        if p.historyInFlight { return StartDecision(action: nil, rejection: .historyBusy) }
        if !p.controlPlaneIdle { return StartDecision(action: nil, rejection: .controlPlaneBusy) }

        profile = requested
        phase = .starting
        validatedFrameCount = 0
        failure = nil
        stopReason = nil
        stopWriteFailed = nil
        stopFirmwareRejected = nil
        stopAttemptCount = 0
        stopRequestedWhileWriting = false
        queued = startActions()
        return StartDecision(action: popNext(), rejection: nil)
    }

    /// Settle the current ATT write. ATT success advances ordering; it never marks acquisition success.
    public mutating func writeCompleted(succeeded: Bool) -> Action? {
        guard let completed = currentWrite else { return nil }
        currentWrite = nil

        if phase == .stopping {
            if !succeeded, stopWriteFailed == nil {
                stopWriteFailed = .stopWriteFailed(opcode: completed.opcode)
            }
            if let next = popNext() { return next }
            return finishStop()
        }

        guard phase == .starting else { return nil }
        if !succeeded {
            failure = .writeFailed(opcode: completed.opcode)
            return beginStopping(reason: .startupFailure)
        }
        if stopRequestedWhileWriting {
            stopRequestedWhileWriting = false
            return beginStopping(reason: stopReason ?? .user)
        }
        if let next = popNext() { return next }
        phase = .awaitingValidatedData
        return nil
    }

    /// Record one CRC-valid, structurally complete 100x6 IMU frame.
    /// Returns true only for the first frame, allowing callers to log the data-plane transition once.
    @discardableResult
    public mutating func noteValidatedImuFrame() -> Bool {
        guard phase == .awaitingValidatedData || phase == .streaming || phase == .awaitingQuiescence else {
            return false
        }
        validatedFrameCount += 1
        let first = phase == .awaitingValidatedData
        if phase != .awaitingQuiescence { phase = .streaming }
        return first
    }

    /// A realtime-candidate frame after both stop writes disproves quiescence. Re-issue the idempotent
    /// stop sequence and require another observation interval.
    public mutating func producerStillEmittingAfterStop() -> Action? {
        guard phase == .awaitingQuiescence else { return nil }
        return beginStopping(reason: stopReason ?? .user)
    }

    /// Complete cleanup after the BLE owner observes a conservative interval with no realtime-candidate
    /// IMU frames. ATT completion alone never clears producer debt. This is an operational host-side
    /// cessation criterion, not physical proof that an unobservable firmware producer cannot exist.
    @discardableResult
    public mutating func confirmProducerQuiescent() -> Bool {
        guard phase == .awaitingQuiescence else { return false }
        cleanupRequired = false
        if failure == nil, validatedFrameCount == 0, profile != nil {
            failure = .noValidatedData
        }
        phase = failure == nil ? .stopped : .failed
        return true
    }

    /// End a bounded run. Zero validated frames is a failed experiment even if every write was accepted.
    public mutating func deadlineReached() -> Action? {
        requestStop(reason: .deadline)
    }

    public mutating func requestStop(reason: StopReason) -> Action? {
        switch phase {
        case .starting:
            stopReason = reason
            queued.removeAll(keepingCapacity: true)
            if currentWrite != nil {
                stopRequestedWhileWriting = true
                return nil
            }
            return beginStopping(reason: reason)
        case .awaitingValidatedData, .streaming, .awaitingQuiescence:
            return beginStopping(reason: reason)
        case .stopping, .producerUnknown, .idle, .stopped, .failed:
            return nil
        }
    }

    /// Fail closed when Level-A persistence cannot keep the exact notification bytes for an explicit run.
    public mutating func evidencePersistenceFailed() -> Action? {
        guard isActive else { return nil }
        failure = .evidencePersistenceFailed
        return requestStop(reason: .startupFailure)
    }

    /// Correlate a CRC-valid WHOOP command response with the active stock-producer operation. SUCCESS is
    /// diagnostic only; it never proves data arrival or cessation. Explicit FAILURE/UNSUPPORTED results
    /// fail closed and cause bounded stop/cleanup. PENDING is not a refusal.
    public mutating func noteFirmwareResponse(action: Action, resultCode: UInt8) -> Action? {
        let opcode = action.opcode
        guard opcode == 81 || opcode == 82 || opcode == 106 else { return nil }
        guard resultCode == 0 || resultCode == 3 else { return nil }
        let rejection = Failure.firmwareRejected(opcode: opcode, resultCode: resultCode)

        switch action.kind {
        case .startRawData, .toggleImuOn:
            failure = rejection
            switch phase {
            case .starting, .awaitingValidatedData, .streaming:
                // Stop-first cleanup is still required because opcode 81 may already have armed the
                // producer even when a later start-side command was refused.
                return requestStop(reason: .startupFailure)
            case .stopping, .awaitingQuiescence, .producerUnknown, .failed:
                // A delayed start response must not be misclassified as rejection of 106-off.
                return nil
            case .idle, .stopped:
                return nil
            }
        case .stopRawData, .toggleImuOff:
            switch phase {
            case .stopping:
                // Do not interrupt an ATT write whose callback still owns the command lane. `finishStop`
                // sees this marker after the current complete stop attempt and retries as one unit.
                stopFirmwareRejected = rejection
                return nil
            case .awaitingQuiescence:
                failure = rejection
                stopFirmwareRejected = rejection
                return beginStopping(reason: stopReason ?? .reconnectRecovery)
            case .producerUnknown, .failed:
                failure = rejection
                cleanupRequired = true
                return nil
            case .idle, .starting, .awaitingValidatedData, .streaming, .stopped:
                return nil
            }
        }
    }

    /// A link loss leaves producer state unknowable. Recovery is stop-first; never silently re-arm.
    public mutating func disconnected() {
        guard isActive || currentWrite != nil || cleanupRequired else { return }
        currentWrite = nil
        queued.removeAll(keepingCapacity: true)
        phase = .producerUnknown
        failure = .disconnected
        cleanupRequired = true
        stopReason = .reconnectRecovery
        stopAttemptCount = 0
    }

    /// Restore only the cleanup obligation after a process interruption.
    ///
    /// The original run cannot be proven active after relaunch, so it must never be silently resumed.
    /// An idempotent stop-first sequence is the only action admitted once an authenticated link exists.
    public mutating func restoreCleanupDebt() {
        guard !isActive, currentWrite == nil else { return }
        profile = nil
        validatedFrameCount = 0
        currentWrite = nil
        queued.removeAll(keepingCapacity: true)
        phase = .producerUnknown
        failure = .disconnected
        cleanupRequired = true
        stopReason = .reconnectRecovery
        stopAttemptCount = 0
    }

    /// Start a serialized 82 -> 106-off cleanup after an authenticated reconnect.
    public mutating func beginRecovery(preconditions p: Preconditions) -> Action? {
        guard cleanupRequired, p.family == .whoop5, p.connected, p.commandChannelReady, p.encryptedBond,
              !p.historyInFlight, p.controlPlaneIdle else { return nil }
        stopReason = .reconnectRecovery
        return beginStopping(reason: .reconnectRecovery)
    }

    /// Stop a producer observed while no session owns it. This is a cleanup operation, not acquisition.
    public mutating func beginOrphanCleanup(preconditions p: Preconditions) -> Action? {
        guard !isActive, currentWrite == nil, !cleanupRequired, p.family == .whoop5,
              p.connected, p.commandChannelReady,
              p.encryptedBond, !p.historyInFlight, p.controlPlaneIdle else { return nil }
        profile = nil
        validatedFrameCount = 0
        failure = nil
        cleanupRequired = true
        stopReason = .orphanProducer
        stopAttemptCount = 0
        return beginStopping(reason: .orphanProducer)
    }

    private mutating func beginStopping(reason: StopReason) -> Action? {
        guard stopAttemptCount < Self.maximumStopAttempts else {
            currentWrite = nil
            queued.removeAll(keepingCapacity: true)
            cleanupRequired = true
            phase = .producerUnknown
            return nil
        }
        stopAttemptCount += 1
        stopReason = reason
        queued = stopActions()
        currentWrite = nil
        stopWriteFailed = nil
        stopFirmwareRejected = nil
        phase = .stopping
        cleanupRequired = true
        return popNext()
    }

    private mutating func popNext() -> Action? {
        guard !queued.isEmpty else { return nil }
        let next = queued.removeFirst()
        currentWrite = next
        return next
    }

    private mutating func finishStop() -> Action? {
        if let stopFailure = stopWriteFailed ?? stopFirmwareRejected {
            failure = stopFailure
            cleanupRequired = true
            // A transient ATT failure during deadline/background cleanup must not leave a producer
            // armed until somebody opens the UI or reconnects. Retry the complete idempotent stop
            // sequence on this authenticated link, with the same cap used for post-stop emissions.
            if stopAttemptCount < Self.maximumStopAttempts {
                return beginStopping(reason: stopReason ?? .reconnectRecovery)
            }
            currentWrite = nil
            queued.removeAll(keepingCapacity: true)
            phase = .producerUnknown
            return nil
        }
        // Both writes reached CoreBluetooth, but that is not evidence that the producer ceased. The BLE
        // owner must observe a quiet interval and call `confirmProducerQuiescent` before debt is cleared.
        phase = .awaitingQuiescence
        return nil
    }

    private func startActions() -> [Action] {
        [
            Action(kind: .startRawData, opcode: 81, payload: [0x01]),
            Action(kind: .toggleImuOn, opcode: 106, payload: [0x01, 0x01]),
        ]
    }

    private func stopActions() -> [Action] {
        [
            Action(kind: .stopRawData, opcode: 82, payload: [0x01]),
            Action(kind: .toggleImuOff, opcode: 106, payload: [0x01, 0x00]),
        ]
    }
}
