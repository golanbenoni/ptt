# Security review — September 3, 2026

## Outcome

This repository-owned review covered the Android and Apple clients, shared
Rust media code, the Rust control and relay services, the Cloudflare service,
the administrator web application, and the supported Helm deployment. No open
critical or high-severity finding was identified by this review. Five verified
defense-in-depth and authorization findings were corrected in the commit that
contains this report, plus one unsafe-FFI documentation hardening item.

This is an internal engineering review. It does not replace the independent
cryptography review and penetration test defined in
`docs/SECURITY_REVIEW_SCOPE.md`.

## Corrected findings

### SR-2026-09-03-01 — Historical ciphertext available to a newly linked device

- Severity: medium
- Surface: Cloudflare history list and download endpoints
- Finding: current channel membership was checked, but the requesting device's
  link time and the account's membership epoch were not applied to history
  reads. A newly linked device could therefore retrieve older encrypted
  ciphertext and associated metadata. It still lacked the content key, but the
  behavior violated the no-history-backfill contract and exposed avoidable
  metadata.
- Resolution: history reads now require an active device linked no later than
  the history object and an account membership that began no later than the
  object's membership epoch. Regression tests prove that a newly linked device
  receives neither the listing nor the object.
- Parity: the Rust/K3s implementation already enforced both conditions.

### SR-2026-09-03-02 — Listen-only member could submit a history object

- Severity: medium
- Surface: Cloudflare history upload endpoint
- Finding: the endpoint required current membership but did not reject the
  `listen` role. That role cannot receive a floor grant and must not create an
  object that represents a transmission.
- Resolution: a listen-only member now receives `TALK_NOT_PERMITTED`. A
  regression test covers the rejected upload.
- Parity: the Rust/K3s implementation already enforced this rule.

### SR-2026-09-03-03 — Sensitive provider or database detail could enter logs

- Severity: low
- Surface: Cloudflare error and email delivery paths; Rust control and gRPC
  error paths
- Finding: unexpected exception messages and some database/provider errors
  were logged verbatim. A provider or uniqueness error can include an email
  address, object identifier, or request-derived value.
- Resolution: operational logs now record stable error categories only. Email
  failures persist a bounded category rather than a provider message. The test
  suite proves that an exception containing a token and email address is not
  copied into logs.

### SR-2026-09-03-04 — Request logs retained correlating resource identifiers

- Severity: low
- Surface: Cloudflare and Rust HTTP telemetry
- Finding: raw paths could retain channel, attachment, message, or history UUIDs;
  the default Rust trace layer could also retain a query string.
- Resolution: Cloudflare replaces UUID path segments with `:id`, while the Rust
  service logs Axum's matched route template. Neither service logs query strings,
  credentials, or raw resource identifiers.

### SR-2026-09-03-05 — Public server origins and static browser policy were too permissive

- Severity: low
- Surface: Android, Apple, Rust, Cloudflare, and public deployment pages
- Finding: configured public origins were not uniformly restricted to a
  canonical HTTPS origin, and the deployment HTML did not receive the same CSP
  as the main public page.
- Resolution: production server origins must now use HTTPS and contain no user
  information, path, query, or fragment. Cloudflare production refuses an empty
  public origin. All public static HTML receives a restrictive CSP. The privacy
  page now directs vulnerability reports to private GitHub Security Advisories.

### SR-2026-09-03-06 — Apple Rust FFI safety contracts were implicit

- Severity: informational
- Surface: native Apple Opus and jitter-buffer C ABI
- Finding: the exported unsafe functions performed null, length, and capacity
  checks, but their caller obligations were not documented as Rust safety
  contracts.
- Resolution: every unsafe exported function now states the required pointer
  provenance, lifetime, mutability, capacity, and single-destruction rules. The
  native workspace passes strict Clippy checks with warnings denied.

## Review and verification performed

- Trivy filesystem vulnerability and secret scans, including the high/critical
  review report.
- CycloneDX SBOM generation with Syft.
- npm production dependency audits for the Cloudflare and administrator web
  projects.
- Cargo advisory review and dependency-tree reachability checks.
- Manual review of enrollment, magic links, resume secrets, second-device
  linking, recovery, revocation, administrator handoff, integration scopes,
  prekeys, mailbox delivery, history, attachments, media fallback, floor
  control, deep links, device key storage, request logging, ingress, workload
  privileges, secrets, and network policy.
- Cloudflare integration tests, Rust workspace tests, Android talk-client unit
  tests, and Swift/libsignal/media tests.

The server lockfile contains `rsa 0.9.10` through SQLx's optional MySQL support,
which is associated with RUSTSEC-2023-0071. PTT Talk builds SQLx with PostgreSQL
only; `cargo tree -i rsa` confirms that the crate is not in the active build
graph. Trivy reports no high or critical reachable vulnerability. The lockfile
also records a yanked `chacha20` version through an inactive optional dependency.
These entries must be rechecked whenever SQLx features or versions change.

## Residual requirements

- Complete the independent review in `docs/SECURITY_REVIEW_SCOPE.md` before a
  production-readiness claim.
- Repeat the full release and physical-device voice gates against signed mobile
  artifacts after any release build is cut from this commit.
- Continue monitoring dependency advisories, Cloudflare deployment settings,
  Apple/Google signing capabilities, K3s host controls, and backup encryption;
  those provider and host settings cannot be proven from source alone.
