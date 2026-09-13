import XCTest
@testable import WhoopProtocol

final class SensorAcquisitionControllerTests: XCTestCase {
    private func ready(family: DeviceFamily = .whoop5,
                       historyInFlight: Bool = false) -> SensorAcquisitionController.Preconditions {
        .init(family: family, connected: true, commandChannelReady: true,
              encryptedBond: true, historyReady: true,
              historyInFlight: historyInFlight, explicitUserInitiated: true)
    }

    func testStartIsSerialized81Then106AndAckIsNotDataSuccess() {
        var sut = SensorAcquisitionController()
        let first = sut.begin(profile: .imuBurst, durationSeconds: 30, preconditions: ready())
        XCTAssertEqual(first.action, .init(kind: .startRawData, opcode: 81, payload: [0x01]))
        XCTAssertEqual(sut.phase, .starting)

        let second = sut.writeCompleted(succeeded: true)
        XCTAssertEqual(second, .init(kind: .toggleImuOn, opcode: 106, payload: [0x01, 0x01]))
        XCTAssertNil(sut.writeCompleted(succeeded: true))
        XCTAssertEqual(sut.phase, .awaitingValidatedData)
        XCTAssertEqual(sut.validatedFrameCount, 0)
    }

    func testStopIsSerialized82Then106OffAndIdempotent() {
        var sut = started()
        sut.noteValidatedImuFrame()
        XCTAssertEqual(sut.requestStop(reason: .user),
                       .init(kind: .stopRawData, opcode: 82, payload: [0x01]))
        XCTAssertNil(sut.requestStop(reason: .user))
        XCTAssertEqual(sut.writeCompleted(succeeded: true),
                       .init(kind: .toggleImuOff, opcode: 106, payload: [0x01, 0x00]))
        XCTAssertNil(sut.writeCompleted(succeeded: true))
        XCTAssertEqual(sut.phase, .awaitingQuiescence)
        XCTAssertTrue(sut.cleanupRequired)
        XCTAssertTrue(sut.confirmProducerQuiescent())
        XCTAssertEqual(sut.phase, .stopped)
        XCTAssertNil(sut.failure)
        XCTAssertNil(sut.requestStop(reason: .user))
    }

    func testTimeoutAlwaysStopsAndAcceptedWritesWithNoDataFail() {
        var sut = started()
        XCTAssertEqual(sut.deadlineReached()?.opcode, 82)
        XCTAssertEqual(sut.writeCompleted(succeeded: true)?.opcode, 106)
        XCTAssertNil(sut.writeCompleted(succeeded: true))
        XCTAssertEqual(sut.phase, .awaitingQuiescence)
        XCTAssertTrue(sut.confirmProducerQuiescent())
        XCTAssertEqual(sut.phase, .failed)
        XCTAssertEqual(sut.failure, .noValidatedData)
    }

    func testValidatedDataMakesBoundedRunSuccessfulOnlyAfterStop() {
        var sut = started()
        XCTAssertTrue(sut.noteValidatedImuFrame())
        XCTAssertFalse(sut.noteValidatedImuFrame())
        XCTAssertEqual(sut.phase, .streaming)
        _ = sut.deadlineReached()
        _ = sut.writeCompleted(succeeded: true)
        _ = sut.writeCompleted(succeeded: true)
        XCTAssertTrue(sut.confirmProducerQuiescent())
        XCTAssertEqual(sut.phase, .stopped)
        XCTAssertEqual(sut.validatedFrameCount, 2)
        XCTAssertNil(sut.failure)
    }

    func testHistoryBarrierCannotBeBypassed() {
        var sut = SensorAcquisitionController()
        let decision = sut.begin(profile: .imuBurst, durationSeconds: 30,
                                 preconditions: ready(historyInFlight: true))
        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.rejection, .historyBusy)
        XCTAssertNil(decision.action)
        XCTAssertEqual(sut.phase, .idle)

