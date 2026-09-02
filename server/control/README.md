# Control service

This README describes the Rust/K3s backend for PTT Talk 0.1.25 (28), protocol
1.1. It is the supported self-hosted data plane and implements the mobile,
administrator, delivery, and encrypted-media contract documented in
[`../../docs/CURRENT_STATE.md`](../../docs/CURRENT_STATE.md).

The Rust control service owns account enrollment, device mailboxes, prekeys,
channel ACLs, floor serialization, presence, and opaque control-envelope
delivery. It never receives SFrame keys or plaintext audio.

Required environment:

- `DATABASE_URL`
- `PTT_PUBLIC_BASE_URL`
- `PTT_BOOTSTRAP_TOKEN` (at least 32 characters; remove from operator access
  after the first administrator is enrolled)
- `PTT_REDIS_URL` (durable connection string for ephemeral floor state)
- `PTT_RELAY_SHARED_SECRET` (at least 32 characters and shared only with the
  UDP relay)
- `PTT_RELAY_PUBLIC_ADDRESS` (the host and UDP port returned to clients)
- `PTT_OBJECT_STORE_ENDPOINT`, `PTT_OBJECT_STORE_BUCKET`,
  `PTT_OBJECT_STORE_ACCESS_KEY`, and `PTT_OBJECT_STORE_SECRET_KEY` (S3-compatible
  ciphertext history storage; the supported chart configures MinIO)
- `PTT_FCM_SERVICE_ACCOUNT_JSON` (optional Firebase service-account JSON)
- `PTT_APNS_TEAM_ID` and `PTT_APNS_BUNDLE_ID`, plus separately restricted
  `PTT_APNS_PRODUCTION_KEY_ID`/`PTT_APNS_PRODUCTION_PRIVATE_KEY` and
  `PTT_APNS_SANDBOX_KEY_ID`/`PTT_APNS_SANDBOX_PRIVATE_KEY` pairs. Production
  and Debug registrations are dispatched to their matching APNs endpoints
  without changing live server configuration.
- `PTT_CONTROL_BIND` (optional, default `0.0.0.0:8080`)
- `PTT_GRPC_BIND` (optional, default `0.0.0.0:50051`)
- `PTT_SMTP_HOST`, `PTT_SMTP_PORT`, `PTT_SMTP_USERNAME`,
  `PTT_SMTP_PASSWORD`, and `PTT_SMTP_FROM` (optional as a group for local
  development, required by the supported production deployment)

Magic links are written to `email_outbox` and delivered by a retrying SMTP
worker over required STARTTLS. API responses do not reveal whether an
invitation or address exists, and delivery logs omit recipient addresses.

`GET /healthz` publishes the current product protocol version, minimum client
version, and capability set. Android and iOS validate it before sending
enrollment, authentication, or encrypted traffic and cache a successful result
for at most five minutes. Deploy this server advertisement before publishing a
client that requires a new capability.

If both devices are lost, `POST /v1/auth/recovery/request` sends a fresh
single-use email link without disclosing whether the account exists. Consuming
that link creates a 24-hour pending claim; a different active instance
administrator must approve it. Approval transactionally removes the old
two-device set and its prekeys, push registrations, mailboxes, links, and relay
leases, rotates every current channel membership epoch, and installs one new
independently keyed device. The claim token becomes that device's access token
only after approval, and its new link timestamp excludes all existing history.

## Administrator API

The current Rust service exposes summary, member/device lists, revocation,
invitations, channel configuration and membership, recovery decisions, audit,
and operations health under `/v1/admin/*`. An active administrator device can
create a two-minute, single-use `/v1/admin/session/start` handoff. The browser
consumes it once for a 15-minute memory-only token and revokes that token on
sign-out. Browser tokens authorize only administrator routes and never satisfy
device authentication.

## Streaming control protocol

