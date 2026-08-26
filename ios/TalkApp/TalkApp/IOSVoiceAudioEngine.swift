import AVFoundation
import Foundation
import PttTalkLib

#if DEBUG
func writeDebugE2EMarker(_ name: String, _ value: String) {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains) else { return }
    guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
        return
    }
    try? Data(value.utf8).write(
        to: documents.appendingPathComponent("ptt-e2e-\(name).txt"),
        options: .atomic
    )
}
#endif

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
    private var debugE2ECurrentTalkId: UUID?
    private var debugE2EPlayedTalkIds: Set<UUID> = []
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

    func prepareForSystemActivation() throws {
        try lock.withLock {
            guard VoiceAudioSessionManagementPolicy.configureBeforeSystemActivation(
                systemManagesAudioSession: systemManagesAudioSession
            ) else { return }
            try configure(AVAudioSession.sharedInstance())
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
            if VoiceAudioSessionManagementPolicy.configureWhenCaptureStarts(
                systemManagesAudioSession: systemManagesAudioSession
            ) {
                try configure(session)
                try activate(session)
                if VoiceAudioSessionManagementPolicy.rebuildGraphWhenCaptureStarts(
                    systemManagesAudioSession: systemManagesAudioSession
                ) {
                    try rebuildEngineForCapture()
                }
            }

            let input = engine.inputNode
            // On physical iOS hardware, route activation can complete after setActive returns.
            // Start the graph first, then inspect the input node's *input* scope: Apple defines
            // that as the hardware format and availability signal. A tap can be installed while
            // the engine is running.
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            guard let inputFormat = try settledInputFormatWithRecovery(for: input),
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
                if rms > 0.05, let talkId = debugE2ECurrentTalkId,
                   debugE2EPlayedTalkIds.insert(talkId).inserted {
                        debugE2EPlaybackTransmissionCount += 1
                        UserDefaults.standard.set(
                            debugE2EPlaybackTransmissionCount,
                            forKey: "pttE2EPlaybackCount"
                        )
                        UserDefaults.standard.set(
                            debugE2EPlaybackTransmissionCount >= 5 ? "pass" : "receiving",
                            forKey: "pttE2EReceiverState"
                        )
                        UserDefaults.standard.synchronize()
                        writeDebugE2EMarker(
                            "receiver-count",
                            String(debugE2EPlaybackTransmissionCount)
                        )
                        writeDebugE2EMarker(
                            "receiver-state",
                            debugE2EPlaybackTransmissionCount >= 5 ? "pass" : "receiving"
                        )
                        NSLog(
                            "PTT_E2E_PLAYBACK_PASS count=%d rms=%f",
                            debugE2EPlaybackTransmissionCount,
                            rms
                        )
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

#if DEBUG
    func expectE2EPlayback(talkId: UUID) {
        lock.withLock { debugE2ECurrentTalkId = talkId }
    }
#endif

    func queuedPlaybackFrameCount() -> Int {
        lock.withLock {
            guard engine.isRunning, player.isPlaying else { return 0 }
            return queuedPlaybackFrames
        }
    }

    func systemDidActivate(_ session: AVAudioSession) throws {
        try lock.withLock {
            // PushToTalk already activated this session. Reapplying category,
            // mode, or preferred I/O settings here can rebuild the route after
            // didActivate and temporarily remove the iPad microphone input.
            // The session is configured before requesting system activation.
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

    private func settledInputFormatWithRecovery(for input: AVAudioInputNode) throws -> AVAudioFormat? {
        for engineStateAttempt in 0..<VoiceAudioInputFormatPolicy.engineStateAttempts {
            if let format = settledInputFormat(for: input) { return format }
            guard engineStateAttempt + 1 < VoiceAudioInputFormatPolicy.engineStateAttempts else {
                return nil
            }

            // Some physical devices report a zero-channel input after the
            // system activates an output-only graph. Rebuilding the graph while
            // leaving the system-owned AVAudioSession active gives AVAudioEngine
            // one clean opportunity to bind its input unit.
            try rebuildEngineForCapture()
        }
        return nil
    }

    private func rebuildEngineForCapture() throws {
        queuedPlaybackFrames = 0
        player.stop()
        engine.stop()
        engine.reset()
        engine.prepare()
        try engine.start()
        player.play()
    }

    private func settledInputFormat(for input: AVAudioInputNode) -> AVAudioFormat? {
        for attempt in 0..<VoiceAudioInputFormatPolicy.routeSettleAttemptsPerEngineState {
            let hardwareInput = input.inputFormat(forBus: 0)
            let nodeOutput = input.outputFormat(forBus: 0)
            let source = VoiceAudioInputFormatPolicy.preferredSource(
                hardwareInputSampleRate: hardwareInput.sampleRate,
                hardwareInputChannels: hardwareInput.channelCount,
                nodeOutputSampleRate: nodeOutput.sampleRate,
                nodeOutputChannels: nodeOutput.channelCount
            )
            switch source {
            case .hardwareInput:
                return hardwareInput
            case .nodeOutput:
                return nodeOutput
            case nil:
                guard attempt + 1 < VoiceAudioInputFormatPolicy.routeSettleAttemptsPerEngineState else {
                    return nil
                }
                Thread.sleep(
                    forTimeInterval: Double(VoiceAudioInputFormatPolicy.routeSettleDelayMs) / 1_000
                )
            }
        }
        return nil
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
        case .inputUnavailable:
            "The microphone route did not become available. Release and hold again, or reconnect the audio device."
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