        var active = started()
        XCTAssertFalse(active.permitsHistoryStart)
        active.noteValidatedImuFrame()
        _ = active.requestStop(reason: .user)
        _ = active.writeCompleted(succeeded: true)
        _ = active.writeCompleted(succeeded: true)
        _ = active.confirmProducerQuiescent()
        XCTAssertTrue(active.permitsHistoryStart)
    }

    func testDisconnectRequiresStopFirstRecoveryAndNeverRearms() {
        var sut = started()
        sut.disconnected()
        XCTAssertEqual(sut.phase, .producerUnknown)
        XCTAssertTrue(sut.cleanupRequired)
        XCTAssertEqual(sut.failure, .disconnected)

        XCTAssertEqual(sut.beginRecovery(preconditions: ready())?.opcode, 82)
        XCTAssertEqual(sut.writeCompleted(succeeded: true)?.opcode, 106)
        XCTAssertNil(sut.writeCompleted(succeeded: true))
        XCTAssertTrue(sut.confirmProducerQuiescent())
        XCTAssertEqual(sut.phase, .failed)
        XCTAssertFalse(sut.cleanupRequired)
        XCTAssertEqual(sut.failure, .disconnected)
    }

    func testProcessRelaunchRestoresOnlyStopFirstDebt() {
        var sut = SensorAcquisitionController()
        sut.restoreCleanupDebt()

        XCTAssertEqual(sut.phase, .producerUnknown)
        XCTAssertNil(sut.profile)
        XCTAssertTrue(sut.cleanupRequired)
        XCTAssertEqual(sut.begin(profile: .researchCapture, durationSeconds: 30,
                                 preconditions: ready()).rejection,
                       .alreadyActive)

        XCTAssertEqual(sut.beginRecovery(preconditions: ready())?.opcode, 82)
        XCTAssertEqual(sut.writeCompleted(succeeded: true)?.opcode, 106)
        XCTAssertNil(sut.writeCompleted(succeeded: true))
        XCTAssertTrue(sut.confirmProducerQuiescent())
        XCTAssertFalse(sut.cleanupRequired)
        XCTAssertEqual(sut.phase, .failed)
    }

    func testStopFailureRetriesImmediatelyOnSameAuthenticatedLink() {
        var sut = started()
        _ = sut.requestStop(reason: .background)
        XCTAssertEqual(sut.writeCompleted(succeeded: false)?.opcode, 106)
        XCTAssertEqual(sut.writeCompleted(succeeded: true)?.opcode, 82)
        XCTAssertEqual(sut.failure, .stopWriteFailed(opcode: 82))
        XCTAssertTrue(sut.cleanupRequired)
        XCTAssertEqual(sut.stopAttemptCount, 2)

        XCTAssertEqual(sut.writeCompleted(succeeded: true)?.opcode, 106)
        XCTAssertNil(sut.writeCompleted(succeeded: true))
        XCTAssertEqual(sut.phase, .awaitingQuiescence)
        XCTAssertTrue(sut.confirmProducerQuiescent())
        XCTAssertFalse(sut.cleanupRequired)
    }

    func testEvidenceFailureFailsClosedAndStopsProducer() {
        var sut = started()
        XCTAssertTrue(sut.requiresWireEvidence)
        sut.noteValidatedImuFrame()
        XCTAssertEqual(sut.evidencePersistenceFailed()?.opcode, 82)
        XCTAssertEqual(sut.writeCompleted(succeeded: true)?.opcode, 106)
        _ = sut.writeCompleted(succeeded: true)
        XCTAssertTrue(sut.confirmProducerQuiescent())
        XCTAssertEqual(sut.phase, .failed)
        XCTAssertEqual(sut.failure, .evidencePersistenceFailed)
        XCTAssertFalse(sut.requiresWireEvidence)
    }

    func testEvidenceFailureAtStopRetryCapLeavesProducerUnknownForReconnect() {
        var sut = started()
        sut.noteValidatedImuFrame()
        _ = sut.requestStop(reason: .user) // attempt 1
        _ = sut.writeCompleted(succeeded: true)
        _ = sut.writeCompleted(succeeded: true)
        for _ in 2...SensorAcquisitionController.maximumStopAttempts {
            _ = sut.producerStillEmittingAfterStop()
            _ = sut.writeCompleted(succeeded: true)
            _ = sut.writeCompleted(succeeded: true)
        }
        XCTAssertEqual(sut.phase, .awaitingQuiescence)
        XCTAssertEqual(sut.stopAttemptCount, SensorAcquisitionController.maximumStopAttempts)

        XCTAssertNil(sut.evidencePersistenceFailed())
        XCTAssertEqual(sut.phase, .producerUnknown)
        XCTAssertTrue(sut.cleanupRequired)
        XCTAssertEqual(sut.failure, .evidencePersistenceFailed)
    }

    func testCompletedProfileIsDiagnosticNotAnActiveEvidenceGate() {
        var sut = started()
        sut.noteValidatedImuFrame()
        _ = sut.requestStop(reason: .user)
        _ = sut.writeCompleted(succeeded: true)
        _ = sut.writeCompleted(succeeded: true)
        _ = sut.confirmProducerQuiescent()

        XCTAssertEqual(sut.profile, .imuBurst)
        XCTAssertEqual(sut.phase, .stopped)
        XCTAssertFalse(sut.requiresWireEvidence)
    }

    func testOpticalControlIsRejectedUntilAContractIsVerified() {
        var sut = SensorAcquisitionController()
        let decision = sut.begin(profile: .opticalBurst, durationSeconds: 30, preconditions: ready())
        XCTAssertEqual(decision.rejection, .unverifiedControlContract)
        XCTAssertNil(decision.action)
    }

    func testExplicitUserActionAndEncryptedBondAreMandatory() {
        var sut = SensorAcquisitionController()
        let notExplicit = SensorAcquisitionController.Preconditions(
            family: .whoop5, connected: true, commandChannelReady: true,
            encryptedBond: true, historyReady: true, historyInFlight: false,
            explicitUserInitiated: false)
        XCTAssertEqual(sut.begin(profile: .imuBurst, durationSeconds: 30,
                                 preconditions: notExplicit).rejection,
                       .explicitUserActionRequired)

        let unbonded = SensorAcquisitionController.Preconditions(
            family: .whoop5, connected: true, commandChannelReady: true,
            encryptedBond: false, historyReady: true, historyInFlight: false,
            explicitUserInitiated: true)
        XCTAssertEqual(sut.begin(profile: .imuBurst, durationSeconds: 30,
                                 preconditions: unbonded).rejection,
                       .encryptedBondRequired)
    }

    func testOutstandingConfirmedCommandBlocksAcquisition() {
        var sut = SensorAcquisitionController()
        let busy = SensorAcquisitionController.Preconditions(
            family: .whoop5, connected: true, commandChannelReady: true,
            encryptedBond: true, historyReady: true, historyInFlight: false,
            controlPlaneIdle: false, explicitUserInitiated: true)

        XCTAssertEqual(sut.begin(profile: .imuBurst, durationSeconds: 30,
                                 preconditions: busy).rejection,
                       .controlPlaneBusy)
        XCTAssertEqual(sut.phase, .idle)
    }

    func testWhoop4IsRejectedBecauseThisContractIsFiveMgOnly() {
        var sut = SensorAcquisitionController()
        let decision = sut.begin(profile: .imuBurst, durationSeconds: 30,
                                 preconditions: ready(family: .whoop4))
        XCTAssertEqual(decision.rejection, .unsupportedFamily)
        XCTAssertNil(decision.action)
        sut.restoreCleanupDebt()
        XCTAssertNil(sut.beginRecovery(preconditions: ready(family: .whoop4)))
    }

    func testContinuedDataAfterStopForcesAnotherStopBeforeDebtClears() {
        var sut = started()
        sut.noteValidatedImuFrame()
        _ = sut.requestStop(reason: .user)
        _ = sut.writeCompleted(succeeded: true)
        _ = sut.writeCompleted(succeeded: true)
        XCTAssertEqual(sut.phase, .awaitingQuiescence)

        XCTAssertFalse(sut.noteValidatedImuFrame())
        XCTAssertEqual(sut.producerStillEmittingAfterStop()?.opcode, 82)
        XCTAssertTrue(sut.cleanupRequired)
        XCTAssertEqual(sut.writeCompleted(succeeded: true)?.opcode, 106)
        _ = sut.writeCompleted(succeeded: true)
        XCTAssertEqual(sut.phase, .awaitingQuiescence)
        XCTAssertTrue(sut.confirmProducerQuiescent())
        XCTAssertFalse(sut.cleanupRequired)
        XCTAssertEqual(sut.phase, .stopped)
    }

    func testRepeatedStopWriteFailuresReachCapAndRemainProducerUnknown() {
        var sut = started()
        _ = sut.requestStop(reason: .user)
        for expectedAttempt in 1...SensorAcquisitionController.maximumStopAttempts {
            XCTAssertEqual(sut.stopAttemptCount, expectedAttempt)
            XCTAssertEqual(sut.writeCompleted(succeeded: false)?.opcode, 106)
            let next = sut.writeCompleted(succeeded: true)
            if expectedAttempt < SensorAcquisitionController.maximumStopAttempts {
                XCTAssertEqual(next?.opcode, 82)
            } else {
                XCTAssertNil(next)
            }
        }
        XCTAssertEqual(sut.phase, .producerUnknown)
        XCTAssertTrue(sut.cleanupRequired)
        XCTAssertEqual(sut.stopAttemptCount, SensorAcquisitionController.maximumStopAttempts)
    }

    func testContinuedProducerRetriesAreCapped() {
        var sut = started()
        sut.noteValidatedImuFrame()
        _ = sut.requestStop(reason: .user) // attempt 1
        _ = sut.writeCompleted(succeeded: true)
        _ = sut.writeCompleted(succeeded: true)

        for expectedAttempt in 2...SensorAcquisitionController.maximumStopAttempts {
            XCTAssertFalse(sut.noteValidatedImuFrame())
            XCTAssertEqual(sut.producerStillEmittingAfterStop()?.opcode, 82)
            XCTAssertEqual(sut.stopAttemptCount, expectedAttempt)
            _ = sut.writeCompleted(succeeded: true)
            _ = sut.writeCompleted(succeeded: true)
        }

        XCTAssertFalse(sut.noteValidatedImuFrame())
        XCTAssertNil(sut.producerStillEmittingAfterStop())
        XCTAssertEqual(sut.phase, .producerUnknown)
        XCTAssertTrue(sut.cleanupRequired)
        XCTAssertEqual(sut.stopAttemptCount, SensorAcquisitionController.maximumStopAttempts)
    }

    func testFirmwareRejectionIsNotConfusedWithAttCompletion() {
        var sut = started()
        let startOn = SensorAcquisitionController.Action(
            kind: .toggleImuOn, opcode: 106, payload: [1, 1])
        XCTAssertEqual(sut.noteFirmwareResponse(action: startOn, resultCode: 3)?.opcode, 82)
        XCTAssertEqual(sut.failure, .firmwareRejected(opcode: 106, resultCode: 3))
        XCTAssertTrue(sut.cleanupRequired)
        XCTAssertEqual(sut.writeCompleted(succeeded: true)?.opcode, 106)
        _ = sut.writeCompleted(succeeded: true)
        XCTAssertTrue(sut.confirmProducerQuiescent())
        XCTAssertEqual(sut.phase, .failed)
    }

    func testStopFirmwareRejectionRetriesAndSuccessResponseIsDiagnosticOnly() {
        var sut = started()
        sut.noteValidatedImuFrame()
        _ = sut.requestStop(reason: .background)
        _ = sut.writeCompleted(succeeded: true)
        let stopRaw = SensorAcquisitionController.Action(
            kind: .stopRawData, opcode: 82, payload: [1])
        _ = sut.noteFirmwareResponse(action: stopRaw, resultCode: 0)
        XCTAssertEqual(sut.writeCompleted(succeeded: true)?.opcode, 82)
        XCTAssertEqual(sut.stopAttemptCount, 2)
        XCTAssertEqual(sut.failure, .firmwareRejected(opcode: 82, resultCode: 0))
        XCTAssertNil(sut.noteFirmwareResponse(action: stopRaw, resultCode: 1))
    }

    func testDelayedStart106RejectionDoesNotMasqueradeAsStop106Rejection() {
        var sut = started()
        sut.noteValidatedImuFrame()
        _ = sut.requestStop(reason: .user)
        let delayedStart = SensorAcquisitionController.Action(
            kind: .toggleImuOn, opcode: 106, payload: [1, 1])
        XCTAssertNil(sut.noteFirmwareResponse(action: delayedStart, resultCode: 3))
        XCTAssertEqual(sut.writeCompleted(succeeded: true)?.kind, .toggleImuOff)
        XCTAssertNil(sut.writeCompleted(succeeded: true))
        XCTAssertEqual(sut.phase, .awaitingQuiescence)
        XCTAssertEqual(sut.stopAttemptCount, 1)
    }

    func testNonFiniteAndOverlongDurationsAreRejected() {
        for duration in [TimeInterval.nan, .infinity, -.infinity,
                         SensorAcquisitionController.maximumDurationSeconds + 1] {
            var sut = SensorAcquisitionController()
            XCTAssertEqual(sut.begin(profile: .imuBurst, durationSeconds: duration,
                                     preconditions: ready()).rejection,
                           .invalidDuration)
        }
    }

    func testAutomaticRecoveryLinksHaveAnIndependentHardCap() {
        var budget = SensorRecoveryLinkBudget(maximumAutomaticLinks: 3)
        XCTAssertTrue(budget.claimAutomaticLink())
        XCTAssertTrue(budget.claimAutomaticLink())
        XCTAssertTrue(budget.claimAutomaticLink())
        XCTAssertFalse(budget.claimAutomaticLink())
        XCTAssertEqual(budget.attemptedLinks, 3)
        budget.reset()
        XCTAssertTrue(budget.claimAutomaticLink())
        XCTAssertEqual(budget.attemptedLinks, 1)
    }

    private func started() -> SensorAcquisitionController {
        var sut = SensorAcquisitionController()
        _ = sut.begin(profile: .imuBurst, durationSeconds: 30, preconditions: ready())
        _ = sut.writeCompleted(succeeded: true)
        _ = sut.writeCompleted(succeeded: true)
        return sut
    }
}
