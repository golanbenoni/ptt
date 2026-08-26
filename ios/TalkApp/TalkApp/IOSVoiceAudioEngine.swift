import AVFoundation
import Foundation
import PttTalkLib

final class IOSVoiceAudioEngine: VoiceAudioIO, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let captureFormat: AVAudioFormat
    private let playbackFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var accumulator: [Int16] = []
    private var onFrame: (@Sendable ([Int16]) -> Void)?
    private var tapInstalled = false
    private var queuedPlaybackFrames = 0
    private var simulatorCaptureTask: Task<Void, Never>?
    private let systemManagesAudioSession: Bool
    private let recoveryQueue = DispatchQueue(label: "app.ptt.talk.audio-recovery")
    private var configurationObserver: NSObjectProtocol?
#if DEBUG
    private var debugE2EPlaybackTransmissionCount = 0
    private var debugE2ELastNonSilentPlaybackAt: TimeInterval?
#endif

    init(systemManagesAudioSession: Bool = false) {
        self.systemManagesAudioSession = systemManagesAudioSession
        guard let captureFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: voiceSampleRate,
            channels: 1,
            interleaved: false
        ), let playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: voiceSampleRate,
            channels: 1,
            interleaved: false
        ) else { preconditionFailure("Unable to create the PTT voice formats") }
        self.captureFormat = captureFormat
        self.playbackFormat = playbackFormat
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.recoveryQueue.async { [weak self] in
                self?.recoverAfterConfigurationChange()
            }
        }
    }

    func preparePlayback() throws {
        try lock.withLock {
            guard !systemManagesAudioSession else { return }
            let session = AVAudioSession.sharedInstance()
            try configure(session)
            try activate(session)
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            if !player.isPlaying { player.play() }
        }
    }

    func startCapture(onFrame: @escaping @Sendable ([Int16]) -> Void) throws {
        try lock.withLock {
            guard !tapInstalled, simulatorCaptureTask == nil else {
                throw VoiceAudioError.captureAlreadyRunning
            }
#if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--ptt-synthetic-mic") {
                startSimulatorCapture(onFrame: onFrame, syntheticVoice: true)
                return
            }
#endif
            let session = AVAudioSession.sharedInstance()
            try configure(session)
            if !systemManagesAudioSession {
                try activate(session)
            }

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  let converter = AVAudioConverter(from: inputFormat, to: captureFormat) else {
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
    private func startSimulatorCapture(
        onFrame: @escaping @Sendable ([Int16]) -> Void,
        syntheticVoice: Bool = false
    ) {
        self.onFrame = onFrame
        simulatorCaptureTask = Task.detached(priority: .userInitiated) {
            var sampleOffset = 0
            while !Task.isCancelled {
                let frame: [Int16]
                if syntheticVoice {
                    frame = (0..<voiceSamplesPerFrame).map { sampleIndex in
                        let phase = Double(sampleOffset + sampleIndex) * 2 * .pi * 997 / voiceSampleRate
                        return Int16(sin(phase) * 20_000)
                    }
                    sampleOffset += voiceSamplesPerFrame
                } else {
                    frame = [Int16](repeating: 0, count: voiceSamplesPerFrame)
                }
                onFrame(frame)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }
#endif

    func play(_ pcm: [Int16]) throws {
        guard pcm.count == voiceSamplesPerFrame else { throw VoiceAudioError.invalidPlaybackFrame }
        try lock.withLock {
            if !engine.isRunning { queuedPlaybackFrames = 0 }
            if systemManagesAudioSession {
                guard engine.isRunning else { throw VoiceAudioError.outputUnavailable }
            } else {
                try preparePlayback()
            }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: playbackFormat,
                frameCapacity: AVAudioFrameCount(pcm.count)
            ), let output = buffer.floatChannelData?.pointee else {
                throw VoiceAudioError.bufferAllocationFailed
            }
            buffer.frameLength = AVAudioFrameCount(pcm.count)
            for (index, sample) in pcm.enumerated() {
                output[index] = Float(sample) / 32_768
            }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ptt-e2e-receiver") {
                let rms = sqrt(pcm.reduce(0.0) { partial, sample in
                    let normalized = Double(sample) / 32_768
                    return partial + normalized * normalized
                } / Double(pcm.count))
                if rms > 0.05 {
                    let now = Date.timeIntervalSinceReferenceDate
                    if debugE2ELastNonSilentPlaybackAt.map({ now - $0 > 0.5 }) ?? true {
                        debugE2EPlaybackTransmissionCount += 1
                        NSLog(
                            "PTT_E2E_PLAYBACK_PASS count=%d rms=%f",
                            debugE2EPlaybackTransmissionCount,
                            rms
                        )
                    }
                    debugE2ELastNonSilentPlaybackAt = now
                }
            }
#endif
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

#if DEBUG
    func runPlaybackProbe() async throws -> Double {
        let probe = PlaybackProbe()
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        mixer.installTap(onBus: 0, bufferSize: AVAudioFrameCount(voiceSamplesPerFrame), format: format) {
            buffer, _ in probe.observe(buffer)
        }
        defer { mixer.removeTap(onBus: 0) }

        try preparePlayback()
        // Activating a play-and-record session can asynchronously rebuild the
        // hardware route. Let that settle, then ensure the graph is running
        // before testing the same scheduling path used by received speech.
        try await Task.sleep(for: .milliseconds(500))
        try preparePlayback()
        for frameIndex in 0..<12 {
            let pcm = (0..<voiceSamplesPerFrame).map { sampleIndex in
                let absoluteIndex = frameIndex * voiceSamplesPerFrame + sampleIndex
                return Int16(sin(Double(absoluteIndex) * 2 * .pi * 997 / voiceSampleRate) * 20_000)
            }
            try play(pcm)
        }
        for _ in 0..<100 where queuedPlaybackFrameCount() > 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let rms = probe.rms
        guard rms > 0.05 else { throw VoiceAudioError.silentPlaybackProbe }
        return rms
    }
#endif

    private func consume(_ input: AVAudioPCMBuffer) {
        lock.withLock {
            guard tapInstalled, let converter, let onFrame else { return }
            let ratio = voiceSampleRate / input.format.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 8)
            guard let converted = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }
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

    private func recoverAfterConfigurationChange() {
        lock.withLock {
            queuedPlaybackFrames = 0
            player.stop()
            guard !systemManagesAudioSession else { return }
            do {
                if !engine.isRunning {
                    engine.prepare()
                    try engine.start()
                }
                player.play()
            } catch {
                engine.stop()
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

    private func activate(_ session: AVAudioSession) throws {
#if targetEnvironment(simulator)
        // Simulator audio is owned by the host aggregate device. Explicitly
        // activating the iOS session can block while that aggregate rebuilds.
#else
        try session.setActive(true)
#endif
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
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
    case outputUnavailable
    case silentPlaybackProbe

    var errorDescription: String? {
        switch self {
        case .captureAlreadyRunning: "Microphone capture is already running."
        case .inputUnavailable: "The microphone audio format is unavailable."
        case .invalidPlaybackFrame: "Received an invalid voice frame."
        case .bufferAllocationFailed: "Could not allocate a voice playback buffer."
        case .outputUnavailable: "The voice playback route is not active."
        case .silentPlaybackProbe: "The voice playback graph produced silence."
        }
    }
}

#if DEBUG
private final class PlaybackProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var sumSquares = 0.0
    private var sampleCount = 0

    func observe(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        lock.withLock {
            for channel in 0..<channelCount {
                for frame in 0..<frames {
                    let sample = Double(channels[channel][frame])
                    sumSquares += sample * sample
                    sampleCount += 1
                }
            }
        }
    }

    var rms: Double {
        lock.withLock { sqrt(sumSquares / Double(max(sampleCount, 1))) }
    }
}
#endif
