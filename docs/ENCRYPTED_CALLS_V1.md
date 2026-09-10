# Encrypted voice calls v1

This is the implementation and acceptance contract for the unreleased PTT Talk
**0.2.0 (33)** call candidate. The currently distributed product remains
**0.1.29 (32)**. Version 0.2.0 must not be published until every software,
deployment, physical-device, performance, and independent-security gate below
has passed for one exact Git commit.

## Product boundary

Calls are a separate full-duplex protocol. They do not change the frozen
floor-controlled PTT framing. One-to-one and private-group conversations can
ring up to eight accounts; both linked devices ring, but an atomic server claim
allows only the first answering device to occupy that account's seat. Adding a
third person to a direct call requires confirmation and creates a private ad-hoc
group conversation.

The mobile navigation is **Talk, Chat, Calls, Activity, Settings**. Calls have
incoming, outgoing, connecting, securing, and active states; accept, decline,
mute, system audio route, participant, add-person, and end controls; recent and
missed history; callback actions; active-speaker and connection-quality status;
and a compact banner while another destination is open. Call timeline records
are encrypted conversation events. Call audio is never recorded.

Normal PTT is unavailable during a call and incoming ordinary transmissions go
to encrypted history. Sending or receiving priority SOS ends the call with
`sos_preempted`, releases WebRTC audio, and returns ownership to PTT without
automatically activating a microphone.

## Protocol and authorization

- `proto/call.proto` defines protocol v1 call invite, call/participant state,
  key announcement, acknowledgement, and call-ended messages.
- `GET /v1/capabilities` reports call protocol, participant limit, enabled
  state, and live media readiness. Clients hide/disable calls unless it reports
  protocol major 1 and a healthy media node.
- Start, get, answer, decline, leave, end, add, and remove APIs are
  device-authenticated and idempotent where a transition can be retried.
- `/v1/calls/events` is an authenticated WebSocket. Rust replicas distribute
  events through Redis; mobile push remains the wake/reconnect path.
  Android serializes stream ownership and ignores callbacks from retired
  sockets so a reconnect cannot displace a newer healthy connection. Both
  clients normalize the URL to the fixed endpoint without carrying unrelated
  path, query, or fragment data. The Rust service continuously reads control
  frames, answers protocol pings, and rejects text or binary application data
  because call coordination on this connection is server-to-client only.
- `/v1/internal/livekit/webhook` accepts only a signature-verified LiveKit
  webhook over the exact raw body. It is not authenticated as a device route.
- Initial calls and later participant invitations ring for 45 seconds. A device
  that claims a seat but does not establish protected media within that bounded
  window is failed and evicted. Calls stop after eight hours and retain
  coordination records for exactly 24 hours after completion. Encrypted
  conversation history follows the conversation retention policy.
- A direct call, or a group call whose final invitee declines before anyone
  joins, ends immediately as `declined`. A host ending a call before protected
  media becomes active is recorded as `cancelled`; active host termination
  remains `host_ended`.
- Device revocation, account deletion, and approved account recovery remove
  claimed call seats, rotate the call epoch, transfer host control when
  possible, and end an empty call.
- Removed participants immediately lose call-state and coordination-event
  authorization in addition to media and key access.

## End-to-end media encryption

The media server is LiveKit server `1.13.6`, with Swift SDK `2.16.0` and
Android SDK `2.28.2`. Each joining device generates a random 32-byte outbound
key. It sends that key only inside existing pairwise Double Ratchet envelopes
to devices that have joined. A frame key is derived with HKDF from the call ID,
epoch, and random per-call LiveKit participant identity.

Media publication and playback remain blocked in **Securing call** until every
required key acknowledgement matches the expected fingerprint. Membership
changes, revocation, and the 30-minute timer rotate the call epoch and every
outbound key. A user's mute state survives rotation. Stale epochs and missing
acknowledgements fail closed. Before a new epoch is accepted, both mobile
clients overwrite every retired key-provider slot for every previously known
participant with an undisclosed random tombstone. The local new slot is then
replaced with its new outbound key. This rejects delayed old-epoch media even
after LiveKit's 16-slot key index wraps.

