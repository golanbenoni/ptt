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

    private mutating func claimVoiceStartIfReady(requested: Bool) -> Bool {
        guard requested, transmissionBegan, audioActive, !voiceStartClaimed else { return false }
        voiceStartClaimed = true
        return true
    }
}
