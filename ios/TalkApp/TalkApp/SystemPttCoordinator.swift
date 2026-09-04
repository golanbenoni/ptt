import AVFoundation
import Foundation
import PttTalkLib
import PushToTalk
import UIKit

final class SystemPttCoordinator: NSObject, PTChannelManagerDelegate, PTChannelRestorationDelegate,
    @unchecked Sendable
{
    weak var owner: TalkModel?

    private let lock = NSLock()
    private var manager: PTChannelManager?
    private var pendingJoin: (channelId: UUID, name: String)?
    private var configuringChannelId: UUID?
    private var configuredChannelId: UUID?
    private var remoteParticipantGate = RemoteParticipantLifecycleGate()
    private let cachedNamesKey = "app.ptt.talk.system-channel-names.v1"

    func start() async throws {
        if lock.withLock({ manager != nil }) { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PTChannelManager.channelManager(delegate: self, restorationDelegate: self) { [weak self] manager, error in
                if let error {
                    continuation.resume(throwing: SystemPttOperationError(
                        operation: .managerStart, underlying: error
                    ))
                    return
                }
                guard let self, let manager else {
                    continuation.resume(throwing: SystemPttOperationError(
                        operation: .managerStart, underlying: SystemPttError.managerUnavailable
                    ))
                    return
                }
                self.lock.withLock { self.manager = manager }
                if let restoredChannelId = manager.activeChannelUUID {
                    self.configureJoinedChannel(manager: manager, channelId: restoredChannelId)
                }
                continuation.resume(returning: ())
            }
        }
    }

    func join(channelId: UUID, name: String) throws {
        let state = lock.withLock { (manager, pendingJoin) }
        guard let manager = state.0 else {
            throw SystemPttOperationError(operation: .join, underlying: SystemPttError.managerUnavailable)
        }
        if state.1?.channelId == channelId { return }
        cache(name: name, for: channelId)
        switch SystemChannelJoinPolicy.decision(
            activeChannelId: manager.activeChannelUUID,
            requestedChannelId: channelId
        ) {
        case .alreadyActive:
            lock.withLock { pendingJoin = nil }
            configureJoinedChannel(manager: manager, channelId: channelId)
        case .requestJoin:
            lock.withLock { pendingJoin = nil }
            requestJoin(manager: manager, channelId: channelId, name: name)
        case .replaceActive(let activeChannelId):
            let shouldRequestLeave = lock.withLock { () -> Bool in
                let shouldRequestLeave = pendingJoin == nil
                pendingJoin = (channelId, name)
                return shouldRequestLeave
            }
            if shouldRequestLeave { manager.leaveChannel(channelUUID: activeChannelId) }
        }
    }

    func leave(channelId: UUID) {
        let manager = lock.withLock { () -> PTChannelManager? in
            pendingJoin = nil
            configuringChannelId = nil
            configuredChannelId = nil
            return self.manager
        }
        manager?.leaveChannel(channelUUID: channelId)
    }

    func beginTransmitting(channelId: UUID) throws {
        guard let manager = lock.withLock({ manager }), manager.activeChannelUUID == channelId else {
            throw SystemPttOperationError(operation: .beginTransmission, underlying: SystemPttError.channelNotJoined)
        }
        manager.requestBeginTransmitting(channelUUID: channelId)
    }

    func stopTransmitting(channelId: UUID) {
        lock.withLock { manager }?.stopTransmitting(channelUUID: channelId)
    }

    func setRemoteParticipant(name: String?, channelId: UUID) {
        let participant = name.map { PTParticipant(name: $0, image: nil) }
        let currentManager = lock.withLock { () -> PTChannelManager? in
            guard let manager = self.manager else { return nil }
            guard remoteParticipantGate.shouldApply(name: name, channelId: channelId) else { return nil }
            return manager
        }
        currentManager?.setActiveRemoteParticipant(
            participant,
            channelUUID: channelId,
            completionHandler: { [weak self] error in
                guard let error else { return }
                if name != nil {
                    self?.lock.withLock {
                        self?.remoteParticipantGate.activeUpdateFailed(channelId: channelId)
                    }
                }
                let nsError = error as NSError
                if name == nil,
                   nsError.domain == PTChannelErrorDomain,
                   nsError.code == PTChannelError.transmissionNotFound.rawValue {
                    return
                }
                self?.report(error, operation: .remoteParticipant)
            }
        )
    }

    func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
#if DEBUG
        writeRestorationMarker()
#endif
        return PTChannelDescriptor(name: cachedName(for: channelUUID) ?? "PTT Talk", image: nil)
    }

    func channelManager(
        _ channelManager: PTChannelManager,
        didJoinChannel channelUUID: UUID,
        reason: PTChannelJoinReason
    ) {
        configureJoinedChannel(manager: channelManager, channelId: channelUUID)
    }

    func channelManager(
        _ channelManager: PTChannelManager,
        didLeaveChannel channelUUID: UUID,
        reason: PTChannelLeaveReason
    ) {
        let replacement = lock.withLock { () -> (channelId: UUID, name: String)? in
            remoteParticipantGate.activeUpdateFailed(channelId: channelUUID)
            if configuringChannelId == channelUUID { configuringChannelId = nil }
            if configuredChannelId == channelUUID { configuredChannelId = nil }
            defer { pendingJoin = nil }
            return pendingJoin
        }
        Task { @MainActor [weak owner] in owner?.systemPttDidLeave(channelUUID) }
        if let replacement {
            requestJoin(manager: channelManager, channelId: replacement.channelId, name: replacement.name)
        }
    }

    func channelManager(
        _ channelManager: PTChannelManager,
        channelUUID: UUID,
        didBeginTransmittingFrom source: PTChannelTransmitRequestSource
    ) {
        Task { @MainActor [weak owner] in owner?.systemPttDidBeginTransmitting(channelUUID) }
    }

    func channelManager(
        _ channelManager: PTChannelManager,
        channelUUID: UUID,
        didEndTransmittingFrom source: PTChannelTransmitRequestSource
    ) {
        Task { @MainActor [weak owner] in owner?.systemPttDidEndTransmitting(channelUUID) }
    }

    func channelManager(_ channelManager: PTChannelManager, receivedEphemeralPushToken pushToken: Data) {
        let channelId = channelManager.activeChannelUUID
        Task { @MainActor [weak owner] in
            await owner?.systemPttReceived(pushToken: pushToken, channelId: channelId)
        }
    }

    func incomingPushResult(
        channelManager: PTChannelManager,
        channelUUID: UUID,
        pushPayload: [String: Any]
    ) -> PTPushResult {
#if DEBUG
        writeMarker(name: "incoming-push-state", value: "received")
#endif
        Task { @MainActor [weak owner] in owner?.systemPttReceivedIncomingPush(channelUUID) }
        return .activeRemoteParticipant(PTParticipant(name: "Encrypted teammate", image: nil))
    }

    func channelManager(_ channelManager: PTChannelManager, didActivate audioSession: AVAudioSession) {
#if DEBUG
        writeMarker(name: "push-audio-activation-state", value: "activated")
#endif
        Task { @MainActor [weak owner] in owner?.systemPttDidActivate(audioSession) }
    }

    func channelManager(_ channelManager: PTChannelManager, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor [weak owner] in owner?.systemPttDidDeactivate() }
    }

    func channelManager(_ channelManager: PTChannelManager, failedToJoinChannel channelUUID: UUID, error: Error) {
        lock.withLock { pendingJoin = nil }
        report(error, operation: .join)
    }

    func channelManager(_ channelManager: PTChannelManager, failedToLeaveChannel channelUUID: UUID, error: Error) {
        lock.withLock { pendingJoin = nil }
        report(error, operation: .leave)
    }

    func channelManager(
        _ channelManager: PTChannelManager,
        failedToBeginTransmittingInChannel channelUUID: UUID,
        error: Error
    ) {
        report(error, operation: .beginTransmission)
    }

    func channelManager(
        _ channelManager: PTChannelManager,
        failedToStopTransmittingInChannel channelUUID: UUID,
        error: Error
    ) {
        let nsError = error as NSError
        if nsError.domain == PTChannelErrorDomain,
           nsError.code == PTChannelError.transmissionNotFound.rawValue {
            // The system can finish a transmission while an app stop request
            // is in flight. Treat that idempotently as an ended transmission.
            Task { @MainActor [weak owner] in owner?.systemPttDidEndTransmitting(channelUUID) }
            return
        }
        report(error, operation: .stopTransmission)
    }

    private func report(_ error: Error, operation: SystemPttOperation) {
        let contextualError = SystemPttOperationError(operation: operation, underlying: error)
        Task { @MainActor [weak owner] in owner?.systemPttFailed(contextualError) }
    }

    private func requestJoin(manager: PTChannelManager, channelId: UUID, name: String) {
        manager.requestJoinChannel(
            channelUUID: channelId,
            descriptor: PTChannelDescriptor(name: name, image: nil)
        )
    }

    /// Apple accepts channel operations asynchronously. Do not expose the
    /// channel as ready to the UI until the system has confirmed every setup
    /// operation; otherwise a fast first press can race channel activation and
    /// fail with the unhelpful PTChannelErrorUnknown error.
    private func configureJoinedChannel(manager: PTChannelManager, channelId: UUID) {
        enum Decision { case configure, alreadyReady, wait }
        let decision = lock.withLock { () -> Decision in
            if configuredChannelId == channelId { return .alreadyReady }
            if configuringChannelId == channelId { return .wait }
            configuringChannelId = channelId
            configuredChannelId = nil
            return .configure
        }
        switch decision {
        case .alreadyReady:
            announceJoined(channelId)
        case .wait:
            return
        case .configure:
            runSetupStep(.confirmHalfDuplex, manager: manager, channelId: channelId)
        }
    }

    private func runSetupStep(
        _ step: SystemChannelReadinessStep,
        manager: PTChannelManager,
        channelId: UUID
    ) {
        guard manager.activeChannelUUID == channelId else {
            failSetup(SystemPttError.channelNotJoined, operation: .configureChannel, channelId: channelId)
            return
        }
        let completion: (Error?) -> Void = { [weak self, weak manager] error in
            guard let self, let manager else { return }
            if let error {
                self.failSetup(error, operation: step.operation, channelId: channelId)
                return
            }
            self.advanceSetup(after: step, manager: manager, channelId: channelId)
        }
        switch step {
        case .confirmHalfDuplex:
            manager.setTransmissionMode(.halfDuplex, channelUUID: channelId, completionHandler: completion)
        case .confirmServiceReady:
            manager.setServiceStatus(.ready, channelUUID: channelId, completionHandler: completion)
        case .confirmAccessoryEvents:
            if #available(iOS 17.0, *) {
                manager.setAccessoryButtonEventsEnabled(
                    true, channelUUID: channelId, completionHandler: completion
                )
            } else {
                completion(nil)
            }
        }
    }

    private func advanceSetup(
        after step: SystemChannelReadinessStep,
        manager: PTChannelManager,
        channelId: UUID
    ) {
        guard lock.withLock({ configuringChannelId == channelId }) else { return }
        if let next = SystemChannelReadinessPolicy.step(after: step) {
            runSetupStep(next, manager: manager, channelId: channelId)
            return
        }
        lock.withLock {
            configuringChannelId = nil
            configuredChannelId = channelId
            remoteParticipantGate.activeUpdateFailed(channelId: channelId)
        }
        announceJoined(channelId)
    }

    private func failSetup(_ error: Error, operation: SystemPttOperation, channelId: UUID) {
        lock.withLock {
            if configuringChannelId == channelId { configuringChannelId = nil }
            if configuredChannelId == channelId { configuredChannelId = nil }
        }
        report(error, operation: operation)
    }

    private func announceJoined(_ channelId: UUID) {
        Task { @MainActor [weak owner] in owner?.systemPttDidJoin(channelId) }
    }

    private func cache(name: String, for channelId: UUID) {
        var values = UserDefaults.standard.dictionary(forKey: cachedNamesKey) as? [String: String] ?? [:]
        values[channelId.uuidString.lowercased()] = name
        UserDefaults.standard.set(values, forKey: cachedNamesKey)
    }

    private func cachedName(for channelId: UUID) -> String? {
        (UserDefaults.standard.dictionary(forKey: cachedNamesKey) as? [String: String])?[
            channelId.uuidString.lowercased()
        ]
    }

