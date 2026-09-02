# Mobile and messaging parity goal

> **Acceptance target, not a current-state claim.** This file defines the next
> product-quality bar. For the implemented 0.1.24 (27) feature matrix, known
> gaps, and release blockers, see [`CURRENT_STATE.md`](CURRENT_STATE.md).

This document is the acceptance contract for bringing PTT Talk to functional
parity across Android and iOS and to a modern private-team messaging baseline.
Platform-native controls may differ, but observable communication behavior and
security guarantees must match.

## P0 — communication reliability

- iOS uses the entitlement-backed Push to Talk framework in release builds,
  including APNs wake, locked-screen receive, restoration, system controls, and
  native audio-session activation. Foreground-only packaging is not parity.
- Debug physical-device builds register only with an app-topic-restricted APNs
  sandbox key; TestFlight/App Store builds register with a separate restricted
  production key. Every ephemeral PTT token is scoped server-side to the one
  joined system channel it represents, while the opaque APNs payload contains
  no channel identifier. Testing must never require switching or interrupting
  the live APNs environment.
- Android and iOS expose durable `queued`, `sending`, `sent`, `delivered`,
  `read`, `played`, and `failed` message states with automatic, idempotent retry.
- Both clients wake for opaque chat pushes, update encrypted local state, show
  unread counts, and open the correct conversation from a notification without
  revealing message content to the push provider.
- Text, live PTT, files, voice notes, and video survive process death, offline
  delivery, duplicate requests, network changes, and interrupted uploads.
- Message events are pairwise encrypted and authenticated. The server only sees
  routing identifiers, ciphertext sizes, expiry, and delivery metadata.

## P1 — conversation experience

- Inline image, video, audio, and PDF previews use client-generated encrypted
  thumbnails and support progress, cancellation, retry, and resumable transfer.
- Voice notes support hold, slide-to-cancel, lock, pause/resume, preview,
  waveform seek, 1x/1.5x/2x playback, consecutive playback, and played receipts.
- Messages support replies, reactions, edit, delete-for-everyone, copy, forward,
  share, pin, star, per-message information, local search, mentions, and drafts.
- Conversations expose unread state, mute, pin, archive, participant details,
  roles, and administrator-controlled retention/disappearing policy.
- Android and iOS share information architecture, terminology, accessibility
  semantics, empty/error/loading states, and visual quality while following
  their native interaction conventions.

## Intentional product differences

- Newly linked devices receive future communications only. PTT Talk does not
  re-wrap historical content for a newly linked device.
- PTT Talk does not need consumer stories, advertising, payments, public social
  discovery, or plaintext server-side media processing to satisfy parity.
- iOS may have one system-managed live PTT channel. Secondary channels remain
  encrypted history/chat targets, matching Apple platform constraints.

## Required proof

- Frozen Kotlin/Swift vectors for every chat event and attachment container.
- Fresh Postgres/Redis/object-store and Cloudflare D1/R2 integration tests.
- Two-process product-client tests for every payload and event in both
  directions while repeated PTT runs concurrently.
- A recurring four-device matrix (two physical iOS and two physical Android)
  covering foreground, locked screen, offline, Wi-Fi/cellular transition,
  Bluetooth/wired routes, interruptions, reboot, and process death.
- The process-death voice gate terminates the receiving app without revoking
  push eligibility, then requires an opaque FCM/APNs wake, iOS system audio
  activation where applicable, decrypted playback completion, and an external
  acoustic burst. A UI `receiving` state or downloaded ciphertext is not a pass.
- Android restores the last user-armed voice channel before reconnecting media;
  iOS restores its one system-managed channel and keeps each ephemeral PTT
  token scoped to that channel.
- Production-timestamp gates requiring warm floor-grant p95 below 150 ms and
  encrypted communication-ready p95 below 400 ms in every platform direction;
  external acoustic timing remains the authority for true mouth-to-ear proof.
- Accessibility checks for VoiceOver/TalkBack and largest supported text.
- The exact release commit passes CI, security, production relay, and store
  signing gates before synchronized TestFlight and Play internal publication.
