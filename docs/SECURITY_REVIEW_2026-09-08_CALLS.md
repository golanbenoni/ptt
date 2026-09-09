# Encrypted calls security review — September 8, 2026

## Outcome

This repository-owned assessment reviewed the unreleased encrypted-calls v1
change set across the Rust and Cloudflare control planes, Android and Apple
clients, LiveKit integration, call key distribution, call/PTT audio ownership,
Kubernetes packaging, and release automation. No open high- or
critical-severity source finding was identified by the assessment and automated
scans.

Fourteen security or reliability findings were corrected during the review and its
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
  backoff for the call's 24-hour coordination-retention window. Integration
  tests verify both participant eviction and room deletion complete through the
  durable queue without placing identifiers in logs.

### CALL-SR-06 — Account-seat races surfaced as internal failures

- Severity: medium reliability
- Surface: Rust/Postgres and Cloudflare/D1 call creation and answer transitions
- Finding: the database correctly rejected two simultaneous active seats for
  one account, but a cross-call race between linked devices could surface the
  unique-index collision as an internal server failure instead of a stable call
  conflict. Clients could not distinguish the protected race result from an
  infrastructure outage.
- Resolution: both control planes now map only the named account-seat constraint
  to `ACCOUNT_ALREADY_IN_CALL` while retaining generic handling for unrelated
  database failures. Concurrent integration tests start calls from both linked
  devices and prove exactly one account-wide seat is created and the loser gets
  the stable conflict response.

### CALL-SR-07 — Later call invitees had no independent expiry

- Severity: medium authorization / availability
- Surface: active group-call participant lifecycle
- Finding: the initial unanswered call expired after 45 seconds, but someone
  invited after a call became active could remain `ringing` indefinitely. A
  device that claimed a seat and abandoned key/media establishment could remain
  `connecting` indefinitely as well.
- Resolution: maintenance now expires each later unanswered invitation after 45
  seconds and fails each abandoned connecting seat after the same bounded
  window. Failed seats are evicted from LiveKit, host control transfers when
  required, the call epoch rotates, and the call ends if no active participant
  remains. Deterministic D1 coverage exercises both paths.

### CALL-SR-08 — Removed participants retained roster metadata access

- Severity: medium privacy
- Surface: call-state reads and coordination events
- Finding: a removed participant lost call keys and media access but could still
  fetch the live roster and receive later roster/end hints because historical
  presence in `call_participants` was treated as current authorization.
- Resolution: `removed` is now terminal for call-state authorization and is
  excluded from subsequent coordination fan-out. The participant's client
  fails closed on its authenticated state poll, while remaining participants
  retain the removal record required for their encrypted timeline.

### CALL-SR-09 — Early system audio activation could be lost

- Severity: high reliability
- Surface: iOS CallKit and Android Core-Telecom audio ownership
- Finding: the system could activate a newly answered call before the protected
  LiveKit session object existed. The activation callback then had no media
  object to update, leaving a successfully connected call muted. On Android, a
  notification Answer action arriving before Telecom registration could also be
  discarded.
- Resolution: each mobile client now latches the system-owned audio-active state
  and applies it as soon as encrypted media is constructed. Android additionally
  retains an early answer request until Core-Telecom registration completes;
  iOS fulfills CallKit actions promptly while protected connection work proceeds
  asynchronously. Both app targets compile after the lifecycle change. Physical
  two-endpoint acoustic validation remains an explicit release gate.

### CALL-SR-10 — Android E2EE construction preceded WebRTC initialization

- Severity: high reliability
- Surface: Android LiveKit/WebRTC startup
- Finding: the frame-cryptor factory could be constructed before LiveKit had
  initialized the native WebRTC runtime. Every otherwise-authorized call then
  failed before protected media could connect.
- Resolution: the call session explicitly initializes LiveKit with the
  application context before constructing the participant-specific key provider.
  Safe stage-only diagnostics distinguish initialization, key exchange and media
  connection failures without exposing identities, tokens or key material. A
  two-runtime Android gate now exercises this order through the production
  `CallSessionService` path.

### CALL-SR-11 — Exact Android frame keys and room deletion used incomplete state

- Severity: high reliability / medium authorization-boundary impact
- Surface: Android LiveKit E2EE and Rust/Cloudflare media administration
- Finding: the Android exact-byte key provider did not retain LiveKit's latest
  key-index bookkeeping, so frame cryptors could remain unready after successful
  Double Ratchet delivery. Separately, ended-room cleanup used `roomAdmin`, while
  LiveKit requires the room-creation grant for `DeleteRoom`; cleanup therefore
  retried with authorization failures.
