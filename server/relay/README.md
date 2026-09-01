# Media relay

`ptt-relay` is the production ciphertext-only UDP fan-out service. It validates
short-lived authenticated binding tickets, pins each sender demux to its source
tuple, supports authenticated rebinding and teardown, rejects injection, and
caps a channel at 256 listeners. It never receives or decrypts SFrame keys.

Clients prefer this relay on K3s and automatically use the control service's
encrypted WebSocket/TLS tunnel when UDP is unavailable. Cloudflare deployments
use the TLS path immediately. Neither transport offers a plaintext fallback.

`scripts/test-control-integration.sh` includes a live capacity gate against the
real UDP process and Redis floor state. It binds 256 independent UDP clients to
one channel, delivers one authenticated media frame to all 255 recipients, and
proves that listener 257 is rejected. This complements the Cloudflare Durable
Object capacity test for the encrypted TLS path.
