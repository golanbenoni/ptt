import AVFoundation
import CryptoKit
import PttTalkLib
import SwiftUI

#if targetEnvironment(simulator)
private let pttUsesSystemFramework = false
#else
private let pttUsesSystemFramework = true
#endif

fileprivate struct SafetyNumber: Identifiable {
    let aci: String
    let deviceId: Int
    let value: String
    var id: String { "\(aci):\(deviceId)" }
}

@MainActor
final class TalkModel: ObservableObject {
    @Published var serverUrl = "https://"
    @Published var email = ""
    @Published var invitationCode = ""
    @Published var magicToken = ""
    @Published private(set) var session: DeviceSession?
    @Published private(set) var channels: [ChannelSummary] = []
    @Published private(set) var devices: [DeviceSummary] = []
    @Published var linkRequestId = ""
    @Published var linkCode = ""
    @Published var recoveryEmail = ""
    @Published var recoveryToken = ""
    @Published private(set) var generatedLinkCode = ""
    @Published private(set) var pendingDeviceLink: PendingDeviceLink?
    @Published private(set) var pendingRecovery: PendingRecovery?
    @Published var selectedChannelId = ""
    @Published private(set) var status = "Sign in to your private PTT server."
    @Published private(set) var encryptionDetails: VoiceEncryptionDetails?
    @Published private(set) var isTransmitting = false
    @Published private(set) var isSystemChannelJoined = false
    @Published private(set) var history: [VoiceHistoryItem] = []
    @Published private(set) var emergencyRecipientCount = 0
    @Published private(set) var isEmergency = false
    @Published fileprivate var safetyNumbers: [SafetyNumber] = []
    @Published var presenceMode = "available"
    @Published private(set) var busy = false

    private let credentials = SecureDeviceStore()
    private var signalStore: KeychainSignalProtocolStore?
    private let audio = IOSVoiceAudioEngine(systemManagesAudioSession: pttUsesSystemFramework)
    private let systemPtt: SystemPttCoordinator
    private var voice: ProductionVoiceSession?
    private var joinedChannelId: UUID?
    private var transmitRequested = false
    private var sosRequested = false
    private var revocationInProgress = false
#if DEBUG
    private var debugEnrollmentStarted = false
    private var debugSessionNeedsActivation = false
#endif

    init() {
        systemPtt = SystemPttCoordinator()
#if DEBUG
        if let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "--ptt-server"),
           ProcessInfo.processInfo.arguments.indices.contains(flag + 1) {
            serverUrl = ProcessInfo.processInfo.arguments[flag + 1]
        }
#endif
        do {
            signalStore = try KeychainSignalProtocolStore()
        } catch {
            signalStore = nil
            status = "Secure storage is unavailable on this device: \(error.localizedDescription)"
        }
        systemPtt.owner = self
        if signalStore != nil {
            do {
                session = try credentials.loadSession()
                if let session {
                    serverUrl = session.serverUrl
                    Task { await activate(session) }
                } else if let pending = try credentials.loadDeviceLink() {
                    pendingDeviceLink = pending
                    serverUrl = pending.serverUrl
                    status = "This device is waiting for approval from an active device."
                } else if let pending = try credentials.loadRecovery() {
                    pendingRecovery = pending
                    serverUrl = pending.serverUrl
                    status = "Account recovery is waiting for administrator approval."
                }
            } catch {
                status = "Could not read this device's secure session: \(error.localizedDescription)"
            }
        }
        if pttUsesSystemFramework {
            Task {
                do { try await systemPtt.start() }
                catch { systemPttFailed(error.localizedDescription) }
            }
        }
#if DEBUG
        if let accessToken = Self.debugArgument("--ptt-access-token"),
           let aci = Self.debugArgument("--ptt-aci"),
           let mailboxId = Self.debugArgument("--ptt-mailbox") {
            let injected = DeviceSession(
                serverUrl: serverUrl,
                aci: aci,
                deviceId: Int(Self.debugArgument("--ptt-device") ?? "1") ?? 1,
                mailboxId: mailboxId,
                accessToken: accessToken
            )
            session = injected
            debugSessionNeedsActivation = true
        }
        if session == nil,
           let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "--ptt-token"),
           ProcessInfo.processInfo.arguments.indices.contains(flag + 1) {
            magicToken = ProcessInfo.processInfo.arguments[flag + 1]
        }
#endif
    }

    var selectedChannel: ChannelSummary? {
        channels.first { $0.channelId == selectedChannelId }
    }

    var systemChannelJoinTitle: String {
        if isSystemChannelJoined { return "Voice channel joined" }
        return pttUsesSystemFramework ? "Join iOS Push to Talk" : "Join simulator voice channel"
    }

    var supportReport: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let accountFingerprint = session.map {
            SHA256.hash(data: Data($0.aci.lowercased().utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        } ?? "signed-out"
        return [
            "PTT Talk privacy-redacted support report",
            "App: \(version) (\(build))",
            "iOS: \(UIDevice.current.systemVersion)",
            "Device family: \(UIDevice.current.model)",
            "Account fingerprint: \(accountFingerprint)",
            "System PTT channel joined: \(isSystemChannelJoined)",
            "Selected channel role: \(selectedChannel?.role ?? "none")",
            "Selected channel epoch: \(selectedChannel?.membershipEpoch ?? 0)",
            "Excluded: email, server URL, account/device/mailbox IDs, tokens, keys, audio, channel IDs, and message contents",
        ].joined(separator: "\n")
    }

#if DEBUG
    func consumeDebugMagicLinkIfNeeded() async {
        if debugSessionNeedsActivation, let session {
            debugSessionNeedsActivation = false
            await activate(session)
            // Unsigned simulator builds cannot open the Keychain-backed Signal store. Still
            // load server-backed UI state so the complete signed-in surface remains testable.
            if channels.isEmpty { await refreshChannels() }
            if selectedChannel != nil, voice == nil {
                status = "Unsigned simulator UI preview. Signed builds use Keychain-backed encrypted voice."
            }
            return
        }
        guard session == nil, !magicToken.isEmpty, !debugEnrollmentStarted else { return }
        debugEnrollmentStarted = true
        await consumeMagicLink()
    }

    private static func debugArgument(_ name: String) -> String? {
        guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: name),
              ProcessInfo.processInfo.arguments.indices.contains(index + 1) else { return nil }
        return ProcessInfo.processInfo.arguments[index + 1]
    }