LiveKit identities and room names are random per-call values. Join JWTs contain
no PTT account or device identifier, are restricted to one room, grant only
publish/subscribe, disable data/admin/recording, and expire after five minutes.
Keys never appear in JWTs, push payloads, server storage, metrics, or logs.
Recording, egress, ingress, SIP, agents, transcription, and plaintext fallback
are absent from the deployment.

## Platform ownership

On iOS, PushKit reports incoming VoIP pushes to CallKit immediately. CallKit
owns system presentation and Bluetooth/wired/interruption behavior. LiveKit
automatic audio-session configuration is disabled; WebRTC audio activates only
inside CallKit's `didActivate` callback and stops in `didDeactivate`. Apple Push
to Talk remains the independent PTT path and its graph is inactive during a
call. Native integration submits a ringing call through the durable push
outbox and requires successful APNs VoIP sandbox and FCM delivery using only
the protocol version, opaque call ID, and ringing event type. This proves
provider request construction against strict local endpoints, not live-device
APNs/FCM receipt or lock-screen CallKit presentation. The Cloudflare integration
fixture independently proves that a ringing call selects only the invited
device's FCM and APNs VoIP registrations and writes both durable call outbox
rows. Push invalidation removes the exact retired token on both control planes,
preventing a delayed PushKit or Firebase callback from deleting a newly rotated
replacement. Explicit Apple sign-out removes standard APNs, Push to Talk, and
VoIP registrations while the device session is still authenticated.

On Android, Jetpack Core-Telecom owns call registration, endpoints, routing,
wearable/automotive actions, and mute state. The phone-call foreground service
posts its ongoing notification immediately. The PTT session service remains
alive but transfers audio ownership to the call service.

## Deployment

K3s installs the pinned official LiveKit Helm dependency with one publicly
routable host-network media pod per node, Redis, health probes, resource limits,
graceful draining, disruption protection, and network policy. Operators provide
trusted certificates and public DNS for `calls.<domain>` and `turn.<domain>` and
open signaling, ICE/UDP, ICE/TCP, TURN/UDP, and TURN/TLS ports. The vendored
chart keeps the complete LiveKit configuration in a Kubernetes Secret because
it contains Redis authentication.

Cloudflare Workers/D1/R2 remain the control plane only. A Cloudflare deployment
must point to a dedicated public LiveKit VM or K3s media node; calls remain
disabled when its health check fails.

Run the local chart contract with `scripts/test-helm-calls.sh`. The CI transport
smoke uses `scripts/test-livekit-eight-party-smoke.sh` to verify the pinned SFU
carries two simultaneous synthetic audio publishers to all six subscribers in
an eight-party room. That deterministic smoke is intentionally not accepted as
encrypted mobile, public TURN, acoustic, or production-load evidence.

For a complete disposable Android call gate, connect or start two Android
runtimes and run:

```sh
PTT_ANDROID_DEVICE_1=emulator-5584 \
PTT_ANDROID_DEVICE_2=emulator-5594 \
LIBSIGNAL_ROOT=/absolute/path/to/pinned/libsignal \
JAVA_HOME=/absolute/path/to/jdk-21 \
ANDROID_HOME=/absolute/path/to/android-sdk \
scripts/test-android-call-local-stack.sh
```

The gate builds the debug app, generates fresh independent libsignal identities,
starts isolated Postgres, Redis, object storage, Rust control/relay services and
LiveKit `1.13.6`, then drives the production Android account, Double Ratchet,
Core-Telecom and E2EE media path on both runtimes. It requires both endpoints to
remain protected and unmuted for five seconds, verifies invite/activation timing,
ends the call through the authenticated API, proves both call services release
audio ownership, and resumes the complete Rust integration suite. Disposable
mobile accounts are separate from the integration fixtures so prekey consumption
cannot make the result order-dependent.

