# Release status

This page is the concise distribution record for the PTT Talk **0.2.0 (35)**
internal calls candidate, product protocol **1.1**, as of
**September 11, 2026**. Detailed feature status
is maintained in [`CURRENT_STATE.md`](CURRENT_STATE.md); test procedures are in
[`SIMULATOR_TESTING.md`](SIMULATOR_TESTING.md).

## Current release candidate

| Platform | Distribution | Status |
| --- | --- | --- |
| iOS/iPadOS | TestFlight · `PTT Internal Testers` | `0.2.0 (35)` replacement candidate pending gated upload; build 34 is stalled in Apple processing |
| Android | Google Play · Internal testing | `0.2.0 (34)` available; synchronized build 35 pending gated upload |
| Hosted service | `https://ptttalk.app` | Protocol 1.1 healthy with enrollment, collaboration, APNs/FCM, and encrypted TLS media capabilities |

Build 34 was accepted by App Store Connect's binary uploader but remained in
Apple's `PROCESSING` state through two independent two-hour verification
windows. It is superseded by replacement build 35. The iOS
release workflow now requires Apple to finish processing the build and verifies
the group relationship before it reports tester delivery as successful.

Full-duplex encrypted calls are included in the internal candidate. The dedicated public
media node is now reachable through DNS-only `calls.ptttalk.app` and
`turn.ptttalk.app`, uses a trusted renewable certificate, and passes signaling
TLS, ICE/TCP, authenticated TURN/UDP, TURN/TLS, protected metrics, and
32-room/256-client concurrency checks. Packet-level ciphertext capture, the
six-direction physical real-microphone matrix, lifecycle/performance evidence,
soak, and independent review have not all passed. Release **0.2.0 (35)**
therefore remains blocked from production promotion. Internal tester
distribution is permitted after all automated exact-commit gates pass so the
remaining hardware evidence can be collected.

The production Cloudflare control plane has the calls schema and protocol 1.0
capability endpoint deployed. With the dedicated LiveKit/TURN node healthy, it
now reports `enabled: true`, `mediaReady: true`, and an eight-participant limit.
This enables controlled development testing; it does not waive the remaining
release gates.

Candidate build 35 records its tested source commit and signed artifact hashes
when uploaded to the internal groups. That upload is evidence distribution, not
general-production approval.

## Post-build testing architecture

The repository now includes Promptfoo-orchestrated pull-request, nightly,
adversarial, weekly, rendered-browser, and physical-release campaigns. These
campaigns wrap deterministic native gates and produce redacted, hashed evidence
tied to the Git commit and workspace state. Build 35 remains a candidate until
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
independent-review gates for 0.2.0 (35).

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

## Required automated evidence for build 35

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

After updating, confirm the opening status card reports **Version 0.2.0 (35)**.
Test repeated talk/release cycles in both directions before moving on to
screen-off, network-change, Bluetooth, SOS, chat, attachment, voice-note, video,
second-device, revocation, and recovery scenarios. Report only the app's
privacy-redacted support bundle; never send access tokens, invitation links,
private keys, raw identifiers, message content, or audio recordings through a
public issue.
