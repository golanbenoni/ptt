# Release status

This page is the concise distribution record for PTT Talk **0.1.28 (31)**,
product protocol **1.1**, as of **September 3, 2026**. Detailed feature status
is maintained in [`CURRENT_STATE.md`](CURRENT_STATE.md); test procedures are in
[`SIMULATOR_TESTING.md`](SIMULATOR_TESTING.md).

## Current internal beta

| Platform | Distribution | Status |
| --- | --- | --- |
| iOS/iPadOS | TestFlight · `PTT Internal Testers` | `0.1.28 (31)` processed as valid and assigned to the internal group |
| Android | Google Play · Internal testing | `0.1.28 (31)` uploaded and committed to the internal track |
| Hosted service | `https://ptttalk.app` | Protocol 1.1 healthy with enrollment, collaboration, APNs/FCM, and encrypted TLS media capabilities |

The mobile binaries were produced from source commit
[`fc31ec77913524ccefd2eb0bbd073dc3b06f6df6`](https://github.com/golanbenoni/ptt/commit/fc31ec77913524ccefd2eb0bbd073dc3b06f6df6).
Later commits that change documentation or the public website do not alter the
published binary provenance.

## Automated evidence for build 31

- Exact-commit CI passed Kotlin/JVM, Swift, Rust, TypeScript, protocol, security,
  container, Helm, clean K3s install, documentation, store assets, Android/iOS
  accessibility, and production app compilation.
- The deployed production suite passed bidirectional encrypted PTT between two
  isolated product-app instances, twenty repeated transmissions in both
  directions, non-silent decoded playback, and encrypted text, file, voice-note,
  video, preview, reply, reaction, edit, delete, pin, star, and receipt flows.
- Production APNs and FCM readiness passed with separate Apple production and
  sandbox credentials and a dedicated Firebase delivery identity.
- The synchronized signed IPA and AAB were accepted by their internal testing
  services. Private handoff artifacts and checksums were retained.

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

After updating, confirm the opening status card reports **Version 0.1.28 (31)**.
Test repeated talk/release cycles in both directions before moving on to
screen-off, network-change, Bluetooth, SOS, chat, attachment, voice-note, video,
second-device, revocation, and recovery scenarios. Report only the app's
privacy-redacted support bundle; never send access tokens, invitation links,
private keys, raw identifiers, message content, or audio recordings through a
public issue.
