import AVFAudio
import CallKit
import Foundation
import PushKit

@MainActor
protocol SystemCallCoordinatorOwner: AnyObject {
    func systemCallReceivedVoipToken(_ token: Data) async
    func systemCallDidReceiveInvite(callId: UUID) async
    func systemCallDidAnswer(callId: UUID) async
    func systemCallDidEnd(callId: UUID) async
    func systemCallDidActivateAudio() async
    func systemCallDidDeactivateAudio() async
    func systemCallDidSetMuted(_ muted: Bool) async
}

/// Bridges PushKit and CallKit. Caller identity is intentionally never accepted from
/// the push payload; the UI starts with a generic label and resolves names through the
/// authenticated directory after the required immediate CallKit report.
final class SystemCallCoordinator: NSObject, PKPushRegistryDelegate, CXProviderDelegate, @unchecked Sendable {
    weak var owner: SystemCallCoordinatorOwner?

    private let queue = DispatchQueue(label: "app.ptt.talk.callkit")
    private let provider: CXProvider
    private let controller = CXCallController()
    private var registry: PKPushRegistry?
    private var voipToken: Data?

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: queue)
    }

    @MainActor
    func start() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    @MainActor
    func deliverCurrentToken() async {
        if let voipToken { await owner?.systemCallReceivedVoipToken(voipToken) }
    }

    func reportOutgoing(callId: UUID, displayName: String) async throws {
        let handle = CXHandle(type: .generic, value: displayName)
        try await controller.requestTransaction(with: CXStartCallAction(call: callId, handle: handle))
        provider.reportOutgoingCall(with: callId, startedConnectingAt: Date())
    }

    func reportConnected(callId: UUID) {
        provider.reportOutgoingCall(with: callId, connectedAt: Date())
    }

    func reportIncoming(callId: UUID) {
        let update = incomingUpdate()
        provider.reportNewIncomingCall(with: callId, update: update) { [weak self] error in
            guard error == nil else { return }
            Task { @MainActor in await self?.owner?.systemCallDidReceiveInvite(callId: callId) }
        }
    }

    func update(callId: UUID, displayName: String, participantCount: Int) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: displayName)
        update.localizedCallerName = displayName
        update.hasVideo = false
        update.supportsGrouping = participantCount < 8
        update.supportsUngrouping = false
        provider.reportCall(with: callId, updated: update)
    }

    func end(callId: UUID) async throws {
        try await controller.requestTransaction(with: CXEndCallAction(call: callId))
    }

    func answer(callId: UUID) async throws {
        try await controller.requestTransaction(with: CXAnswerCallAction(call: callId))
    }

    func setMuted(callId: UUID, muted: Bool) async throws {
        try await controller.requestTransaction(with: CXSetMutedCallAction(call: callId, muted: muted))
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        let token = pushCredentials.token
        Task { @MainActor [weak self] in
            self?.voipToken = token
            await self?.owner?.systemCallReceivedVoipToken(token)
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {}

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP,
              let version = payload.dictionaryPayload["protocolVersion"] as? String,
              version == "1",
              let rawCallId = payload.dictionaryPayload["callId"] as? String,
              let callId = UUID(uuidString: rawCallId),
              payload.dictionaryPayload["eventType"] as? String == "ringing" else {
            completion()
            return
        }
        provider.reportNewIncomingCall(with: callId, update: incomingUpdate()) { [weak self] error in
            completion()
            guard error == nil else { return }
            Task { @MainActor in await self?.owner?.systemCallDidReceiveInvite(callId: callId) }
        }
    }

    private nonisolated func incomingUpdate() -> CXCallUpdate {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Encrypted PTT Talk call")
        update.localizedCallerName = "PTT Talk"
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsDTMF = false
        update.supportsGrouping = true
        update.supportsUngrouping = false
        return update
    }

    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor [weak self] in await self?.owner?.systemCallDidDeactivateAudio() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        action.fulfill()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await owner?.systemCallDidAnswer(callId: action.callUUID)
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        Task { @MainActor [weak self] in
            await self?.owner?.systemCallDidEnd(callId: action.callUUID)
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor [weak self] in
            await self?.owner?.systemCallDidSetMuted(action.isMuted)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor [weak self] in await self?.owner?.systemCallDidActivateAudio() }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor [weak self] in await self?.owner?.systemCallDidDeactivateAudio() }
    }
}

private extension CXCallController {
    func requestTransaction(with action: CXAction) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            request(CXTransaction(action: action)) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
}
