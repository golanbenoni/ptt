# Release status

This page is the concise distribution record for PTT Talk **0.2.0 (51)**,
product protocol **1.1**, updated **October 7, 2026**. Detailed feature status
is maintained in [`CURRENT_STATE.md`](CURRENT_STATE.md); test procedures are in
[`SIMULATOR_TESTING.md`](SIMULATOR_TESTING.md).

## Current release candidate

| Platform | Distribution | Status |
| --- | --- | --- |
| iOS/iPadOS | TestFlight · `PTT Internal Testers` | `0.2.0 (51)` processed VALID and attached to the internal group October 7 |
| Android | Google Play · Internal testing | `0.2.0 (51)` accepted and confirmed available to internal testers October 7 |
| Hosted service | `https://ptttalk.app` | Protocol 1.1 healthy with enrollment, collaboration, APNs/FCM, and encrypted TLS media capabilities |

Both build-51 binaries use source `d2fc6ae698643fc54fa58d34f7ea26c27edfeda1`.
TestFlight run `37610755928` and Play run `37610815016` succeeded using the
authorized internal-upload override. App Store Connect independently confirmed
build `d1f9e98f-6570-4770-9eb5-d4689c3f231d` is VALID, not expired, and attached to
`PTT Internal Testers`. Play Console confirmed version code 51 is available to
internal testers with full rollout at 07:05 Eastern on October 7.

Build 51's signed IPA SHA-256 is
`87aa8f16c5482dfbd09c387fec4a19f897629aba8cc868ef7c63d3909c4813a6`.
The accepted Android AAB SHA-256 is
`0a9a1a1da6ec62b9b39855afb2ecefb3e42cda3196e487781970c6bb5b139350`.
These are signed-file hashes, not the enclosing GitHub artifact ZIP digests.
The original Android upload key was recovered from SuperMac01, verified against
the existing Play certificate, and restored on the build hosts. The replacement
key reset request was canceled before the accepted upload. No key reset is pending.

These internal uploads were explicitly authorized without prerequisite gate
evidence. They do not constitute production approval. The user abandoned the
physical-gate workflow; further app development does not wait for it.

## Messaging upgrade and verification

The approved messaging upgrade was distributed as synchronized build 50. A real
native-client test subsequently found that iOS rejects the Rust server's omission
of an empty `uploadedParts` array when starting an attachment upload. Text and
replies arrived, but attachment delivery failed. The client now accepts both
omitted and empty-array encodings while rejecting malformed resume state.
The correction is distributed in synchronized build **51**, because 50 was consumed.
Superseded build 50 used source `a652b113cafeacc91941ce64c4621aec12e2f900`,
TestFlight run `37608878387`, and Play run `37608819790`. Its signed IPA hash was
`7359eec1fae0e433350beabec7fd2a760c4915cc9fcde2c0df79283f8f0b0f61` and AAB hash was
`640e30778e9d01f749f0fd58e74d0152549f1dcb4cd85dae507ffd03a26f6f8a`.
Existing GitHub CLI/API credentials return HTTP 401; Git HTTPS push remains
available. The existing Edge GitHub session is authenticated for browser dispatch.
Existing Android and Apple signing assets
are retained, and no replacement key is requested.

The distributed implementation includes matching encrypted composer and
staged-media models, searchable teammate selection and separate group review,
chronological main-timeline replies, quoted reply navigation, visible-message read
handling, photo normalization, multi-item preview with captions/order/removal,
stable attachment acceptance IDs, durable local enqueueing, and in-app media
viewing with explicit save/share. These are not yet described as complete on
both platforms: end-to-end media/restart/interruption and accessibility acceptance
remain outstanding. Android capture coordination now excludes concurrent voice
notes, PTT and calls, and preserves a voice-note preview when calls/SOS interrupt
capture. Device interruption scenarios still need real-hardware verification.

On October 7, all **120 Swift client tests passed** in the repaired signed,
app-hosted simulator test lane. This resolves the former standalone Keychain
entitlement and duplicate framework-output failures without skipping tests.
New tests cover draft limits/ordering, encrypted staged bytes, durable outbox
reopen/idempotence, and rejection of conflicting message content. Android's
77 unit tests, debug assembly, and lint passed, including video previews and
large-text PTT controls. All **13 iOS standard-size UI tests passed** on build 51,
including main-timeline/quoted replies and the repaired Reply context-menu action.
Android's complete fixture accessibility audit passed all 12 light/dark and
standard/maximum-size surfaces plus inbox filters, search/thread navigation,
saved messages, waveform scrolling, invitation/link/recovery, and Calls navigation.
Largest-text iOS tests passed on the build-50 candidate with the simulator
configured at the required accessibility text size; earlier standard-size runs
of that specific test are retained as configuration failures. Fixture checks are not
evidence of real messaging delivery. Release screenshots, store proof, test logs,
and integration results are retained under `artifacts/messaging-51/`; earlier
candidate results and failures remain under `artifacts/messaging-50/`.
The build-51 iOS UI result is `artifacts/messaging-51/ios-ui-standard.xcresult`.
Phone/iPad screenshots are in `ios-fixtures`, Android phone screenshots in
`android-fixtures`, and native tablet screenshots in `android-tablet-native-fixtures`.
These rendered screens contain fixture content, not live customer conversations.