#endif

    func requestMagicLink() async {
        await perform("Requesting sign-in email…") {
            let api = try ControlApi(serverUrl: serverUrl, allowInsecureHttp: Self.allowInsecure(serverUrl))
            try await api.requestMagicLink(email: email, invitationCode: invitationCode)
            status = "Check your email, then paste or open the one-time token."
        }
    }

    func consumeMagicLink() async {
        guard let signalStore else {
            status = "Secure storage is unavailable. Restart the app after verifying its signing and Keychain access."
            return
        }
        await perform("Securing this device…") {
            let api = try ControlApi(serverUrl: serverUrl, allowInsecureHttp: Self.allowInsecure(serverUrl))
            let enrolled = try await api.consumeMagicLink(
                token: magicToken.trimmingCharacters(in: .whitespacesAndNewlines),
                deviceName: UIDevice.current.name,
                identityKey: signalStore.identityPublicKey
            )
            try credentials.save(session: enrolled)
            session = enrolled
            magicToken = ""
            await activate(enrolled)
        }
    }

    func claimDeviceLink() async {
        await perform("Creating an independent key for this device…") {
            try KeychainSignalProtocolStore.resetLocalDeviceState()
            let newStore = try KeychainSignalProtocolStore()
            signalStore = newStore
            let api = try ControlApi(serverUrl: serverUrl, allowInsecureHttp: Self.allowInsecure(serverUrl))
            let pending = try await api.claimDeviceLink(
                serverUrl: serverUrl,
                requestId: linkRequestId.trimmingCharacters(in: .whitespacesAndNewlines),
                linkCode: linkCode.trimmingCharacters(in: .whitespacesAndNewlines),
                deviceName: UIDevice.current.name,
                identityKey: newStore.identityPublicKey
            )
            try credentials.save(deviceLink: pending)
            pendingDeviceLink = pending
            status = "Approval requested. Return to the active device."
        }
    }

    func checkDeviceLink() async {
        guard let pendingDeviceLink else { return }
        await perform("Checking device approval…") {
            let api = try ControlApi(
                serverUrl: pendingDeviceLink.serverUrl,
                allowInsecureHttp: Self.allowInsecure(pendingDeviceLink.serverUrl)
            )
            guard let active = try await api.deviceLinkStatus(pendingDeviceLink) else {
                status = "Still waiting for approval from the active device."
                return
            }
            try credentials.save(session: active)
            self.pendingDeviceLink = nil
            session = active
            await activate(active)
        }
    }

    func requestRecovery() async {
        await perform("Requesting recovery email…") {
            let api = try ControlApi(serverUrl: serverUrl, allowInsecureHttp: Self.allowInsecure(serverUrl))
            try await api.requestRecovery(email: recoveryEmail)
            status = "If this account exists, its recovery email is on the way."
        }
    }

    func submitRecovery() async {
        await perform("Creating a replacement device identity…") {
            try KeychainSignalProtocolStore.resetLocalDeviceState()
            let newStore = try KeychainSignalProtocolStore()
            signalStore = newStore
            let api = try ControlApi(serverUrl: serverUrl, allowInsecureHttp: Self.allowInsecure(serverUrl))
            let claim = try await api.consumeRecovery(
                token: recoveryToken.trimmingCharacters(in: .whitespacesAndNewlines),
                deviceName: UIDevice.current.name,
                identityKey: newStore.identityPublicKey
            )
            let pending = PendingRecovery(
                serverUrl: serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                requestId: claim.requestId,
                claimToken: claim.claimToken
            )
            try credentials.save(recovery: pending)
            pendingRecovery = pending
            status = "Waiting for approval from a different instance administrator."
        }
    }

    func checkRecovery() async {
        guard let pendingRecovery else { return }
        await perform("Checking recovery approval…") {
            let api = try ControlApi(
                serverUrl: pendingRecovery.serverUrl,
                allowInsecureHttp: Self.allowInsecure(pendingRecovery.serverUrl)
            )
            let result = try await api.recoveryStatus(pendingRecovery)
            guard result.status == "approved", let aci = result.aci, let deviceId = result.deviceId,
                  let mailboxId = result.mailboxId, let accessToken = result.accessToken else {
                status = result.status == "denied"
                    ? "The administrator denied this recovery request."
                    : "Still waiting for independent administrator approval."
                return
            }
            let active = DeviceSession(
                serverUrl: pendingRecovery.serverUrl,
                aci: aci,
                deviceId: deviceId,
                mailboxId: mailboxId,
                accessToken: accessToken
            )
            try credentials.save(session: active)
            self.pendingRecovery = nil
            session = active
            await activate(active)
        }
    }

    func createDeviceLink() async {
        guard let session else { return }
        await perform("Generating a one-time link code…") {
            let api = try ControlApi(serverUrl: session.serverUrl, allowInsecureHttp: Self.allowInsecure(session.serverUrl))
            let link = try await api.startDeviceLink(session: session)
            linkRequestId = link.requestId
            generatedLinkCode = link.linkCode
            status = "Enter this request ID and code on the new device, then approve here."
        }
    }

    func approveDeviceLink() async {
        guard let session, !linkRequestId.isEmpty else { return }
        await perform("Approving the independently keyed device…") {
            let api = try ControlApi(serverUrl: session.serverUrl, allowInsecureHttp: Self.allowInsecure(session.serverUrl))
            try await api.approveDeviceLink(session: session, requestId: linkRequestId)
            generatedLinkCode = ""
            status = "Second device approved. It receives future transmissions only."
            await refreshDevices()
        }
    }

    func refreshDevices() async {
        guard let session else { return }
        do {
            devices = try await ControlApi(
                serverUrl: session.serverUrl,
                allowInsecureHttp: Self.allowInsecure(session.serverUrl)
            ).devices(session: session)
        } catch {
            if isUnauthorized(error) { await wipeRevokedDevice() }
            else { status = "Could not refresh devices: \(error.localizedDescription)" }
        }
    }

    func revokeDevice(_ device: DeviceSummary) async {
        guard let session, device.deviceId != session.deviceId else { return }
        await perform("Revoking device \(device.deviceId)…") {
            try await ControlApi(
                serverUrl: session.serverUrl,
                allowInsecureHttp: Self.allowInsecure(session.serverUrl)
            ).revokeDevice(session: session, deviceId: device.deviceId)
            await refreshDevices()
            status = "Device revoked; affected channel keys rotate server-side."
        }
    }

    func refreshChannels() async {
        guard let session else { return }
        await perform("Loading channels…") {
            let api = try ControlApi(
                serverUrl: session.serverUrl,
                allowInsecureHttp: Self.allowInsecure(session.serverUrl)
            )
            channels = try await api.channels(session: session)
            if !channels.contains(where: { $0.channelId == selectedChannelId }) {
                selectedChannelId = channels.first?.channelId ?? ""
            }
            if let selectedChannel { await voice?.prepare(selectedChannel) }
            else { status = "Your administrator has not assigned a channel yet." }
            await refreshEmergencyRecipients()
            await refreshDevices()
        }
    }

    func selectChannel() async {
        guard let selectedChannel else { return }
        if let joinedChannelId, joinedChannelId != UUID(uuidString: selectedChannel.channelId) {
            leaveSystemChannel(joinedChannelId)
        }
        await voice?.prepare(selectedChannel)
        await refreshHistory()
        await refreshEmergencyRecipients()
    }

    func updatePresence() {
        Task { await voice?.setPresence(presenceMode) }
    }

    func refreshHistory() async {
        do { history = try await voice?.historyItems() ?? [] }
        catch { status = "Could not read encrypted history: \(error.localizedDescription)" }
    }

    func playHistory(_ item: VoiceHistoryItem) {
        Task { await voice?.playHistory(talkId: item.talkId) }
    }

    func joinSelectedSystemChannel() {
        guard let selectedChannel, let channelId = UUID(uuidString: selectedChannel.channelId) else { return }
        if !pttUsesSystemFramework {
            systemPttDidJoin(channelId)
            return
        }
        do {
            try systemPtt.join(channelId: channelId, name: selectedChannel.displayName)
            status = "Joining \(selectedChannel.displayName) in the iOS Push to Talk system…"
        } catch {
            systemPttFailed(error.localizedDescription)
        }
    }

    func beginTransmit() { beginTransmit(sos: false) }

    func beginSos() { beginTransmit(sos: true) }

    private func beginTransmit(sos: Bool) {
        guard !transmitRequested, let channelId = joinedChannelId else {
            status = "Join the selected iOS Push to Talk channel first."
            return
        }
        transmitRequested = true
        sosRequested = sos
        Task {
            let allowed = await requestMicrophonePermission()
            guard allowed else {
                status = "Microphone access is required for push-to-talk."
                transmitRequested = false
                return
            }
            if !pttUsesSystemFramework {
                isTransmitting = true
                isEmergency = sos
                await voice?.beginTransmit(sos: sos)
                return
            }
            do { try systemPtt.beginTransmitting(channelId: channelId) }
            catch {
                transmitRequested = false
                systemPttFailed(error.localizedDescription)
            }
        }
    }

    func endTransmit() {
        guard transmitRequested || isTransmitting, let channelId = joinedChannelId else { return }
        transmitRequested = false
        if !pttUsesSystemFramework {
            isTransmitting = false
            isEmergency = false
            Task { await voice?.endTransmit() }
            return
        }
        systemPtt.stopTransmitting(channelId: channelId)
    }

    func sendSilentSos() {
        guard selectedChannel != nil else {
            status = "Select an emergency channel first."
            return
        }
        Task { await voice?.beginTransmit(sos: true, silent: true) }
    }

    private func refreshEmergencyRecipients() async {
        guard let session, let selectedChannel else {
            emergencyRecipientCount = 0
            safetyNumbers = []
            return
        }
        do {
            let api = try ControlApi(
                serverUrl: session.serverUrl,
                allowInsecureHttp: Self.allowInsecure(session.serverUrl)
            )
            let devices = try await api.channelDevices(session: session, channelId: selectedChannel.channelId)
            emergencyRecipientCount = devices.filter {
                $0.aci != session.aci || $0.deviceId != session.deviceId
            }.count
            if let local = signalStore?.identityPublicKey {
                safetyNumbers = devices.compactMap { device in
                    guard device.aci != session.aci || device.deviceId != session.deviceId else { return nil }
                    let ordered = [local, device.identityKey].sorted { $0.lexicographicallyPrecedes($1) }
                    let digest = SHA512.hash(data: ordered[0] + ordered[1])
                    let digits = digest.prefix(20).map { String(format: "%03d", $0) }.joined()
                    return SafetyNumber(
                        aci: device.aci,
                        deviceId: device.deviceId,
                        value: stride(from: 0, to: digits.count, by: 5).map {
                            String(digits.dropFirst($0).prefix(5))
                        }.joined(separator: " ")
                    )
                }
            }
        } catch {
            emergencyRecipientCount = 0
            safetyNumbers = []
            if isUnauthorized(error) { await wipeRevokedDevice() }
        }
    }

    func signOut() async {
        if let session {
            try? await ControlApi(
                serverUrl: session.serverUrl,
                allowInsecureHttp: Self.allowInsecure(session.serverUrl)
            ).removePushRegistration(session: session, provider: "apns-ptt")
        }
        if let joinedChannelId { leaveSystemChannel(joinedChannelId) }
        await voice?.shutdown()
        voice = nil
        try? credentials.clear()
        session = nil
        channels = []
        devices = []
        history = []
        emergencyRecipientCount = 0
        safetyNumbers = []
        isEmergency = false
        selectedChannelId = ""
        encryptionDetails = nil
        joinedChannelId = nil
        isSystemChannelJoined = false
        status = "Signed out. Device cryptographic identity remains protected in Keychain."
    }

    func deleteAccount() async {
        guard let session else { return }
        await perform("Deleting account and rotating channel keys…") {
            try await ControlApi(
                serverUrl: session.serverUrl,
                allowInsecureHttp: Self.allowInsecure(session.serverUrl)
            ).deleteAccount(session: session)
            if let joinedChannelId { leaveSystemChannel(joinedChannelId) }
            await voice?.shutdown()
            voice = nil
            try credentials.clear()
            try KeychainSignalProtocolStore.resetLocalDeviceState()
            signalStore = try KeychainSignalProtocolStore()
            self.session = nil
            channels = []
            devices = []
            history = []
            emergencyRecipientCount = 0
            safetyNumbers = []
            selectedChannelId = ""
            encryptionDetails = nil
            joinedChannelId = nil
            isSystemChannelJoined = false
            isTransmitting = false
            isEmergency = false
            status = "Account deleted. Server access and local encryption data were removed."
        }
    }

    func acceptDeepLink(_ url: URL) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if let token = oneTimeToken(from: url) {
            if components.host == "recover" {
                recoveryToken = token
                status = "Recovery link received. Submit it for independent administrator approval."
            } else {
                magicToken = token
                await consumeMagicLink()
            }
        }
    }

    private func activate(_ session: DeviceSession) async {
        guard let signalStore else {
            status = "Secure storage is unavailable, so encrypted voice cannot start."
            return
        }
        do {
            voice = try ProductionVoiceSession(
                session: session,
                signalStore: signalStore,
                audio: audio,
                allowInsecureHttp: Self.allowInsecure(session.serverUrl),
                requiresExternalAudioActivation: pttUsesSystemFramework
            ) { [weak self] event in
                Task { @MainActor in self?.receive(event) }
            }
            // Enrollment is not operational until peers can establish a PQXDH session with
            // this device. Await publication so backgrounding immediately after sign-in cannot
            // leave the account visible but unable to receive authenticated Sender Keys.
            await voice?.publishPreKeys()
            await refreshChannels()
        } catch {
            status = "Could not initialize the encrypted voice session: \(error.localizedDescription)"
        }
    }

    private func receive(_ event: VoiceSessionEvent) {
        switch event {
        case .preparing(let name): status = "Preparing \(name) securely…"
        case .ready(let detail):
            status = detail
            isTransmitting = false
            isEmergency = false
            if let joinedChannelId { systemPtt.setRemoteParticipant(name: nil, channelId: joinedChannelId) }
        case .requestingFloor: status = "Waiting for an authenticated floor grant…"
        case .floorDenied(let reason):
            status = reason
            isTransmitting = false
        case .transmitting(let details):
            status = details.isSos ? "Priority SOS is transmitting. Stop when safe." : "Encrypted floor granted. Release to stop."
            encryptionDetails = details
            isEmergency = details.isSos
        case .receiving(let details):
            status = details.isSos
                ? "SOS from encrypted teammate device \(details.senderDeviceId)."
                : "Receiving authenticated encrypted voice."
            encryptionDetails = details
            systemPtt.setRemoteParticipant(name: "Encrypted teammate", channelId: details.channelId)
        case .historyUpdated:
            status = "Encrypted history updated."
            Task { await refreshHistory() }
        case .deviceRevoked:
            Task { await wipeRevokedDevice() }
        case .error(let detail):
            status = detail
            isTransmitting = false
            isEmergency = false
        }
    }

    private func wipeRevokedDevice() async {
        guard !revocationInProgress else { return }
        revocationInProgress = true
        if let joinedChannelId { leaveSystemChannel(joinedChannelId) }
        await voice?.shutdown()
        voice = nil
        try? credentials.clear()
        try? KeychainSignalProtocolStore.resetLocalDeviceState()
        signalStore = try? KeychainSignalProtocolStore()
        session = nil
        channels = []
        devices = []
        history = []
        emergencyRecipientCount = 0
        safetyNumbers = []
        encryptionDetails = nil
        joinedChannelId = nil
        isSystemChannelJoined = false
        isTransmitting = false
        isEmergency = false
        status = "This device was revoked. Local credentials and encryption keys were removed."
        revocationInProgress = false
    }

    func systemPttDidJoin(_ channelId: UUID) {
        joinedChannelId = channelId
        isSystemChannelJoined = true
        if pttUsesSystemFramework { systemPtt.setReady(channelId: channelId) }
        status = pttUsesSystemFramework
            ? "System Push to Talk is active for \(selectedChannel?.displayName ?? "the selected channel")."
            : "Simulator voice is active for \(selectedChannel?.displayName ?? "the selected channel")."
    }

    func systemPttDidLeave(_ channelId: UUID) {
        if joinedChannelId == channelId { joinedChannelId = nil }
        isSystemChannelJoined = false
        transmitRequested = false
        isTransmitting = false
        Task { await voice?.endTransmit() }
        status = "System Push to Talk channel left."
    }

    func systemPttDidBeginTransmitting(_ channelId: UUID) {
        guard transmitRequested, joinedChannelId == channelId else {
            systemPtt.stopTransmitting(channelId: channelId)
            return
        }
        isTransmitting = true
        isEmergency = sosRequested
        Task { await voice?.beginTransmit(sos: sosRequested) }
    }

    func systemPttDidEndTransmitting(_ channelId: UUID) {
        transmitRequested = false
        sosRequested = false
        isTransmitting = false
        isEmergency = false
        Task { await voice?.endTransmit() }
    }

    func systemPttDidActivate(_ session: AVAudioSession) {
        do {
            try audio.systemDidActivate(session)
            Task { await voice?.setExternalAudioActive(true) }
        } catch {
            systemPttFailed("Audio activation failed: \(error.localizedDescription)")
        }
    }

    func systemPttDidDeactivate() {
        Task { await voice?.setExternalAudioActive(false) }
        audio.systemDidDeactivate()
    }

    func systemPttReceived(pushToken: Data) async {
        guard let session else { return }
        do {
            try await ControlApi(
                serverUrl: session.serverUrl,
                allowInsecureHttp: Self.allowInsecure(session.serverUrl)
            ).registerPush(session: session, provider: "apns-ptt", token: pushToken)
        } catch {
            systemPttFailed("Push registration failed: \(error.localizedDescription)")
        }
    }

    func systemPttReceivedIncomingPush(_ channelId: UUID) {
        guard joinedChannelId == channelId else { return }
        status = "Incoming encrypted transmission is reconnecting…"
        if let selectedChannel { Task { await voice?.prepare(selectedChannel) } }
    }

    func systemPttFailed(_ detail: String) {
        transmitRequested = false
        isTransmitting = false
        status = detail
    }

    private func leaveSystemChannel(_ channelId: UUID) {
        if pttUsesSystemFramework { systemPtt.leave(channelId: channelId) }
        else { systemPttDidLeave(channelId) }
    }

    private func perform(_ progress: String, operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        status = progress
        do { try await operation() }
        catch {
            if isUnauthorized(error) { await wipeRevokedDevice() }
            else { status = error.localizedDescription }
        }
        busy = false
    }

    private func isUnauthorized(_ error: Error) -> Bool {
        guard case let ControlApiError.server(status, _) = error else { return false }
        return status == 401
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        @unknown default: return false
        }
    }

    private static func allowInsecure(_ value: String) -> Bool {
        #if DEBUG
        return value.lowercased().hasPrefix("http://")
        #else
        return false
        #endif
    }
}

