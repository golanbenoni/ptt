# push gateway

The production push worker is implemented in `server/control/src/push.rs`. It
supports APNs, APNs Push to Talk, and FCM Installation ID delivery with retry
and deduplication. Payloads contain only opaque wake/message identifiers: no
names, plaintext, encryption material, or audio. Android push never starts a
microphone foreground service without prior user arming.