The disposable integration stack's pinned upstream MinIO container registry
returned HTTP 401. For this local test only, MinIO was built from official source
commit `7ced9663e6a791fef9dc6be798ff24cda9c730ac` and its client from
`ee72571936f15b0e65dc8b4a231a4dd445e5ccb6` (the originally pinned release tags).
Optional test image overrides do not change production service configuration or
test assertions. The corrected native-client messaging rerun passed in **both
directions**, with 14 assertions per direction covering text, replies, encrypted
file/voice/video payloads and thumbnails, edits, reactions, pins, delete, and
delivered/read/played receipts. Payloads crossed the real disposable Rust service
between separate accounts and were decrypted and byte-checked by the receiving
native client. Media payloads are deterministic fixtures: this is real encrypted
delivery evidence, not camera, codec playback, or physical audio evidence.
The failing build-50 run and corrected run are retained separately in
`chat-integration` and `chat-integration-2`. Earlier call attempts failed during call-key
delivery or Android media joining. Retained LiveKit logs and server state exposed
a test-only ICE port mismatch: the container advertised 7881 while the Android
tunnel forwarded a dynamic port. The corrected harness uses the same port on
both sides; it does not relax timing assertions or change production networking.
The corrected call run established encrypted media in both directions. iOS to
Android passed (ringing 1,949 ms; protected media 689 ms). Android to iOS failed
the unchanged 5,000 ms ringing limit at 5,774 ms. This is a failed timing check,
not a full call-acceptance pass. Logs are retained in `call-integration-5`.

### Known limitations and remaining acceptance work

- Unsent voice-recording previews are not restored across app restart; encrypted
  text, quoted-reply context, and staged photo/document drafts are restored.
- Download/retry feedback is primarily in the conversation, not a complete
  progress-and-retry experience inside the media viewer.
- A process crash between text acceptance and draft clearing can leave the
  accepted text offered again in the composer. Stable per-item acceptance IDs
  prevent duplicate staged-attachment events; text draft acceptance is not yet
  atomic with clearing the composer.
- Crashes between encrypted staging writes and metadata writes can leave orphaned
  encrypted files. Video preview temporary files are removed on normal dismissal,
  but crash-orphan cleanup is not yet exhaustive.
- Interrupted multi-item delivery, mixed build-49/new-build media, permission
  denial, and actual VoiceOver/TalkBack use still need dedicated acceptance runs.
  A retained build-number-49 simulator binary was tried as a receiver, but failed
  secure-store initialization before messaging; it is not compatibility evidence.
  That local binary is not asserted to match the distributed build-49 artifact.
- The larger native screens have reusable directory, timeline/composer, preview,
  and capture helpers, but inbox/call-control extraction is not exhaustive.
- No physical audio, PushKit/CallKit interruption, or production readiness is
  implied by the local simulator/emulator tests. The acoustic workflow remains
  abandoned.

### Internal tester checklist

1. Use two separate invited accounts. Find a teammate, reopen an existing direct
   chat, and create a named group without exceeding eight members.
2. Exchange text, photos, and a voice note. Reply in the main timeline and tap
   its quote; confirm older history does not jump when a message arrives.
3. Stage several photos, reorder/remove them, add captions, switch chats, and
   restart before sending. Check the recovered draft and each item's delivery.
4. Send offline, reconnect, and retry only failed items. Check that successful
   items do not appear twice.
5. Place and end a call in each direction. Check mute, output, PTT, and voice-note
   interruption behavior. Report platform, build, time, and the visible error.

The chat list now offers pin/unpin, mute/unmute, and archive/restore actions on
Android and iOS without opening the conversation or marking messages read.
Archived conversations collapse into an expandable section and appear
automatically when they match a search. Preferences remain device-local. These
changes are included in the distributed build 50 binaries.

Delivery controls now add conversation-scoped queued/sending/failed counts,
accessible individual retry for text and attachments, and membership-change
guidance. Retries retain the original durable event, ciphertext, and recipient
envelopes. Reentrant delivery is guarded; manual retry reloads local state without
triggering an account-wide retry or marking messages read. Local history remains
available when network refresh fails. These changes are included in build 50.

