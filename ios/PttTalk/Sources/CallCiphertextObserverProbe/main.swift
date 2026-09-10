import AVFoundation
import Foundation
import LiveKit

private final class UnauthorizedObserver: NSObject, RoomDelegate, AudioRenderer, @unchecked Sendable {
    private struct State {
        var audioTrackIds = Set<String>()
        var failureTrackIds = Set<String>()
        var cryptorStates = Set<String>()
        var renderedFrames = 0
        var nonSilentFrames = 0
        var peakRms = 0.0
    }

    private let keyProvider: BaseKeyProvider
    private let lock = NSLock()
    private var state = State()

    init(keyProvider: BaseKeyProvider) {
        self.keyProvider = keyProvider
    }

    func room(
        _: Room,
        participant: RemoteParticipant,
        didSubscribeTrack publication: RemoteTrackPublication
    ) {
        guard publication.source == .microphone,
              let track = publication.track as? RemoteAudioTrack,
              let identity = participant.identity?.stringValue else { return }
        for index in 0..<16 {
            keyProvider.setKey(
                keyData: Data(repeating: UInt8(index + 1), count: 32),
                participantId: identity,
                index: Int32(index)
            )
        }
        _ = lock.withLock { state.audioTrackIds.insert(publication.sid.stringValue) }
        track.add(audioRenderer: self)
    }

    func room(
        _: Room,
        trackPublication publication: TrackPublication,
        didUpdateE2EEState encryptionState: E2EEState
    ) {
        lock.withLock {
            state.cryptorStates.insert(encryptionState.toString())
            if encryptionState == .missing_key || encryptionState == .decryption_failed {
                state.failureTrackIds.insert(publication.sid.stringValue)
            }
        }
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let frameCount = Int(pcmBuffer.frameLength)
        let channels = Int(pcmBuffer.format.channelCount)
        guard frameCount > 0, channels > 0 else { return }

        var sumSquares = 0.0
        switch pcmBuffer.format.commonFormat {
        case .pcmFormatInt16:
            guard let samples = pcmBuffer.int16ChannelData else { return }
            let stride = Int(pcmBuffer.stride)
            for frame in 0..<frameCount {
                let value = Double(samples[0][frame * stride])
                sumSquares += value * value
            }
        case .pcmFormatFloat32:
            guard let samples = pcmBuffer.floatChannelData else { return }
            let stride = Int(pcmBuffer.stride)
            for frame in 0..<frameCount {
                let value = Double(samples[0][frame * stride]) * Double(Int16.max)
                sumSquares += value * value
            }
        default:
            return
        }

        let rms = sqrt(sumSquares / Double(frameCount))
        lock.withLock {
            state.renderedFrames += frameCount
            state.peakRms = max(state.peakRms, rms)
            if rms >= 100 { state.nonSilentFrames += frameCount }
        }
    }

    func snapshot() -> (
        tracks: Int,
        failures: Int,
        rendered: Int,
        nonSilent: Int,
        peakRms: Double,
        states: [String]
    ) {
        lock.withLock {
            (
                state.audioTrackIds.count,
                state.failureTrackIds.count,
                state.renderedFrames,
                state.nonSilentFrames,
                state.peakRms,
                state.cryptorStates.sorted()
            )
        }
    }
}

@main
private enum CallCiphertextObserverProbe {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["PTT_OBSERVER_LIVEKIT_URL"],
              let token = environment["PTT_OBSERVER_LIVEKIT_TOKEN"],
              let expectedText = environment["PTT_OBSERVER_EXPECTED_TRACKS"],
              let expectedTracks = Int(expectedText), expectedTracks >= 1, expectedTracks <= 8,
              let durationText = environment["PTT_OBSERVER_DURATION_SECONDS"],
              let duration = Int(durationText), duration >= 3, duration <= 30 else {
            fputs("The observer probe requires a LiveKit URL, token, expected track count, and 3-30 second duration.\n", stderr)
            exit(2)
        }

        let provider = BaseKeyProvider(options: KeyProviderOptions(
            sharedKey: false,
            failureTolerance: 0,
            discardFrameWhenCryptorNotReady: true,
            keyDerivationAlgorithm: .hkdf
        ))
        let observer = UnauthorizedObserver(keyProvider: provider)
        let room = Room(
            delegate: observer,
            roomOptions: RoomOptions(
                encryptionOptions: EncryptionOptions(keyProvider: provider, encryptionType: .gcm),
                singlePeerConnection: true
            )
        )

        do {
            try await room.connect(url: url, token: token)
            try await Task.sleep(for: .seconds(duration))
            await room.disconnect()
        } catch {
            fputs("The unauthorized observer could not complete its bounded subscription.\n", stderr)
            exit(3)
        }

        let result = observer.snapshot()
        let json: [String: Any] = [
            "subscribedMicrophoneTracks": result.tracks,
            "failedDecryptions": result.failures,
            "renderedFrames": result.rendered,
            "nonSilentFrames": result.nonSilent,
            "peakRms": result.peakRms,
            "cryptorStates": result.states,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }

        guard result.tracks == expectedTracks else {
            fputs("The observer did not subscribe to every expected encrypted microphone track.\n", stderr)
            exit(4)
        }
        guard result.failures == expectedTracks else {
            fputs("The observer did not observe a decryption failure for every encrypted track.\n", stderr)
            exit(5)
        }
        guard result.nonSilent == 0 else {
            fputs("An unauthorized observer rendered non-silent PCM.\n", stderr)
            exit(6)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
