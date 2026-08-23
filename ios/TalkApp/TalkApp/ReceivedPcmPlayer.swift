import AVFoundation
import Combine
import Foundation

@MainActor
final class ReceivedPcmPlayer: ObservableObject {
    private static let sampleRate = 16_000.0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    init() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            preconditionFailure("Unable to create the received-audio format")
        }
        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(_ pcm: Data) throws {
        guard !pcm.isEmpty else {
            throw ReceivedAudioError.emptyPcm
        }
        guard pcm.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw ReceivedAudioError.misalignedPcm
        }

        let frameCount = AVAudioFrameCount(pcm.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.int16ChannelData?.pointee else {
            throw ReceivedAudioError.bufferAllocationFailed
        }
        buffer.frameLength = frameCount
        pcm.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            memcpy(samples, source, pcm.count)
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)

        player.stop()
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        player.scheduleBuffer(buffer)
        player.play()
    }
}

private enum ReceivedAudioError: LocalizedError {
    case emptyPcm
    case misalignedPcm
    case bufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .emptyPcm: "received no PCM samples"
        case .misalignedPcm: "received an incomplete PCM sample"
        case .bufferAllocationFailed: "could not allocate an audio buffer"
        }
    }
}
