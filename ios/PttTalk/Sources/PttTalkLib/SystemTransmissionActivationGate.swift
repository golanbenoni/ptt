public struct SystemTransmissionActivationGate: Sendable {
    public private(set) var transmissionBegan = false
    public private(set) var audioActive = false
    private var voiceStartClaimed = false

    public init() {}

    public mutating func didBegin(requested: Bool) -> Bool {
        transmissionBegan = true
        return claimVoiceStartIfReady(requested: requested)
    }

    public mutating func didActivate(requested: Bool) -> Bool {
        audioActive = true
        return claimVoiceStartIfReady(requested: requested)
    }

    public mutating func didDeactivate() {
        audioActive = false
    }

    public mutating func didEnd() {
        transmissionBegan = false
        voiceStartClaimed = false
    }

    public mutating func reset() {
        transmissionBegan = false
        audioActive = false
        voiceStartClaimed = false
    }

    public var shouldStopOnRelease: Bool { transmissionBegan }

    /// Half-duplex Push to Talk must not begin a new local request until Apple
    /// has delivered both the previous end and audio-deactivation callbacks.
    /// Bluetooth routes can keep the audio session active noticeably longer
    /// than the encrypted media pipeline needs to finish. Starting during that
    /// interval can wedge the subsequent `stopTransmitting` call.
    public var isReadyForNewLocalRequest: Bool {
        !transmissionBegan && !audioActive
    }

    private mutating func claimVoiceStartIfReady(requested: Bool) -> Bool {
        guard requested, transmissionBegan, audioActive, !voiceStartClaimed else { return false }
        voiceStartClaimed = true
        return true
    }
}
