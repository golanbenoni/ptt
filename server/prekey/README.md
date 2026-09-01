# Prekey service

The production prekey API is implemented by `ptt-control`: authenticated
per-device signed bundle upload, X25519/Kyber one-time prekey batching,
single-consumption, and key-ID reuse rejection. The frozen HTTP/2 service is
also exposed through the control gRPC listener.

This component is part of protocol 1.1 and is not a separately deployed service
in the current K3s chart. See [`../control/README.md`](../control/README.md) for
configuration and [`../../docs/PROTOCOL_V1.md`](../../docs/PROTOCOL_V1.md) for
the compatibility contract.