While both endpoints are publishing, the gate also runs
`scripts/assert-livekit-e2ee-room.sh` through LiveKit's authenticated
administration API. It requires one random base64url room, two random base64url
participant identities, no room or participant metadata, no recording state,
and only `GCM`-encrypted microphone tracks from both publishers. The companion
`scripts/test-livekit-e2ee-inspection.sh` starts deliberately unencrypted
publishers and proves the assertion fails closed. This is direct SFU-side
configuration and metadata evidence; it complements but does not replace the
mandatory packet capture and unauthorized-observer proof on the public media
node.

The focused physical Android campaign additionally runs
`scripts/test-android-two-device-call-unauthorized-observer.sh`. It transmits
five known encrypted audio bursts between the authorized product clients while
a subscriber-only Swift client joins the same room with random incorrect frame
keys. The gate requires both encrypted microphone tracks to report
`decryption_failed`, zero non-silent PCM at the observer, and all five decrypted
bursts at the authorized receiver. The observer token is room-restricted,
subscribe-only, data-disabled, and valid for one minute. This proves the local
SFU cannot give an unauthorized SDK client usable call media; public SFU/TURN
packet capture and independent review remain mandatory.

The driver defaults to `PTT_CALL_WAIT_FOR_PREWARM=1`, which models a normal
human answer after the encrypted call-start event has arrived. Set it to `0`
only for the explicit immediate-answer stress diagnostic. For an exact release
latency gate, also set `PTT_CALL_MAX_ANSWER_TO_MEDIA_MS=2000`; the
driver measures from the answer request to both endpoints' protected LiveKit
connection, independently of the later server webhook/UI state.

While the call rings, the clients authenticate the channel/device directory and
prepare the host's PQXDH data session without distributing a call key or
claiming an account seat. After answer, they connect LiveKit while publication
and playback remain muted, in parallel with Double Ratchet call-key exchange;
media becomes usable only after the required peer acknowledgements succeed.

This local gate proves protected session establishment and lifecycle state. Its
ordinary mode does not prove that microphone samples reached a remote speaker,
public UDP/TURN behavior, lock-screen push delivery, or physical-device
routing. The focused physical modes below add capture, render, speaker and
acoustic evidence without weakening the remaining release gates.

On the September 9 local loopback runs, two Android emulators measured
1.49–1.58 seconds invite-to-ring and 0.909–0.995 seconds
answer-to-protected-media across five consecutive ring-prewarmed calls. Every
run passed the strict 2-second automation threshold. An immediate cold answer
completed safely in 3.599 seconds; it deliberately answered before prewarming
could finish and is not the normal human-answer path. Both mobile clients now
commit call-key messages to protected local state before server acknowledgement
(SQLCipher on Android and Keychain-backed state on iOS) and remove them only
after protected media is established. These measurements demonstrate the
optimized ordering, durable handoff and honest instrumentation, but they are
not physical or acoustic performance evidence.

Twenty subsequent alternating calls on a physical Pixel 3a and Samsung
SM-F966U passed on exact commit `79cd031`. Invite-to-ring p95 was 3.651 seconds
against the five-second bound and answer-to-protected-media p95 was 1.846
seconds against the two-second bound. Each run held both endpoints protected
and unmuted for five seconds, released Core-Telecom ownership after authenticated
host teardown, and completed the Rust integration suite. The repetition exposed
a valid future-epoch key arriving before the authoritative roster update; both
clients now defer rather than discard that announcement and force a roster
refresh before accepting it. Invite-to-ring values
from this ADB-driven harness include configuration copy and activity-launch
overhead and do not measure FCM delivery. The result proves real-device media
graph lifecycle, not an external acoustic path.