- Resolution: Android now uses a binary `KeyProvider` that preserves the exact
  32-byte call keys, tracks the latest index per participant and uses HKDF with
  discard-when-not-ready behavior. Rust and Cloudflare now mint action-specific,
  one-minute room-scoped grants: `roomAdmin` only for participant removal and
  `roomCreate` only for room deletion. Unit and live disposable-integration tests
  cover both grant shapes and successful cleanup.

### CALL-SR-12 — Acknowledged call keys could be lost before media connected

- Severity: high reliability / availability
- Surface: Android and Apple call-key receive paths
- Finding: a decrypted call-key envelope could be acknowledged to the server
  while retained only in one component's memory. Another Android component
  could consume it, or either mobile process could restart, before the call
  security loop installed the key. The server would correctly stop redelivering
  the acknowledged envelope, leaving the call unable to establish media.
- Resolution: both clients now persist a bounded, sender-bound call-key inbox
  in protected local storage before acknowledging delivery. Android uses its
  SQLCipher store; iOS uses its Keychain-backed application state. Entries are
  removed only after protected LiveKit media is established, and same-process
  IDs prevent duplicate work while preserving crash replay. Malformed,
  truncated and over-capacity queue encodings fail closed in unit tests.

### CALL-SR-13 — Ring-time preparation could serialize behind SQLCipher

- Severity: high reliability / call availability
- Surface: Android encrypted chat/call coordination
- Finding: ring-time preparation could hold an already-open coordination store
  and then reopen the same SQLCipher database while polling. The nested open
  waited for the database busy timeout and held the shared ratchet lock.
  Delivery receipts for call-timeline envelopes added avoidable encrypted work
  on the same critical path.
- Resolution: polling now reuses the provided open store, call-timeline messages
  skip delivery receipts, and abandoned prewarm workers close their store before
  a fresh client consumes durable state. The host authenticates and prepares its
  PQXDH session while ringing, and both clients connect LiveKit muted in parallel
  with key exchange. Publication and playback still fail closed until exact peer
  key acknowledgements complete. Five alternating physical Android calls met the
  two-second protected-media threshold with a 1.751-second maximum.

### CALL-SR-14 — Native group additions failed at the roster boundary

- Severity: high reliability
- Surface: Rust/PostgreSQL direct-to-private-group conversion
- Finding: the native control plane locked the authoritative call row, then
  attempted to add `FOR UPDATE` to an aggregate `max(join_order)` query.
  PostgreSQL rejects row locking on aggregate queries, so adding a third person
  or expanding an existing group returned an internal error even though the
  Cloudflare implementation worked.
- Resolution: the invalid aggregate lock was removed. The existing
  `call_sessions` row lock remains the serialization authority for concurrent
  roster additions. Native integration now confirms explicit direct-call
  conversion, eight-account membership, ninth-account rejection, epoch
  rotation, and host transfer.

### CALL-SR-15 — Retired LiveKit key slots survived an epoch rotation

- Severity: high confidentiality
- Surface: Android and Apple participant-specific frame-key providers
- Finding: the clients generated and acknowledged a new outbound key at each
  call epoch, but the LiveKit providers could retain keys at earlier indices.
  A delayed or malicious old-epoch frame could therefore reach a previously
  valid decryption slot while the UI was securing the new epoch.
- Resolution: rotation now overwrites every retired slot for every known
  participant identity with an undisclosed random tombstone before installing
  the local new key. Remote current slots remain tombstoned until an authorized
  Double Ratchet announcement arrives. Unit tests cover remote invalidation,
  local-slot replacement, and the 16-index wraparound boundary on both clients.
  A physical two-Android run and a separately signed two-simulator iOS run each
  converted a live direct call to a private group, advanced to epoch 3, and
  required both active clients to acknowledge the new epoch before protected
  media resumed. Independent old-ciphertext injection remains a release gate.

### CALL-SR-16 — Retired Android event sockets could displace the active stream

- Severity: medium reliability
- Surface: Android authenticated call-event WebSocket
- Finding: delayed `onFailure` or `onClosed` callbacks did not verify that their
  socket still owned the stream. After a successful reconnect, a retired socket
  could therefore clear the new connection and schedule another reconnect,
  causing duplicate streams or avoidable ringing/roster latency. The endpoint
  string also appended the call path to any path, query, or fragment already in
  the configured server URL.
- Resolution: a synchronized connection-state owner now accepts messages and
  reconnect requests only from the active socket. Retired callbacks are ignored,
  concurrent connects are rejected, close is terminal, and retry backoff resets
  only when the owning socket opens. URL construction now replaces path state
  with `/v1/calls/events`, drops query/fragment data, requires TLS outside debug
  builds, and has deterministic ownership and normalization tests.

## Security properties reviewed

- Device-authenticated start, read, answer, decline, leave, end, add, remove,
  events, and webhook boundaries in both server implementations.
