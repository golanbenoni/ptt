import AVFoundation
import CryptoKit
import PttTalkLib
import SwiftUI

#if targetEnvironment(simulator)
private let pttUsesSystemFramework = false
#else
private let pttUsesSystemFramework =
    (Bundle.main.object(forInfoDictionaryKey: "PTTUsesSystemFramework") as? Bool) ?? true
#endif

fileprivate struct SafetyNumber: Identifiable {
    let aci: String
    let deviceId: Int
    let value: String
    var id: String { "\(aci):\(deviceId)" }
}

@MainActor
final class TalkModel: ObservableObject {
    @Published var serverUrl = "https://ptttalk.app"
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
    @Published private(set) var magicLinkRequested = false
    @Published private(set) var recoveryLinkRequested = false
    @Published private(set) var incomingEnrollmentLink = false
    @Published private(set) var generatedLinkCode = ""
    @Published private(set) var pendingDeviceLink: PendingDeviceLink?
    @Published private(set) var pendingRecovery: PendingRecovery?
    @Published var selectedChannelId = ""
    @Published private(set) var status = "Sign in to your private PTT server."
    @Published private(set) var encryptionDetails: VoiceEncryptionDetails?
    @Published private(set) var isTransmitting = false
    @Published private(set) var isSystemChannelJoined = false
    @Published private(set) var isMediaRelayReady = false
    @Published private(set) var isMediaRelayReconnecting = false
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
            incomingEnrollmentLink = true
        }