The focused debug acoustic gate now injects a deterministic fixture only after
the caller's WebRTC capture stage and independently measures a local 613 Hz
source marker against the decrypted 997 Hz output from the remote physical
speaker. On September 9, Pixel-to-Samsung and Samsung-to-Pixel runs each
detected all five bursts inside the remote playback callback and passed at 280
ms and 200 ms acoustic p95 under the calls-v1 300 ms limit. They completed
protected media in 1.757 seconds and 0.817 seconds respectively, followed by
authenticated teardown and the complete Rust integration suite. During
development this gate exposed a real ownership race where LiveKit could switch
Samsung back to its earpiece after Core-Telecom selected Speaker; call sessions
now disable LiveKit's route handler and retry a user-selected Telecom endpoint
until the endpoint flow acknowledges it. The render detector bridges callback
dips shorter than 600 ms but separates the fixture's real 800 ms gaps. Because
the fixture enters after capture, this bidirectional result proves E2EE
transport, decode, render, routing, and both physical speakers—not real
microphone capture or the still-required four-device directions.

For actual capture proof, set the local stack's driver to
`scripts/test-android-two-device-call-real-microphone.sh`. The driver waits
until both endpoints are protected and active, then plays five externally
generated tones from the host output. It refuses synthetic capture, requires
the physical caller's non-mutating debug capture processor to observe exactly
five bursts, and requires the remote decrypted-render processor to observe the
same five. The stimulus temporarily raises a quiet or muted macOS output to at
least 80 percent by default and restores the exact previous volume and mute
state after the run; operators can change the floor with
`PTT_CALL_STIMULUS_MINIMUM_OUTPUT_VOLUME`. It also supplies a two-second audio-
graph settling period and two-second gaps. During the directional stimulus the
debug harness mutes the callee uplink, attenuates its physical voice-call output
without disabling the pre-render observer, and verifies the prior volume is
restored. This prevents either nearby device from republishing or acoustically
feeding back the known tone. The physical capture/render detectors tolerate
1.2-second AEC, Opus and WebRTC suppression gaps; the separate synthetic lane
keeps its 600 ms rule. Run it again with the serials swapped. On September 9 both physical
directions passed: Pixel→Samsung at 1.331 seconds answer-to-protected-media and
Samsung→Pixel at 0.723 seconds. The prior post-capture room-microphone runs
remain the separate proof of physical speaker output and 300 ms acoustic
latency; neither focused result substitutes for the complete four-device,
physical-iOS, push, route, interruption, or public-network matrix.

The two-device driver also accepts a reusable mid-call rotation hook. It adds a
third ringing account to a direct call, confirms the private-group conversion,
requires the server epoch to advance exactly once, and waits for both active
devices to report the same newly secured epoch while unmuted:

```sh
PTT_ANDROID_DEVICE_1=ANDROID_SERIAL_A \
PTT_ANDROID_DEVICE_2=ANDROID_SERIAL_B \
PTT_CALL_ACTIVE_HOOK="$PWD/scripts/test-android-call-epoch-rotation-hook.sh" \
PTT_CALL_PROOF_DURATION_MS=20000 \
scripts/test-android-call-local-stack.sh
```

The disposable integration fixture supplies the eligible third account. This
proves live Android rotation and media resumption. The equivalent signed iOS
simulator gate uses the same server transition and requires both Swift clients
to secure the new epoch:

```sh
PTT_CALL_ACTIVE_HOOK="$PWD/scripts/test-ios-simulator-call-epoch-rotation-hook.sh" \
PTT_CALL_PROOF_DURATION_MS=20000 \
scripts/test-ios-call-local-stack.sh
```

On September 9, the physical Pixel/Samsung run and the two signed iOS simulator
clients each advanced to epoch 3, exchanged fresh Double Ratchet call keys, and
returned to protected media. The Android rotation run reached protected media
initially in 1.716 seconds after answer; the iOS simulator run reached it
initially in 0.587 seconds. Independent stale-frame injection, physical iOS
audio, and the external four-device gates remain separate requirements.

The signed two-simulator iOS clean-room gate passed at 3.433 seconds
invite-to-ring and 0.434 seconds answer-to-protected-media, including encrypted
call-key exchange, muted simulator LiveKit E2EE connection, five seconds active,
remote teardown, and the Rust suite. The harness rejects linker-signed apps
built with `CODE_SIGNING_ALLOWED=NO`, because they cannot exercise Keychain.
A September 9 rerun after adding the iOS diagnostic observer passed at 2.132
seconds invite-to-ring and 0.540 seconds answer-to-protected-media, followed by
the complete Rust integration suite. Simulator media remains non-acoustic and
does not prove CallKit or PushKit.

