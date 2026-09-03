# Public roadmap

Updated: September 3, 2026

PTT Talk is public-source software with privately distributed beta apps. This
roadmap describes priorities, not delivery promises. The current evidence and
remaining gates are authoritative in [`RELEASE_STATUS.md`](RELEASE_STATUS.md).

## Now — reliability before reach

- Complete the four-device iOS/Android acoustic matrix in both directions.
- Finish the eight-hour Android screen-off receive soak across representative
  Pixel, Samsung, Xiaomi, and Oppo devices.
- Measure warm floor-grant and mouth-to-ear latency on good Wi-Fi and LTE.
- Close remaining audio-route, network-transition, interruption, push-wake, and
  repeated-transmission failures with automated regression tests.
- Run backup/restore and upgrade/rollback drills against clean K3s and Cloudflare
  deployments.
- Triage the first public issues through the structured templates.

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
