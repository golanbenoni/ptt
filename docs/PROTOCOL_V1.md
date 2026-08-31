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

Each talk begins with a `PTTG` sender-key envelope. It contains one signed
Sender Key ciphertext plus, for every destination device, a PQXDH/Double
Ratchet-authenticated Sender Key distribution message. The envelope binds the
sender ACI/device and the channel's server-issued `distribution_id`; receivers
reject an ID from a stale membership epoch before installing the key. A
membership change rotates both the membership epoch and distribution ID. The
legacy `PTTE` per-device announcement remains decodable during the v1 rollout,
but new clients send `PTTG` only.

The inner media-epoch encoding version 2 adds a one-byte flags field after
total-talk-time; bit 0 marks an SOS. Version 1 announcements remain decodable
with all flags clear. Unknown versions or flag layouts fail closed.

Missed/history delivery stores only a second, independently authenticated
ciphertext wrapper around the already-SFrame-encrypted, fixed-size production
datagrams. The `PTTH` wrapper binds channel, talk, membership epoch, and media
key id as AES-256-GCM AAD. Media keys are delivered only through the existing
per-device encrypted mailbox, so newly linked or revoked devices cannot open
earlier history and object storage never receives plaintext audio or keys.

Channel chat uses a queue separate from media-key mailboxes so an older client
cannot interpret chat as a Sender Key update. Each `PTTC` message is encrypted
independently to every eligible device with the existing PQXDH/Double Ratchet
`PTTE` envelope. Text, file names, MIME types, captions, attachment keys, and
digests are visible only after device-side decryption. File, voice-note, and
video bytes use the `PTTA` AES-256-GCM container described in `docs/WIRE.md`;
object storage receives ciphertext only. A newly linked device is ineligible
for attachments created before its `linked_at` time and chat is never
historically re-wrapped.

Voice-message waveform samples use the backward-readable `PTTC` version 2
attachment metadata layout. They are generated on the sender, limited to 64
bytes, and remain inside each recipient's pairwise-encrypted envelope. Version
1 attachment records and local archives decode with an empty waveform.

## Fixed limits

- Two active devices per account.
- 64 accounts per encrypted channel.
- 128 normal recipient devices per channel at the two-device limit.
- 256 connected relay listeners per channel.
- 1,501 fixed-size datagrams per history object (30 seconds at 20 ms).
- Prekey batch requests contain at most 128 device records.
- SSv2 chunks contain at most 100 recipients or 96 KiB.
- Chat text is at most 4,096 UTF-8 bytes.
- Chat attachments are at most 25 MiB plaintext and 10 minutes duration.