The frozen `ControlService.Connect` bidirectional HTTP/2 stream accepts a
device-authenticated `ClientHello`, returns negotiated version and demux
material, then carries opaque device envelopes, presence, push registration,
and serialized floor messages. The frozen `PreKeyService` uploads and consumes
per-device signed, X25519, and Kyber material. Unsupported major versions,
forged device addresses, stale membership epochs, unauthorized priority, and
floor-token mismatches fail closed.

`MediaFallbackService.Tunnel` is available on the same HTTP/2 endpoint for
networks that block UDP. A bearer-authenticated device is subscribed to its
current channels. Each outbound frame must carry the device's current,
unexpired relay demux lease; malformed headers, unknown channels, removed
members, and forged demux values terminate the stream. The service broadcasts
the unchanged RFC 9605 ciphertext and never receives an SFrame key. Clients
still prefer UDP and may switch transports without a plaintext mode.

## Device mailbox delivery

Authenticated devices can fan out opaque, end-to-end encrypted control
envelopes without exposing their contents to the server:

- `POST /v1/mailbox/envelopes` accepts one client-generated `messageId`, up to
  128 unique recipient devices, base64url ciphertext envelopes, and an expiry
  no more than 30 days in the future. Repeating the same message and recipient
  is idempotent.
- `GET /v1/mailbox/items?limit=100` returns only the authenticated device's
  pending, unexpired envelopes. The limit may be between 1 and 256.
- `POST /v1/mailbox/ack` marks up to 256 returned `itemIds` as delivered. IDs
  outside the authenticated mailbox are ignored.

Cross-account delivery is allowed only when both accounts are active members
of at least one channel. Same-account delivery supports encrypted fan-out to a
second device. The server stores ciphertext only and never logs envelope data.

Devices register or remove FCM, APNs, and APNs Push to Talk tokens through
`POST`/`DELETE /v1/push/registrations`. Tokens are base64url-encoded, may belong
to only one device, and are never returned by the API. Each newly queued
mailbox message creates at most one wake-up outbox item per registered provider;
retries cannot duplicate the logical wake-up.

The delivery worker exchanges the Firebase service-account assertion for a
short-lived OAuth token and sends data-only FCM HTTP v1 messages. It caches an
ES256 APNs provider token for 50 minutes and sends normal background or
`pushtotalk` requests over HTTP/2 with the required topic, priority, and
expiration headers. Permanent provider rejection removes only the matching
registration; transient failures use bounded exponential retry.

## Encrypted history delivery

`POST /v1/history/objects` stores a bounded ciphertext blob plus authenticated
metadata in S3-compatible storage. Uploads require current talk permission and
the current membership epoch; reuse of a `talkId` with different ciphertext is
rejected. `GET /v1/history/objects?channelId=…` lists eligible metadata and
`GET /v1/history/objects/{objectId}` returns ciphertext after verifying its
stored SHA-256 digest.

History queries require active membership and exclude epochs from before the
account joined. They also exclude objects created before the requesting device
was linked, so a second device receives future transmissions only. The service
signs object-store requests with AWS Signature Version 4 and never exposes
storage credentials or URLs to clients.

## Encrypted chat attachment transport

The original authenticated `PUT /v1/chat/attachments/{attachmentId}` remains
available for compatible older clients. Current clients use a resumable flow:

- `POST /v1/chat/attachments/{attachmentId}/uploads` creates or rediscovers an
  upload and returns the verified part set.
- `PUT .../uploads/{uploadId}/parts/{partNumber}` stores one exact 1 MiB-or-less
  ciphertext part with its SHA-256.
- `POST .../uploads/{uploadId}/complete` verifies contiguous parts, exact total
  size, and the declared full-object SHA-256 before publishing it.
- `DELETE .../uploads/{uploadId}` cancels the upload and removes staged objects.

Upload state expires after 24 hours and maintenance deletes orphaned staged
objects. The attachment `GET` route supports authenticated byte ranges and
returns `Content-Range`, `Accept-Ranges: bytes`, and the whole-object digest.
Authorization is re-evaluated on every operation; neither Postgres nor object
storage receives attachment keys, filenames, MIME types, captions, or clear
file bytes.
