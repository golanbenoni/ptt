# Simulator testing

The current Android and iOS apps are **device harnesses** for the encrypted
prekey, relay, and media path. They exchange a generated 440 Hz tone; they are
not yet the final microphone or push-to-talk product UI.

## SuperMac01 setup

Run these commands from `/Users/golanbenoni/src/ptt` on SuperMac01. Start the
test services in one terminal and leave them running:

```bash
PREKEY=8088 RELAY=47000 ./scripts/device-harness.sh
```

Build and install Android on a booted emulator:

```bash
source ./scripts/java21-env.sh
./gradlew --no-daemon :talkandroid:assembleDebug
adb install -r android/talk/build/outputs/apk/debug/talk-debug.apk
```

Build and install iOS on the booted iPhone 17 simulator:

```bash
./ios/TalkApp/install-sim.sh
```

Use these endpoints in the apps:

| Simulator | Prekey URL | Relay |
| --- | --- | --- |
| Android | `http://10.0.2.2:8088` | `10.0.2.2:47000` |
| iOS | `http://127.0.0.1:8088` | `127.0.0.1:47000` |

## Acceptance walkthrough

1. Tap **Listen continuously as Bob** on one simulator. Its endpoint fields and
   send button should disable, the listen button should change to **Stop
   listening**, and the log should say `listening as Bob...`.
2. Tap **Send tone as Alice** twice on the other simulator without touching the
   listener between sends. Each send should report `sent 20 encrypted frames`; the
   receiver should report `recv #1` and `recv #2`, each with 20 frames and
   non-zero energy, play both tones through its speaker, and rearm after each
   one. Android also writes `cache/bob.wav`. After each send, compare the
   **Encryption** section on both devices: talk ID, channel, key fingerprint,
   AAD fingerprint, wrapped-key size, demux, and frame count must match. The
   section intentionally displays a short key fingerprint rather than the raw
   media key.
3. Tap **Stop listening**, verify the log reports `listener stopped`, and repeat
   the two-tone test with the platforms' roles reversed.
4. Enter an invalid prekey URL and invalid relay value separately. Each action
   should append a readable error, stay open, and allow a successful retry after
   correcting the field.
5. On Android, rotate while listening and then send from iOS. Only one
   `listening as Bob...` entry should appear and the transfer should complete.
6. Check portrait, landscape, dark appearance, and the largest text setting.
   All controls and the scrollable log must remain reachable.

The listener timeout is 120 seconds. The harness does not yet promise sustained
background operation on physical devices; that belongs in the product session
service rather than this Activity/View test surface.

## Non-UI regression gates

```bash
source ./scripts/java21-env.sh
./gradlew --no-daemon compileKotlin :crypto:test :floor:test :media:test \
  :loopback:test :net:test :talkandroid:assembleDebug
./scripts/two-process.sh
cargo test --manifest-path native/Cargo.toml
(cd ios/PttWire && swift test)
(cd ios/PttTalk && swift build)
```

## Beta release builds

The Android upload keystore lives outside the repository and its password is
read from the macOS Keychain. On SuperMac01, build the signed App Bundle with:

```bash
./scripts/android-release.sh
```

The iOS project supports both simulator and physical-device destinations. Its
device archive links the release `aarch64-apple-ios` libsignal FFI archive and
uses Apple team `M2M4752Z6K` with automatic signing.
