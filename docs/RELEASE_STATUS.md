# Release status

This page is the concise distribution record for PTT Talk **0.1.29 (32)**,
product protocol **1.1**, as of **September 4, 2026**. Detailed feature status
is maintained in [`CURRENT_STATE.md`](CURRENT_STATE.md); test procedures are in
[`SIMULATOR_TESTING.md`](SIMULATOR_TESTING.md).

## Current release candidate

| Platform | Distribution | Status |
| --- | --- | --- |
| iOS/iPadOS | TestFlight · `PTT Internal Testers` | `0.1.29 (32)` candidate; upload and assignment pending exact-commit gates |
| Android | Google Play · Internal testing | `0.1.29 (32)` candidate; upload pending exact-commit gates |
| Hosted service | `https://ptttalk.app` | Protocol 1.1 healthy with enrollment, collaboration, APNs/FCM, and encrypted TLS media capabilities |

The previously distributed synchronized build remains available to existing
testers. Candidate build 32 will record its tested source commit and signed
artifact hashes here only after physical acoustic and soak evidence passes.

## Post-build testing architecture

The repository now includes Promptfoo-orchestrated pull-request, nightly,
adversarial, weekly, rendered-browser, and physical-release campaigns. These
campaigns wrap deterministic native gates and produce redacted, hashed evidence
tied to the Git commit and workspace state. Build 32 remains a candidate until
the physical acoustic and eight-hour soak requirements below pass on its exact
source commit.

Development-workspace validation of the campaign implementation passed the 9-lane PR suite,
22-lane nightly suite, 3-lane deterministic adversarial suite, disposable K3s
lifecycle, Android and iOS accessibility matrices, and the production website
browser audit. The website audit found and fixed mobile horizontal scrolling;
Cloudflare browser analytics was disabled to match the published no-analytics
privacy promise. Clean-checkout GitHub evidence is generated after the commit is
pushed and does not convert the still-open hardware gates into a pass.

## Required automated evidence for build 32

- Exact-commit CI must pass Kotlin/JVM, Swift, Rust, TypeScript, protocol, security,
  container, Helm, clean K3s install, documentation, store assets, Android/iOS
  accessibility, and production app compilation.
- The deployed production suite must pass bidirectional encrypted PTT between two
  isolated product-app instances, twenty repeated transmissions in both
  directions, non-silent decoded playback, and encrypted text, file, voice-note,
  video, preview, reply, reaction, edit, delete, pin, star, and receipt flows.
- Production APNs and FCM readiness must pass with separate Apple production and
  sandbox credentials and a dedicated Firebase delivery identity.
- The synchronized signed IPA and AAB will be uploaded only after every required
  exact-commit gate passes; upload acceptance alone will not count as proof.

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

After updating, confirm the opening status card reports **Version 0.1.29 (32)**.
Test repeated talk/release cycles in both directions before moving on to
screen-off, network-change, Bluetooth, SOS, chat, attachment, voice-note, video,
second-device, revocation, and recovery scenarios. Report only the app's
privacy-redacted support bundle; never send access tokens, invitation links,
private keys, raw identifiers, message content, or audio recordings through a
public issue.