Validation on October 5: Android debug assembly, lint, and all 74 app unit tests
passed. The iOS simulator build and three focused UI tests passed, covering
pin/mute/archive/restore, archived-content search, existing inbox filters, and
preservation of unread counts and unrelated preferences, plus accessible retry
and membership-blocked guidance using a debug fixture. The standalone Swift codec,
delivery-policy, and encrypted-archive probe passed, including failed attachment
reopen, stable event/envelope/ciphertext, and isolation of another channel's outbox
entry. These checks do not claim a live two-device network-failure test.
The October 5 standalone Swift package test limitation was resolved on October 7
by the signed app-hosted lane described above. Use `scripts/test-swift-client.sh`
with a dedicated simulator and platform-matching native libraries.

## Historical candidate evidence (through build 46)

Build 35 was rejected during App Store processing because its app bundle lacked
the camera-purpose string Apple requires for attachment capture APIs; the
privacy explanation and regression check were added afterward. Build 37 was
accepted and processed, but App Store Connect returned its alternate 422
already-associated response when release automation requested the internal
group relationship. Build 38 recognizes both of Apple's idempotent conflict
forms and still requires an authoritative group-membership query before tester
delivery can pass.

Build 39 passed every automated exact-commit prerequisite, but its mandatory
Android screen-off soak failed after 3 hours 33 minutes: the Samsung receiver
accepted transmission 43 while the Pixel sender remained in finalization beyond
the release deadline during a degraded control-plane interval. Build 40 moves
media-key prewarming to an isolated queue and treats TLS relay handshake timeouts
as recoverable reconnect events. Its eight-hour rerun delivered all 97 encrypted
transmissions, proving that repair, but floor-grant p95 was 195 ms against the
required 150 ms ceiling. Build 41 keeps the armed Android TLS route warm with
protocol-level heartbeats. Its focused physical run achieved a 70 ms floor-grant
p95, but exposed repeated OEM microphone construction that produced a 448 ms
communication-ready p95 against the 400 ms ceiling. Build 42 reused a stopped,
initialized recorder and its audio effects between holds while keeping capture
inactive outside an authenticated floor. Its physical run delivered all 20
encrypted transmissions with 70 ms floor-grant p95, but periodic sender-key
preparation contention produced a 502 ms communication-ready p95. Build 43
prepares the next media epoch during the active talk and bypasses device
discovery when that prepared epoch is available. Its exact physical run passed
40/40 encrypted transmissions and both latency ceilings, but the independent
room recording found only 12 of 20 source timestamps because the phones' system
streams were muted. Build 44 preserves, raises, and restores that test-only
sonification stream for acoustic measurement. Build 45 added the conversation-
first interface, encrypted thread controls, global search, saved items, and
pairwise-encrypted ephemeral typing indicators. Build 46 adds a prepared
pairwise-media epoch reserve and reduces repeated Android PTT audio-readiness
latency while preserving explicit private-output routing. No earlier candidate
evidence is carried forward to its exact-commit release decision.

Full-duplex encrypted calls are included in the internal candidate. The dedicated public
media node is now reachable through DNS-only `calls.ptttalk.app` and
`turn.ptttalk.app`, uses a trusted renewable certificate, and passes signaling
TLS, ICE/TCP, authenticated TURN/UDP, TURN/TLS, protected metrics, and
32-room/256-client concurrency checks. Packet-level ciphertext capture, the
six-direction physical real-microphone matrix, lifecycle/performance evidence,
soak, and independent review have not all passed. Release **0.2.0 (46)**
therefore remains blocked from production promotion. Internal tester
distribution is permitted after all automated exact-commit gates pass so the
remaining hardware evidence can be collected.

The production Cloudflare control plane has the calls schema and protocol 1.0
capability endpoint deployed. With the dedicated LiveKit/TURN node healthy, it
now reports `enabled: true`, `mediaReady: true`, and an eight-participant limit.
This enables controlled development testing; it does not waive the remaining
release gates.

Candidate build 46 records its tested source commit and signed artifact hashes
when uploaded to the internal groups. That upload is evidence distribution, not
general-production approval.

## Post-build testing architecture

The repository now includes Promptfoo-orchestrated pull-request, nightly,
adversarial, weekly, rendered-browser, and physical-release campaigns. These
campaigns wrap deterministic native gates and produce redacted, hashed evidence
tied to the Git commit and workspace state. Build 46 remains a candidate until
the physical acoustic and eight-hour soak requirements below pass on its exact
source commit.

Development-workspace validation of the campaign implementation passed the 9-lane PR suite,
22-lane nightly suite, 3-lane deterministic adversarial suite, disposable K3s
lifecycle, Android and iOS accessibility matrices, and the production website
browser audit. The website audit found and fixed mobile horizontal scrolling;
Cloudflare browser analytics was disabled to match the published no-analytics
privacy promise. Clean-checkout GitHub evidence is generated after the commit is
pushed and does not convert the still-open hardware gates into a pass.

