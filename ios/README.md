# iOS client

This tree is the **iOS half** of two-device PTT. It cannot be compiled on the Linux builder (no Xcode). On a Mac with Xcode + a local [libsignal](https://github.com/signalapp/libsignal) checkout at v0.101.0:

```bash
cd ios/PttWire && swift test          # AAD, bind/key packets, AES-GCM golden vector
cd ~/src/libsignal && ./swift/build_ffi.sh -d
export LIBSIGNAL_SWIFT=$HOME/src/libsignal/swift
export LIBSIGNAL_FFI=$HOME/src/libsignal/target/debug
cd ios/PttTalk && swift build
```

`PttWire` matches `docs/WIRE.md` (UUID layout, AAD, bind/key/frame packets, AES-GCM). `PttTalk` is the CLI Talk client (LibSignalClient PQXDH wrap of a 16-byte media key, UDP through the JVM relay).

```bash
# Bob (this Mac) listens; Alice is the JVM `net send` on Linux.
.build/debug/PttTalk recv \
  --prekey http://192.168.1.229:8088 \
  --relay 192.168.1.229:47000 \
  --out /tmp/ptt-bob.wav
```

Or from Linux: `./scripts/kotlin-swift-lan.sh`.

Device harness (not product Talk UI):

```bash
# Android debug APK (SuperMac01 Android SDK + API 35 emulator)
export ANDROID_HOME=$HOME/Library/Android/sdk JAVA_HOME=$(/usr/libexec/java_home -v 21)
./gradlew :talkandroid:assembleDebug
adb install -r android/talk/build/outputs/apk/debug/talkandroid-debug.apk
# Emulator NAT: host is 10.0.2.2 (run prekey+relay on the Mac)
adb shell am start -n app.ptt.talk/.TalkActivity \
  --es ptt_role bob --es ptt_prekey http://10.0.2.2:8088 --es ptt_relay 10.0.2.2:47000
```

iOS Simulator TalkApp (verified: Bob recv 20 frames, energy 65,185,344 vs Android emulator Alice):

```bash
# FFI: do NOT use swift/build_ffi.sh on iOS — it sets OPENSSL_SMALL and
# drops ring's p256_point_mul_base_vartime. Use:
./scripts/build-libsignal-ios-sim.sh
cd ios/TalkApp && ./install-sim.sh
xcrun simctl launch booted app.ptt.talk \
  --ptt-role bob --ptt-prekey http://127.0.0.1:8088 --ptt-relay 127.0.0.1:47000
```

When the relay is on SuperMac01, the Android emulator must use `10.0.2.2` (NAT) and the iOS sim uses `127.0.0.1`.

Fold7 / iPad on Tailscale: enable wireless debugging / USB, then sideload the same APK / iOS app. Default URLs are `192.168.1.229:8088` / `:47000` (`./scripts/device-harness.sh` on Linux).

Demo ACIs (must match Android):

- iOS (Bob): `bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb`
- Android (Alice): `aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa`
- Channel: `dddddddd-dddd-4ddd-8ddd-dddddddddddd`

Live mic / SwiftUI button is PR5/UI. This CLI is the two-OS crypto+wire proof.
