# Supabase integration decision

Status: proposed pilot, not a production dependency  
Reviewed: September 3, 2026

## Decision

Introduce Supabase first as an **optional public-project and collaboration data
service**, isolated from PTT Talk's cryptographic identity, authenticated floor,
and live media paths. Do not replace the Rust control/relay services, SFrame
media, device-key enrollment, or the supported K3s deployment with Supabase.

This preserves the product's self-hosted architecture and fail-closed security
model while letting the team evaluate managed Postgres, Auth, Storage, Realtime,
and Edge Functions in a reversible way.

## Best uses for PTT Talk

### Phase 1: public project operations

Create a separate Supabase project for non-sensitive website workflows:

- deployment-interest and beta-request forms;
- documentation feedback;
- public roadmap voting or release announcements;
- aggregate, opt-in website operations with no cross-site tracking.

Keep this database separate from any live PTT instance. Do not collect message
content, audio, attachments, cryptographic identifiers, device keys, push
tokens, or channel membership. Use a minimal schema, explicit consent copy,
retention limits, bot protection, rate limits, and Row Level Security (RLS) on
every exposed table.

### Phase 2: optional managed control-plane adapter

Prototype a backend adapter behind the existing repository interfaces:

- Supabase Postgres for accounts, invitations, devices, channels, memberships,
  prekey inventory metadata, and audit records;
- Supabase Storage's S3-compatible API for ciphertext-only mailbox, history, and
  attachment objects;
- Supabase Auth for the web administrator console and single-use email links;
- Edge Functions for short, idempotent invitation, webhook, and administrative
  orchestration;
- Realtime Presence for slow-changing online/availability state and Broadcast
  for chat notifications or typing indicators.

The adapter must remain optional. The canonical data model and migrations stay
portable PostgreSQL, object access stays behind the S3 interface, and the Helm
deployment continues to work without Supabase.

### Keep outside Supabase

- live Opus media, UDP/TLS media relay, packet fan-out, jitter, and playout;
- authenticated floor arbitration, priority/SOS preemption, and talk timers;
- SFrame counters, Sender Keys, PQXDH, Double Ratchet, device private keys, or
  plaintext content;
- APNs Push to Talk execution and mobile background audio lifecycle;
- high-frequency connection state that must not be subject to general Realtime
  plan limits, reconnect behavior, or fan-out billing.

Supabase Realtime is appropriate for chat and slow-changing presence, not the
latency-critical voice plane. PTT Talk's existing serialized floor coordinator
and encrypted relay remain authoritative.

## Identity boundary

Supabase Auth identity is not the PTT cryptographic identity. If Auth is used,
map its immutable user identifier to a PTT `Aci` in a server-controlled table.
The PTT service still issues and verifies device credentials and independently
keyed `DeviceId`/`MailboxId` records. A Supabase session alone must never enroll
a device, approve recovery, rotate channel keys, grant floor, or decrypt data.

For account recovery, retain the existing requirement for a fresh email proof
plus instance-administrator approval when no active device is available.

## Proposed pilot schema

Use a dedicated `community` schema rather than `public` where practical:

- `interest_requests(id, email, organization, use_case, consent_at, status,
  created_at, expires_at)`
- `documentation_feedback(id, page, category, body, created_at, status)`
- `release_subscriptions(id, email, confirmed_at, unsubscribed_at, created_at)`

Only a narrowly scoped server-side function may insert interest requests or
send confirmation mail. The browser receives a publishable key only. Secret or
legacy service-role keys remain server-side and are never embedded in the
website or mobile apps. Public `select`, `update`, and `delete` grants are
revoked; direct anonymous reads are not allowed.

If Phase 2 is approved, use a separate project (or a fully separate schema and
roles at minimum) and add portable migrations for `accounts`, `devices`,
`invitations`, `channels`, `memberships`, `prekeys`, and `audit_events`.

## Security and privacy controls

- Enable RLS and explicitly review both grants and policies for every exposed
  table and Storage bucket.
- Disable public Realtime channels; authorize private topics with user JWTs and
  RLS.
- Keep Supabase secret keys, S3 access keys, SMTP credentials, and push secrets
  in server-side secret storage only.
- Store ciphertext objects under opaque random names. Do not put email
  addresses, account IDs, channel names, filenames, captions, or message text in
  object paths or unencrypted metadata.
- Configure custom SMTP for production; the default Supabase mail service is
  only suitable for exploration and pre-authorized recipients.
- Add abuse throttling, email normalization, single-use tokens, short expiry,
  audit events, deletion jobs, and documented retention.
- Maintain off-platform logical backups and restore drills. Paid hosted projects
  provide daily backups; point-in-time recovery is a separate operational and
  cost decision.
- Redact Supabase request, function, and database logs using the same rules as
  the existing support-report pipeline.

## Delivery plan and gates

### Pilot A — public website

1. Choose a Supabase organization, region, plan, data-retention period, and
   custom SMTP provider.
2. Create an isolated project named for the public website, not the production
   PTT service.
3. Commit declarative SQL migrations, RLS tests, seed fixtures, and local CLI
   configuration under a future `supabase/` directory.
4. Add one server-side submission endpoint; do not call privileged APIs directly
   from static website JavaScript.
5. Test spam/rate limits, replay, duplicate submission, deletion, export,
   inaccessible rows, SMTP failure, and restore.

Gate: an anonymous visitor can submit only the documented fields, cannot read or
alter any row, secrets do not appear in the client bundle or logs, and expired
records are deleted on schedule.

### Pilot B — managed instance adapter

1. Define storage, database, auth, queue, and presence interfaces at the current
   Rust service boundary.
2. Implement Supabase-backed adapters without changing protocol 1.1 or mobile
   cryptography.
3. Run the full two-account/two-device, revocation, no-old-history, relay
   injection, recovery, backup/restore, and cross-platform suites against both
   K3s and Supabase variants.
4. Load-test Realtime only for its approved metadata/chat uses; test the existing
   voice relay independently at the release concurrency targets.

Gate: both backends pass the same security and interoperability contract, a
Supabase outage cannot cause plaintext or authorization downgrade, and an
operator can export data into the portable PostgreSQL/S3 model.

## Current account state

The signed-in Supabase account was inspected on September 3, 2026. It currently
contains no organization, no project, and no personal access token. No Supabase
resource, credential, database, or billing commitment was created during this
review.
