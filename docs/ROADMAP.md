# Public roadmap

Updated: October 7, 2026

PTT Talk is public-source software with privately distributed beta apps. This
roadmap describes priorities, not delivery promises. The current evidence and
remaining release work are authoritative in [`RELEASE_STATUS.md`](RELEASE_STATUS.md).

## Now — complete messaging upgrade and internal release

- Deliver the approved native messaging upgrade on iOS and Android, keeping
  Chats, Calls, Activity, and Settings and PTT's own branding.
- Provide a searchable inbox and teammate directory, direct-conversation reuse,
  a separate reviewed group-creation flow, chronological replies, and visible-only
  read handling that preserves the reader's position.
- Deliver encrypted composer drafts and staged photos, videos, and documents:
  selection, preview, ordering, captions, durable acceptance, individual retry,
  and explicit in-app viewing and save/share controls.
- Preserve live PTT, SOS, voice calls, device linking and recovery; make microphone
  conflicts and the one-live-call-seat rule understandable.
- Verify real dedicated-account journeys separately from fixture-based visual
  tests, retain screenshots and defects, and deliver the same source revision
  through TestFlight and Google Play internal testing.

Build 50 is available on both internal tracks. The follow-up targets synchronized
build 51 to fix an iOS attachment-upload response compatibility defect found by
real-client integration testing. The acoustic-gate workflow was abandoned at the user's direction;
it is not a prerequisite for this release and will not be restarted. Production
promotion is outside this delivery. Private invitation-only teams, the existing
encryption architecture, and the eight-person conversation/call limit remain.
Consumer signup, address-book discovery, video calling, and public social
features are excluded; this release does not claim complete Signal or WhatsApp parity.

## Next — trustworthy private-team beta

- Complete independent cryptography review and application penetration testing.
- Expand dependency, SBOM, CodeQL, secret, container, and Kubernetes findings
  into tracked remediation with release-blocking severity policy.
- Harden invitation, device linking, administrator-approved recovery, revocation,
  membership rotation, and second-device UX.
- Exercise chat files, voice messages, video, receipts, search, retention, and
  deletion across both platforms and offline/reconnect states.
- Validate relay fan-out at 64 encrypted members and 256 connected devices.
- Pilot the optional Supabase community-data boundary described in
  [`SUPABASE_INTEGRATION.md`](SUPABASE_INTEGRATION.md) without placing PTT
  cryptographic identity or live media in Supabase.

## Later — production 1.0

- Publish signed, reproducible release artifacts with provenance and documented
  support windows.
- Complete accessibility, localization readiness, privacy disclosures, operator
  monitoring, abuse controls, disaster recovery, and migration compatibility.
- Prove hardware PTT, SOS priority, TLS media fallback, and privacy-redacted
  support exports on supported device and network combinations.
- Roll out through one closed private-team deployment, expanded beta groups, and
  staged production releases only after every production gate is satisfied.

## Outside 1.0

Public directory and phone-number identity, multi-tenant SaaS and billing,
compliance recording, transcripts, maps, dispatch consoles, RoIP, Wear, kiosk,
scene sharing, video calling, and mesh networking are outside the 1.0 scope.

## How to participate

- Ask architecture and deployment questions in
  [GitHub Discussions](https://github.com/golanbenoni/ptt/discussions).
- Report reproducible problems or focused proposals through
  [GitHub Issues](https://github.com/golanbenoni/ptt/issues).
- Follow [`CONTRIBUTING.md`](../CONTRIBUTING.md) for code and documentation.
- Report vulnerabilities privately under [`SECURITY.md`](../SECURITY.md).
