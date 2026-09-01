import AVFoundation
import Foundation
import PttTalkLib

#if DEBUG
let pttE2EPushWakeReceiverKey = "pttE2EPushWakeReceiver"
let pttE2EPushWakeDeviceKey = "pttE2EPushWakeDevice"

func isDebugE2EReceiver() -> Bool {
    ProcessInfo.processInfo.arguments.contains("--ptt-e2e-receiver") ||
        UserDefaults.standard.bool(forKey: pttE2EPushWakeReceiverKey)
}

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
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let captureFormat: AVAudioFormat
    private let playbackFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var accumulator: [Int16] = []
    private var onFrame: (@Sendable ([Int16]) -> Void)?
    private var tapInstalled = false
    private var capturePrepared = false
    private var captureGraphPreparing = false
    private var preparedInputFormat: AVAudioFormat?
    private var queuedPlaybackFrames = 0
    private var simulatorCaptureTask: Task<Void, Never>?
    private let systemManagesAudioSession: Bool
    private let recoveryQueue = DispatchQueue(label: "app.ptt.talk.audio-recovery")
    private var configurationObserver: NSObjectProtocol?
    private var lastRouteDiagnostics = "not inspected"
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
        connectPlayerGraph()
        installConfigurationObserver()
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

    func prepareCapture() throws {
        try lock.withLock {
            guard !tapInstalled, simulatorCaptureTask == nil else {
                throw VoiceAudioError.captureAlreadyRunning
            }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ptt-synthetic-mic") { return }
#endif
            let session = AVAudioSession.sharedInstance()
            if VoiceAudioSessionManagementPolicy.configureWhenCaptureStarts(
                systemManagesAudioSession: systemManagesAudioSession
            ) {
                try configure(session)
                try activate(session)
            }
            try prepareFreshCaptureGraph(session: session)
        }
    }

    func startCapture(onFrame: @escaping @Sendable ([Int16]) -> Void) throws {
        try lock.withLock {
            guard !tapInstalled, simulatorCaptureTask == nil else {
                throw VoiceAudioError.captureAlreadyRunning
            }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ptt-synthetic-mic") {
                startSimulatorCapture(onFrame: onFrame, syntheticVoice: true)
                return
            }
#endif
            if !capturePrepared { try prepareCapture() }
            let input = engine.inputNode
            guard let inputFormat = preparedInputFormat,
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
            do {
                engine.prepare()
                try engine.start()
                if !player.isPlaying { player.play() }
                capturePrepared = false
                lastRouteDiagnostics = routeDiagnostics(
                    session: AVAudioSession.sharedInstance(),
                    input: input,
                    stage: "capture-running"
                )
                NSLog("PTT_AUDIO_ROUTE %@", lastRouteDiagnostics)
            } catch {
                input.removeTap(onBus: 0)
                tapInstalled = false
                capturePrepared = false
                preparedInputFormat = nil
                self.converter = nil
                self.onFrame = nil
                accumulator.removeAll(keepingCapacity: false)
                throw error
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
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            capturePrepared = false
            preparedInputFormat = nil
            converter = nil
            onFrame = nil
            accumulator.removeAll(keepingCapacity: false)
        }
    }

#if DEBUG || targetEnvironment(simulator)
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
            let completedE2EPlayback: (talkId: UUID, rms: Double)? = {
                guard isDebugE2EReceiver() else {
                    return nil
                }
                let rms = sqrt(pcm.reduce(0.0) { partial, sample in
                    let normalized = Double(sample) / 32_768
                    return partial + normalized * normalized
                } / Double(pcm.count))
                guard rms > 0.05, let talkId = debugE2ECurrentTalkId,
                      debugE2EPlayedTalkIds.insert(talkId).inserted else {
                    return nil
                }
                return (talkId, rms)
            }()
#endif
            if !player.isPlaying { queuedPlaybackFrames = 0 }
            queuedPlaybackFrames += 1
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.lock.withLock {
                    guard let self else { return }
                    self.queuedPlaybackFrames = max(0, self.queuedPlaybackFrames - 1)
#if DEBUG
                    if let completedE2EPlayback {
                        self.completeE2EPlayback(
                            talkId: completedE2EPlayback.talkId,
                            rms: completedE2EPlayback.rms
                        )
                    }
#endif
                }
            }
            if engine.isRunning && !player.isPlaying { player.play() }
        }
    }

#if DEBUG
    func expectE2EPlayback(talkId: UUID) {
        lock.withLock { debugE2ECurrentTalkId = talkId }
    }

    private func completeE2EPlayback(talkId: UUID, rms: Double) {
        debugE2EPlaybackTransmissionCount += 1
        UserDefaults.standard.set(debugE2EPlaybackTransmissionCount, forKey: "pttE2EPlaybackCount")
        let state = debugE2EPlaybackTransmissionCount >= 5 ? "pass" : "receiving"
        UserDefaults.standard.set(state, forKey: "pttE2EReceiverState")
        UserDefaults.standard.synchronize()
        writeDebugE2EMarker("receiver-count", String(debugE2EPlaybackTransmissionCount))
        writeDebugE2EMarker("receiver-state", state)
        NSLog(
            "PTT_E2E_PLAYBACK_PASS talk=%@ count=%d rms=%f",
            talkId.uuidString,
            debugE2EPlaybackTransmissionCount,
            rms
        )
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
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            capturePrepared = false
            preparedInputFormat = nil
            converter = nil
            onFrame = nil
            queuedPlaybackFrames = 0
            player.stop()
            engine.stop()
        }
    }

    func supportDiagnostics() -> String {
        lock.withLock { lastRouteDiagnostics }
    }

