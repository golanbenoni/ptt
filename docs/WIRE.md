# Wire protocols

## Production protocol v1

The production contract is frozen in `proto/control.proto`,
`proto/media.proto`, and `docs/PROTOCOL_V1.md`. Control uses a
device-authenticated bidirectional HTTP/2 stream. Inner messages are Signal
Double Ratchet or Sender Key ciphertext. Media uses RFC 9605 SFrame before it
reaches either UDP or the TLS fallback.

### Authenticated Sender Key mailbox envelope

New production clients fan out a `PTTG` envelope. Multi-byte lengths are
unsigned big-endian. The `distribution_id` is returned with the channel and is
rotated whenever membership changes.

| Offset | Size | Field |
|---|---:|---|
| 0 | 4 | magic `PTTG` |
| 4 | 1 | version (`1`) |
| 5 | 16 | sender ACI UUID |
| 21 | 1 | sender device ID (`1` or `2`) |
| 22 | 16 | channel `distribution_id` UUID |
| 38 | 4 | authenticated key-envelope length |
| 42 | variable | pairwise `PTTE` envelope containing `PTTK` |
| variable | remainder | serialized libsignal Sender Key ciphertext |

The pairwise plaintext is `PTTK || version(1) || distribution_id(16) ||
skdm_length(u32) || serialized_skdm`. The receiver first authenticates and
decrypts `PTTE`, verifies its sender and distribution ID match the outer
envelope and current channel, processes the SKDM, then verifies/decrypts the
signed group ciphertext. Any mismatch fails closed. `PTTE` containing `PTTM`
remains receive-only compatible with the first v1 internal builds.

The production UDP datagram is padded to 160 bytes and begins with this packed
20-byte routing header:

| Offset | Size | Field |
|---|---:|---|
| 0 | 1 | version (`1`) |
| 1 | 1 | flags (`FEC`, `START`, `END`, `HMAC8`) |
| 2 | 4 | `sender_demux`, unsigned big-endian |
| 6 | 4 | sequence, unsigned big-endian |
| 10 | 4 | RTP timestamp in 48 kHz units |
| 14 | 2 | payload type (`0` = SFrame Opus 20 ms) |
| 16 | 4 | first four bytes of `talk_id` |
| 20 | variable | RFC 9605 SFrame ciphertext |
| final 8 | optional | truncated relay-auth HMAC when `HMAC8` is set |

SFrame AAD is exactly 36 bytes: `channel_id` (16) || `talk_id` (16) ||
`sender_demux` (4, unsigned big-endian). A relay accepts media only from a
tuple authenticated with its short-lived, HMAC-signed binding ticket. The
control service returns the ticket and a 32-byte `demux_token`; the client
sends `PTTB || ticket` and requires a `PTTA || sender_demux` acknowledgement.
Every production datagram sets `HMAC8` and authenticates all bytes except the
final eight with the `demux_token`. Network rebinding replaces the old source
tuple for that device. The token is routing authentication and is never an
SFrame key.

### Encrypted history object

History uses a deterministic binary envelope around a sequence of complete
160-byte production datagrams. Multi-byte integers are unsigned big-endian.

| Offset | Size | Field |
|---|---:|---|
| 0 | 4 | magic `PTTH` |
| 4 | 1 | version (`1`) |
| 5 | 12 | random AES-GCM nonce |
| 17 | variable | ciphertext and 16-byte GCM tag |

The plaintext is `frame_count` (u32) followed by exactly that many 160-byte
datagrams. `frame_count` is 1–1,501. AES-256-GCM uses a key derived from the
32-byte media base key with HKDF-SHA256 (`salt = channel_id || talk_id`,
`info = "PTT-HISTORY-V1" || membership_epoch || media_kid`). Its AAD is
`"PTT-HISTORY-AAD-V1" || channel_id || talk_id || membership_epoch || media_kid`.
Readers reject trailing data, altered metadata, invalid frame lengths, and GCM
failures before handing any packet to the media pipeline.

