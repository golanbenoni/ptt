public enum SystemChannelReadinessStep: CaseIterable, Equatable, Sendable {
    case confirmHalfDuplex
    case confirmServiceReady
    case confirmAccessoryEvents
}

public enum SystemChannelReadinessPolicy {
    public static let orderedSteps = SystemChannelReadinessStep.allCases

    public static func step(after completed: SystemChannelReadinessStep) -> SystemChannelReadinessStep? {
        guard let index = orderedSteps.firstIndex(of: completed),
              orderedSteps.indices.contains(index + 1) else { return nil }
        return orderedSteps[index + 1]
    }
}

public enum SystemTransmissionReadinessPolicy {
    public static func canStartAutomation(usesSystemFramework: Bool, isAppActive: Bool) -> Bool {
        !usesSystemFramework || isAppActive
    }
}

/// Apple can deliver the completion of a programmatic begin request after the
/// app has released that request or relaunched into a receive-only state. A
/// late failure must not tear down the current receive session; only a failure
/// correlated with the currently requested transmission is actionable.
public enum SystemTransmissionFailurePolicy {
    public static func shouldIgnoreBeginFailure(transmitRequested: Bool) -> Bool {
        !transmitRequested
    }
}