The physical iOS driver has a real-microphone mode matching Android. Run
`scripts/test-ios-two-physical-call-real-microphone.sh` with two signed,
unlocked devices and the call test credentials. It waits for protected media,
plays five external 997 Hz bursts, inspects LiveKit's local capture and remote
render callbacks without retaining PCM, and rejects any result other than
exactly five bursts at both stages. The debug harness mutes the callee uplink
during the stimulus and observes decrypted render PCM before clearing physical
playout, then restores and verifies the unmuted state through a private marker.
Its physical detector uses the same 1.2-second separation policy as Android;
release builds do not contain these controls. Swap the two device identifiers
and account credentials for the reverse direction. This gate is implemented
but has not passed on two physical Apple devices yet.

For a bidirectional cross-platform interoperability check, use the same local
stack with one connected Android runtime:

```sh
PTT_ANDROID_DEVICE_1=ANDROID_SERIAL \
PTT_CALL_DRIVER="$PWD/scripts/test-android-ios-two-client-calls.sh" \
LIBSIGNAL_ROOT="$HOME/src/libsignal" \
scripts/test-android-call-local-stack.sh
```

On September 9 this passed with a physical Pixel endpoint at 0.791 seconds
iOS→Android and 1.282 seconds Android→iOS answer-to-protected-media. Both
directions used the product Double Ratchet and LiveKit E2EE paths and completed
authenticated teardown. The iOS simulator remains muted by design, so this is
wire/crypto/media-lifecycle interoperability evidence rather than physical iOS
or acoustic proof.

Run `scripts/test-livekit-multiroom-load.sh` for the deterministic 10-room
shape, or set `PTT_LIVEKIT_LOAD_ROOMS=32` for 256 simulated participants across
32 independent eight-person rooms. The gate requires all 12 expected
publisher-to-subscriber subscriptions in every room to remain healthy and
enforces a normalized CPU ceiling of 70 percent. On September 9 the pinned
local container completed both shapes: 10 rooms carried 80 participants and
120 healthy subscriptions, and a subsequent 20-second 32-room run carried 256
participants and 384 healthy subscriptions at 15.63 percent normalized peak
CPU across the 12-core Docker allocation. This closes
deterministic concurrency coverage, not the public
production-shaped resource, packet-loss, latency, or packet-level ciphertext
gate. The local physical Android call gate separately inspects the authenticated
SFU room and rejects any microphone track that is not marked as client-side GCM
encrypted. The same script accepts only a trusted-TLS remote URL and requires
protected LiveKit API credential injection when used against the public node.
The exact-commit public lane also invokes `scripts/probe-livekit-cpu.sh` against
an authenticated HTTPS Prometheus endpoint during the load; missing, malformed,
reset, or over-budget process CPU evidence fails the lane.

Validate a live installation with:

```sh
scripts/validate-calls-deployment.sh \
  https://ptt.example.com calls.ptt.example.com turn.ptt.example.com
```

For a release proof, set `PTT_CALLS_REQUIRE_TURN_PROBE=1` and supply temporary
TURN test credentials through protected environment injection. The validator
then performs relayed TURN/UDP and TURN/TLS exchanges in addition to signaling,
certificate and ICE/TCP checks. Do not put credentials in shell history or
evidence artifacts. `.github/workflows/encrypted-calls-release.yml` runs this
fail-closed public gate, the pinned ten-room load shape, focused Android tests,
and a signed two-simulator iOS E2EE lifecycle for one exact commit.

The exact-commit `.github/workflows/physical-release.yml` additionally invokes
`scripts/test-four-device-encrypted-calls.sh`. Two test accounts each contribute
an independently keyed Android device and iOS device. The matrix requires real
microphone delivery in Android A→B, Android B→A, iOS A→B, iOS B→A,
Android→iOS, and iOS→Android calls. It also performs authenticated TURN/UDP and
TURN/TLS allocation/relay probes before any physical call can count. A
connection label, active CallKit/Core-Telecom state, or valid ciphertext alone
cannot pass this matrix.

