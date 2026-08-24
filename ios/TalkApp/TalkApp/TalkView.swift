import AVFoundation
import PttTalkLib
import SwiftUI

@MainActor
final class TalkModel: ObservableObject {
    @Published var serverUrl = "https://"
    @Published var email = ""
    @Published var invitationCode = ""
    @Published var magicToken = ""
    @Published private(set) var session: DeviceSession?
    @Published private(set) var channels: [ChannelSummary] = []
    @Published var selectedChannelId = ""
    @Published private(set) var status = "Sign in to your private PTT server."
    @Published private(set) var encryptionDetails: VoiceEncryptionDetails?
    @Published private(set) var isTransmitting = false
    @Published private(set) var busy = false

    private let credentials = SecureDeviceStore()
    private let signalStore: KeychainSignalProtocolStore
    private let audio = IOSVoiceAudioEngine()
    private var voice: ProductionVoiceSession?

    init() {
        do {
            signalStore = try KeychainSignalProtocolStore()
            session = try credentials.loadSession()
            if let session {
                serverUrl = session.serverUrl
                Task { await activate(session) }
            }
        } catch {
            fatalError("The device Keychain could not be initialized: \(error)")
        }
    }

    var selectedChannel: ChannelSummary? {
        channels.first { $0.channelId == selectedChannelId }
    }

    func requestMagicLink() async {
        await perform("Requesting sign-in email…") {
            let api = try ControlApi(serverUrl: serverUrl, allowInsecureHttp: Self.allowInsecure(serverUrl))
            try await api.requestMagicLink(email: email, invitationCode: invitationCode)
            status = "Check your email, then paste or open the one-time token."
        }
    }

    func consumeMagicLink() async {
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
        }
    }

    func selectChannel() async {
        guard let selectedChannel else { return }
        await voice?.prepare(selectedChannel)
    }

    func beginTransmit() {
        guard !isTransmitting else { return }
        isTransmitting = true
        Task {
            let allowed = await requestMicrophonePermission()
            guard allowed else {
                status = "Microphone access is required for push-to-talk."
                isTransmitting = false
                return
            }
            await voice?.beginTransmit()
        }
    }

    func endTransmit() {
        guard isTransmitting else { return }
        isTransmitting = false
        Task { await voice?.endTransmit() }
    }

    func signOut() async {
        await voice?.shutdown()
        voice = nil
        try? credentials.clear()
        session = nil
        channels = []
        selectedChannelId = ""
        encryptionDetails = nil
        status = "Signed out. Device cryptographic identity remains protected in Keychain."
    }

    func acceptDeepLink(_ url: URL) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if let token = components.queryItems?.first(where: { $0.name == "token" })?.value {
            magicToken = token
            await consumeMagicLink()
        }
    }

    private func activate(_ session: DeviceSession) async {
        do {
            voice = try ProductionVoiceSession(
                session: session,
                signalStore: signalStore,
                audio: audio,
                allowInsecureHttp: Self.allowInsecure(session.serverUrl)
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
        case .requestingFloor: status = "Waiting for an authenticated floor grant…"
        case .floorDenied(let reason):
            status = reason
            isTransmitting = false
        case .transmitting(let details):
            status = "Encrypted floor granted. Release to stop."
            encryptionDetails = details
        case .receiving(let details):
            status = "Receiving authenticated encrypted voice."
            encryptionDetails = details
        case .error(let detail):
            status = detail
            isTransmitting = false
        }
    }

    private func perform(_ progress: String, operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        status = progress
        do { try await operation() }
        catch { status = error.localizedDescription }
        busy = false
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
                }
            }
            Section("Push to talk") {
                holdButton
                Text("Hold while speaking. The server must grant the channel floor before microphone audio is sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            statusSection
            if let details = model.encryptionDetails {
                Section("Encryption") { encryption(details) }
            }
            Section("Device") {
                if let session = model.session {
                    LabeledContent("Account", value: short(session.aci))
                    LabeledContent("Device", value: "\(session.deviceId) of 2")
                    LabeledContent("Mailbox", value: short(session.mailboxId))
                }
                Button("Refresh channels") { Task { await model.refreshChannels() } }
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
        ].joined(separator: "\n"))
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }

    private func short(_ value: String) -> String {
        value.count > 12 ? "\(value.prefix(8))…\(value.suffix(4))" : value
    }
}
