# Current implementation state

This document describes what exists in the repository at PTT Talk **0.1.27
(30)**, product protocol **1.1**. It separates implemented behavior from release
proof and operator provisioning. A feature being present in source does not by
itself mean the exact store binary has passed the physical release gate.

Status terms:

- **Implemented** — product code and automated tests are present.
- **Provisioning required** — code is present, but an operator-owned service or
  credential must be configured.
- **Proof required** — the feature must still pass the exact-commit physical or
  operational release gate.
- **Known gap** — source parity is incomplete and must be fixed before the
  affected deployment is described as release-ready.

## Product capabilities

| Area | Current implementation | Status |
| --- | --- | --- |
| Enrollment | Administrator email invitations, single-use magic links, app links, manual fallback, non-enumerating responses | Implemented; SMTP provisioning required |
| Identity | Stable random account ACI; independent device identity, prekeys, mailbox, access token, and push registration | Implemented |
| Devices | Two active devices per account, setup-link/code approval, device list, remote revocation, local key erasure | Implemented |
| Recovery | Fresh email link plus approval by a different active administrator; old-device revocation and membership-key rotation | Implemented |
| Channels | Private/direct/group conversations, topics, announcement posting, templates, user groups, roles, membership epochs, retention, presence, 64 encrypted members | Implemented |
| Live voice | 20 ms Opus capture/playback, authenticated floor, repeated transmissions, feedback tones, interruption handling, audio routing, meters | Implemented; physical acoustic proof required |
| Media security | RFC 9605 SFrame, authenticated headers, persistent counters, replay rejection, unknown-key buffering, no plaintext downgrade | Implemented |
| Media transport | Authenticated UDP relay plus automatic encrypted WebSocket/TLS fallback | Implemented |
| Priority | Normal and silent SOS, visible recipients, authenticated preemption | Implemented; multi-device proof required |
| History | Ciphertext-only missed voice, local encrypted 30-day/1-GB history, membership/link-time authorization | Implemented |
| Chat | Text, files, voice messages, video, encrypted thumbnails, resumable transfer, offline outbox, notifications | Implemented |
| Message tools | Reply, reaction, edit, delete, copy, share, forward, pin, star, search, mentions, drafts, mute/archive, delivery/read/played receipts | Implemented on Android and iOS |
| Collaboration | Conversation workspaces for messages/media/brief/members/security; activity inbox; structured operation status and acknowledgement; expiring guests | Implemented on Android, iOS, and both services |
| Automation | Channel-scoped automation enrolled as an independently keyed device identity; one-time credentials; prekeys, encrypted fan-out, expiry and revocation | Implemented; integration-side encryption client required per automation |
| Device privacy | SQLCipher/Keystore on Android, Keychain and protected local state on iOS, safety numbers, redacted support reports, account deletion | Implemented |
| Administration | Invitations, members/guests, devices, revocation, channels, templates, user groups, integrations, roles, retention, recovery approvals, audit and operations health | Implemented in the web console |
| Accessibility | Stable semantics, VoiceOver/TalkBack automation, dark appearance and largest-text matrices | Implemented; physical assistive-technology walkthrough required |
| Interface | Four stable destinations, task-first titles, compact Talk hierarchy, conversation-first Chat, progressive disclosure for security details | Implemented on Android and iOS |

## Platform-specific behavior

### Android

- Minimum API 26; target API 36.
- The foreground session service owns sockets, crypto, floor state, and audio.
- **Stay connected** is a deliberate user arm. Force-stop and reboot clear that
  authority and require a visible tap before microphone-capable background work
  resumes.
- Opaque FCM wakes reconnect encrypted delivery. Push payloads do not contain
  email, channel names, keys, message content, or audio.
- Bluetooth/wired routes, media buttons, hardware broadcast integration, tile,
  widget, and overlay use the same authenticated floor controller as the main
  talk button.

### iOS and iPadOS

- Minimum iOS/iPadOS 16.
- SwiftUI provides Talk, Activity, Chat, Settings, onboarding, linking, and
  recovery experiences.
- Physical release builds use Apple's Push to Talk framework and APNs PTT
  pushes. The system manages one joined live PTT channel; changing it requires
  foreground user interaction.
- The opening status card reports the installed version/build. Restored-channel
  cleanup is idempotent and does not surface Apple's harmless
  `transmissionNotFound` result when no remote transmission exists.
- Push to Talk activation now creates a fresh application audio graph only after
  Apple's `didActivate` callback. Route-change recovery preserves playback and
  retries the graph without taking ownership of the system audio session.
- Native `AVAudioEngine` capture/playback is used on devices. A simulator can
  prove protocol and decoded playback callbacks but cannot prove APNs wake,
  system PTT restoration, microphone routing, or audible speaker output.
