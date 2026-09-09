# Changelog

This file records user-visible and operator-visible changes. Release evidence,
store distribution state, and remaining release gates are maintained in
[`docs/RELEASE_STATUS.md`](docs/RELEASE_STATUS.md).

## Unreleased

- Added a live-sample preflight to the privacy-local physical acoustic gate.
  A disconnected or temporarily zeroed USB room microphone now fails in about
  two seconds with an actionable diagnostic instead of invalidating an entire
  encrypted voice campaign after it completes.
- Added an acoustic-only dispatch mode for focused two-Android diagnostics and
  privacy-safe source/receiver timing evidence when acoustic latency pairing
  fails. Normal release runs still require the complete encrypted product matrix.
- Fixed terminated-process Android voice wake on Android 14 and newer. An
  authenticated FCM wake now restores a receive-only media-playback foreground
  session instead of illegally requesting while-in-use microphone access from
  the background. Microphone access is promoted only for an eligible user PTT
  action, and the physical gate now fails immediately if session restoration
  fails before speaker playback.
- Made Android session arming and initial channel selection one atomic service
  command. Startup can no longer race an automatic persisted-channel restore
  against an explicit UI selection and tear down the first floor request.
- Fixed Android encrypted-media recovery during Wi-Fi and cellular transitions.
  A closed UDP or TLS relay is now replaced atomically and the interrupted
  ciphertext or authenticated floor operation is retried once on a fresh TLS
  tunnel. Successful in-place recovery cancels obsolete full-channel retries,
  and a terminal capture failure is reported only once instead of once per
  20-millisecond audio callback.
- Added an exact-commit physical Android encrypted-call campaign. It alternates
  caller and callee roles for 20 protected calls, enforces complete p95 latency
  samples, proves encrypted output at both speakers, proves unmodified real
  microphone capture in both directions, and verifies live epoch rotation.
  The separate four-device Android/iOS release gate remains mandatory.
- Added the unreleased encrypted full-duplex calls v1 implementation for up to
  eight participants, with CallKit/Core-Telecom integration, Double
  Ratchet-delivered LiveKit frame keys, call history, PTT exclusion and SOS
  preemption. Distribution remains blocked on the documented call-release gates.
- Fixed Android call-event reconnection ownership so a delayed failure or close
  callback from a retired WebSocket cannot clear a newer healthy stream or
  create duplicate coordination connections. Event URLs are now normalized to
  the fixed authenticated endpoint without retaining unrelated path, query, or
  fragment state on both mobile platforms.
- Fixed the Rust call-event service to continuously consume authenticated
  client control frames and answer WebSocket keepalives. Mobile clients no
  longer lose an otherwise healthy ringing/roster stream when their 20- or
  25-second protocol ping goes unread, and application data sent in the
  server-only direction closes the connection.
- Added native control-plane integration coverage for a complete call-wake
  dispatch through the durable push outbox to both FCM and APNs VoIP sandbox.
  The provider mocks require the VoIP topic/type and the exact minimal opaque
  ringing payload, and reject mailbox or PTT registrations for call delivery.
  The Cloudflare integration fixture now proves the same call-only registration
  selection and durable outbox fan-out.
- Fixed Cloudflare registration of TestFlight VoIP tokens. The allowlisted
  `apns-voip-sandbox` provider was one character longer than the request
  parser's former limit, so Apple sandbox call wake could never be enabled.
- Made push-token invalidation race-safe on both control planes. Mobile clients
  now remove the exact invalidated token instead of every registration for the
  provider, so a delayed callback cannot erase a newer FCM or APNs replacement.
  Apple sign-out also unregisters standard APNs, Push to Talk, and VoIP routes.
- Fixed Android call startup by initializing the native WebRTC runtime before
  constructing frame cryptors and preserving LiveKit's participant key-index
  state for exact binary keys.
- Made call-epoch rotation actively tombstone every retired participant key
  slot on Android and Apple before installing the new outbound key. Delayed or
  malicious old-epoch frames therefore cannot use a key retained by the
  LiveKit provider, including after the 16-slot key index wraps.
- Added physical Android and signed iOS-simulator mid-call rotation probes that
  convert a direct call to a confirmed private group and require both active
  clients to secure the new epoch. The Android probe additionally requires
  unmuted encrypted media to resume.