On September 9, exact commit `79cd031` passed 20 alternating encrypted calls
between the physical Pixel 3a and Samsung SM-F966U, with a 3.651-second
invite-to-ring p95 and 1.846-second answer-to-protected-media p95. The same
commit passed the complete pull-request, CodeQL, and deterministic Promptfoo
checks. This closes the focused Android repeated-call regression only; it does
not close the public-media, physical-Apple, four-device lifecycle/acoustic, or
independent-review gates for 0.2.0 (46).

A subsequent local adversarial call subscribed to both physical Android
publishers with incorrect frame keys. Both tracks reported decryption failure,
the unauthorized observer rendered no PCM, and the authorized receiver decoded
all five known encrypted bursts. The next exact-commit physical campaign now
includes this assertion; public SFU/TURN packet capture and external review are
still required.

On September 10, the new 4-OCPU/24-GB public ARM64 media node passed the pinned
LiveKit 1.13.6 load at 32 simultaneous eight-person rooms: 256 connected test
clients, 384 healthy subscriptions, and 33.96% normalized sustained CPU against
the 70% ceiling. External allocation tests passed TURN/UDP and TURN/TLS, the
signaling certificate and ICE/TCP endpoint were reachable, unauthenticated
metrics returned 401, and authenticated sampling succeeded. The production DNS
and Cloudflare control-plane wiring are complete. This remains pre-release
evidence until the exact Git commit, packet capture, and remaining independent
and physical gates pass.

The later Android coordination-latency change on exact commit `a8debb4` passed
six alternating Pixel/Samsung calls with all 30 authorized encrypted bursts
decoded. Invite-to-ring p95 was 4.863 seconds and answer-to-protected-media p95
was 1.902 seconds. A separate wrong-key subscriber again rendered zero frames
while the authorized receiver decoded 5/5 bursts. The equivalent bounded
roster, directory, call-key queue, and idempotent-send behavior is now
implemented on iOS and is awaiting the current exact-commit simulator and
cross-platform rerun. These results do not close the public-media,
physical-Apple, soak, or independent-review gates.

## Required automated evidence for build 46

- Exact-commit CI must pass Kotlin/JVM, Swift, Rust, TypeScript, protocol, security,
  container, Helm, clean K3s install, documentation, store assets, Android/iOS
  accessibility, and production app compilation.
- Exact-commit Promptfoo PR, nightly/adversarial, and weekly infrastructure/browser
  campaigns plus CodeQL must pass before any signed tester upload can begin.
- The deployed production suite must pass bidirectional encrypted PTT between two
  isolated product-app instances, twenty repeated transmissions in both
  directions, non-silent decoded playback, and encrypted text, file, voice-note,
  video, preview, reply, reaction, edit, delete, pin, star, and receipt flows.
- Production APNs and FCM readiness must pass with separate Apple production and
  sandbox credentials and a dedicated Firebase delivery identity.
- The synchronized signed IPA and AAB may be uploaded to internal testing after
  the automated exact-commit gates pass; upload acceptance alone does not count
  as physical, soak, independent-review, or production-promotion proof.

The Android soak, physical-device, public call-media, and signed
independent-review workflows may run in parallel after their shared software
prerequisites pass. Each evidence producer defers only the other independent
result lookups while it runs. Internal-store workflows may defer only the
production-specific physical, soak, and signed-review results; every automated
software and media gate remains mandatory.

## What remains before general production

Internal distribution is intentionally used to complete hardware-dependent
proof. PTT Talk must not be described as generally production-ready until it
also completes:

1. the four-device iOS↔iOS, Android↔Android, Android→iOS, and iOS→Android
   physical matrix with an independent microphone proving audible output;
2. locked-screen wake, process death, network transition, Bluetooth/wired
   routing, interruption, reboot/restoration, and revocation on representative
   devices;
3. the non-shortenable eight-hour Android screen-off receive soak;
4. storage-capacity and disaster-recovery proof on the selected production
   infrastructure; and
5. an independent cryptography review and application penetration test.

Simulator playback callbacks, a receiving label, accepted ciphertext, and a
successful store upload are useful evidence but are not substitutes for the
physical acoustic gate.

## Tester checklist

After updating, confirm the opening status card reports **Version 0.2.0 (49)**.
Test repeated talk/release cycles in both directions before moving on to
screen-off, network-change, Bluetooth, SOS, chat, attachment, voice-note, video,
second-device, revocation, and recovery scenarios. Report only the app's
privacy-redacted support bundle; never send access tokens, invitation links,
private keys, raw identifiers, message content, or audio recordings through a
public issue.
