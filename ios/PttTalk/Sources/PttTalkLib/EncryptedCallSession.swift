import CryptoKit
import Foundation
import LiveKit
@preconcurrency import AVFoundation

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

public struct CallAudioToneDiagnosticSnapshot: Equatable, Sendable {
    public let toneBurstCount: Int
    public let peakRms: Double
    public let peakCorrelation: Double
    public let formatLabel: String

    static let disabled = CallAudioToneDiagnosticSnapshot(
        toneBurstCount: 0, peakRms: 0, peakCorrelation: 0, formatLabel: "DISABLED"
    )
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
#if DEBUG
    private var captureDiagnostic: CallAudioToneObserver?
    private var renderDiagnostic: CallAudioToneObserver?
#endif

    public init(
        callId: String,
        epoch: Int,
        localParticipantIdentity: String,
        diagnoseAudio: Bool = false
    ) throws {
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
#if DEBUG
        if diagnoseAudio {
            let capture = CallAudioToneObserver(label: "capture")
            let render = CallAudioToneObserver(label: "render")
            captureDiagnostic = capture
            renderDiagnostic = render
            AudioManager.shared.add(localAudioRenderer: capture)
            AudioManager.shared.add(remoteAudioRenderer: render)
        }
#else
        _ = diagnoseAudio
#endif
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

    /// Establish the ciphertext transport while microphone publication and playback remain muted.
    public func prepareTransport(serverUrl: String, token: String) async throws {
        guard state == .idle else { throw EncryptedCallMediaError.callAlreadyActive }
        state = .connecting
        do {
            try await room.connect(url: serverUrl, token: token)
            // A connected SFU is not media authorization. Frames continue to fail closed until
            // every exact-epoch key acknowledgement has arrived over the Double Ratchet path.
            state = .securing
        } catch {
            state = .failed("Unable to establish encrypted call media.")
            throw error
        }
    }

    public func completeInitialSecurity(requiredParticipantAcknowledgements: Set<String>) async throws {
        guard state == .securing else { throw EncryptedCallMediaError.callAlreadyActive }
        guard requiredParticipantAcknowledgements.isSubset(of: acknowledgedParticipants) else {
            throw EncryptedCallMediaError.missingKeyAcknowledgement
        }
        state = .connected
        if audioActivated { try await setMuted(false) }
    }

    public func connect(
        serverUrl: String,
        token: String,
        requiredParticipantAcknowledgements: Set<String>
    ) async throws {
        try await prepareTransport(serverUrl: serverUrl, token: token)
        try await completeInitialSecurity(
            requiredParticipantAcknowledgements: requiredParticipantAcknowledgements
        )
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

    public var captureDiagnosticSnapshot: CallAudioToneDiagnosticSnapshot {
#if DEBUG
        captureDiagnostic?.snapshot ?? .disabled
#else
        .disabled
#endif
    }

    public var renderDiagnosticSnapshot: CallAudioToneDiagnosticSnapshot {
#if DEBUG
        renderDiagnostic?.snapshot ?? .disabled
#else
        .disabled
#endif
    }

    public func disconnect() async {
        try? await setMuted(true)
        await room.disconnect()
#if DEBUG
        if let captureDiagnostic {
            AudioManager.shared.remove(localAudioRenderer: captureDiagnostic)
        }
        if let renderDiagnostic {
            AudioManager.shared.remove(remoteAudioRenderer: renderDiagnostic)
        }
        captureDiagnostic = nil
        renderDiagnostic = nil
#endif
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

/// Debug-only observers are attached by the app's physical harness. They inspect
/// LiveKit PCM without retaining or modifying it and never log audio samples.
#if DEBUG
final class CallAudioToneObserver: NSObject, AudioRenderer, @unchecked Sendable {
    private struct State {
        var sampleRate = 48_000
        var channels = 1
        var toneActive = false
        var silentFrames = 28_800
        var toneBurstCount = 0
        var peakRms = 0.0
        var peakCorrelation = 0.0
        var formatLabel = "WAITING"
    }

    private let label: String
    private let lock = NSLock()
    private var state = State()

    init(label: String) {
        self.label = label
    }

    var snapshot: CallAudioToneDiagnosticSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return CallAudioToneDiagnosticSnapshot(
            toneBurstCount: state.toneBurstCount,
            peakRms: state.peakRms,
            peakCorrelation: state.peakCorrelation,
            formatLabel: state.formatLabel
        )
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let frameCount = Int(pcmBuffer.frameLength)
        let channels = Int(pcmBuffer.format.channelCount)
        let sampleRate = Int(pcmBuffer.format.sampleRate.rounded())
        guard frameCount > 0, channels > 0, sampleRate > 0,
              pcmBuffer.format.commonFormat == .pcmFormatInt16,
              let channelData = pcmBuffer.int16ChannelData else { return }
        let stride = Int(pcmBuffer.stride)
        var sumSquares = 0.0
        var real = 0.0
        var imaginary = 0.0
        for frame in 0..<frameCount {
            let value = Double(channelData[0][frame * stride])
            let phase = Double(frame) * 2.0 * Double.pi * 997.0 / Double(sampleRate)
            sumSquares += value * value
            real += value * cos(phase)
            imaginary -= value * sin(phase)
        }
        let rms = sqrt(sumSquares / Double(frameCount))
        let correlation = rms > 0
            ? sqrt(real * real + imaginary * imaginary) / (Double(frameCount) * rms)
            : 0
        let detected = rms >= 300 && correlation >= 0.55

        lock.lock()
        defer { lock.unlock() }
        if state.sampleRate != sampleRate || state.channels != channels {
            state = State(
                sampleRate: sampleRate,
                channels: channels,
                silentFrames: sampleRate * 600 / 1_000
            )
        }
        state.formatLabel = "\(sampleRate)hz-\(channels)ch-int16-\(frameCount)frames-\(label)"
        state.peakRms = max(state.peakRms, rms)
        state.peakCorrelation = max(state.peakCorrelation, correlation)
        let minimumGapFrames = sampleRate * 600 / 1_000
        if detected {
            if !state.toneActive, state.silentFrames >= minimumGapFrames {
                state.toneBurstCount += 1
            }
            state.toneActive = true
            state.silentFrames = 0
        } else {
            state.silentFrames += frameCount
            if state.silentFrames >= minimumGapFrames { state.toneActive = false }
        }
    }
}
#endif
