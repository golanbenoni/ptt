import AVFoundation
import Foundation
import PttTalkLib

final class IOSVoiceAudioEngine: VoiceAudioIO, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let voiceFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var accumulator: [Int16] = []
    private var onFrame: (@Sendable ([Int16]) -> Void)?
    private var tapInstalled = false
    private var queuedPlaybackFrames = 0
    private var simulatorCaptureTask: Task<Void, Never>?
    private let systemManagesAudioSession: Bool

    init(systemManagesAudioSession: Bool = false) {
        self.systemManagesAudioSession = systemManagesAudioSession
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: voiceSampleRate,
            channels: 1,
            interleaved: false
        ) else { preconditionFailure("Unable to create the PTT voice format") }
        voiceFormat = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func startCapture(onFrame: @escaping @Sendable ([Int16]) -> Void) throws {
        try lock.withLock {
            guard !tapInstalled, simulatorCaptureTask == nil else {
                throw VoiceAudioError.captureAlreadyRunning
            }
            let session = AVAudioSession.sharedInstance()
            try configure(session)
            if !systemManagesAudioSession {
                try session.setActive(true)
            }

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  let converter = AVAudioConverter(from: inputFormat, to: voiceFormat) else {
#if targetEnvironment(simulator)
                startSimulatorCapture(onFrame: onFrame)
                return
#else
                throw VoiceAudioError.inputUnavailable
#endif
            }
            self.converter = converter
            self.onFrame = onFrame
            accumulator.removeAll(keepingCapacity: true)
            input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(voiceSamplesPerFrame), format: inputFormat) {
                [weak self] buffer, _ in
                self?.consume(buffer)
            }
            tapInstalled = true
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        }
    }

    func stopCapture() {
        lock.withLock {
            if let simulatorCaptureTask {
                simulatorCaptureTask.cancel()
                self.simulatorCaptureTask = nil
                onFrame = nil
                accumulator.removeAll(keepingCapacity: false)
                return
            }
            guard tapInstalled else { return }
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            converter = nil
            onFrame = nil
            accumulator.removeAll(keepingCapacity: false)
        }
    }

#if targetEnvironment(simulator)
    private func startSimulatorCapture(onFrame: @escaping @Sendable ([Int16]) -> Void) {
        self.onFrame = onFrame
        let frame = [Int16](repeating: 0, count: voiceSamplesPerFrame)
        simulatorCaptureTask = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                onFrame(frame)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }
#endif

    func play(_ pcm: [Int16]) throws {
        guard pcm.count == voiceSamplesPerFrame else { throw VoiceAudioError.invalidPlaybackFrame }
        try lock.withLock {
            let session = AVAudioSession.sharedInstance()
            if !engine.isRunning {
                queuedPlaybackFrames = 0
                try configure(session)
                if !systemManagesAudioSession {
                    try session.setActive(true)
                    engine.prepare()
                    try engine.start()
                }
            }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: voiceFormat,
                frameCapacity: AVAudioFrameCount(pcm.count)
            ), let output = buffer.int16ChannelData?.pointee else {
                throw VoiceAudioError.bufferAllocationFailed
            }
            buffer.frameLength = AVAudioFrameCount(pcm.count)
            pcm.withUnsafeBufferPointer { source in
                output.update(from: source.baseAddress!, count: pcm.count)
            }
            if !player.isPlaying { queuedPlaybackFrames = 0 }
            queuedPlaybackFrames += 1
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.lock.withLock {
                    guard let self else { return }
                    self.queuedPlaybackFrames = max(0, self.queuedPlaybackFrames - 1)
                }
            }
            if engine.isRunning && !player.isPlaying { player.play() }
        }
    }

    func queuedPlaybackFrameCount() -> Int {
        lock.withLock {
            guard engine.isRunning, player.isPlaying else { return 0 }
            return queuedPlaybackFrames
        }
    }

    func systemDidActivate(_ session: AVAudioSession) throws {
        try lock.withLock {
            try configure(session)
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            if !player.isPlaying { player.play() }
        }
    }

    func systemDidDeactivate() {
        lock.withLock {
            queuedPlaybackFrames = 0
            player.stop()
            engine.stop()
        }
    }

    private func consume(_ input: AVAudioPCMBuffer) {
        lock.withLock {
            guard tapInstalled, let converter, let onFrame else { return }
            let ratio = voiceSampleRate / input.format.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 8)
            guard let converted = AVAudioPCMBuffer(pcmFormat: voiceFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, state in
                if supplied {
                    state.pointee = .noDataNow
                    return nil
                }
                supplied = true
                state.pointee = .haveData
                return input
            }
            guard status != .error, conversionError == nil,
                  let samples = converted.int16ChannelData?.pointee else { return }
            accumulator.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(converted.frameLength)))
            while accumulator.count >= voiceSamplesPerFrame {
                let frame = Array(accumulator.prefix(voiceSamplesPerFrame))
                accumulator.removeFirst(voiceSamplesPerFrame)
                onFrame(frame)
            }
        }
    }

    private func configure(_ session: AVAudioSession) throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setPreferredSampleRate(voiceSampleRate)
        try session.setPreferredIOBufferDuration(0.02)
    }

    deinit {
        stopCapture()
        player.stop()
        engine.stop()
    }
}

private enum VoiceAudioError: LocalizedError {
    case captureAlreadyRunning
    case inputUnavailable
    case invalidPlaybackFrame
    case bufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .captureAlreadyRunning: "Microphone capture is already running."
        case .inputUnavailable: "The microphone audio format is unavailable."
        case .invalidPlaybackFrame: "Received an invalid voice frame."
        case .bufferAllocationFailed: "Could not allocate a voice playback buffer."
        }
    }
}
