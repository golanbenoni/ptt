# Encrypted calls security review — September 8, 2026

## Outcome

This repository-owned assessment reviewed the unreleased encrypted-calls v1
change set across the Rust and Cloudflare control planes, Android and Apple
clients, LiveKit integration, call key distribution, call/PTT audio ownership,
Kubernetes packaging, and release automation. No open high- or
critical-severity source finding was identified by the assessment and automated
scans.

Five security or reliability findings were corrected during the review and its
September 9 continuation. The
change set is suitable for continued controlled development testing, but is not
approved for release as **0.2.0 (33)**. A live media deployment, physical-device
matrix, packet inspection, load/performance evidence, and the independent
cryptography review and penetration test remain mandatory.

This is an internal engineering assessment. It is not the independent review
required by `docs/SECURITY_REVIEW_SCOPE.md`.

## Corrected findings

### CALL-SR-01 — PTT could contend with normal-call audio

- Severity: high reliability / medium security-boundary impact
- Surface: Android and Apple PTT receive paths
- Finding: an authenticated ordinary PTT transmission could still open a live
  playback route while a full-duplex call owned the audio session. Incoming SOS
  also did not consistently wait for the call graph to release audio before PTT
  playout.
- Resolution: normal call ownership now suspends the PTT graph on both
  platforms. Ordinary PTT received during a call is authenticated and retained
  through encrypted history but never played live or replayed after the call.
  Authenticated SOS ends the call first, waits for audio release, then transfers
  ownership to PTT. Policy tests cover normal, archived-only, and SOS-preemption
  decisions.

### CALL-SR-02 — iOS attempted to reactivate CallKit-owned audio

- Severity: medium reliability
- Surface: iOS CallKit/LiveKit audio activation
- Finding: LiveKit activation ran from CallKit's `didActivate` callback but also
  called `AVAudioSession.setActive(true)`. CallKit had already activated the
  session, so the second activation could race route/interruption handling and
  destabilize microphone or Bluetooth availability.
- Resolution: automatic LiveKit audio-session configuration remains disabled.
  The app configures voice-call category/mode and enables WebRTC media only from
  `didActivate`, without reactivating the session. `didDeactivate` mutes and
  releases call media before PTT can regain ownership.

### CALL-SR-03 — Remote roster changes were not uniformly journaled

- Severity: low integrity/auditability
- Surface: encrypted call timeline on Android and Apple
- Finding: locally initiated additions produced an encrypted participant event,
  but a join, leave, removal, or host transfer initiated elsewhere did not
  consistently produce the same conversation event.
- Resolution: the current host now compares the non-terminal authorized roster
  during authenticated state polling and emits one encrypted participant-change
  event when that roster changes. UI-side duplicate emission was removed.
  Periodic key rotations do not create false participant events.

### CALL-SR-04 — Call keys could fan out to an unclaimed linked device

- Severity: high confidentiality
- Surface: Android and Apple call-key distribution
- Finding: the media-key exchange selected recipients by account ACI. The
  existing pairwise chat fan-out could therefore encrypt a call key to both
  linked devices even though only one device had atomically claimed the
  account's call seat.
- Resolution: call-key announcements and acknowledgements now target the exact
  authenticated `(ACI, DeviceId)` recorded in the active call roster. Both
  clients reject key messages whose pairwise-authenticated sender device is not
  the claimed device. Unit tests prove that a recipient for device 2 does not
  match device 1. Missing or stale device claims continue to fail closed.

### CALL-SR-05 — Removed participants relied on cooperative media disconnect

- Severity: medium authorization / availability
- Surface: Rust and Cloudflare LiveKit administration
- Finding: removing or revoking a participant changed the authorized roster and
  rotated end-to-end keys, but did not forcibly evict a buggy or hostile client
  from the LiveKit room. Such a client could not decrypt the new epoch, yet
  could continue consuming SFU resources or publishing unusable ciphertext.
- Resolution: roster removal and call termination now transactionally enqueue
  room-scoped LiveKit `RemoveParticipant` or `DeleteRoom` actions. Both control
  planes use a 60-second least-privilege `roomAdmin` token, attempt the action
  immediately, and retain generic-error retry state with bounded exponential
  backoff. Call coordination records cannot be deleted while an eviction is
  pending. Integration tests verify both participant eviction and room deletion
  complete through the durable queue without placing identifiers in logs.