- Fixed Android call routing so Core-Telecom remains the only audio-route owner.
  LiveKit no longer races Telecom back to the earpiece, and user-selected
  speaker/Bluetooth/wired endpoints are retried until Telecom's endpoint flow
  acknowledges the change instead of silently dropping an early request.
- Fixed least-privilege LiveKit cleanup grants: participant eviction uses only
  room administration while room deletion uses only room creation authority.
- Added a disposable two-runtime Android call gate covering fresh identities,
  account authorization, key exchange, protected media readiness, Core-Telecom
  audio ownership, remote teardown and the complete Rust integration suite.
- Added a pinned multi-room LiveKit gate for the required 10-room shape and the
  full 32-room/256-participant coordination shape, including a protected
  trusted-TLS mode for validating the eventual public media node.
- Made the public media-node release gate run the full 32-room/256-participant
  shape and fail closed unless an authenticated Prometheus probe proves
  normalized sustained CPU remains at or below 70 percent. Local Docker load
  results now normalize multi-core CPU and enforce the same ceiling instead of
  merely printing Docker's per-core percentage.
- Reduced answer-to-audio setup latency on both mobile platforms by consuming
  the authenticated call-start envelope while the call rings, prioritizing the
  call-key inbox after answer, caching the verified Android channel directory,
  reusing the open encrypted state and HTTP connections through key exchange,
  establishing the host's authenticated PQXDH data session while ringing,
  connecting the still-muted LiveKit transport in parallel with Double Ratchet
  key exchange, and moving encrypted history bookkeeping out of the media
  critical path. Five alternating Pixel/Samsung calls completed protected media
  in 0.752–1.751 seconds after answer.
- Made mobile call-key delivery crash-safe and cross-component-safe: decrypted
  announcements are committed to a bounded SQLCipher inbox on Android and
  protected Keychain-backed state on iOS before server acknowledgement, then
  removed only after protected media is established.
- Corrected the Android call gate to timestamp the actual answer action and
  protected-media connection separately from ringing and server room-state
  propagation, preventing optimistic latency claims.
- Corrected a nested SQLCipher open and unnecessary delivery-receipt path that
  could hold the call-coordination lock for the database busy timeout during
  ring-time prewarming.
- Added a signed two-simulator iOS call gate with a Keychain-signature preflight,
  failure-stage markers, privacy-safe logs and optional failed-simulator
  preservation. The clean-room gate completed at 3.433 seconds invite-to-ring
  and 0.434 seconds answer-to-protected-media.
- Added a bidirectional Android/iOS call-interoperability gate. A physical
  Android endpoint and muted iOS simulator completed protected media in 0.791
  seconds iOS→Android and 1.282 seconds Android→iOS, including authenticated
  teardown and the complete Rust integration suite.
- Added a debug-only Android encrypted-call acoustic fixture and playback-head
  detector. Pixel-to-Samsung and Samsung-to-Pixel runs each delivered and
  decrypted all five bursts and measured 280 ms and 200 ms acoustic p95 under
  the calls-v1 300 ms budget. The detector now bridges sub-600 ms callback
  jitter without merging the fixture's real 800 ms gaps. This proves
  post-capture encrypted media reaches both physical remote speakers; the
  complete four-device gate remains mandatory.
- Added a second fail-closed Android physical-call gate that stimulates each
  real microphone only after protected media is active and observes capture
  without replacing samples. Pixel→Samsung and Samsung→Pixel each delivered
  all five microphone-originated tones to the remote decrypted-render graph at
  1.331 and 0.723 seconds answer-to-media respectively. The complete physical
  iOS, lifecycle, public-network, and independent-review gates remain open.
- Hardened the external microphone fixture against low host-volume false
  negatives. The physical gate temporarily raises a muted or quiet macOS output
  to a configurable minimum, then restores the exact prior volume and mute state
  on success, failure, or interruption.
- Hardened bidirectional real-microphone proof against acoustic feedback and
  device noise-processing artifacts. During each directional stimulus the
  debug-only harness mutes the callee uplink and temporarily attenuates its
  physical voice-call output while the pre-render observer remains active, then
  verifies restoration of the original device volume. Physical capture/render
  burst separation now tolerates up to 1.2 seconds of AEC, Opus or WebRTC
  suppression inside one tone while the fixture supplies two-second true gaps.
