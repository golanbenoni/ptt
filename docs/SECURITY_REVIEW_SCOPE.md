# Independent security review scope

This is the engagement brief for the independent cryptography review and
application penetration test required before PTT Talk can be called
production-ready. The reviewer must be organizationally independent from the
people who designed or implemented the product. Repository-owned tests and
scanner reports are inputs, not substitutes for the review.

## Release under review

- Product: PTT Talk 0.1.27 (30), protocol 1.1.
- Source: `https://github.com/golanbenoni/ptt`.
- The review report must record the full Git commit SHA, signed mobile artifact
  hashes, deployed server revision, test dates, reviewer identities, and any
  environmental exceptions.
- Findings fixed after testing require a documented retest on the replacement
  commit and artifacts.

## Security objectives

1. A server, relay, object store, push provider, or network observer cannot
   recover message text, attachments, voice, video, history audio, or their
   content-encryption keys.
2. A device can receive only current membership traffic addressed to that
   device. Newly linked and revoked devices cannot recover unauthorized
   history.
3. No forged floor grant, relay binding, media frame, chat event, receipt,
   device-link approval, recovery approval, or administrator session is
   accepted.
4. Replay, reordering, crash recovery, counter exhaustion, duplicate delivery,
   interrupted transfer, and network rebinding fail closed without key or nonce
   reuse.
5. Every network path remains encrypted. UDP failure may select the
   authenticated TLS media path but can never select plaintext or unauthenticated
   media.
6. Push messages and support/operations data do not disclose content, keys,
   email addresses, raw account identifiers, or channel identifiers beyond the
   explicitly documented server metadata.

## Components in scope

- Android application code under `android/`, including Keystore/SQLCipher
  persistence, libsignal sessions, Sender Keys, SFrame, audio lifecycle, FCM,
  device linking/recovery, attachments, and foreground/background behavior.
- iOS/iPadOS code under `ios/`, including Keychain persistence, libsignal and
  native media integration, Apple Push to Talk/APNs, audio-session lifecycle,
  device linking/recovery, and attachment handling.
- Shared Rust media and SFrame implementation under `native/`.
- Rust control and UDP relay services under `server/`.
- Cloudflare Workers, Durable Objects, D1/R2/Queue paths under `cloudflare/`.
- Administrator console under `admin-web/`.
- K3s/Helm manifests, backup/restore jobs, ingress, secrets, and network policy
  under `deploy/helm/ptt/`.
- Frozen public contracts in `proto/`, `docs/PROTOCOL_V1.md`, and
  `docs/WIRE.md`.

Store portals, Cloudflare account administration, Firebase/Google Cloud
administration, Apple Developer administration, SMTP-provider administration,
and the underlying K3s host are in scope only to review least privilege,
credential separation, and deployment configuration. Destructive testing of
those provider accounts requires separate written approval.

## Required cryptography review

The reviewer must trace key creation, storage, distribution, rotation,
revocation, and deletion for identity keys, prekeys/PQXDH, Double Ratchet,
Sender Keys, sender certificates, SFrame media keys, history wrappers,
attachments, thumbnails, access tokens, relay tickets, and administrator
sessions. At minimum, test and analyze:

- protocol transcript binding, domain separation, AAD coverage, nonce/counter
  construction, randomness, key erasure, crash-counter recovery, and
  multi-device fan-out;
- malformed and cross-protocol inputs, unknown versions/flags, truncated and
  oversized records, replay windows, skipped-message limits, stale membership
  epochs, stale distribution IDs, prekey reuse, and talk-ID reuse;
- membership additions/removals, device linking, revocation, account recovery,
  safety-number change, and the no-historical-backfill guarantee;
- authenticated UDP binding, source-tuple replacement, floor authorization,
  truncated relay HMAC, TLS fallback authentication, and downgrade resistance;
- encrypted attachment and thumbnail resumability, range handling,
  cancellation, digest/AEAD verification order, object authorization, and
  partial-file cleanup;
- platform key storage and backup/migration behavior on rooted/jailbroken,
  restored, and passcode-changed devices, with platform limitations explicitly
  documented.

The report must distinguish a verified use of a reviewed primitive from custom
protocol composition and must not describe libsignal, SFrame, TLS, or an OS key
store as blanket proof for the surrounding implementation.

## Required application and infrastructure testing

Use dedicated test accounts, devices, provider projects, and an isolated K3s
installation. Include authenticated and unauthenticated testing for:

- enrollment, magic-link replay, resume secrets, second-device approval,
  recovery, remote revocation, account deletion, and administrator handoff;
- horizontal and vertical authorization across accounts, devices, mailboxes,
  channels, epochs, history objects, attachment uploads/parts, push tokens,
  audit data, health endpoints, and metrics;
- request smuggling/desynchronization, SSRF, injection, path traversal,
  malicious files/metadata, content-type confusion, range abuse, resource
  exhaustion, race conditions, idempotency collisions, and rate-limit bypass;
- foreground/background mobile lifecycle, process death, notification entry,
  clipboard/share/export paths, local database/files, logs, crash reports, and
  accessibility surfaces;
- administrator-console session isolation, CSRF, XSS, CSP, clickjacking,
  browser storage, cache behavior, logout/revocation, and cross-origin policy;
- Kubernetes RBAC, service accounts, pod security, network policy, image
  provenance, secret mounts, persistent-volume access, ingress/TLS, backup
  confidentiality/integrity, restore authorization, upgrade/rollback, and
  storage pressure;
- Cloudflare binding isolation, Durable Object authorization and capacity,
  D1/R2 object authorization, Queue replay, secret exposure, preview/deployment
  separation, and denial-of-service controls.

Do not send exploit payloads to production users or provider infrastructure.
Any test that could cause data loss, account lockout, high cost, or third-party
traffic requires an agreed maintenance window and explicit authorization.

## Evidence supplied to the reviewer

- A clean checkout at the candidate SHA and the signed release artifacts.
- Protocol and wire documentation plus the current-state and parity contracts.
- Kotlin, Swift, Rust, TypeScript, service-integration, relay-capacity, and K3s
  operations test results for that SHA.
- CycloneDX SBOM and Trivy secret/vulnerability reports produced by
  `scripts/security-audit.sh`.
- Four-device external-acoustic evidence and the eight-hour Android screen-off
  soak report when those gates have passed.
- A redacted deployment diagram, provider configuration export, Helm values,
  backup/restore evidence, and metadata-safe logs for the isolated test system.

Never place plaintext private keys, access tokens, service-account JSON, email
addresses, raw account identifiers, or decrypted user content in the review
bundle or issue tracker.

## Required deliverables and acceptance

The independent reviewer must provide:

- an executive report and a technical report with reproducible evidence;
- severity, affected commit/artifact, exploit preconditions, impact, and a
  concrete remediation recommendation for every finding;
- an explicit list of untested areas, environmental limitations, and residual
  risks;
- retest results showing each accepted critical/high issue fixed or formally
  risk-accepted by the product owner;
- a final signed statement identifying the reviewed commit and whether any
  unresolved finding permits plaintext, unauthorized decryption, forged
  transmission/floor state, privilege escalation, or material account takeover.

Production release is rejected while any critical or high finding is open.
Any crypto finding that could expose content, reuse a key/nonce, accept a forged
message, or downgrade transport also blocks transmission until fixed and
retested, regardless of its initial severity label.
