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
