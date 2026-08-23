# Control service

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
- `PTT_CONTROL_BIND` (optional, default `0.0.0.0:8080`)
- `PTT_SMTP_HOST`, `PTT_SMTP_PORT`, `PTT_SMTP_USERNAME`,
  `PTT_SMTP_PASSWORD`, and `PTT_SMTP_FROM` (optional as a group for local
  development, required by the supported production deployment)

Magic links are written to `email_outbox` and delivered by a retrying SMTP
worker over required STARTTLS. API responses do not reveal whether an
invitation or address exists, and delivery logs omit recipient addresses.
