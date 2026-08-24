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

    init() {
        systemPtt = SystemPttCoordinator()
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

    func acceptDeepLink(_ url: URL) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if let token = components.queryItems?.first(where: { $0.name == "token" })?.value {
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
            Task { await voice?.publishPreKeys() }
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

    var body: some View {
        NavigationStack {
            Group {
                if model.session == nil { onboarding }
                else { talk }
            }
            .navigationTitle("PTT Talk")
            .onOpenURL { url in Task { await model.acceptDeepLink(url) } }
        }
    }

    private var onboarding: some View {
        Form {
            Section("Private server") {
                TextField("https://ptt.example.com", text: $model.serverUrl)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Email", text: $model.email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                SecureField("Invitation code", text: $model.invitationCode)
                Button("Email me a sign-in link") { Task { await model.requestMagicLink() } }
                    .disabled(model.busy || model.email.isEmpty || model.invitationCode.isEmpty)
            }
            Section("Finish sign in") {
                SecureField("One-time token", text: $model.magicToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Secure this device") { Task { await model.consumeMagicLink() } }
                    .disabled(model.busy || model.magicToken.isEmpty)
            }
            Section("Second device") {
                if model.pendingDeviceLink != nil {
                    Text("Waiting for approval from an active device.")
                    Button("Check device approval") { Task { await model.checkDeviceLink() } }
                } else {
                    TextField("Link request ID", text: $model.linkRequestId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("One-time link code", text: $model.linkCode)
                    Button("Request second-device approval") { Task { await model.claimDeviceLink() } }
                        .disabled(model.busy || model.linkRequestId.isEmpty || model.linkCode.isEmpty)
                }
            }
            Section("Account recovery") {
                if model.pendingRecovery != nil {
                    Text("Waiting for approval from a different instance administrator.")
                    Button("Check recovery approval") { Task { await model.checkRecovery() } }
                } else {
                    TextField("Account email", text: $model.recoveryEmail)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                    Button("Email a recovery link") { Task { await model.requestRecovery() } }
                        .disabled(model.busy || model.recoveryEmail.isEmpty)
                    SecureField("Recovery token", text: $model.recoveryToken)
                    Button("Request administrator approval") { Task { await model.submitRecovery() } }
                        .disabled(model.busy || model.recoveryToken.isEmpty)
                }
            }
            statusSection
        }
    }

    private var talk: some View {
        Form {
            Section("Channel") {
                if model.channels.isEmpty {
                    Text("No assigned channels")
                } else {
                    Picker("Talk target", selection: $model.selectedChannelId) {
                        ForEach(model.channels) { channel in
                            Text(channel.displayName).tag(channel.channelId)
                        }
                    }
                    .onChange(of: model.selectedChannelId) { _ in Task { await model.selectChannel() } }
                    Button(model.systemChannelJoinTitle) {
                        model.joinSelectedSystemChannel()
                    }
                    .disabled(model.isSystemChannelJoined)
                }
            }
            Section("Presence") {
                Picker("Mode", selection: $model.presenceMode) {
                    Text("Available").tag("available")
                    Text("Busy").tag("busy")
                    Text("Solo").tag("solo")
                    Text("Standby").tag("standby")
                }
                .onChange(of: model.presenceMode) { _ in model.updatePresence() }
            }
            Section("Push to talk") {
                holdButton
                Text("Hold while speaking. The server must grant the channel floor before microphone audio is sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Emergency") {
                Text("SOS targets \(model.emergencyRecipientCount) other active device\(model.emergencyRecipientCount == 1 ? "" : "s") in the selected channel and can preempt normal voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(model.isEmergency ? "Stop priority SOS voice" : "Start priority SOS voice", role: .destructive) {
                    if model.isEmergency { model.endTransmit() }
                    else { model.beginSos() }
                }
                .disabled(model.selectedChannel == nil || !model.isSystemChannelJoined)
                Button("Send silent SOS", role: .destructive) { model.sendSilentSos() }
                    .disabled(model.selectedChannel == nil)
            }
            statusSection
            if let details = model.encryptionDetails {
                Section("Encryption") { encryption(details) }
            }
            Section("Safety numbers") {
                if model.safetyNumbers.isEmpty {
                    Text("No other active devices are in this channel.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.safetyNumbers) { safety in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Encrypted teammate \(short(safety.aci)) · device \(safety.deviceId)")
                            Text(safety.value)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    Text("Compare after a device-key change over a trusted channel. Raw identity keys are never displayed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("History") {
                if model.history.isEmpty {
                    Text("No encrypted transmissions saved on this device.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.history) { item in
                        Button {
                            model.playHistory(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.senderAci == model.session?.aci ? "You" : "Encrypted teammate")
                                Text("\(item.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(item.durationMs / 1_000)s · device \(item.senderDeviceId)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button("Refresh history") { Task { await model.refreshHistory() } }
            }
            Section("Device") {
                if let session = model.session {
                    LabeledContent("Account", value: short(session.aci))
                    LabeledContent("Device", value: "\(session.deviceId) of 2")
                    LabeledContent("Mailbox", value: short(session.mailboxId))
                }
                ForEach(model.devices, id: \.deviceId) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.displayName)
                            Text("Device \(device.deviceId) · \(device.status)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if device.deviceId != model.session?.deviceId, device.status == "active" {
                            Button("Revoke", role: .destructive) {
                                Task { await model.revokeDevice(device) }
                            }
                        }
                    }
                }
                Button("Link another device") { Task { await model.createDeviceLink() } }
                    .disabled(model.devices.filter { $0.status == "active" }.count >= 2)
                if !model.generatedLinkCode.isEmpty {
                    Text("Request ID\n\(model.linkRequestId)\n\nOne-time code\n\(model.generatedLinkCode)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Approve claimed device") { Task { await model.approveDeviceLink() } }
                }
                Button("Refresh channels") { Task { await model.refreshChannels() } }
                ShareLink(item: model.supportReport, subject: Text("PTT Talk support report")) {
                    Label("Share privacy-redacted support report", systemImage: "square.and.arrow.up")
                }
                Button("Sign out", role: .destructive) { Task { await model.signOut() } }
            }
        }
        .refreshable { await model.refreshChannels() }
    }

    private var holdButton: some View {
        Circle()
            .fill(model.isTransmitting ? Color.red : Color.accentColor)
            .frame(width: 190, height: 190)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: model.isTransmitting ? "waveform" : "mic.fill")
                        .font(.system(size: 42, weight: .bold))
                    Text(model.isTransmitting ? "RELEASE" : "HOLD TO TALK")
                        .font(.headline)
                }
                .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in model.beginTransmit() }
                    .onEnded { _ in model.endTransmit() }
            )
            .opacity(model.selectedChannel == nil || model.selectedChannel?.role == "listen" ? 0.45 : 1)
            .allowsHitTesting(model.selectedChannel != nil && model.selectedChannel?.role != "listen")
            .accessibilityLabel(model.isTransmitting ? "Release to stop talking" : "Hold to talk")
    }

    private var statusSection: some View {
        Section("Status") {
            Text(model.status)
            if model.busy { ProgressView() }
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
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }

    private func short(_ value: String) -> String {
        value.count > 12 ? "\(value.prefix(8))…\(value.suffix(4))" : value
    }
}
