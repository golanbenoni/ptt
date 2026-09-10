# Public encrypted-call media node

This directory deploys the Cloudflare control plane's dedicated LiveKit media
node. It keeps LiveKit pinned to `1.13.6`, provides external authenticated
Coturn paths for UDP and TLS fallback, exposes signaling through TLS, and keeps
Prometheus metrics behind a bearer token.

The node requires these DNS-only records before installation:

- `calls.<domain>` A/AAAA to the media node
- `turn.<domain>` A/AAAA to the same media node

The firewall must allow TCP 80, 443, 7881, and 5349 plus UDP 3478, 7882, and
50000–50100. Restrict TCP 22 to the operator's administration address.

Copy this directory to an Ubuntu 24.04 ARM64 or AMD64 host, then run
`install.sh` as root with all required environment variables. Set
`ADMIN_CIDR` to the operator's specific IPv4 administration range; do not use a
world-open range. Credentials must
be generated independently and passed through a protected operator session;
never commit them or place them in shell history. The installer obtains a
Let's Encrypt certificate without registering an email address, renders
root-readable runtime configuration, enables the host firewall, disables
request/TURN logs that could retain tokens or client addresses, and starts the
four pinned containers.

After installation, configure the Cloudflare Worker binding `LIVEKIT_URL` and
secrets `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET`, then validate the public
deployment with `scripts/validate-calls-deployment.sh`. The Rust/K3s control
service uses the equivalent `PTT_LIVEKIT_*` environment names. The production release
workflow additionally needs its documented GitHub variables and secrets for
the 256-participant and CPU evidence gates.