struct TalkView: View {
    @StateObject private var model = TalkModel()
    @State private var confirmAccountDeletion = false

    var body: some View {
        NavigationStack {
            ZStack {
                PttPalette.background.ignoresSafeArea()
                Group {
                    if model.session == nil { onboarding }
                    else { talk }
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 9) {
                        ZStack {
                            Circle().fill(PttPalette.brandGradient)
                            Image(systemName: "waveform.badge.mic")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(PttPalette.onAccent)
                        }
                        .frame(width: 32, height: 32)
                        Text("PTT Talk")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(PttPalette.text)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .toolbarBackground(PttPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onOpenURL { url in Task { await model.acceptDeepLink(url) } }
#if DEBUG
            .task { await model.consumeDebugMagicLinkIfNeeded() }
#endif
            .confirmationDialog(
                "Permanently delete this account?",
                isPresented: $confirmAccountDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete account and server data", role: .destructive) {
                    Task { await model.deleteAccount() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the account from every channel, revokes both devices, de-identifies its email, and deletes local keys and history. Previously delivered ciphertext cannot be recalled.")
            }
        }
    }

    private var onboarding: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(PttPalette.brandGradient)
                            .shadow(color: PttPalette.accent.opacity(0.28), radius: 24, y: 10)
                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 42, weight: .bold))
                            .foregroundStyle(PttPalette.onAccent)
                    }
                    .frame(width: 92, height: 92)
                    Text("Private team access")
                        .font(.largeTitle.bold())
                        .foregroundStyle(PttPalette.text)
                        .multilineTextAlignment(.center)
                    Text("Fast, authenticated push-to-talk for the people your team trusts.")
                        .font(.body)
                        .foregroundStyle(PttPalette.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                .padding(.vertical, 12)

                PttCard(title: "Join your team", eyebrow: "PRIVATE SERVER", symbol: "shield.checkered") {
                    TextField("https://ptt.example.com", text: $model.serverUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(PttTextFieldStyle())
                    TextField("Email", text: $model.email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .textFieldStyle(PttTextFieldStyle())
                    SecureField("Invitation code", text: $model.invitationCode)
                        .textFieldStyle(PttTextFieldStyle())
                    Button("Email me a sign-in link") { Task { await model.requestMagicLink() } }
                        .buttonStyle(PttSecondaryButtonStyle())
                        .disabled(model.busy || model.email.isEmpty || model.invitationCode.isEmpty)
                }

                PttCard(title: "Finish sign in", eyebrow: "SECURE THIS DEVICE", symbol: "key.fill") {
                    SecureField("One-time token", text: $model.magicToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(PttTextFieldStyle())
                    Button("Secure this device") { Task { await model.consumeMagicLink() } }
                        .buttonStyle(PttPrimaryButtonStyle())
                        .disabled(model.busy || model.magicToken.isEmpty)
                }

                statusBanner

                PttCard(title: "Second device", eyebrow: "EXISTING ACCOUNT", symbol: "iphone.gen2.badge.plus") {
                    if model.pendingDeviceLink != nil {
                        PttEmptyState(symbol: "clock.arrow.circlepath", text: "Waiting for approval from an active device.")
                        Button("Check device approval") { Task { await model.checkDeviceLink() } }
                            .buttonStyle(PttPrimaryButtonStyle())
                    } else {
                        TextField("Link request ID", text: $model.linkRequestId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(PttTextFieldStyle())
                        SecureField("One-time link code", text: $model.linkCode)
                            .textFieldStyle(PttTextFieldStyle())
                        Button("Request second-device approval") { Task { await model.claimDeviceLink() } }
                            .buttonStyle(PttSecondaryButtonStyle())
                            .disabled(model.busy || model.linkRequestId.isEmpty || model.linkCode.isEmpty)
                    }
                }

                PttCard(title: "Account recovery", eyebrow: "ADMIN APPROVAL REQUIRED", symbol: "person.badge.key.fill") {
                    if model.pendingRecovery != nil {
                        PttEmptyState(symbol: "person.crop.circle.badge.clock", text: "Waiting for approval from a different instance administrator.")
                        Button("Check recovery approval") { Task { await model.checkRecovery() } }
                            .buttonStyle(PttPrimaryButtonStyle())
                    } else {
                        TextField("Account email", text: $model.recoveryEmail)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .textFieldStyle(PttTextFieldStyle())
                        Button("Email a recovery link") { Task { await model.requestRecovery() } }
                            .buttonStyle(PttSecondaryButtonStyle())
                            .disabled(model.busy || model.recoveryEmail.isEmpty)
                        SecureField("Recovery token", text: $model.recoveryToken)
                            .textFieldStyle(PttTextFieldStyle())
                        Button("Request administrator approval") { Task { await model.submitRecovery() } }
                            .buttonStyle(PttSecondaryButtonStyle())
                            .disabled(model.busy || model.recoveryToken.isEmpty)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 36)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var talk: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                sessionHeader

                PttCard(title: "Live channel", eyebrow: "TALK TARGET", symbol: "antenna.radiowaves.left.and.right") {
                    if model.channels.isEmpty {
                        PttEmptyState(symbol: "person.2.slash", text: "No assigned channels")
                    } else {
                        HStack(spacing: 12) {
                            Picker("Talk target", selection: $model.selectedChannelId) {
                                ForEach(model.channels) { channel in
                                    Text(channel.displayName).tag(channel.channelId)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(PttPalette.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                Task { await model.refreshChannels() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.body.weight(.semibold))
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(PttPalette.accent)
                            .background(PttPalette.raised, in: Circle())
                            .accessibilityLabel("Refresh channels")
                        }
                        .onChange(of: model.selectedChannelId) { _ in Task { await model.selectChannel() } }
                        if model.isSystemChannelJoined {
                            Button(model.systemChannelJoinTitle) {}
                                .buttonStyle(PttSecondaryButtonStyle())
                                .disabled(true)
                        } else {
                            Button(model.systemChannelJoinTitle) {
                                model.joinSelectedSystemChannel()
                            }
                            .buttonStyle(PttPrimaryButtonStyle())
                        }
                    }
                }

                PttCard(title: "Push to talk", eyebrow: "HOLD · SPEAK · RELEASE", symbol: "mic.fill") {
                    holdButton
                    Text("The authenticated floor must be granted before microphone audio leaves this device.")
                        .font(.footnote)
                        .foregroundStyle(PttPalette.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    statusBanner
                }

                PttCard(title: "Presence", eyebrow: "TEAM AVAILABILITY", symbol: "person.wave.2.fill") {
                    Picker("Mode", selection: $model.presenceMode) {
                        Text("Available").tag("available")
                        Text("Busy").tag("busy")
                        Text("Solo").tag("solo")
                        Text("Standby").tag("standby")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.presenceMode) { _ in model.updatePresence() }
                }

                PttCard(title: "Emergency", eyebrow: "PRIORITY FLOOR", symbol: "sos.circle.fill") {
                    Text("SOS targets \(model.emergencyRecipientCount) other active device\(model.emergencyRecipientCount == 1 ? "" : "s") in the selected channel and can preempt normal voice.")
                        .font(.footnote)
                        .foregroundStyle(PttPalette.muted)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { emergencyButtons }
                        VStack(spacing: 10) { emergencyButtons }
                    }
                }

                if let details = model.encryptionDetails {
                    PttCard(title: "Encryption", eyebrow: "LIVE CRYPTOGRAPHY", symbol: "lock.shield.fill") {
                        encryption(details)
                    }
                }

                PttCard(title: "History", eyebrow: "ENCRYPTED ON THIS DEVICE", symbol: "clock.arrow.circlepath") {
                    if model.history.isEmpty {
                        PttEmptyState(symbol: "waveform.slash", text: "No encrypted transmissions saved on this device.")
                    } else {
                        ForEach(model.history.prefix(10)) { item in historyRow(item) }
                        if model.history.count > 10 {
                            DisclosureGroup("Show \(model.history.count - 10) older transmissions") {
                                ForEach(model.history.dropFirst(10)) { item in historyRow(item) }
                            }
                            .tint(PttPalette.accent)
                        }
                    }
                    Button("Refresh history") { Task { await model.refreshHistory() } }
                        .buttonStyle(PttSecondaryButtonStyle())
                }

                PttCard(title: "Safety numbers", eyebrow: "VERIFY TEAMMATES", symbol: "number.square.fill") {
                    if model.safetyNumbers.isEmpty {
                        PttEmptyState(symbol: "person.crop.circle.badge.questionmark", text: "No other active devices are in this channel.")
                    } else {
                        ForEach(model.safetyNumbers) { safety in
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Encrypted teammate \(short(safety.aci)) · device \(safety.deviceId)", systemImage: "checkmark.shield.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(PttPalette.text)
                                Text(safety.value)
                                    .font(.system(.caption, design: .monospaced).weight(.medium))
                                    .foregroundStyle(PttPalette.accent)
                                    .textSelection(.enabled)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(PttPalette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        Text("Compare after a device-key change over a trusted channel. Raw identity keys are never displayed.")
                            .font(.footnote)
                            .foregroundStyle(PttPalette.muted)
                    }
                }

                deviceCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .refreshable { await model.refreshChannels() }
    }

    private var sessionHeader: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(PttPalette.raised)
                Image(systemName: model.isSystemChannelJoined ? "antenna.radiowaves.left.and.right" : "lock.shield")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(model.isSystemChannelJoined ? PttPalette.success : PttPalette.accent)
            }
            .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 4) {
                Text("SECURE SESSION")
                    .font(.caption2.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(PttPalette.accent)
                Text(model.selectedChannel?.displayName ?? "Choose a channel")
                    .font(.title2.bold())
                    .foregroundStyle(PttPalette.text)
                Text(model.isSystemChannelJoined ? "Voice channel joined" : "Encrypted voice is not joined")
                    .font(.caption)
                    .foregroundStyle(model.isSystemChannelJoined ? PttPalette.success : PttPalette.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(PttPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(PttPalette.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var emergencyButtons: some View {
        Button(model.isEmergency ? "Stop priority SOS voice" : "Start priority SOS voice") {
            if model.isEmergency { model.endTransmit() }
            else { model.beginSos() }
        }
        .buttonStyle(PttDangerButtonStyle(filled: true))
        .disabled(model.selectedChannel == nil || !model.isSystemChannelJoined)
        Button("Send silent SOS") { model.sendSilentSos() }
            .buttonStyle(PttDangerButtonStyle(filled: false))
            .disabled(model.selectedChannel == nil)
    }

    private var holdButton: some View {
        ZStack {
            Circle()
                .stroke(model.isTransmitting ? PttPalette.danger.opacity(0.24) : PttPalette.accent.opacity(0.16), lineWidth: 18)
                .frame(width: 224, height: 224)
                .scaleEffect(model.isTransmitting ? 1.06 : 1)
            Circle()
                .fill(model.isTransmitting ? PttPalette.dangerGradient : PttPalette.brandGradient)
                .shadow(
                    color: (model.isTransmitting ? PttPalette.danger : PttPalette.accent).opacity(0.32),
                    radius: model.isTransmitting ? 26 : 18,
                    y: 10
                )
                .frame(width: 190, height: 190)
            VStack(spacing: 10) {
                Image(systemName: model.isTransmitting ? "waveform" : "mic.fill")
                    .font(.system(size: 44, weight: .bold))
                    .symbolRenderingMode(.monochrome)
                Text(model.isTransmitting ? "RELEASE" : "HOLD TO TALK")
                    .font(.headline.weight(.heavy))
                    .tracking(0.8)
            }
            .foregroundStyle(PttPalette.onAccent)
        }
        .frame(maxWidth: .infinity, minHeight: 236)
        .contentShape(Circle())
        .animation(.easeInOut(duration: 0.2), value: model.isTransmitting)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in model.beginTransmit() }
                    .onEnded { _ in model.endTransmit() }
            )
        .opacity(model.selectedChannel == nil || model.selectedChannel?.role == "listen" ? 0.38 : 1)
        .allowsHitTesting(model.selectedChannel != nil && model.selectedChannel?.role != "listen")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.isTransmitting ? "Release to stop talking" : "Hold to talk")
        .accessibilityHint("Press and hold while speaking, then release")
        .accessibilityAddTraits(.isButton)
    }

    private func historyRow(_ item: VoiceHistoryItem) -> some View {
        Button {
            model.playHistory(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.fill")
                    .font(.caption.bold())
                    .foregroundStyle(PttPalette.onAccent)
                    .frame(width: 34, height: 34)
                    .background(PttPalette.brandGradient, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.senderAci == model.session?.aci ? "You" : "Encrypted teammate")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PttPalette.text)
                    Text("\(item.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(item.durationMs / 1_000)s · device \(item.senderDeviceId)")
                        .font(.caption)
                        .foregroundStyle(PttPalette.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(PttPalette.muted)
            }
            .padding(11)
            .background(PttPalette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var statusBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            if model.busy {
                ProgressView().tint(PttPalette.accent)
            } else {
                Image(systemName: model.isSystemChannelJoined ? "checkmark.shield.fill" : "lock.shield.fill")
                    .foregroundStyle(model.isSystemChannelJoined ? PttPalette.success : PttPalette.accent)
            }
            Text(model.status)
                .font(.footnote.weight(.medium))
                .foregroundStyle(PttPalette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(PttPalette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status, \(model.status)")
    }

    private var deviceCard: some View {
        PttCard(title: "Device & privacy", eyebrow: "ACCOUNT SECURITY", symbol: "iphone.gen2") {
            if let session = model.session {
                VStack(spacing: 10) {
                    LabeledContent("Account", value: short(session.aci))
                    Divider().overlay(PttPalette.border)
                    LabeledContent("Device", value: "\(session.deviceId) of 2")
                    Divider().overlay(PttPalette.border)
                    LabeledContent("Mailbox", value: short(session.mailboxId))
                }
                .font(.subheadline)
                .foregroundStyle(PttPalette.text)
                .padding(12)
                .background(PttPalette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            ForEach(model.devices, id: \.deviceId) { device in
                HStack {
                    Image(systemName: "iphone.gen2")
                        .foregroundStyle(device.status == "active" ? PttPalette.success : PttPalette.muted)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PttPalette.text)
                        Text("Device \(device.deviceId) · \(device.status)")
                            .font(.caption)
                            .foregroundStyle(PttPalette.muted)
                    }
                    Spacer()
                    if device.deviceId != model.session?.deviceId, device.status == "active" {
                        Button("Revoke", role: .destructive) {
                            Task { await model.revokeDevice(device) }
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
                .padding(12)
                .background(PttPalette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Button("Link another device") { Task { await model.createDeviceLink() } }
                .buttonStyle(PttSecondaryButtonStyle())
                .disabled(model.devices.filter { $0.status == "active" }.count >= 2)
            if !model.generatedLinkCode.isEmpty {
                Text("Request ID\n\(model.linkRequestId)\n\nOne-time code\n\(model.generatedLinkCode)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(PttPalette.text)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PttPalette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Button("Approve claimed device") { Task { await model.approveDeviceLink() } }
                    .buttonStyle(PttPrimaryButtonStyle())
            }
            ShareLink(item: model.supportReport, subject: Text("PTT Talk support report")) {
                Label("Share privacy-redacted support report", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PttSecondaryButtonStyle())
            Link(destination: URL(string: "https://golanbenoni.github.io/ptt-talk-privacy/#deletion")!) {
                Label("Privacy policy and data choices", systemImage: "hand.raised.fill")
            }
            .buttonStyle(PttSecondaryButtonStyle())
            Button("Sign out", role: .destructive) { Task { await model.signOut() } }
                .buttonStyle(PttDangerButtonStyle(filled: false))
            Button("Delete account and server data", role: .destructive) {
                confirmAccountDeletion = true
            }
            .buttonStyle(PttDangerButtonStyle(filled: false))
        }
    }

    private func encryption(_ value: VoiceEncryptionDetails) -> some View {
        Text([
            "media: \(value.algorithm)",
            "key setup: \(value.keyEstablishment)",
            "channel: \(value.channelId.uuidString.lowercased())",
            "talk: \(value.talkId.uuidString.lowercased())",
            "sender: \(short(value.senderAci)) device \(value.senderDeviceId)",
            "demux: \(value.senderDemux)",
            "key id: \(String(value.kid, radix: 16))",
            "membership epoch: \(value.membershipEpoch)",
            "emergency: \(value.isSos ? "SOS" : "no")",
        ].joined(separator: "\n"))
        .font(.system(.caption, design: .monospaced).weight(.medium))
        .foregroundStyle(PttPalette.text)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PttPalette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .textSelection(.enabled)
    }

    private func short(_ value: String) -> String {
        value.count > 12 ? "\(value.prefix(8))…\(value.suffix(4))" : value
    }
}

private enum PttPalette {
    static let background = adaptive(light: 0xF4F7FB, dark: 0x061125)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x0D1D36)
    static let raised = adaptive(light: 0xEAF1F8, dark: 0x142944)
    static let border = adaptive(light: 0xD9E4EF, dark: 0x27415E)
    static let text = adaptive(light: 0x10233F, dark: 0xF4FAFF)
    static let muted = adaptive(light: 0x58708A, dark: 0xA4B7CC)
    static let accent = adaptive(light: 0x007FA8, dark: 0x18D8EF)
    static let success = adaptive(light: 0x087C69, dark: 0x39D7B5)
    static let danger = adaptive(light: 0xC62948, dark: 0xFF496A)
    static let onAccent = Color.white
    static let brandGradient = LinearGradient(
        colors: [Color(red: 0.02, green: 0.84, blue: 0.90), Color(red: 0.04, green: 0.48, blue: 0.96)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let dangerGradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.29, blue: 0.42), Color(red: 0.72, green: 0.08, blue: 0.22)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in color(traits.userInterfaceStyle == .dark ? dark : light) })
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

private struct PttCard<Content: View>: View {
    let title: String
    let eyebrow: String
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PttPalette.accent)
                    .frame(width: 34, height: 34)
                    .background(PttPalette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(eyebrow)
                        .font(.caption2.weight(.bold))
                        .tracking(1.15)
                        .foregroundStyle(PttPalette.accent)
                    Text(title)
                        .font(.title3.bold())
                        .foregroundStyle(PttPalette.text)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PttPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(PttPalette.border, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.04), radius: 12, y: 5)
    }
}

private struct PttEmptyState: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(PttPalette.muted)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(PttPalette.muted)
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(PttPalette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct PttTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.body)
            .foregroundStyle(PttPalette.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(PttPalette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(PttPalette.border, lineWidth: 1)
            }
    }
}

private struct PttPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.bold))
            .foregroundStyle(PttPalette.onAccent)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 14)
            .background(PttPalette.brandGradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PttSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(PttPalette.accent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 14)
            .background(PttPalette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(PttPalette.border, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct PttDangerButtonStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.bold))
            .foregroundStyle(filled ? PttPalette.onAccent : PttPalette.danger)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 12)
            .background(
                filled ? PttPalette.danger : PttPalette.danger.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(PttPalette.danger.opacity(filled ? 0 : 0.4), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}