- Atomic account-seat claiming, one active seat per account, one call per
  device, idempotency, initial and per-participant 45-second expiry, bounded
  securing failure, eight-hour termination, 24-hour coordination retention,
  and host transfer.
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
- Fresh cold-answer and ring-prewarmed two-emulator Android calls using
  independent libsignal identities, production client/service APIs,
  Core-Telecom, LiveKit E2EE and authenticated teardown. Each combined
  disposable-stack run also completed the entire Rust integration suite. Five
  consecutive strict prewarmed runs measured 1.49–1.58 seconds
  invite-to-ring, 0.823–0.913 seconds to complete acknowledged call-key
  exchange, and 0.909–0.995 seconds from the actual answer action to both
  protected LiveKit connections on loopback ICE/TCP. An immediate cold answer
  completed protected media in 3.599 seconds. The decrypted call-key inbox is
  bounded, SQLCipher-backed, committed before server acknowledgement and
  cleared only after protected media connects. These are functional lifecycle
  and regression measurements, not acoustic or physical p95 evidence; the
  physical 2-second answer-to-audio gate remains open.
- Five alternating physical Pixel 3a/Samsung SM-F966U calls passed the same
  protected/unmuted five-second lifecycle and authenticated teardown. Their
  answer-to-protected-media samples were 1.751, 0.752, 1.557, 0.779 and 1.510
  seconds, so the maximum and nearest-rank p95 were 1.751 seconds. This does not
  replace an external microphone-to-speaker acoustic measurement or production
  push timing.
- Later bidirectional Pixel/Samsung debug fixtures injected five deterministic
  tones per direction after capture and proved that all ten crossed
  participant-specific LiveKit E2EE, reached the remote decrypted render
  callback, stayed on Core-Telecom's Speaker endpoint, and exited each physical
  speaker. A fixed room microphone measured 280 ms Pixel→Samsung and 200 ms
  Samsung→Pixel acoustic p95 under the calls-v1 300 ms limit. This closed both
  post-capture Android directions and exposed/fixed a LiveKit-versus-Telecom
  route race plus a callback-jitter detector split; it does not prove real
  microphone capture or the complete four-device matrix.
- A separate debug-only gate then left WebRTC capture samples untouched and
  drove each physical Android microphone with five external acoustic tones
  after protected media was ready. Non-mutating capture and remote-render
  processors observed 5/5 in both directions: Pixel→Samsung at 1.331 seconds
  answer-to-media and Samsung→Pixel at 0.723 seconds. This closes the two
  Android capture-to-render directions and complements, but does not merge
  with, the independent physical-speaker latency evidence above.
- The directional microphone harness now prevents the known fixture from being
  republished or fed back by the callee: its debug-only automation mutes the
  callee uplink and temporarily attenuates the physical voice-call output while
  observing the pre-render PCM without modifying it. The original device volume
  is read, restored and verified on the normal path, with a cleanup retry after
  failures or interruption. Two-second true fixture gaps remain wider than the
  1.2-second physical detector continuity rule.
- A fresh signed two-simulator iOS call passed encrypted key exchange, muted
  LiveKit E2EE connection and teardown at 3.433 seconds invite-to-ring and 0.434
  seconds answer-to-protected-media. The gate now rejects linker-signed builds
  without Keychain access and preserves privacy-safe failure evidence. It is not
  CallKit, PushKit, route or acoustic proof.
- Bidirectional Android/iOS calls then passed through one disposable stack with
  a physical Android endpoint and muted iOS simulator: 0.791 seconds
  iOS→Android and 1.282 seconds Android→iOS answer-to-protected-media. This
  directly exercises cross-platform call-key encoding and participant-specific
  E2EE installation, but not a physical Apple audio path.
- Pinned LiveKit multi-room load completed both the 10-room/80-participant and
  32-room/256-participant shapes with every expected subscription healthy (120
  and 384 respectively). A repeated 32-room run stayed at 15.63 percent
  normalized peak CPU across the 12-core Docker allocation, below the enforced
  70 percent ceiling. The public lane now fails closed without an authenticated
  CPU sample and runs the full 256-participant shape. This is isolated
  local-container concurrency evidence;
  it does not substitute for the public media node's resource, transport,
  packet-loss, latency, or ciphertext-inspection proof.
- Native control-plane integration now converts a direct call to a confirmed
  private ad-hoc conversation at the exact eight-account boundary, rejects a
  ninth active participant, rotates the call epoch, and transfers host control
  to the earliest remaining connected participant. The matching Cloudflare
  conversion and participant-lifecycle coverage remains green.

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
3. Pass the remaining two-iOS/two-Android physical matrix, including both linked-device
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
