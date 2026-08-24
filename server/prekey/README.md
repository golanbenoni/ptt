# prekey service

The production prekey API is implemented by `ptt-control`: authenticated
per-device signed bundle upload, X25519/Kyber one-time prekey batching,
single-consumption, and key-ID reuse rejection. The frozen HTTP/2 service is
also exposed through the control gRPC listener.
