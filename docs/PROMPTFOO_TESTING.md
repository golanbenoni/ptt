# Promptfoo test orchestration

PTT Talk uses Promptfoo as the top-level campaign runner and evidence formatter.
Native deterministic tools remain authoritative for cryptography, mobile
lifecycle, real audio, infrastructure recovery, authorization, and performance.
Promptfoo selects an allowlisted lane, runs its native tool, and records a
redacted, hashed result tied to the Git commit and workspace state.

This architecture prevents a model-generated score from being mistaken for
proof that a security boundary, speaker, device lifecycle, or backup worked.

## Campaigns

| Profile | Coverage | Normal cadence |
| --- | --- | --- |
| `pr` | Protocol, immutable dependency pins, documentation, store metadata, acoustic/latency analyzer self-tests, Firebase fixtures, and D1 restore fixtures | Every pull request and `main` push |
| `nightly` | PR lanes plus Rust tests/strict static analysis, Swift, Android tests/lint, admin browser journeys, Cloudflare, all-route accounting, live control integration, security/SBOM/misconfiguration, and Helm | Daily |
| `adversarial` | Rust, Cloudflare, and live service misuse, malformed-input, replay, authorization, and isolation regressions | Daily |
| `weekly` | Disposable K3s lifecycle, Android/iOS accessibility matrices, and production-site responsive/accessibility/link/header/no-analytics audit | Weekly |
| `browser` | Rendered production product, deployment, and privacy pages | Weekly |
| `release` | Clean checkout, four-device acoustic parity, restoration, eight-hour Android screen-off soak, version/store/push readiness | Before internal distribution |
| `release-aggregate` | Exact-commit CI, production voice, physical, soak, version, store, and push evidence | After physical and soak workflows pass |

Run a profile from the repository root:

```sh
./scripts/run-promptfoo-suite.sh pr
./scripts/run-promptfoo-suite.sh nightly
./scripts/run-promptfoo-suite.sh adversarial
./scripts/run-promptfoo-suite.sh weekly
./scripts/run-promptfoo-suite.sh browser
./scripts/run-promptfoo-suite.sh release
./scripts/run-promptfoo-suite.sh release-aggregate
```

Promptfoo is pinned in `qa/promptfoo/package-lock.json`. Browser testing pins
Playwright and installs the matching Chromium build explicitly. Evidence is
written to `artifacts/promptfoo/<commit>/<profile>/` and is intentionally not
committed.

## Evidence contract

Each deterministic lane reports:

- schema version and stable lane name;
- pass/fail status and process exit code;
- elapsed milliseconds;
- full Git commit;
- clean/dirty workspace state and a workspace evidence hash;
- a bounded, redacted diagnostic summary; and
- a SHA-256 evidence hash.

Release evidence requires a clean checkout. Development runs may use a dirty
tree, but the evidence says so and hashes its state. Test output is stripped of
email addresses, bearer values, secret-like assignments, private-key labels,
and long hexadecimal material before Promptfoo stores it.

## Route accounting

`scripts/verify-api-route-coverage.mjs` derives the Rust service's registered
v1 routes and fails unless each route path appears in executable tests and the
Cloudflare service implementation. It currently accounts for 64 v1 route
paths, including regex-defined attachment, history, and channel-device routes.

Route accounting is a guard against accidental omission; the Rust and
Cloudflare suites remain responsible for behavior. Authentication routes also
have explicit indistinguishable-response and rate-limit tests. Live integration
uses disposable Postgres, Redis, object storage, relays, and push mocks.

## Requested capability map

