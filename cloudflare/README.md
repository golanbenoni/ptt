# PTT Talk on Cloudflare

This deployment preserves the mobile JSON API and end-to-end encrypted SFrame
media contract while replacing the K3s data plane with Cloudflare-managed
services:

- Workers serves the enrollment pages, API, and administrator console.
- D1 stores accounts, devices, invitations, prekeys, membership, and audit data.
- R2 stores encrypted history objects only.
- One hibernating Durable Object per channel serializes floor ownership and
  fans out fixed-size authenticated ciphertext media frames over WebSockets.
- Queues deliver invitation/recovery email and privacy-minimized APNs/FCM wake
  signals asynchronously, with separate dead-letter queues.
- An hourly maintenance trigger removes expired mailbox, relay, authentication,
  and encrypted R2 history records.

There is no plaintext media fallback. Cloudflare deployments return a
deliberately unsupported UDP endpoint so existing clients immediately select
their encrypted WebSocket/TLS path.

The optional `media-floor-control-v1` capability moves the latency-critical
floor request/response onto that already-open tunnel. The Durable Object still
revalidates the current device session, channel membership, role, epoch, and
relay lease in D1 on every press before serializing the floor. REST remains the
automatic client fallback.

`GET /healthz` publishes the current product protocol version, minimum client
version, and capability set. Android and iOS validate it before sending
enrollment, authentication, or encrypted traffic and cache a successful result
for at most five minutes. Deploy this server advertisement before publishing a
client that requires a new capability.

Chat attachments and encrypted previews are uploaded through resumable 1 MiB
ciphertext parts. D1 stores upload state and per-part digests; R2 stores only
opaque chunks and the completed opaque object. Repeating upload creation lets a
client recover the verified part list after process death. Completion checks
contiguity, exact size, and the full SHA-256 before publication. Cancellation
and hourly expiry cleanup delete staged chunks. Authenticated downloads support
byte ranges so mobile clients can resume an OS-protected ciphertext partial and
verify it before decryption.

## Local checks

```bash
npm install
npm run build:admin
npm run check
```

## Staging provisioning

Create the D1 database, R2 bucket, delivery queues, and dead-letter queues, replace
the generated D1 identifier in `wrangler.jsonc`, then apply migrations and set
the bootstrap secret:

```bash
npx wrangler d1 create ptt-talk-staging
npx wrangler r2 bucket create ptt-talk-history-staging
npx wrangler queues create ptt-talk-email-staging
npx wrangler queues create ptt-talk-email-staging-dlq
npx wrangler queues create ptt-talk-push-staging
npx wrangler queues create ptt-talk-push-staging-dlq
npx wrangler d1 migrations apply DB --env staging --remote
npx wrangler secret put BOOTSTRAP_TOKEN --env staging
npm run deploy:staging
```

Email sending is enabled only after the production domain is onboarded to
Cloudflare Email Service and `EMAIL_FROM` names a verified sender on that
domain. Until then, links remain pending and no secret link is written to logs.

Set push provider credentials as encrypted Worker secrets. FCM requires
`FCM_SERVICE_ACCOUNT_JSON`. APNs requires the complete
`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, and `APNS_PRIVATE_KEY` group;
`APNS_ENVIRONMENT` selects `production` or `sandbox`. Push payloads contain
only `kind=mailbox` and an opaque message UUID—never identity, channel, key, or
audio data.

## Administrator sign-in

The bootstrap secret is used only to enroll the first administrator and is not
an admin-console password. An enrolled administrator opens **Settings → Open
admin console** in the mobile app. The authenticated device creates a two-minute,
single-use handoff; the browser redeems it for a memory-only session that expires
after 15 minutes. The handoff and browser token are stored by the server only as
SHA-256 hashes, and browser sign-out revokes the active session.