Run `scripts/check-proto-contract.sh` before changing either protobuf. A
descriptor hash change requires compatibility review and new Kotlin/Swift/Rust
golden vectors.

## Legacy encrypted-tone harness

The following compact protocol remains only as a deterministic Android/iOS/JVM
interoperability fixture. Product clients must not use it for real voice.

Android, iOS, and the JVM `talk` CLI speak this. The relay never sees media keys.

## Prekey HTTP (`:8088` default)

JSON, UTF-8, `Content-Type: application/json`. Byte fields are **standard Base64**.

### `PUT /v1/prekeys/{aci}`

Upload/replace this device’s bundle. Body = `PreKeyBundle` JSON.

### `GET /v1/prekeys/{aci}`

`200` + bundle, or `404`.

### `PreKeyBundle` JSON

```json
{
  "aci": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "deviceId": 1,
  "registrationId": 1234,
  "identityKey": "<b64, 33 bytes DJB>",
  "signedPreKeyId": 1,
  "signedPreKey": "<b64>",
  "signedPreKeySig": "<b64>",
  "preKeyId": 2,
  "preKey": "<b64 or omit>",
  "kyberPreKeyId": 1,
  "kyberPreKey": "<b64 ML-KEM-1024>",
  "kyberPreKeySig": "<b64>"
}
```

One-time prekeys are consumed **on GET** (server drops `preKeyId`/`preKey` after a successful fetch) so two devices do not share an OTPK.

## UDP relay (`:47000` default)

No encryption at the relay. Bind pins the 5-tuple.

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | type |
| 1 | 16 | `channel_id` UUID big-endian |
| 17 | … | type-specific |

Types:

| type | Rest |
|---|---|
| `0xB1` bind | `aci` UUID (16) |
| `0x4B` key | `talk_id` UUID (16) + `sender_demux` u32 BE + `frame_count` u32 BE + PQXDH-wrapped AES-128 key |
| `0xF1` frame | `talk_id` UUID (16) + `sender_demux` u32 BE + AES-GCM packet (`counter u64 BE \|\| ciphertext+tag`) |

AES-GCM AAD is 36 bytes: `channel_id` (16) \|\| `talk_id` (16) \|\| `sender_demux` u32 BE. Nonce is 12 bytes: `4 zero \|\| counter u64 BE`.

On `0xB1` the relay remembers `src 5-tuple` for `(channel, aci)`. On `0x4B`/`0xF1` it copies the datagram to every **other** bound tuple on that channel.

## Two-device run (phones)

```bash
./gradlew :net:installDist
export JAVA_OPTS="-Djava.library.path=$PWD/native/jni"
# LAN: --bind 0.0.0.0 so phones can connect
./tools/net/build/install/net/bin/net prekey --bind 0.0.0.0 --port 8088
./tools/net/build/install/net/bin/net relay --bind 0.0.0.0 --port 47000
```

1. Host both services on a machine the phones can reach (LAN IP or Cloudflare tunnel).
2. Android Talk: ACI `aaaaaaaa-…`, peer `bbbbbbbb-…`, `--prekey http://HOST:8088 --relay HOST:47000`.
3. iOS Talk: ACI `bbbbbbbb-…`, peer `aaaaaaaa-…`, same host.
4. Send on one; the other writes/plays PCM. This generated-tone flow is a
   frozen wire fixture; the product clients use their platform microphone and
   shared Opus/SFrame engine.

## What the harness verifies

Linux cannot build/run iOS. Before handoff we verify **two OS processes**, same wire, same crypto, through the real relay — that is the phone architecture without UI.

Kotlin ↔ Swift on the LAN (Linux JVM Alice, macOS `PttTalk` Bob):

```bash
./scripts/kotlin-swift-lan.sh
```

That starts `prekey`/`relay` on `0.0.0.0`, SSHs to SuperMac01, runs `PttTalk recv`, then `net send`. Success is Bob writing a WAV with energy > 50_000.