- The iOS target is excluded from Apple-silicon Mac availability because the
  Push to Talk framework is not available on macOS.

## Server implementations

### Rust/K3s

The Rust control plane implements enrollment, authentication, device and channel
management, prekeys, pairwise mailbox delivery, chat, resumable attachments,
history, push delivery, floor control, presence, UDP relay credentials, and
encrypted TLS media fallback. PostgreSQL stores durable routing data, Redis
stores ephemeral floor/presence state, and S3-compatible storage contains only
ciphertext objects.

The Helm chart installs these services with ingress, network policy, health
checks, metrics, optional encrypted backups, and upgrade/rollback controls. The
Rust service implements the same two-minute, single-use administrator browser
handoff and 15-minute revocable session used by the mobile apps, web console,
and Cloudflare backend. Integration tests prove that a browser session can use
administrator routes but cannot impersonate a device API credential.

A disposable K3s gate builds every application image from the checkout and
proves clean installation, service and metrics readiness, coordinated database
and ciphertext-object backup, deliberate deletion and two-part restore,
upgrade, rollback, and recovery after sequential K3s worker and server-node
restarts without losing the restored records. It uses a test-only local storage
class; an operator must still prove encryption at rest, capacity, and disaster
recovery on the actual deployment infrastructure.

### Cloudflare

The Cloudflare implementation uses Workers, D1, R2, Queues, and one hibernating
Durable Object per channel. It implements the mobile/admin JSON contract,
short-lived admin browser handoff, resumable ciphertext attachments, background
maintenance, push queues, and fixed-capacity encrypted WebSocket media fan-out.
It intentionally advertises no usable UDP endpoint; clients select encrypted
TLS media immediately.

## Security model

- Account/device establishment uses PQXDH and Double Ratchet sessions.
- Channel voice uses Sender Keys and per-talk media epochs.
- Live media uses RFC 9605 SFrame; history adds a separate authenticated
  ciphertext wrapper.
- Chat events are encrypted independently for every eligible recipient device.
- Attachment names, MIME types, captions, previews, file bytes, and keys remain
  inside device-encrypted containers.
- Servers see routing identifiers, ciphertext size/timing, membership/floor
  metadata, expiry, and delivery status. There is no plaintext media fallback.
- A new device receives only communications created after its link time.
- Crypto, membership, counter, floor, or transport-authentication failures fail
  closed.

This design has automated misuse, replay, tamper, malformed-input, dependency,
secret-scan, and integration coverage. It has **not yet completed the required
independent cryptography review and application penetration test**.

## Release readiness

The repository has automated gates for Kotlin, Swift, Rust, TypeScript,
protobuf compatibility, container builds, Helm rendering, Cloudflare dry-run,
integration services, accessibility journeys, screenshots, privacy metadata,
signing, push readiness, and production relay behavior. Both relay
implementations have live capacity tests: native UDP binds 256 clients and
delivers an authenticated frame to 255 listeners, while the Cloudflare TLS gate
does the equivalent through the channel Durable Object. Both reject listener
257.

The hosted Cloudflare beta passes the production push-readiness endpoint with
separate app-topic-restricted APNs production and sandbox credentials. Its
Firebase project contains distinct release and debug Android applications, and
FCM delivery uses a dedicated least-privilege service account. Push payloads
remain opaque.

The following remain mandatory before calling a store build production-ready:

1. Pass the exact-commit four-device matrix: iOS↔iOS, Android↔Android,
   Android→iOS, and iOS→Android, including external acoustic proof.
2. Pass foreground, screen-off, lock-screen wake, process death, network change,
   Bluetooth/wired route, interruption, reboot/restoration, and revocation
   scenarios.
3. Pass the non-shortenable eight-hour Android screen-off receive soak.
4. Pass the automated K3s operations and relay-load gates in CI for the exact
   release commit, then run the storage-capacity gate on the selected deployment
   infrastructure.
5. Complete independent cryptography review, penetration testing, SBOM review,
   and operator disaster-recovery exercise.
6. Publish the same proven commit and synchronized version/build to TestFlight
   and Google Play internal testing.

## Deliberate product limits

- Single-tenant private-team deployments only; no multi-tenant billing or public
  directory.
- Two active devices per account.
- 64 accounts and 256 connected relay devices per channel.
- One system-managed background PTT channel on iOS.
- No historical backfill to newly linked devices.
- No advertising, analytics SDK, tracking, compliance recording, transcripts,
  maps, dispatch console, RoIP, public social discovery, or plaintext server-side
  media processing in this release.

The future acceptance contract is maintained separately in
[`PARITY_GOAL.md`](PARITY_GOAL.md). Testing procedures are in
[`SIMULATOR_TESTING.md`](SIMULATOR_TESTING.md).
