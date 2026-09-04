# PTT Talk

[![CI](https://github.com/golanbenoni/ptt/actions/workflows/ci.yml/badge.svg)](https://github.com/golanbenoni/ptt/actions/workflows/ci.yml)
[![Public pull requests](https://github.com/golanbenoni/ptt/actions/workflows/public-pr.yml/badge.svg)](https://github.com/golanbenoni/ptt/actions/workflows/public-pr.yml)
[![License: AGPLv3](https://img.shields.io/badge/license-AGPLv3-0b263a.svg)](LICENSE)
[![Beta: 0.1.29](https://img.shields.io/badge/beta-0.1.29-05aedd.svg)](docs/RELEASE_STATUS.md)

PTT Talk is an AGPLv3, self-hosted communication system for private teams. It
combines live push-to-talk voice with encrypted channel messaging, attachments,
voice messages, video, missed-transmission history, and two-device accounts.

## Current status

The next internal-testing candidate is **0.1.29 (build 32)** on product protocol
**1.1**. It is not yet uploaded: distribution is gated on the exact-commit
four-device acoustic matrix and non-shortenable Android screen-off soak. The
previous synchronized build remains available to the existing TestFlight and
Google Play internal groups while this candidate is validated.
Android and iOS product clients, the K3s and Cloudflare server implementations,
the administrator console, store assets, and automated release gates are in
this repository.

The source is now **public under AGPLv3**, while the distributed apps remain a
**private beta**, not a general-production release. Candidate build 32 must pass
CI, production relay, application-level decoded audio, collaboration,
accessibility, push-readiness, signing, the physical four-device acoustic
matrix, and the eight-hour Android screen-off soak before it can replace the
current tester binaries. External cryptography review, penetration testing, and
deployment-specific disaster-recovery proof also remain required before general
production. See [`docs/RELEASE_STATUS.md`](docs/RELEASE_STATUS.md) for the
distribution record and [`docs/CURRENT_STATE.md`](docs/CURRENT_STATE.md) for the
full implementation matrix.

## What the app does

- Administrator invitation and single-use email enrollment, with no public
  directory or phone-number identity.
- One random account identity with up to two independently keyed devices,
  active-device approval for linking, remote revocation, and administrator-
  approved recovery when every device is lost.
- Live Opus push-to-talk with authenticated channel floor control, talk limits,
  normal and silent SOS priority, feedback tones, presence, and encryption
  details on sender and receiver.
- RFC 9605 SFrame media encryption, replay protection, persistent counters,
  Sender Keys, PQXDH/Double Ratchet device delivery, and no plaintext fallback.
- Authenticated UDP media with automatic encrypted WebSocket/TLS fallback when
  UDP is blocked.
- Encrypted missed-transmission history with a 30-day/1-GB local limit. A newly
  linked device receives future communications only; old history is not
  re-wrapped.
- End-to-end encrypted channel chat with text, files, encrypted previews, voice
  messages, and video; resumable upload/download; replies, reactions, edits,
  delete, copy, share, forward, pin, star, search, mentions, drafts, and
  delivered/read/played receipts.
- A modern collaboration layer with direct and private-group conversations,
  topics, announcement channels, channel workspaces, a cross-channel activity
  inbox, operation status/acknowledgement, templates, user groups, time-limited
  guests, and channel-scoped encrypted automation identities.
- Device management, safety numbers, privacy-redacted support reports, account
  deletion, and a short-lived mobile-approved administrator-console session.

## Platform behavior

### Android

Android supports API 26 and later and targets API 36. A user must explicitly
arm **Stay connected** before the foreground session service can maintain voice
and opaque FCM-assisted reconnect. Force-stop and reboot intentionally require a
new visible arm action. The client also includes headset/hardware PTT routing,
quick settings, widget, and overlay entry points; device and OEM behavior must
still be included in physical release testing.

### iOS and iPadOS

The SwiftUI client supports iOS/iPadOS 16 and later. Physical release builds use
Apple's Push to Talk framework, APNs PTT pushes, native system controls, and
native audio-session activation. Apple permits one joined system PTT channel at
a time and requires foreground user interaction to join it. Secondary channels
remain available for encrypted chat and history. The simulator exercises the
same protocol and media code but cannot prove system PTT wake or acoustic output.

## Deployment choices

- [`deploy/helm/ptt/`](deploy/helm/ptt/) is the supported single-tenant K3s
  installation. It runs the Rust control and relay services, PostgreSQL, Redis,
  S3-compatible ciphertext storage, the admin console, ingress, monitoring, and
  coordinated backups.
- [`cloudflare/`](cloudflare/) is the managed-edge alternative using Workers,
  D1, R2, Queues, and hibernating Durable Objects. Media uses the encrypted TLS
  path; there is no plaintext or server-side decryption mode.

Both deployments route ciphertext and operational metadata. Encryption keys,
message text, attachment contents, and audio remain on enrolled devices.

## Repository layout

- `android/` — Android product app, lifecycle, audio, crypto, persistence, floor,
  and hardware-input modules.
- `ios/` — iOS/iPadOS product app, wire package, crypto/media integration, and
  simulator/device tests.
- `native/` — shared Rust Opus and SFrame implementation.
- `proto/` and `docs/PROTOCOL_V1.md` — frozen protocol 1.1 compatibility
  contract and golden vectors.
- `server/` — Rust control plane, HTTP/2 control services, push delivery, and UDP
  relay.
- `admin-web/` — responsive administrator console.
- `cloudflare/` — Cloudflare deployment and encrypted media coordinator.
- `deploy/helm/ptt/` — K3s Helm chart and operator runbook.
- `tests/` and `scripts/` — cross-platform, lifecycle, accessibility, physical
  device, soak, release, security, and store-readiness gates.
- `store/` — current metadata, privacy disclosures, and exact-size screenshots.
- `website/` — public product and privacy website source.

## Documentation

- [Deployment, build, and verification guide](docs/DEPLOYMENT_GUIDE.md) - complete K3s and Cloudflare installation, mobile builds, operations, and AI-agent execution contract.
- [`Current internal release status`](docs/RELEASE_STATUS.md)
- [`Current implementation and release gaps`](docs/CURRENT_STATE.md)
- [`Cross-platform interface system`](docs/UX_SYSTEM.md)
- [`Collaboration and workspace model`](docs/COLLABORATION_MODEL.md)
- [`Independent security review scope`](docs/SECURITY_REVIEW_SCOPE.md)
- [`Latest repository security review (September 3, 2026)`](docs/SECURITY_REVIEW_2026-09-03.md)
- [`Member guide`](docs/USER_GUIDE.md)
- [`Administrator guide`](docs/ADMIN_GUIDE.md)
- [`Simulator and physical-device testing`](docs/SIMULATOR_TESTING.md)
- [`Promptfoo campaign orchestration and evidence`](docs/PROMPTFOO_TESTING.md)
- [`Protocol v1.1 contract`](docs/PROTOCOL_V1.md)
- [`Wire formats`](docs/WIRE.md)
- [`Supabase integration decision and pilot plan`](docs/SUPABASE_INTEGRATION.md)
- [`Public roadmap`](docs/ROADMAP.md)
- [`Project governance`](GOVERNANCE.md)
- [`Changelog`](CHANGELOG.md)
- [`Android release setup`](docs/ANDROID_RELEASE.md)
- [`iOS build and release setup`](ios/README.md)
- [`K3s installation and operations`](deploy/helm/ptt/README.md)
- [`Cloudflare deployment`](cloudflare/README.md)
- [`Store privacy disclosures`](store/metadata/PRIVACY_DISCLOSURES.md)

## Community and security

- Browse and contribute at [github.com/golanbenoni/ptt](https://github.com/golanbenoni/ptt).
- Use [GitHub Discussions](https://github.com/golanbenoni/ptt/discussions) for
  design questions and deployment help.
- Use [GitHub Issues](https://github.com/golanbenoni/ptt/issues) for reproducible
  bugs and feature proposals.
- Report vulnerabilities privately through the repository's **Security** tab;
  do not include sensitive findings in a public issue. See
  [`SECURITY.md`](SECURITY.md).
- See [`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a pull request.
- Participation is governed by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## Local verification

The complete release suite needs platform SDKs, libsignal, containers, and
physical devices. The following is the portable source/integration baseline:

```bash
source scripts/java21-env.sh
./scripts/check-proto-contract.sh
./gradlew --no-daemon compileKotlin :crypto:test :floor:test :media:test \
  :hardware:test :crypto-persistence:lintDebug :talkandroid:lintDebug \
  :talkandroid:assembleDebug
cargo test --manifest-path native/Cargo.toml --locked
cargo test --manifest-path server/Cargo.toml --locked
./scripts/test-control-integration.sh
(cd ios/PttWire && swift test)
(cd ios/PttTalk && swift test)
npm ci --prefix admin-web && npm run typecheck --prefix admin-web
npm ci --prefix cloudflare && npm run check --prefix cloudflare
node scripts/verify-store-readiness.mjs
```

With Docker, Helm, `kubectl`, and `k3d` available, the disposable operations
gate builds the three application images and proves a clean K3s install,
authenticated readiness, coordinated backup/restore, upgrade, and rollback:

```bash
./scripts/test-k3s-clean-install.sh
```

The generated-tone tools remain cross-platform protocol fixtures only. They are
not part of the product UI and are not evidence of audible device-to-device
voice.

## License

GNU Affero General Public License v3.0. See [`LICENSE`](LICENSE).
