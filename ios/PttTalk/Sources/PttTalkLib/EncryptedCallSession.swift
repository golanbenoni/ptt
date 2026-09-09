import CryptoKit
import Foundation
import LiveKit
#if os(iOS)
import AVFAudio
#endif

public enum EncryptedCallMediaState: Equatable, Sendable {
    case idle
    case securing
    case connecting
    case connected
    case ended
    case failed(String)
}

public enum EncryptedCallMediaError: Error, Equatable {
    case invalidKey
    case missingKeyAcknowledgement
    case staleEpoch
    case callAlreadyActive
}

/// Owns one LiveKit room while deliberately leaving AVAudioSession ownership to CallKit.
/// Frames are discarded until participant-specific keys have been installed and acknowledged.
@MainActor
public final class EncryptedCallSession: ObservableObject {
    @Published public private(set) var state: EncryptedCallMediaState = .idle
    @Published public private(set) var isMuted = true

    public let callId: String
    public private(set) var epoch: Int
    public let localParticipantIdentity: String
    public private(set) var outboundKey: Data

    private let keyProvider: BaseKeyProvider
    private let room: Room
    private var acknowledgedParticipants = Set<String>()
    private var audioActivated = false
    private var resumeMutedAfterRotation = false

    public init(callId: String, epoch: Int, localParticipantIdentity: String) throws {
        guard UUID(uuidString: callId) != nil, epoch > 0, !localParticipantIdentity.isEmpty else {
            throw EncryptedCallMediaError.invalidKey
        }
        self.callId = callId
        self.epoch = epoch
        self.localParticipantIdentity = localParticipantIdentity
        self.outboundKey = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })

        let provider = BaseKeyProvider(options: KeyProviderOptions(
            sharedKey: false,
            discardFrameWhenCryptorNotReady: true,
            keyDerivationAlgorithm: .hkdf
        ))
        self.keyProvider = provider
        self.room = Room(roomOptions: RoomOptions(
            encryptionOptions: EncryptionOptions(keyProvider: provider, encryptionType: .gcm),
            singlePeerConnection: true
        ))
#if os(iOS)
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
#endif
        provider.setKey(
            keyData: Self.frameKey(
                material: outboundKey,
                callId: callId,
                epoch: epoch,
                participantIdentity: localParticipantIdentity
            ),
            participantId: localParticipantIdentity,
            index: Int32(epoch % 16)
        )
    }

    public func installParticipantKey(
        _ key: Data,
        participantIdentity: String,
        epoch announcedEpoch: Int
    ) throws {
        guard key.count == 32, !participantIdentity.isEmpty else {
            throw EncryptedCallMediaError.invalidKey
        }
        guard announcedEpoch == epoch else { throw EncryptedCallMediaError.staleEpoch }
        keyProvider.setKey(
            keyData: Self.frameKey(
                material: key,
                callId: callId,
                epoch: epoch,
                participantIdentity: participantIdentity
            ),
            participantId: participantIdentity,
            index: Int32(epoch % 16)
        )
    }

    public func acknowledgeParticipantKey(participantIdentity: String, epoch acknowledgedEpoch: Int) throws {
        guard acknowledgedEpoch == epoch else { throw EncryptedCallMediaError.staleEpoch }
        acknowledgedParticipants.insert(participantIdentity)
    }

    public func rotate(to newEpoch: Int) async throws {
        guard newEpoch > epoch else { throw EncryptedCallMediaError.staleEpoch }
        resumeMutedAfterRotation = isMuted
        if state == .connected { try await room.localParticipant.setMicrophone(enabled: false) }
        isMuted = true
        state = .securing
        epoch = newEpoch
        outboundKey = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        acknowledgedParticipants.removeAll()
        keyProvider.setKey(
            keyData: Self.frameKey(
                material: outboundKey,
                callId: callId,
                epoch: newEpoch,
                participantIdentity: localParticipantIdentity
            ),
            participantId: localParticipantIdentity,
            index: Int32(newEpoch % 16)
        )
    }

    public func completeRotation(requiredParticipantAcknowledgements: Set<String>) async throws {
        guard requiredParticipantAcknowledgements.isSubset(of: acknowledgedParticipants) else {
            throw EncryptedCallMediaError.missingKeyAcknowledgement
        }
        state = .connected
        if audioActivated { try await setMuted(resumeMutedAfterRotation) }
    }

    /// Connect only after the application-layer Double Ratchet exchange has completed.
    public func connect(
        serverUrl: String,
        token: String,
        requiredParticipantAcknowledgements: Set<String>
    ) async throws {
        guard state == .idle || state == .securing else { throw EncryptedCallMediaError.callAlreadyActive }
        state = .securing
        guard requiredParticipantAcknowledgements.isSubset(of: acknowledgedParticipants) else {
            throw EncryptedCallMediaError.missingKeyAcknowledgement
        }
        state = .connecting
        do {
            try await room.connect(url: serverUrl, token: token)
            state = .connected
            if audioActivated { try await setMuted(false) }
        } catch {
            state = .failed("Unable to establish encrypted call media.")
            throw error
        }
    }

    /// Call from CXProviderDelegate.provider(_:didActivate:) only.
    public func activateAudio() async throws {
        audioActivated = true
#if os(iOS)
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowAirPlay])
#endif
        if state == .connected { try await setMuted(false) }
    }

    /// Call from CXProviderDelegate.provider(_:didDeactivate:) before another audio graph takes ownership.
    public func deactivateAudio() async {
        audioActivated = false
        try? await setMuted(true)
    }

    public func setMuted(_ muted: Bool) async throws {
        guard state == .connected || muted else { return }
        try await room.localParticipant.setMicrophone(enabled: !muted)
        isMuted = muted
    }

    public var activeSpeakerIdentities: [String] {
        room.activeSpeakers.compactMap { $0.identity?.stringValue }
    }

    public var connectionQualityLabel: String {
        switch room.localParticipant.connectionQuality {
        case .excellent: "Excellent"
        case .good: "Good"
        case .poor: "Poor"
        case .lost: "Reconnecting"
        case .unknown: "Checking"
        @unknown default: "Checking"
        }
    }

    public func disconnect() async {
        try? await setMuted(true)
        await room.disconnect()
        audioActivated = false
        acknowledgedParticipants.removeAll()
        state = .ended
    }

    nonisolated static func frameKey(material: Data, callId: String, epoch: Int, participantIdentity: String) -> Data {
        let input = SymmetricKey(data: material)
        let salt = Data(callId.utf8)
        let info = Data("ptt-talk-call-v1|\(epoch)|\(participantIdentity)".utf8)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: info, outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }
}
