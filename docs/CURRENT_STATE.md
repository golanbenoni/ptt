# Current implementation state

This document describes what exists in the repository at PTT Talk **0.1.29
(32)**, product protocol **1.1**. It separates implemented behavior from release
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

## Current distribution

Version **0.1.29 (32)** is the next synchronized internal-testing candidate; it
has not been uploaded to TestFlight or Google Play. The previously distributed
tester binaries remain available while build 32 completes exact-commit
software, four-device acoustic, lifecycle, and eight-hour soak gates. See
[`RELEASE_STATUS.md`](RELEASE_STATUS.md) for the concise evidence and tester
checklist.

The candidate contains a regression fix that keeps the talk control unavailable
until the previous encrypted media flush and authenticated floor release have
finished. Its exact-commit automated and physical evidence is being regenerated;
no simulator callback will be treated as proof that a physical speaker was
audible.

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
| Full-duplex calls | Ringing 1:1/private-group calls, eight active participants, linked-device first-answer claim, encrypted call history, active speaker/quality, add/remove, SOS preemption | Implemented in development source; 20 alternating Pixel/Samsung protected lifecycle gates passed on exact commit `79cd031` with 3.651-second invite-to-ring p95 and 1.846-second answer-to-media p95, both post-capture encrypted physical Android directions passed 5/5 bursts at 200 ms and 280 ms p95, both real-microphone Android capture-to-render directions passed 5/5, signed two-simulator iOS gates pass, and both Android/iOS call directions passed with a physical Android endpoint. iOS/cross-platform real-microphone instrumentation is implemented but not yet physically passed; public LiveKit/TURN, four-device/lifecycle performance proof, and independent review remain required before 0.2.0 (33) |
| Call media security | Participant-specific LiveKit E2EE keys delivered by Double Ratchet, HKDF context binding, acknowledgement gate, membership/30-minute rotation with retired-slot tombstoning, random SFU identities, five-minute least-privilege JWT | Implemented; independent cryptography review required |
| History | Ciphertext-only missed voice, local encrypted 30-day/1-GB history, membership/link-time authorization | Implemented |
| Chat | Text, files, voice messages, video, encrypted thumbnails, resumable transfer, offline outbox, notifications | Implemented |
| Message tools | Reply, reaction, edit, delete, copy, share, forward, pin, star, search, mentions, drafts, mute/archive, delivery/read/played receipts | Implemented on Android and iOS |
| Collaboration | Conversation workspaces for messages/media/brief/members/security; activity inbox; structured operation status and acknowledgement; expiring guests | Implemented on Android, iOS, and both services |
| Automation | Channel-scoped automation enrolled as an independently keyed device identity; one-time credentials; prekeys, encrypted fan-out, expiry and revocation | Implemented; integration-side encryption client required per automation |
| Device privacy | SQLCipher/Keystore on Android, Keychain and protected local state on iOS, safety numbers, redacted support reports, account deletion | Implemented |
| Administration | Invitations, members/guests, devices, revocation, channels, templates, user groups, integrations, roles, retention, recovery approvals, audit and operations health | Implemented in the web console |
| Accessibility | Stable semantics, VoiceOver/TalkBack automation, dark appearance and largest-text matrices | Implemented; physical assistive-technology walkthrough required |
| Interface | Five stable destinations (Talk, Chat, Calls, Activity, Settings), compact Talk hierarchy, conversation-first Chat, persistent active-call banner, progressive disclosure for security details | Implemented on Android and iOS |

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
257. The pinned LiveKit call gate also carries 256 simulated participants
across 32 isolated eight-person rooms with every expected subscription healthy;
the local reference run stayed at 15.63 percent normalized peak CPU across its
12-core Docker allocation, below the enforced 70 percent ceiling. The public
release workflow now requires the same 256-participant shape and an
authenticated metrics sample rather than accepting an unmeasured remote run;
public production-node resource, loss, latency, transport and ciphertext proof
remains open.

Promptfoo is now the top-level campaign and evidence layer for portable,
nightly, adversarial, weekly, rendered-browser, and physical-release profiles.
Native deterministic tools remain authoritative. Campaign evidence records the
Git commit, clean/dirty workspace state, duration, redacted summary, and hashes.
All 75 registered v1 route paths are accounted for in executable tests and both
service implementations. This orchestration is part of the build 32 candidate;
it does not retroactively change any previously distributed binary's provenance.

On September 4, 2026, development-workspace validation passed all 9 PR lanes, all 22 nightly
lanes, all 3 deterministic adversarial lanes, the disposable K3s lifecycle,
both mobile accessibility matrices, and the live production website audit. The
audit also removed mobile page-level horizontal scrolling and disabled
Cloudflare Real User Measurements so the deployed site matches its no-analytics
privacy statement. These automated results do not replace the physical proof
listed below.

On September 9, 2026, 20 alternating encrypted calls between a physical Pixel
3a and Samsung SM-F966U passed Core-Telecom ownership, authenticated seat claim,
Double Ratchet call-key exchange, protected/unmuted LiveKit readiness for five
seconds, host teardown, and the complete Rust integration suite on exact commit
`79cd031`. Invite-to-ring p95 was 3.651 seconds against the five-second bound;
answer-to-protected-media p95 was 1.846 seconds against the two-second bound.
The campaign exposed and then verified the fix for a transport-order race in
which a valid future-epoch key announcement could arrive before the authoritative
roster update and be discarded permanently. Both clients now retain that
announcement, refetch the roster, and process it only when the server confirms
the matching epoch. A fresh two-simulator iOS run passed at 3.433 seconds
invite-to-ring and 0.434 seconds
answer-to-protected-media. The Android harness launch metric is not production
FCM timing, and neither result is external microphone-to-speaker acoustic proof.
The same disposable stack also passed both cross-platform directions using a
physical Android device and muted iOS simulator: 0.791 seconds
iOS→Android and 1.282 seconds Android→iOS from answer to protected media. This
proves Kotlin/Swift call-key and LiveKit interoperability, not physical iOS
CallKit/PushKit behavior.