When the two physical Android devices are available before the Apple pair,
dispatch `.github/workflows/android-call-physical.yml` with their authorized
ADB serials and the exact AVFoundation measurement-microphone name. The focused
campaign alternates caller/callee ownership for 20 calls in one disposable
control/media stack, rejects a missing latency sample, enforces the five-second
invite-to-ring and two-second answer-to-protected-media p95 budgets, then runs
the wrong-key subscriber proof, post-capture encrypted speaker proof, untouched
real-microphone capture proof, and live epoch rotation in both Android
directions. Its green result is useful
exact-commit hardware evidence but never substitutes for physical iOS,
cross-platform, public TURN, lock-screen push, or four-device release proof.

Configure that workflow with repository variables `PTT_E2E_SERVER`,
`PTT_CALLS_DOMAIN`, and `PTT_TURN_DOMAIN`; protected TURN secrets
`PTT_TURN_USERNAME` and `PTT_TURN_PASSWORD`; and a private call-test
conversation in `PTT_CALL_CONVERSATION_ID`. The two test accounts use
`PTT_CALL_ACCOUNT_A_ACI` and `PTT_CALL_ACCOUNT_B_ACI`. For each account,
provide separate `ANDROID` and `IOS` values for `MAILBOX`, `TOKEN`, and
`IDENTITY_FIXTURE` using names such as
`PTT_CALL_ACCOUNT_A_ANDROID_MAILBOX` and
`PTT_CALL_ACCOUNT_A_IOS_IDENTITY_FIXTURE`. Identity fixtures are the existing
base64-encoded libsignal test records and must remain GitHub Actions secrets,
never repository variables or artifacts. The deterministic
`scripts/test-four-device-encrypted-calls-mapping.sh` contract verifies all six
platform/account/device mappings without reading real credentials or hardware.

## Mandatory evidence before 0.2.0 (33)

The exact release commit must provide all of the following:

1. Rust, Cloudflare, Kotlin, Swift, protocol, lint, dependency, SBOM, secret,
   Helm, container, and Promptfoo lanes pass from a clean checkout.
2. A real LiveKit deployment proves signaling plus ICE/UDP, ICE/TCP, TURN/UDP,
   and TURN/TLS. Packet inspection proves the SFU receives ciphertext only.
3. Two physical iOS and two physical Android endpoints pass 1:1 and group calls
   in every direction, including lock screen, push wake, route changes,
   interruptions, network transitions, reconnect, reboot, and SOS preemption.
4. The first-answer race is exercised concurrently on both devices of one
   account and exactly one seat/token is granted.
5. Join, leave, remove, revoke, recovery, periodic rotation, stale-key, replay,
   and forged-webhook cases fail closed.
6. Invite-to-ring, answer-to-audio, mouth-to-ear, and reconnect percentiles meet
   the v1 plan, using external acoustic/network evidence rather than a UI label.
7. Eight active participants and the 256-device coordination limit are tested;
   a production-shaped media node sustains 256 concurrent devices across 32
   eight-person rooms (including the required 10-room case) within its declared
   CPU, loss, and latency limits.
8. Existing PTT, chat, two-device enrollment/recovery, accessibility, backup,
   restore, upgrade, rollback, and eight-hour Android soak gates still pass.
9. An independent cryptography review and application penetration test cover
   call key distribution, LiveKit E2EE integration, JWT/webhook authorization,
   mobile lifecycle, and deployment exposure.

The independent-review result must pass the protected, signed exact-commit
attestation flow in [`SECURITY_REVIEW_SCOPE.md`](SECURITY_REVIEW_SCOPE.md).
Internal engineering reports and repository-owned scanner output cannot satisfy
that gate.

Until those items pass, this is implemented development source—not a store-ready
or production-approved calling release.

The latest internal calls assessment is
[`SECURITY_REVIEW_2026-09-08_CALLS.md`](SECURITY_REVIEW_2026-09-08_CALLS.md).