#endif
    }

    var selectedChannel: ChannelSummary? {
        channels.first { $0.channelId == selectedChannelId }
    }

    var isTalkReady: Bool { isSystemChannelJoined && isMediaRelayReady }

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
            "Encrypted media relay ready: \(isMediaRelayReady)",
            "Selected channel role: \(selectedChannel?.role ?? "none")",
            "Selected channel epoch: \(selectedChannel?.membershipEpoch ?? 0)",
            "Excluded: email, server URL, account/device/mailbox IDs, tokens, keys, audio, channel IDs, and message contents",
        ].joined(separator: "\n")
    }

    var generatedDeviceLinkURL: URL? {
        guard let session, !linkRequestId.isEmpty, !generatedLinkCode.isEmpty else { return nil }
        return deviceLinkInviteURL(
            serverUrl: session.serverUrl,
            requestId: linkRequestId,
            linkCode: generatedLinkCode
        )
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
        magicLinkRequested = false
        await perform("Requesting sign-in email…") {
            let api = try ControlApi(serverUrl: serverUrl, allowInsecureHttp: Self.allowInsecure(serverUrl))
            try await api.requestMagicLink(email: email, invitationCode: invitationCode)
            magicLinkRequested = true
            status = "Sign-in email sent. Open its Join PTT Talk button on this device."
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
                identityKey: signalStore.identityPublicKey,
                resumeSecret: try credentials.enrollmentResumeSecret()
            )
            try credentials.save(session: enrolled)
            try credentials.clearEnrollmentResumeSecret()
            session = enrolled
            magicToken = ""
            incomingEnrollmentLink = false
            status = "Device secured. Starting encrypted voice…"
            Task { await activate(enrolled) }
        }
    }

    func cancelIncomingEnrollment() {
        magicToken = ""
        incomingEnrollmentLink = false
        status = "Open your invitation email to join your team."
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
            status = "Device linked. Starting encrypted voice…"
            Task { await activate(active) }
        }
    }

    func requestRecovery() async {
        recoveryLinkRequested = false
        await perform("Requesting recovery email…") {
            let api = try ControlApi(serverUrl: serverUrl, allowInsecureHttp: Self.allowInsecure(serverUrl))
            try await api.requestRecovery(email: recoveryEmail)
            recoveryLinkRequested = true
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
            status = "Device recovered. Starting encrypted voice…"
            Task { await activate(active) }
        }
    }

    func createDeviceLink() async {
        guard let session else { return }
        await perform("Generating a one-time link code…") {
            let api = try ControlApi(serverUrl: session.serverUrl, allowInsecureHttp: Self.allowInsecure(session.serverUrl))
            let link = try await api.startDeviceLink(session: session)
            linkRequestId = link.requestId
            generatedLinkCode = link.linkCode
            status = "Setup link ready. Send it to the new device, open it there, then return here to approve."
        }
    }

    func openAdminConsole() async {
        guard let session else { return }
        await perform("Creating a one-time browser approval…") {
            let api = try ControlApi(serverUrl: session.serverUrl, allowInsecureHttp: Self.allowInsecure(session.serverUrl))
            let handoff = try await api.startAdminConsoleSession(session: session)
            guard await UIApplication.shared.open(handoff.adminUrl) else {
                throw ControlApiError.invalidResponse
            }
            status = "Admin console approved for 15 minutes."
        }
    }

    func approveDeviceLink() async {
        guard let session, !linkRequestId.isEmpty else { return }
        await perform("Approving the independently keyed device…") {
            let api = try ControlApi(serverUrl: session.serverUrl, allowInsecureHttp: Self.allowInsecure(session.serverUrl))
            try await api.approveDeviceLink(session: session, requestId: linkRequestId)
            generatedLinkCode = ""
            linkRequestId = ""
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
        isMediaRelayReady = false
        isMediaRelayReconnecting = false
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
        guard isMediaRelayReady else {
            status = "Encrypted media is reconnecting. Try again in a moment."
            return
        }
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
        guard isMediaRelayReady else {
            status = "Encrypted media is reconnecting. Try again in a moment."
            return
        }
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
        isMediaRelayReady = false
        isMediaRelayReconnecting = false
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
            isMediaRelayReady = false
            isMediaRelayReconnecting = false
            isTransmitting = false
            isEmergency = false
            status = "Account deleted. Server access and local encryption data were removed."
        }
    }

    func acceptDeepLink(_ url: URL) async {
        if let invite = deviceLinkInvite(from: url) {
            guard session == nil else {
                status = "This device is already enrolled. Open the setup link on the device you want to add."
                return
            }
            serverUrl = invite.serverUrl
            linkRequestId = invite.requestId
            linkCode = invite.linkCode
            status = "Secure setup link received. Creating this device's independent encryption keys…"
            await claimDeviceLink()
            return
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "ptttalk.app",
              let action = components.path.split(separator: "/").last.map(String.init),
              action == "enroll" || action == "recover"
        else { return }
        guard session == nil else {
            status = "This device is already enrolled. Sign out before joining a different team."
            return
        }
        serverUrl = "https://ptttalk.app"
        if let token = oneTimeToken(from: url), (32...256).contains(token.count) {
            if action == "recover" {
                recoveryToken = token
                status = "Recovery link received. Submit it for independent administrator approval."
            } else {
                magicToken = token
                incomingEnrollmentLink = true
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
        case .preparing(let name):
            isMediaRelayReady = false
            isMediaRelayReconnecting = false
            status = "Preparing \(name) securely…"
        case .relayState(let state):
            switch state {
            case .connected(let transport):
                isMediaRelayReady = true
                isMediaRelayReconnecting = false
                status = "Encrypted media connected over \(transport)."
            case .reconnecting(let attempt):
                isMediaRelayReady = false
                isMediaRelayReconnecting = true
                isTransmitting = false
                isEmergency = false
                status = attempt == 1
                    ? "Encrypted media disconnected. Reconnecting…"
                    : "Reconnecting encrypted media (attempt \(attempt))…"
            case .unavailable:
                isMediaRelayReady = false
                isMediaRelayReconnecting = true
                isTransmitting = false
                isEmergency = false
                status = "Renewing the encrypted media connection…"
            }
        case .ready(let detail):
            if isMediaRelayReady { status = detail }
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
        isMediaRelayReady = false
        isMediaRelayReconnecting = false
        isTransmitting = false
        isEmergency = false
        status = "This device was revoked. Local credentials and encryption keys were removed."
        revocationInProgress = false
    }

    func systemPttDidJoin(_ channelId: UUID) {
        joinedChannelId = channelId
        isSystemChannelJoined = true
        if pttUsesSystemFramework { systemPtt.setReady(channelId: channelId) }
        if isMediaRelayReady {
            status = pttUsesSystemFramework
                ? "System Push to Talk is active for \(selectedChannel?.displayName ?? "the selected channel")."
                : "Simulator voice is active for \(selectedChannel?.displayName ?? "the selected channel")."
        } else {
            status = "Voice channel joined. Securing the encrypted media connection…"
        }
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

private enum OnboardingRoute {
    case join
    case manualInvitation
    case checkEmail
    case manualCode
    case finishingEnrollment
    case secondDevice
    case recovery
}

private enum AppSection: Hashable {
    case talk
    case activity
    case settings
}

struct TalkView: View {
    @StateObject private var model = TalkModel()
    @State private var confirmAccountDeletion = false
    @State private var onboardingRoute: OnboardingRoute = .join
    @State private var selectedSection: AppSection = .talk
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ZStack {
                PttPalette.background.ignoresSafeArea()
                Group {
                    if model.session == nil { onboarding }
                    else { talk }
                }
                if scenePhase != .active {
                    ZStack {
                        PttPalette.background.ignoresSafeArea()
                        VStack(spacing: 12) {
                            Image(systemName: "waveform.circle.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(PttPalette.accent)
                            Text("PTT Talk")
                                .font(.title2.bold())
                                .foregroundStyle(PttPalette.text)
                            Text("Protected while this device is inactive")
                                .font(.subheadline)
                                .foregroundStyle(PttPalette.muted)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .toolbar(model.session == nil ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 9) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(PttPalette.brandGradient)
                            Image(systemName: "waveform")
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
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let url = activity.webpageURL else { return }
                Task { await model.acceptDeepLink(url) }
            }
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
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(PttPalette.brandGradient)
                            .shadow(color: PttPalette.accent.opacity(0.22), radius: 20, y: 8)
                        Image(systemName: "waveform")
                            .font(.system(size: 40, weight: .bold))
                            .foregroundStyle(PttPalette.onAccent)
                    }
                    .frame(width: 84, height: 84)
                    Text("Private voice for your team")
                        .font(.largeTitle.bold())
                        .foregroundStyle(PttPalette.text)
                        .multilineTextAlignment(.center)
                    Text("Open your team invitation on this device. PTT Talk handles the server connection and creates your encryption keys automatically.")
                        .font(.body)
                        .foregroundStyle(PttPalette.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                .padding(.vertical, 12)

                onboardingContent

                statusBanner
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 36)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: model.magicLinkRequested) { sent in
            if sent { onboardingRoute = .checkEmail }
        }
        .onChange(of: model.recoveryToken) { token in
            if !token.isEmpty { onboardingRoute = .recovery }
        }
    }

    @ViewBuilder
    private var onboardingContent: some View {
        switch effectiveOnboardingRoute {
        case .join:
            PttCard(title: "Open your team invite", eyebrow: "GET STARTED", symbol: "envelope.open.fill") {
                PttStepRow(number: 1, title: "Open the invitation email", detail: "Use the email address your administrator invited.")
                PttStepRow(number: 2, title: "Tap Join PTT Talk", detail: "The invite securely configures this device for you.")
                PttStepRow(number: 3, title: "Choose a channel and talk", detail: "Hold the talk button while you speak, then release.")
                Button("Open Mail") {
                    if let mail = URL(string: "message://") { openURL(mail) }
                }
                .buttonStyle(PttPrimaryButtonStyle())
            }
            VStack(spacing: 0) {
                PttLinkRow(symbol: "keyboard", title: "Enter invite manually", detail: "Use server, email, and invitation code") {
                    onboardingRoute = .manualInvitation
                }
                Divider().overlay(PttPalette.border).padding(.leading, 56)
                PttLinkRow(symbol: "iphone.gen2", title: "Link a second device", detail: "Requires approval from your active device") {
                    onboardingRoute = .secondDevice
                }
                Divider().overlay(PttPalette.border).padding(.leading, 56)
                PttLinkRow(symbol: "person.badge.key.fill", title: "Recover an account", detail: "Use only when no active device remains") {
                    onboardingRoute = .recovery
                }
            }
            .background(PttPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(PttPalette.border, lineWidth: 1) }

        case .manualInvitation:
            PttCard(title: "Request your sign-in email", eyebrow: "STEP 1 OF 2", symbol: "envelope.badge.shield.half.filled") {
                onboardingLabel("Team server address")
                TextField("https://ptttalk.app", text: $model.serverUrl)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(PttTextFieldStyle())
                onboardingLabel("Your invited email address")
                TextField("name@example.com", text: $model.email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .textFieldStyle(PttTextFieldStyle())
                onboardingLabel("Invitation code")
                SecureField("Code from your administrator", text: $model.invitationCode)
                    .textFieldStyle(PttTextFieldStyle())
                Button("Send sign-in email") {
                    Task { await model.requestMagicLink() }
                }
                .buttonStyle(PttPrimaryButtonStyle())
                .disabled(model.busy || model.email.isEmpty || model.invitationCode.isEmpty)
                Button("Back") { onboardingRoute = .join }
                    .buttonStyle(PttSecondaryButtonStyle())
            }

        case .checkEmail:
            PttCard(title: "Check your email", eyebrow: "STEP 2 OF 2", symbol: "envelope.open.fill") {
                PttEmptyState(symbol: "checkmark.circle.fill", text: "We sent a one-time sign-in link to \(model.email).")
                Text("Open the email on this device and tap Join PTT Talk. The app will return here and finish setup automatically—there is no code to copy.")
                    .font(.body)
                    .foregroundStyle(PttPalette.muted)
                Button("Open Mail") {
                    if let mail = URL(string: "message://") { openURL(mail) }
                }
                .buttonStyle(PttPrimaryButtonStyle())
                Button("Paste a code instead") { onboardingRoute = .manualCode }
                    .buttonStyle(PttSecondaryButtonStyle())
                Button("Use a different invitation") { onboardingRoute = .join }
                    .buttonStyle(PttSecondaryButtonStyle())
            }

        case .manualCode:
            PttCard(title: "Enter your one-time code", eyebrow: "MANUAL SIGN-IN", symbol: "key.fill") {
                Text("Most people can open the email link instead. Use this only if the link opened on another device.")
                    .font(.footnote)
                    .foregroundStyle(PttPalette.muted)
                SecureField("Code from the sign-in email", text: $model.magicToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(PttTextFieldStyle())
                Button("Join this team") { Task { await model.consumeMagicLink() } }
                    .buttonStyle(PttPrimaryButtonStyle())
                    .disabled(model.busy || model.magicToken.isEmpty)
                Button("Back") { onboardingRoute = .checkEmail }
                    .buttonStyle(PttSecondaryButtonStyle())
            }

        case .finishingEnrollment:
            PttCard(title: "Joining your team", eyebrow: "SECURE DEVICE SETUP", symbol: "checkmark.shield.fill") {
                if model.busy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                    Text("PTT Talk is verifying the one-time invitation and creating encryption keys for this device.")
                        .font(.body)
                        .foregroundStyle(PttPalette.muted)
                } else {
                    Text("Setup could not finish. The invitation may have expired or the team server may be unavailable.")
                        .font(.body)
                        .foregroundStyle(PttPalette.muted)
                    Button("Try again") { Task { await model.consumeMagicLink() } }
                        .buttonStyle(PttPrimaryButtonStyle())
                }
                Button("Use a different invitation") {
                    model.cancelIncomingEnrollment()
                    onboardingRoute = .join
                }
                .buttonStyle(PttSecondaryButtonStyle())
            }

        case .secondDevice:
            PttCard(title: "Add this device", eyebrow: "EXISTING ACCOUNT", symbol: "iphone.gen2.badge.plus") {
                if model.pendingDeviceLink != nil {
                    PttEmptyState(symbol: "clock.arrow.circlepath", text: "This device is ready. Return to your current device and tap Approve new device.")
                    Button("Check approval now") { Task { await model.checkDeviceLink() } }
                        .buttonStyle(PttPrimaryButtonStyle())
                } else {
                    PttStepRow(number: 1, title: "Use your current device", detail: "Open Settings → Add another device.")
                    PttStepRow(number: 2, title: "Send the setup link", detail: "Use AirDrop, Messages, or another private method.")
                    PttStepRow(number: 3, title: "Open it here", detail: "PTT Talk fills everything in and requests approval automatically.")
                    Text("Only use the manual fields below if the setup link cannot open this app.")
                        .font(.body)
                        .foregroundStyle(PttPalette.muted)
                    TextField("Link request ID", text: $model.linkRequestId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(PttTextFieldStyle())
                    SecureField("One-time link code", text: $model.linkCode)
                        .textFieldStyle(PttTextFieldStyle())
                    Button("Continue with the manual codes") { Task { await model.claimDeviceLink() } }
                        .buttonStyle(PttPrimaryButtonStyle())
                        .disabled(model.busy || model.linkRequestId.isEmpty || model.linkCode.isEmpty)
                    Button("Back") { onboardingRoute = .join }
                        .buttonStyle(PttSecondaryButtonStyle())
                }
            }

        case .recovery:
            PttCard(title: "Recover your account", eyebrow: "ADMIN APPROVAL REQUIRED", symbol: "person.badge.key.fill") {
                if model.pendingRecovery != nil {
                    PttEmptyState(symbol: "person.crop.circle.badge.clock", text: "A different team administrator must approve this request. This screen can stay open.")
                    Button("Check approval now") { Task { await model.checkRecovery() } }
                        .buttonStyle(PttPrimaryButtonStyle())
                } else if !model.recoveryToken.isEmpty {
                    PttEmptyState(symbol: "checkmark.seal.fill", text: "Recovery email verified.")
                    Text("Continuing will ask a team administrator to approve this replacement device. Approval revokes the old devices and rotates channel keys.")
                        .font(.body)
                        .foregroundStyle(PttPalette.muted)
                    Button("Request administrator approval") { Task { await model.submitRecovery() } }
                        .buttonStyle(PttPrimaryButtonStyle())
                        .disabled(model.busy)
                } else if model.recoveryLinkRequested {
                    PttEmptyState(symbol: "envelope.open.fill", text: "Check \(model.recoveryEmail) and open the recovery link on this device.")
                    Button("Open Mail") {
                        if let mail = URL(string: "message://") { openURL(mail) }
                    }
                    .buttonStyle(PttPrimaryButtonStyle())
                    Button("Use a different account") { onboardingRoute = .join }
                        .buttonStyle(PttSecondaryButtonStyle())
                } else {
                    Text("Use this only if you no longer have an active device. Recovery requires both a fresh email and approval from a different team administrator.")
                        .font(.body)
                        .foregroundStyle(PttPalette.muted)
                    onboardingLabel("Team server address")
                    TextField("https://ptttalk.app", text: $model.serverUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(PttTextFieldStyle())
                    onboardingLabel("Account email")
                    TextField("name@example.com", text: $model.recoveryEmail)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .textFieldStyle(PttTextFieldStyle())
                    Button("Send recovery email") { Task { await model.requestRecovery() } }
                        .buttonStyle(PttPrimaryButtonStyle())
                        .disabled(model.busy || model.recoveryEmail.isEmpty)
                    Button("Back") { onboardingRoute = .join }
                        .buttonStyle(PttSecondaryButtonStyle())
                }
            }
        }
    }

    private var effectiveOnboardingRoute: OnboardingRoute {
        if model.pendingDeviceLink != nil { return .secondDevice }
        if model.pendingRecovery != nil || !model.recoveryToken.isEmpty { return .recovery }
        if model.incomingEnrollmentLink { return .finishingEnrollment }
        return onboardingRoute
    }

    private func onboardingLabel(_ value: String) -> some View {
        Text(value)
            .font(.caption.weight(.semibold))
            .foregroundStyle(PttPalette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var talk: some View {
        TabView(selection: $selectedSection) {
            talkDashboard
                .tabItem { Label("Talk", systemImage: "mic.fill") }
                .tag(AppSection.talk)

            activityDashboard
                .tabItem { Label("Activity", systemImage: "clock.fill") }
                .tag(AppSection.activity)

            settingsDashboard
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppSection.settings)
        }
        .tint(PttPalette.accent)
    }

    private var talkDashboard: some View {
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

            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .refreshable { await model.refreshChannels() }
    }

    private var activityDashboard: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                sectionHeading("Activity", detail: "Encrypted transmissions and teammate verification")

                PttCard(title: "Transmission history", eyebrow: "SAVED ON THIS DEVICE", symbol: "clock.arrow.circlepath") {
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

                PttCard(title: "Safety numbers", eyebrow: "VERIFY TEAMMATES", symbol: "checkmark.shield.fill") {
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

            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private var settingsDashboard: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                sectionHeading("Settings", detail: "Your device, encryption, and privacy")

                if let details = model.encryptionDetails {
                    PttCard(title: "Live encryption", eyebrow: "CURRENT SESSION", symbol: "lock.shield.fill") {
                        encryption(details)
                    }
                } else {
                    PttCard(title: "End-to-end encryption", eyebrow: "SECURITY", symbol: "lock.shield.fill") {
                        PttEmptyState(symbol: "checkmark.shield.fill", text: "Encryption details appear here during a transmission.")
                    }
                }

                deviceCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(PttPalette.text)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(PttPalette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
    }

    private var sessionHeader: some View {
        let isReady = model.isTalkReady
        let isSecuring = model.isSystemChannelJoined && !model.isMediaRelayReady
        let stateColor = isReady ? PttPalette.success : (isSecuring ? PttPalette.warning : PttPalette.accent)
        return HStack(spacing: 13) {
            ZStack {
                Circle().fill(PttPalette.raised)
                Image(systemName: isReady ? "antenna.radiowaves.left.and.right" : (isSecuring ? "arrow.triangle.2.circlepath" : "lock.shield"))
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(stateColor)
            }
            .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 4) {
                Text(isReady ? "Ready to talk" : (isSecuring ? "Securing connection" : "Secure session"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stateColor)
                Text(model.selectedChannel?.displayName ?? "Choose a channel")
                    .font(.title2.bold())
                    .foregroundStyle(PttPalette.text)
                Text(isReady ? "Encrypted voice connected" : (isSecuring ? "Push to talk is temporarily unavailable" : "Encrypted voice is not joined"))
                    .font(.caption)
                    .foregroundStyle(isReady ? PttPalette.success : PttPalette.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .background(PttPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
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
        .disabled(model.selectedChannel == nil || !model.isTalkReady)
        Button("Send silent SOS") { model.sendSilentSos() }
            .buttonStyle(PttDangerButtonStyle(filled: false))
            .disabled(model.selectedChannel == nil || !model.isMediaRelayReady)
    }

    private var holdButton: some View {
        ZStack {
            Circle()
                .fill(model.isTransmitting ? PttPalette.danger.opacity(0.12) : PttPalette.accent.opacity(0.10))
                .frame(width: 210, height: 210)
                .scaleEffect(model.isTransmitting ? 1.04 : 1)
            Circle()
                .fill(model.isTransmitting ? PttPalette.dangerGradient : PttPalette.brandGradient)
                .shadow(
                    color: (model.isTransmitting ? PttPalette.danger : PttPalette.accent).opacity(0.32),
                    radius: model.isTransmitting ? 26 : 18,
                    y: 10
                )
                .frame(width: 178, height: 178)
            VStack(spacing: 8) {
                Image(systemName: model.isTransmitting ? "waveform" : "mic.fill")
                    .font(.system(size: 40, weight: .bold))
                    .symbolRenderingMode(.monochrome)
                Text(model.isTransmitting ? "RELEASE" : "HOLD TO TALK")
                    .font(.headline.weight(.heavy))
                    .tracking(0.35)
            }
            .foregroundStyle(PttPalette.onAccent)
        }
        .frame(maxWidth: .infinity, minHeight: 216)
        .contentShape(Circle())
        .animation(.easeInOut(duration: 0.2), value: model.isTransmitting)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in model.beginTransmit() }
                    .onEnded { _ in model.endTransmit() }
            )
        .opacity(model.selectedChannel == nil || model.selectedChannel?.role == "listen" || !model.isTalkReady ? 0.38 : 1)
        .allowsHitTesting(model.selectedChannel != nil && model.selectedChannel?.role != "listen" && model.isTalkReady)
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
        let isReady = model.isTalkReady
        let isSecuring = model.isSystemChannelJoined && !model.isMediaRelayReady
        return HStack(alignment: .top, spacing: 10) {
            if model.busy {
                ProgressView().tint(PttPalette.accent)
            } else {
                Image(systemName: isReady ? "checkmark.shield.fill" : (isSecuring ? "arrow.triangle.2.circlepath" : "lock.shield.fill"))
                    .foregroundStyle(isReady ? PttPalette.success : (isSecuring ? PttPalette.warning : PttPalette.accent))
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
            Button("Add another device") { Task { await model.createDeviceLink() } }
                .buttonStyle(PttSecondaryButtonStyle())
                .disabled(model.devices.filter { $0.status == "active" }.count >= 2)
            if let link = model.generatedDeviceLinkURL {
                PttEmptyState(
                    symbol: "link.badge.plus",
                    text: "Send this private setup link to the new device. It expires in 10 minutes and works once."
                )
                ShareLink(
                    item: link,
                    subject: Text("Add a device to PTT Talk"),
                    message: Text("Open this one-time setup link on the device you want to add to PTT Talk.")
                ) {
                    Label("Send setup link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PttPrimaryButtonStyle())
                Text("After the new device says it is ready, come back here for the final security approval.")
                    .font(.footnote)
                    .foregroundStyle(PttPalette.muted)
                Button("Approve new device") { Task { await model.approveDeviceLink() } }
                    .buttonStyle(PttPrimaryButtonStyle())
                DisclosureGroup("Manual fallback codes") {
                    Text("Request ID\n\(model.linkRequestId)\n\nOne-time code\n\(model.generatedLinkCode)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(PttPalette.text)
                        .textSelection(.enabled)
                        .padding(.top, 8)
                }
                .font(.footnote.weight(.semibold))
                .tint(PttPalette.accent)
            }
            ShareLink(item: model.supportReport, subject: Text("PTT Talk support report")) {
                Label("Share privacy-redacted support report", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PttSecondaryButtonStyle())
            Button {
                Task { await model.openAdminConsole() }
            } label: {
                Label("Open admin console", systemImage: "rectangle.and.hand.point.up.left.fill")
            }
            .buttonStyle(PttSecondaryButtonStyle())
            Link(destination: URL(string: "https://ptttalk.app/privacy#deletion")!) {
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
    static let warning = adaptive(light: 0xA65D00, dark: 0xFFB84D)
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
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PttPalette.muted)
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(PttPalette.text)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PttPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(PttPalette.border, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.025), radius: 8, y: 3)
    }
}

private struct PttStepRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(PttPalette.onAccent)
                .frame(width: 26, height: 26)
                .background(PttPalette.accent, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PttPalette.text)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(PttPalette.muted)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PttLinkRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PttPalette.accent)
                    .frame(width: 34, height: 34)
                    .background(PttPalette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PttPalette.text)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(PttPalette.muted)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(PttPalette.muted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
