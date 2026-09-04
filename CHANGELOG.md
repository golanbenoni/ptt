# Changelog

This file records user-visible and operator-visible changes. Release evidence,
store distribution state, and remaining release gates are maintained in
[`docs/RELEASE_STATUS.md`](docs/RELEASE_STATUS.md).

## Unreleased

- Made the source repository public under AGPLv3.
- Added public contribution, conduct, governance, issue, pull-request, and
  private vulnerability-reporting guidance.
- Added a GitHub-hosted pull-request validation lane that does not expose the
  project's self-hosted build machines to untrusted contributor code.
- Enabled Dependabot update coverage and GitHub CodeQL default scanning.
- Added a public community path to the product website.
- Documented a staged, optional Supabase integration that leaves PTT encryption,
  device enrollment, floor control, and live media outside Supabase.

## 0.1.29 (32) — 2026-09-04

- Synchronized the iOS and Android internal beta version and protocol 1.1.
- Added encrypted channel chat with files, voice messages, video, replies,
  reactions, search, receipts, topics, announcements, and operational activity.
- Improved iOS audio-session activation, Push to Talk integration, channel
  readiness, version reporting, and two-device production voice probes. A
  repeated hold is now blocked until the previous encrypted media flush and
  authenticated floor release have completed.
- Fixed delayed-media loss when a future prewarmed key announcement overtakes
  an earlier talk on the separate control transport; receivers now retain a
  bounded authenticated window instead of discarding the valid older stream.
- Added debug-only acoustic source markers so the independent microphone gate
  measures true receiver-speaker mouth-to-ear p95 instead of substituting the
  sender's communication-ready callback.
- Hardened the physical-device gate to reject multiple network endpoints that
  resolve to one Android hardware identity.
- Extended Trivy's fail-closed scan timeout for slower vulnerability-database
  downloads and added a regression that verifies the timeout reaches every
  security scan.
- Published current simulator screenshots, deployment guides, privacy material,
  and release gates.

This remains a private mobile beta. The physical acoustic matrix, Android
screen-off soak, external cryptography review, penetration test, and deployment
recovery proof remain production requirements.