#if DEBUG
    func runCaptureProbe() async throws -> Int {
        let probe = CaptureProbe()
        try prepareCapture()
        try startCapture { frame in probe.observe(frame) }
        defer { stopCapture() }
        for _ in 0..<50 where probe.frameCount < 5 {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard probe.frameCount >= 5 else { throw VoiceAudioError.captureProbeTimedOut }
        return probe.frameCount
    }

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
            // Configuration notifications are expected while a VoiceProcessingIO
            // capture graph is being assembled. Restarting that graph from this
            // observer races the microphone tap installation on physical devices.
            guard !captureGraphPreparing, !capturePrepared, !tapInstalled else { return }
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

    private func prepareFreshCaptureGraph(session: AVAudioSession) throws {
        captureGraphPreparing = true
        defer { captureGraphPreparing = false }
        capturePrepared = false
        preparedInputFormat = nil

        for graphAttempt in 0..<VoiceAudioInputFormatPolicy.engineStateAttempts {
            if graphAttempt > 0 && !systemManagesAudioSession {
                // A clean session reactivation is the last-resort recovery for
                // a route that remained output-only after setActive returned.
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                try configure(session)
                try activate(session)
            }
            preferAvailableInputIfRouteIsEmpty(session)
            replaceAudioGraph()
            let input = engine.inputNode
#if !targetEnvironment(simulator)
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                // Voice processing is desirable for PTT, but a device/route that
                // cannot enable it may still provide a valid microphone format.
                NSLog("PTT_AUDIO_VOICE_PROCESSING_UNAVAILABLE error=%@", error.localizedDescription)
            }
#endif
            if let format = settledInputFormat(for: input) {
                preparedInputFormat = format
                capturePrepared = true
                lastRouteDiagnostics = routeDiagnostics(
                    session: session,
                    input: input,
                    stage: "capture-prepared"
                )
                NSLog("PTT_AUDIO_ROUTE %@", lastRouteDiagnostics)
                return
            }
            lastRouteDiagnostics = routeDiagnostics(
                session: session,
                input: input,
                stage: "capture-attempt-\(graphAttempt + 1)-failed"
            )
            NSLog("PTT_AUDIO_ROUTE %@", lastRouteDiagnostics)
        }
        throw VoiceAudioError.inputUnavailable
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

    private func preferAvailableInputIfRouteIsEmpty(_ session: AVAudioSession) {
        guard session.currentRoute.inputs.isEmpty,
              let available = session.availableInputs,
              let preferred = available.first(where: { $0.portType == .builtInMic }) ?? available.first else {
            return
        }
        do {
            try session.setPreferredInput(preferred)
        } catch {
            NSLog("PTT_AUDIO_PREFERRED_INPUT_UNAVAILABLE type=%@", preferred.portType.rawValue)
        }
    }

    private func replaceAudioGraph() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        queuedPlaybackFrames = 0
        player.stop()
        engine.stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        connectPlayerGraph()
        installConfigurationObserver()
    }

    private func connectPlayerGraph() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
    }

    private func installConfigurationObserver() {
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

    private func routeDiagnostics(
        session: AVAudioSession,
        input: AVAudioInputNode,
        stage: String
    ) -> String {
        let hardware = input.inputFormat(forBus: 0)
        let node = input.outputFormat(forBus: 0)
        let routeInputs = session.currentRoute.inputs.map(\.portType.rawValue).sorted().joined(separator: ",")
        let availableInputs = (session.availableInputs ?? []).map(\.portType.rawValue).sorted().joined(separator: ",")
        let preferred = session.preferredInput?.portType.rawValue ?? "none"
        return [
            "stage=\(stage)",
            "category=\(session.category.rawValue)",
            "mode=\(session.mode.rawValue)",
            "inputAvailable=\(session.isInputAvailable)",
            "routeInputs=\(routeInputs.isEmpty ? "none" : routeInputs)",
            "availableInputs=\(availableInputs.isEmpty ? "none" : availableInputs)",
            "preferredInput=\(preferred)",
            "hardware=\(Int(hardware.sampleRate))/\(hardware.channelCount)",
            "node=\(Int(node.sampleRate))/\(node.channelCount)",
        ].joined(separator: " ")
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
    case captureProbeTimedOut

    var errorDescription: String? {
        switch self {
        case .captureAlreadyRunning: "Microphone capture is already running."
        case .inputUnavailable:
            "The microphone route did not become available. Open Settings and share the privacy-redacted support report."
        case .invalidPlaybackFrame: "Received an invalid voice frame."
        case .bufferAllocationFailed: "Could not allocate a voice playback buffer."
        case .outputUnavailable: "The voice playback route is not active."
        case .silentPlaybackProbe: "The voice playback graph produced silence."
        case .captureProbeTimedOut: "The microphone graph started but did not produce audio frames."
        }
    }
}

#if DEBUG
private final class CaptureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0

    func observe(_ frame: [Int16]) {
        guard frame.count == voiceSamplesPerFrame else { return }
        lock.withLock { frames += 1 }
    }

    var frameCount: Int { lock.withLock { frames } }
}

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
