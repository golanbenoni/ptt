# PTT protocol v1 contract

This document is the compatibility boundary shared by Android, iOS, and the
self-hosted server. `proto/control.proto`, `proto/media.proto`, and the packed
media layout in `docs/WIRE.md` are frozen together.

## Compatibility

- Protocol major version is `1`. A different major version is rejected with
  `ERROR_CODE_UNSUPPORTED_VERSION`.
- Minor versions are additive. Receivers ignore unknown protobuf fields and
  unknown message variants.
- Field numbers are never reused. Deleted fields are reserved in the same PR.
- Unknown control data never grants a floor and never enables plaintext media.
- Crypto failures disable the affected transmission. There is no plaintext
  downgrade.

## Identity and devices

An account has one random 16-byte ACI and at most two active personal devices.
Each device has its own nonzero `device_id`, identity key, prekeys, mailbox,
access token, and push registrations. Fan-out addresses devices, not merely
accounts. Linking a new device does not re-wrap history created before the
device joined.

## Control and media

`ControlService.Connect` is a device-authenticated bidirectional HTTP/2 stream.
Inner control bodies remain Double Ratchet or Sender Key ciphertext. Floor
serialization and routing metadata are visible to the instance server.

Live media prefers raw UDP. A relay-authenticated binding pins a source tuple;
the relay fans out a 20-byte routing header plus RFC 9605 SFrame ciphertext.
Production v1 may tunnel the identical packed header and ciphertext through
`MediaFallbackService` when UDP is unavailable. The fallback does not decrypt
or re-encrypt media.

Each talk begins with a per-device encrypted media-epoch announcement. Encoding
version 2 adds a one-byte flags field after total-talk-time; bit 0 marks an SOS.
Version 1 announcements remain decodable with all flags clear. Unknown versions
or flag layouts fail closed.

Missed/history delivery stores only a second, independently authenticated
ciphertext wrapper around the already-SFrame-encrypted, fixed-size production
datagrams. The `PTTH` wrapper binds channel, talk, membership epoch, and media
key id as AES-256-GCM AAD. Media keys are delivered only through the existing
per-device encrypted mailbox, so newly linked or revoked devices cannot open
earlier history and object storage never receives plaintext audio or keys.

## Fixed limits

- Two active devices per account.
- 64 accounts per encrypted channel.
- 128 normal recipient devices per channel at the two-device limit.
- 256 connected relay listeners per channel.
- 1,501 fixed-size datagrams per history object (30 seconds at 20 ms).
- Prekey batch requests contain at most 128 device records.
- SSv2 chunks contain at most 100 recipients or 96 KiB.
