# Push gateway

The production push worker is implemented in `server/control/src/push.rs`. It
supports APNs, APNs Push to Talk, and FCM Installation ID delivery with retry
and deduplication. Payloads contain only opaque wake/message identifiers: no
names, plaintext, encryption material, or audio. Android push never starts a
microphone foreground service without prior user arming.

The worker is part of `ptt-control`, not a separate deployment. Release
readiness requires independent APNs production/sandbox credentials and a
configured FCM service account; source support alone is not a delivery proof.
See [`../../docs/ADMIN_GUIDE.md`](../../docs/ADMIN_GUIDE.md).
