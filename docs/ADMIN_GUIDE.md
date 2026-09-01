# Administrator guide

PTT Talk is a single-tenant private-team system. The instance operator owns the
domain, hosting, SMTP, push credentials, storage, backups, and policy choices.
Enrolled administrators manage people, devices, channels, roles, retention,
recovery, and instance health.

## Bootstrap the first administrator

1. Deploy either the supported K3s chart or the Cloudflare implementation.
2. Configure HTTPS, SMTP, ciphertext object storage, and push providers.
3. Generate a unique bootstrap token of at least 32 random characters and keep
   it outside source control.
4. Use the bootstrap flow once to create the first administrator invitation.
5. Enroll that administrator on a device, then rotate/remove operator access to
   the bootstrap token. A populated instance never treats it as a console
   password.

Deployment-specific instructions:

- [`K3s/Helm runbook`](../deploy/helm/ptt/README.md)
- [`Cloudflare runbook`](../cloudflare/README.md)

## Open the administrator console

On an enrolled administrator device, choose **Settings → Open admin console**.
The app asks the server for a two-minute, single-use browser handoff. The browser
redeems it for a memory-only administrator session that expires after 15
minutes. Signing out revokes it.

This flow is implemented on Cloudflare. The Rust/K3s backend does not yet expose
the admin-session start/consume/revoke endpoints; treat that as a release blocker
for K3s rather than copying a permanent device token into a browser.

## Invite and manage members

- Create an invitation for the exact email address the member controls.
- Assign administrator status only when the member needs instance-wide recovery
  and policy authority.
- Invitation and magic-link APIs do not disclose whether an address exists.
- Do not place invitation links or tokens in tickets, logs, or chat messages.
- Review the member/device list after enrollment. Each account may have two
  active devices.

Revoking a device removes its server access and push registrations. On its next
authenticated request the app signs out and erases local credential and
cryptographic state. Revocation cannot recall content already decrypted on that
device.

## Create and manage channels

- Create a private or direct channel and choose retention from 1–365 days.
- Add members with the minimum role they need: listen, talk, or administrator.
- Membership changes rotate the membership epoch and Sender Key distribution
  identifier.
- A channel supports 64 accounts, up to 128 normal recipient devices, and 256
  connected relay listeners.
- iOS users can have one system-managed background live channel; secondary
  channels remain available for chat/history.

## Approve recovery

Recovery is for a member who has lost every active device. A fresh email link
creates a pending claim. Approval must come from a different active instance
administrator.

Before approving, verify the person outside the recovery email channel. Approval
revokes both prior devices, removes their prekeys/push/mailboxes/relay leases,
rotates every affected channel epoch, and installs one new device. The recovered
device receives future communications only.

## Configure delivery providers

### Email

Production enrollment requires SMTP with STARTTLS and a verified sender on the
instance domain. Monitor the delivery outbox and dead-letter/error state without
logging recipient addresses or secret links.

### Android push

Configure a Firebase Android application for `app.ptt.talk` and a separate Debug
application identity for physical automation. Store the service-account JSON
only on the server. Mobile builds receive public Firebase application values;
they never contain service-account credentials.

### Apple push

Use separate app-topic-restricted APNs keys for production and sandbox. Do not
reuse a key ID or private key across the two environments. Configure the team ID
and `app.ptt.talk` bundle ID. Release readiness requires both environments to
report configured without exposing credential material.

Push payloads carry only an opaque kind and message identifier. Email, account,
channel, keys, message content, and audio are fetched through the authenticated
encrypted service.

## Monitor and operate

- `/healthz` is public compatibility/readiness information; `/readyz` is the
  service readiness probe.
- K3s metrics are cluster-only and require the configured bearer token. They use
  aggregate labels only.
- Review pending/failed push delivery, database pressure, relay capacity, backup
  age, recovery approvals, device revocations, and recent audit events.
- Preserve request IDs for troubleshooting; do not add raw account, device,
  channel, token, key, message, or audio values to logs.
- Apply rate limits at ingress and in authentication/recovery flows.

## Back up, restore, and upgrade

K3s backups must pair a consistent PostgreSQL dump with the matching ciphertext
object snapshot on an operator-confirmed encrypted storage class. Redis
floor/presence state is ephemeral. Cloudflare deployments export D1 and verify
the SQL against a disposable SQLite database; R2 ciphertext objects require a
coordinated retention/backup policy.

Before any upgrade:

1. Take and verify a backup.
2. Render and inspect configuration changes.
3. Verify migrations against a disposable restore.
4. Roll out with health checks and retain the previous signed images.
5. Exercise administrator login, device lists, a channel floor, chat delivery,
   an attachment, and encrypted history after the upgrade.

Never automate a destructive production restore without an explicitly selected
instance and timestamp.

## Store and privacy responsibilities

The repository's current answers are in
[`store/metadata/PRIVACY_DISCLOSURES.md`](../store/metadata/PRIVACY_DISCLOSURES.md).
They assume no advertising, analytics, tracking, compliance recording, public
directory, or vendor reuse of customer data. An operator who adds a vendor or
new data practice must update the public policy and both store disclosures
before distributing that build.

Do not call a build production-ready until the exact commit passes the physical
four-device matrix, external acoustic proof, Android eight-hour screen-off soak,
push readiness, backup/restore exercise, and independent security review listed
in [`CURRENT_STATE.md`](CURRENT_STATE.md).