## Security properties reviewed

- Device-authenticated start, read, answer, decline, leave, end, add, remove,
  events, and webhook boundaries in both server implementations.
- Atomic account-seat claiming, one active seat per account, one call per
  device, idempotency, 45-second ring expiry, eight-hour termination, 24-hour
  coordination retention, and host transfer.
- Random per-call room and participant identities; five-minute, audience- and
  room-restricted LiveKit tokens without account identifiers or key material.
- Participant-specific 32-byte outbound keys delivered only through existing
  Double Ratchet envelopes, HKDF context binding, acknowledgement fingerprints,
  fail-closed media, membership rotation, and stale-epoch rejection.
- Signature verification over the exact LiveKit webhook body and the absence of
  device access to the internal webhook route.
- Durable, idempotent LiveKit participant eviction and room deletion using
  short-lived room-scoped administration grants; failures retain only generic
  operational error codes and are retried without restoring authorization.
- Push payload minimization to protocol version, random call ID, and event type.
- No recording, ingress, egress, SIP, agents, transcription, server media
  inspection, or plaintext fallback in the supported deployment.
- CallKit/PushKit and Core-Telecom lifecycle, mute, route ownership, ongoing
  notification, and SOS handoff behavior.
- Pinned LiveKit server `1.13.6`, Swift SDK `2.16.0`, Android SDK `2.28.2`, and
  official Helm chart `1.9.0`.
- Secret-backed media configuration, restricted network policy, resource
  limits, health probes, disruption protection, and metadata-safe metrics.

## Verification performed

- Rust control integration, including a genuinely concurrent two-device answer
  race, plus all control, relay, core, native audio, Apple FFI, and SFrame tests.
- Cloudflare integration, type checking, route parity, dry deployment, and D1
  migration coverage.
- Android unit tests and debug/release assembly; Swift package tests and iOS
  simulator application build with the pinned LiveKit SDKs.
- Frozen protocol hash, Android/Swift wire vectors, API route coverage,
  dependency pin validation, Helm calls contract, and APNs credential
  separation.
- Android and Apple accessibility/navigation matrices including the Calls
  destination.
- Promptfoo nightly and adversarial repository campaigns.
- Trivy secret, high/critical vulnerability, and high/critical configuration
  scans; all returned zero findings. Syft generated a CycloneDX 1.6 SBOM.
- Production npm audits for the Cloudflare service, administrator console, and
  public site; all returned zero vulnerabilities.

The host Swift test lane reports linker warnings because the local libsignal
archive was built against a newer macOS SDK than the host test target. The
signed iOS/simulator build lane uses the platform archive and passes; the warning
does not change the release requirement to rebuild all dependencies from a clean
release toolchain.

## Residual release blockers

1. Deploy `calls.<domain>` and `turn.<domain>` on a publicly routable LiveKit
   media node and pass signaling, ICE/UDP, ICE/TCP, TURN/UDP, and TURN/TLS probes.
2. Capture packets at the SFU and TURN node and independently confirm that media
   remains ciphertext and that no key, token, ACI, email, or device identifier
   enters logs or metrics.
3. Pass the two-iOS/two-Android physical matrix, including both linked-device
   answer races, lock screen, real VoIP push, Bluetooth/wired routes,
   interruptions, network changes, reboot, SOS preemption, and acoustic audio.
4. Meet invite-to-ring, answer-to-audio, mouth-to-ear, and reconnect percentiles
   with external timestamps and acoustic evidence.
5. Pass the eight-participant and production-shaped LiveKit load gates,
   including at least 256 devices across 32 rooms and the required 10-room case.
6. Complete independent cryptography review and application penetration testing
   against the exact release commit and deployed configuration.
7. Re-run every CI, security, Promptfoo, physical, soak, backup/restore,
   upgrade/rollback, signing, and store gate from a clean checkout of that exact
   commit.

Until those blockers are closed, calls must remain hidden when media readiness
is false and the distributed versions must remain at **0.1.29 (32)** or earlier.
