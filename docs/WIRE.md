# Wire protocol (two-device)

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
4. Send on one; the other writes/plays PCM. Live mic is AudioEngine (PR5), not required to prove the wire.

## What this repo verifies today

Linux cannot build/run iOS. Before handoff we verify **two OS processes**, same wire, same crypto, through the real relay — that is the phone architecture without UI.

Kotlin ↔ Swift on the LAN (Linux JVM Alice, macOS `PttTalk` Bob):

```bash
./scripts/kotlin-swift-lan.sh
```

That starts `prekey`/`relay` on `0.0.0.0`, SSHs to SuperMac01, runs `PttTalk recv`, then `net send`. Success is Bob writing a WAV with energy > 50_000.