| Requested area | Deterministic authority used by Promptfoo | Hardware or external remainder |
| --- | --- | --- |
| Source, dependencies, secrets, SBOM, supply chain | Strict Rust Clippy, Android lint, TypeScript checks, Trivy vulnerability/secret/container/Helm/Kubernetes scans, Syft CycloneDX, immutable npm and Action pin verification | Independent penetration and cryptography reviews remain external |
| Rust and Cloudflare APIs | Rust unit/live integration and Cloudflare Vitest suites plus 64-route accounting | Deployed media probe requires protected staging credentials |
| Invitations, enrollment, linking, recovery, revocation, deletion | Cloudflare and live Postgres/Redis/object-store integration regressions plus Android/iOS onboarding UI routes | Physical deep-link and process-restoration proof is a release lane |
| Admin browser and roles | Playwright approval/invite/recovery/channel-role/revocation/sign-out journey plus live backend authorization tests | None for browser behavior |
| PQXDH, ratchets, Sender Keys, SFrame, counters, epochs, history | Kotlin, Swift, Rust vectors, persistence, tamper, replay, and removed-member regressions | Physical restart/revocation is a release lane |
| Text collaboration | Cross-platform codecs, mutation/reply/reaction/receipt/pin/search/mention/offline synchronization tests | Four-device release journey repeats the encrypted chat matrix |
| Attachments, voice notes, video | Cross-platform encrypted file/voice/video/thumbnail codecs and archive tests; single and multipart upload, resume, range, corruption, cancellation, and authorization integration tests | Physical media picker and playback behavior is a release journey |
| Floor and SOS | Kotlin controller, hardware-router, Cloudflare coordinator, Rust service, contention, preemption, timeout, and live relay tests | Physical controls and audible priority behavior are release lanes |
| UDP and TLS media | Kotlin/Swift/Rust datagram, replay, tamper, jitter/PLC, heartbeat/fallback, 256-client UDP and 256-socket TLS capacity tests | Network transition and real speaker proof are release lanes |
| Mobile UI and lifecycle | Android/iOS light/dark/large-text accessibility, simulator launch/audio graph, and lifecycle state regressions | Lock screen, process death, reboot, route changes, interruptions, and eight-hour soak require devices |
| K3s | Disposable install, migration, backup, destructive restore, upgrade, rollback, node restart, health, network policy, and relay load | Operator disaster-recovery drill and storage exhaustion on the chosen installation remain external |
| Cloudflare | Worker/D1/R2/Queue/Durable Object/WebSocket tests, D1 restore fixture, capacity, push separation, and dry deploy | Production configuration is probed with protected credentials |
| Public website | Production Chromium content plus 390/768/1440 responsive, accessible-name, assets, all links/downloads, headers, and no-analytics audit | Visual editorial review remains human judgment |
| Performance and release provenance | Latency assertions, capacity tests, log redaction, push fixtures, synchronized version/store metadata, clean-tree hashes, exact-commit workflow aggregation | Signed-store provenance and installability are closed only after physical/soak gates |

## Adversarial policy

`qa/promptfoo/policies/ptt-security.yaml` defines synthetic attacks covering
credential substitution, cross-account access, invitation replay, third-device
enrollment, recovery bypass, removed-member access, forged floor grants,
counter rollback, media injection, WebSocket credential reuse, attachment-part
substitution, administrator escalation, metadata leakage, deletion bypass, and
bounded resource exhaustion.

Generated attacks are exploratory. A generated case becomes a release gate
only after it is reviewed and converted into a deterministic regression with
an exact expected state and response.

## Privacy and remote processing

The launcher disables Promptfoo telemetry and remote red-team generation.
Synthetic identities and disposable infrastructure are mandatory. Production
credentials, keys, account identifiers, email addresses, messages, attachments,
and recordings must never be placed in configurations or reports. Promptfoo
Code Scanning must not be connected to a remote service until the source-code
data-processing terms and destination are explicitly approved; local CodeQL,
Trivy, dependency, secret, and SBOM gates remain active meanwhile.

## Non-negotiable release proof

Promptfoo cannot turn a simulator callback into acoustic proof. Internal release
still requires two Apple and two Android devices, twenty repeated transmissions
in every same-platform and cross-platform direction, an independent external
microphone, floor p95 below 150 ms, mouth-to-ear p95 below 400 ms, lifecycle and
route-change coverage, and the full eight-hour Android receive soak.

Unavailable devices or credentials fail the requested release lane. They are
not represented as skipped or passed.
