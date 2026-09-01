import AVFoundation
import Foundation
import PushToTalk
import UIKit

final class SystemPttCoordinator: NSObject, PTChannelManagerDelegate, PTChannelRestorationDelegate,
    @unchecked Sendable
{
    weak var owner: TalkModel?

    private let lock = NSLock()
    private var manager: PTChannelManager?
    private let cachedNamesKey = "app.ptt.talk.system-channel-names.v1"

    func start() async throws {
        if lock.withLock({ manager != nil }) { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PTChannelManager.channelManager(delegate: self, restorationDelegate: self) { [weak self] manager, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let self, let manager else {
                    continuation.resume(throwing: SystemPttError.managerUnavailable)
                    return
                }
                self.lock.withLock { self.manager = manager }
                if let restoredChannelId = manager.activeChannelUUID {
                    Task { @MainActor [weak owner = self.owner] in
                        owner?.systemPttDidJoin(restoredChannelId)
                    }
                }
                continuation.resume(returning: ())
            }
        }
    }

    func join(channelId: UUID, name: String) throws {
        guard let manager = lock.withLock({ manager }) else { throw SystemPttError.managerUnavailable }
        cache(name: name, for: channelId)
        manager.requestJoinChannel(
            channelUUID: channelId,
            descriptor: PTChannelDescriptor(name: name, image: nil)
        )
    }

    func leave(channelId: UUID) {
        lock.withLock { manager }?.leaveChannel(channelUUID: channelId)
    }

    func beginTransmitting(channelId: UUID) throws {
        guard let manager = lock.withLock({ manager }), manager.activeChannelUUID == channelId else {
            throw SystemPttError.channelNotJoined
        }
        manager.requestBeginTransmitting(channelUUID: channelId)
    }

    func stopTransmitting(channelId: UUID) {
        lock.withLock { manager }?.stopTransmitting(channelUUID: channelId)
    }

    func setRemoteParticipant(name: String?, channelId: UUID) {
        let participant = name.map { PTParticipant(name: $0, image: nil) }
        lock.withLock { manager }?.setActiveRemoteParticipant(
            participant,
            channelUUID: channelId,
            completionHandler: { [weak self] error in
                if let error { self?.report(error) }
            }
        )
    }

    func setReady(channelId: UUID) {
        lock.withLock { manager }?.setServiceStatus(.ready, channelUUID: channelId, completionHandler: nil)
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
        channelManager.setTransmissionMode(.halfDuplex, channelUUID: channelUUID, completionHandler: nil)
        if #available(iOS 17.0, *) {
            channelManager.setAccessoryButtonEventsEnabled(true, channelUUID: channelUUID, completionHandler: nil)
        }
        Task { @MainActor [weak owner] in owner?.systemPttDidJoin(channelUUID) }
    }

    func channelManager(
        _ channelManager: PTChannelManager,
        didLeaveChannel channelUUID: UUID,
        reason: PTChannelLeaveReason
    ) {
        Task { @MainActor [weak owner] in owner?.systemPttDidLeave(channelUUID) }
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
        report(error)
    }

    func channelManager(
        _ channelManager: PTChannelManager,
        failedToBeginTransmittingInChannel channelUUID: UUID,
        error: Error
    ) {
        report(error)
    }

    func channelManager(
        _ channelManager: PTChannelManager,
        failedToStopTransmittingInChannel channelUUID: UUID,
        error: Error
    ) {
        report(error)
    }

    private func report(_ error: Error) {
        Task { @MainActor [weak owner] in owner?.systemPttFailed(error.localizedDescription) }
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