- Added native-control-plane integration coverage for confirmed direct-call
  conversion to a private ad-hoc group, the exact eight-account boundary,
  ninth-account rejection, epoch rotation, and deterministic host transfer.
- Fixed Rust group-call additions returning an internal error. The call row
  already serializes roster changes; the implementation no longer attempts the
  PostgreSQL-invalid operation of applying `FOR UPDATE` to an aggregate query.
- Added the matching non-mutating LiveKit capture/render diagnostic on iOS and
  made the signed physical driver require exactly five caller-microphone bursts
  and five remote decrypted-render bursts. The observer is debug-only, retains
  no PCM and has unit coverage proving it does not change samples. The iOS and
  cross-platform drivers now apply the same directional isolation as Android:
  they mute the callee uplink during the stimulus, suppress physical playout
  only after observing decrypted render PCM, then verify the callee is unmuted.
  Physical iOS diagnostics use the same 1.2-second burst-separation policy.
- Extended cross-platform physical-call automation with the same real-microphone
  requirement and added a four-device matrix covering both Android directions,
  both iOS directions, Android→iOS and iOS→Android. The release workflow now
  also requires live signaling, ICE/TCP, TURN/UDP and TURN/TLS before it can
  pass; these new physical/public gates have not yet been satisfied.
- Made the source repository public under AGPLv3.
- Added public contribution, conduct, governance, issue, pull-request, and
  private vulnerability-reporting guidance.
- Added a GitHub-hosted pull-request validation lane that does not expose the
  project's self-hosted build machines to untrusted contributor code.
- Enabled Dependabot update coverage and GitHub CodeQL default scanning.
- Added a public community path to the product website.
- Documented a staged, optional Supabase integration that leaves PTT encryption,
  device enrollment, floor control, and live media outside Supabase.
- Updated Promptfoo to 0.121.3, replaced its vulnerable `csv-parse` and
  Anthropic SDK dependency ranges with patched releases, and made
  moderate-or-higher npm advisories across every JavaScript workspace a
  fail-closed security gate.
- Added a protected signed-attestation workflow that binds the independent
  cryptography and application-security review to the exact commit, synchronized
  mobile build, signed artifact hashes, report hashes, covered scope, retest
  state, and zero open blocking findings before release automation can proceed.
- Removed the encrypted-call gate's dependency on an undeclared host-side
  libsignal build. CI now checks out and verifies the frozen v0.101.0 commit,
  while local Android gates discover the same pinned full source checkout when
  a partial prebuilt export cannot regenerate fresh identity fixtures.

## 0.1.29 (32) — 2026-09-04

- Synchronized the iOS and Android internal beta version and protocol 1.1.
- Added encrypted channel chat with files, voice messages, video, replies,
  reactions, search, receipts, topics, announcements, and operational activity.
- Improved iOS audio-session activation, Push to Talk integration, channel
  readiness, version reporting, and two-device production voice probes. A
  repeated hold is now blocked until the previous encrypted media flush and
  authenticated floor release have completed.
- Fixed delayed-media loss when a future prewarmed key announcement overtakes
  an earlier talk on the separate control transport; receivers now retain a
  bounded authenticated window instead of discarding the valid older stream.
- Added debug-only acoustic source markers so the independent microphone gate
  measures true receiver-speaker mouth-to-ear p95 instead of substituting the
  sender's communication-ready callback.
- Hardened the physical-device gate to reject multiple network endpoints that
  resolve to one Android hardware identity.
- Extended Trivy's fail-closed scan timeout for slower vulnerability-database
  downloads and added a regression that verifies the timeout reaches every
  security scan.
- Kept live PTT available on both Android and iOS when encrypted-history
  storage is throttled or temporarily offline by staging ciphertext durably
  on-device and retrying it with bounded backoff instead of failing or delaying
  the next voice session.
- Made encrypted-history upload retries idempotent while rejecting ciphertext
  or metadata substitution for an existing transmission identifier.
- Published current simulator screenshots, deployment guides, privacy material,
  and release gates.

This remains a private mobile beta. The physical acoustic matrix, Android
screen-off soak, external cryptography review, penetration test, and deployment
recovery proof remain production requirements.
