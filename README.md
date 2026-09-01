# PTT Talk

PTT Talk is an AGPLv3, self-hosted communication system for private teams. It
combines live push-to-talk voice with encrypted channel messaging, attachments,
voice messages, video, missed-transmission history, and two-device accounts.

## Current status

The current release candidate is **0.1.21 (build 24)** and uses product protocol
**1.1**. Android and iOS product clients, both server implementations, the web
administrator console, store assets, and automated release gates are present in
this repository.

PTT Talk is still a **private beta**, not a general-production release. Source,
simulator, integration, accessibility, protocol, store-asset, and security gates
are automated. Publication of an exact release commit still requires successful
four-device physical audio proof, the eight-hour Android screen-off soak,
production APNs/FCM readiness, and external security review. See
[`docs/CURRENT_STATE.md`](docs/CURRENT_STATE.md) for the implementation matrix
and remaining release gates.

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

- [`Current implementation and release gaps`](docs/CURRENT_STATE.md)
- [`Member guide`](docs/USER_GUIDE.md)
- [`Administrator guide`](docs/ADMIN_GUIDE.md)
- [`Simulator and physical-device testing`](docs/SIMULATOR_TESTING.md)
- [`Protocol v1.1 contract`](docs/PROTOCOL_V1.md)
- [`Wire formats`](docs/WIRE.md)
- [`Android release setup`](docs/ANDROID_RELEASE.md)
- [`iOS build and release setup`](ios/README.md)
- [`K3s installation and operations`](deploy/helm/ptt/README.md)
- [`Cloudflare deployment`](cloudflare/README.md)
- [`Store privacy disclosures`](store/metadata/PRIVACY_DISCLOSURES.md)

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
