# Encrypted broadband PTT

AGPLv3. Android-first walkie-talkie: live Opus PTT, Signal-grade E2EE, one session process.

Design: [`research/DESIGN-encrypted-ptt.md`](research/DESIGN-encrypted-ptt.md). Competitive notes: [`research/COMPETITIVE_ANALYSIS.md`](research/COMPETITIVE_ANALYSIS.md).

## Now (PR0 + PR1)

- Multi-module Gradle (Kotlin/JVM placeholders; Android AGP lands with the session/UI PRs).
- `:crypto` — `InMemoryCryptoStack` on libsignal **0.101.0** (`org.signal:libsignal-client` from Signal’s Maven).
- Native Rust stubs (`sframe-ptt`, `audio-engine`) for PR4.
- Server directory stubs.

## Build

JDK 21. Tests need libsignal’s JNI:

- **linux amd64 / mac:** the published jar already contains the `.so` / `.dylib`.
- **linux aarch64:** `scripts/build-libsignal-jni.sh` (copies `native/jni/libsignal_jni.so`).

```bash
./gradlew :crypto:test :floor:test :media:test :loopback:test
./gradlew :loopback:run
```

```bash
./gradlew :crypto:test :loopback:test :net:test
./gradlew :loopback:run              # in-process 1:1
./gradlew :loopback:channelLoopback  # 3-person channel; kick Carol
./scripts/two-process.sh             # two OS processes + HTTP prekey + UDP relay
./scripts/kotlin-swift-lan.sh        # Linux JVM Alice <-> SuperMac01 Swift Bob
```

Two-device (Android + iOS) uses the same wire as `two-process.sh`. See `docs/WIRE.md` and `ios/README.md`. This Linux builder cannot run Xcode; two processes through the real relay is the check before phones.

`:loopback:run` is a 2-second 1:1 PTT: Alice holds the floor, PQXDH-wraps a media key, sends 440 Hz PCM frames over UDP `127.0.0.1:47111` with AES-GCM, Bob decrypts, writes `tools/loopback/build/ptt-loopback.wav`, and plays it with `aplay` if present.

`:loopback:channelLoopback` is PR2: Alice, Bob, Carol share sender keys; Alice’s TalkStart is heard by both; after Carol is kicked she cannot decrypt the next TX.

`CryptoStack.PQXDH_INFO` is frozen as `PTT-PQXDH-v1`. Session setup uses libsignal’s built-in PQXDH (X25519 + ML-KEM-1024 in the prekey bundle).

## License

GNU Affero General Public License v3.0. Linking libsignal requires the whole networked app and servers to be AGPL (KD-1).
