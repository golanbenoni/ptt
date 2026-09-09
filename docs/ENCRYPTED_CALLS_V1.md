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
acknowledgements fail closed.

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
call.

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

Validate a live installation with:

```sh
scripts/validate-calls-deployment.sh \
  https://ptt.example.com calls.ptt.example.com turn.ptt.example.com
```

For a release proof, set `PTT_CALLS_REQUIRE_TURN_PROBE=1` and supply temporary
TURN test credentials through protected environment injection. Do not put them
in shell history or evidence artifacts.

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

Until those items pass, this is implemented development source—not a store-ready
or production-approved calling release.

The latest internal calls assessment is
[`SECURITY_REVIEW_2026-09-08_CALLS.md`](SECURITY_REVIEW_2026-09-08_CALLS.md).