#if DEBUG
    private func writeRestorationMarker() {
        writeMarker(name: "system-restoration-state", value: "pass")
    }

    private func writeMarker(name: String, value: String) {
        guard name.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? Data(value.utf8).write(
            to: documents.appendingPathComponent("ptt-e2e-\(name).txt"), options: .atomic
        )
    }
#endif
}

enum SystemPttOperation: String {
    case managerStart = "manager-start"
    case join
    case leave
    case configureChannel = "configure-channel"
    case confirmHalfDuplex = "confirm-half-duplex"
    case confirmServiceReady = "confirm-service-ready"
    case configureAccessory = "configure-accessory"
    case beginTransmission = "begin-transmission"
    case stopTransmission = "stop-transmission"
    case remoteParticipant = "remote-participant"
}

struct SystemPttOperationError: LocalizedError {
    let operation: SystemPttOperation
    let underlying: Error

    var errorDescription: String? {
        "Apple Push to Talk \(operation.rawValue) failed: \(underlying.localizedDescription)"
    }
}

private extension SystemChannelReadinessStep {
    var operation: SystemPttOperation {
        switch self {
        case .confirmHalfDuplex: .confirmHalfDuplex
        case .confirmServiceReady: .confirmServiceReady
        case .confirmAccessoryEvents: .configureAccessory
        }
    }
}

private enum SystemPttError: LocalizedError {
    case managerUnavailable
    case channelNotJoined

    var errorDescription: String? {
        switch self {
        case .managerUnavailable: "The iOS Push to Talk service is unavailable."
        case .channelNotJoined: "Join the selected system Push to Talk channel first."
        }
    }
}