Subsequent bidirectional Pixel/Samsung acoustic fixtures passed after removing
LiveKit's automatic Android route handler and making Core-Telecom endpoint
selection acknowledged and retryable. Each caller generated five debug-only
997 Hz fixtures after capture, paired with a separately audible 613 Hz source
marker. Each callee's decrypted playback callback detected all five, and a fixed
room microphone measured 280 ms Pixel→Samsung and 200 ms Samsung→Pixel
nearest-rank p95 under the calls-v1 300 ms limit. Answer-to-protected-media was
1.757 seconds and 0.817 seconds respectively. The render detector now requires
600 ms of silence before counting a new burst, preventing callback jitter from
splitting one transmission while preserving the fixture's 800 ms gaps. This is
direct encrypted transport-to-both-physical-speakers evidence, but synthetic
post-capture injection is not proof that real microphone samples traverse the
complete path by itself.

A second debug-only physical gate now leaves the caller's WebRTC capture
samples untouched and plays five deterministic external acoustic tones only
after both encrypted endpoints report protected media ready. Non-mutating
processors require all five tones in the physical caller's microphone graph
and all five in the remote device's decrypted render graph. Pixel→Samsung
passed at 1.331 seconds answer-to-protected-media; Samsung→Pixel passed at
0.723 seconds. Together with the separate physical-speaker result above, this
closes both Android capture-to-render directions without claiming a same-run
external microphone-to-speaker latency measurement. Physical iOS,
cross-platform acoustic, lifecycle, public-network, and exact-commit
four-device gates remain open.

The physical microphone stimulus now prevents a low or muted macOS output from
silently weakening that proof. It raises the output only for the bounded five-
tone fixture and restores the prior volume and mute state through its cleanup
trap. The fixture begins with a two-second settling interval and separates its
five tones with two-second true gaps. To prevent one nearby phone from feeding
the remote speaker back into either microphone, the debug-only directional
harness mutes the callee uplink and temporarily attenuates its voice-call output
while the non-mutating pre-render observer stays active; it verifies the exact
volume is restored afterward. Physical capture and render analysis require 1.2
seconds of non-tone audio before counting another burst, while the independent
synthetic fixture retains its tighter 600 ms rule. The Rust integration suite
also exercises confirmed direct-to-private-
group conversion at the exact eight-account limit, rejects a ninth account,
rotates the call epoch, and transfers host control to the earliest remaining
connected participant.

A subsequent live-rotation regression gate converted an active direct call to
a confirmed private-group call and advanced its epoch exactly once. Both the
physical Pixel/Samsung clients and two separately signed iOS simulator clients
installed and acknowledged epoch 3. Android resumed unmuted protected media at
the new epoch; the run's initial answer-to-protected-media was 1.716 seconds.
The muted-by-design iOS simulator run likewise secured the new epoch after an
initial 0.587-second answer-to-protected-media setup. This exercises both mobile
key-provider rotation paths, but does not replace stale-ciphertext injection or
physical iOS audio evidence.

An exact-commit `android-call-physical` workflow now makes that focused Android
evidence repeatable: it requires 20 alternating protected calls with complete
p95 latency samples, both encrypted physical-speaker directions, both
unmodified microphone-to-decrypted-render directions, and live epoch rotation.
It shares hardware concurrency with the existing PTT and soak campaigns and
does not relax the separate two-Android/two-Apple release gate.

The iOS call client now has an equivalent debug-only, non-mutating LiveKit
observer and a physical driver that rejects fewer or more than five external
tone bursts in either the caller capture graph or remote decrypted render graph.
The iOS and cross-platform drivers also mute the callee uplink during the
directional stimulus and suppress physical playout only after the decrypted
render observer runs; a private completion marker restores and verifies the
unmuted state. Physical iOS diagnostics use the same 1.2-second gap policy as
Android. Cross-platform automation uses the same markers. The exact-commit physical
release workflow now requires six real-microphone directions across two Android
and two iOS devices, plus authenticated public TURN/UDP and TURN/TLS probes.
Those iOS/cross-platform/public checks are implemented release gates, not passed
evidence; no two physical Apple devices or ready public call media node were
available for this change.

The hosted Cloudflare beta passes the production push-readiness endpoint with
separate app-topic-restricted APNs production and sandbox credentials. Its
Firebase project contains distinct release and debug Android applications, and
FCM delivery uses a dedicated least-privilege service account. Push payloads
remain opaque.

For the exact build-31 source commit, automated CI, production relay/application
delivery, clean K3s installation, security scanning, store readiness, signing,
TestFlight processing/group assignment, and Google Play internal-track delivery
have passed.

The following remain mandatory before calling the internal build generally
production-ready or promoting it beyond controlled testing:

1. Pass the exact-commit four-device matrix: iOS↔iOS, Android↔Android,
   Android→iOS, and iOS→Android, including external acoustic proof.
2. Pass foreground, screen-off, lock-screen wake, process death, network change,
   Bluetooth/wired route, interruption, reboot/restoration, and revocation
   scenarios.
3. Pass the non-shortenable eight-hour Android screen-off receive soak.
4. Run the storage-capacity gate and an operator disaster-recovery exercise on
   the selected production infrastructure. The disposable K3s install,
   backup/restore, upgrade, rollback, node-restart, and relay-load gates already
   pass in CI.
5. Complete independent cryptography review and application penetration
   testing. Automated dependency, SBOM, secret, and misuse scanning already
   pass.

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
