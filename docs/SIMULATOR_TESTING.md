# Simulator and device testing

The Android and iOS apps are the production Talk clients. The generated-tone
tools remain protocol fixtures only and are not part of either product UI.

## Start an isolated test instance

The integration harness creates fresh Postgres, Redis, MinIO, control, gRPC,
UDP relay, and mock push services. Set a ready file to pause it after seed data
is installed:

```bash
PTT_INTEGRATION_READY_FILE=/tmp/ptt-ui-ready ./scripts/test-control-integration.sh
```

Run mobile tests while `/tmp/ptt-ui-ready` exists. Remove that file to resume
all assertions and clean up every temporary container and process.

## Android

On SuperMac01:

```bash
source ./scripts/java21-env.sh
./gradlew --no-daemon :talkandroid:lintDebug :talkandroid:assembleDebug
adb install -r android/talk/build/outputs/apk/debug/talkandroid-debug.apk
adb shell am start -n app.ptt.talk/.TalkActivity --es ptt_server http://10.0.2.2:8080
```

Debug builds may use loopback HTTP. Release builds require HTTPS. A physical
device must use the test host's reachable LAN/Tailscale address.

## iOS

Build libsignal and the native voice archive, then build/install the app:

```bash
./scripts/build-libsignal-ios-sim.sh
./scripts/build-apple-native.sh
cd ios/TalkApp && ./install-sim.sh
```

The iOS simulator uses `http://127.0.0.1:8080` for a local instance. Physical
iOS devices require HTTPS, valid signing, Push to Talk entitlement approval,
and APNs configuration.

## Production acceptance walkthrough

Use two independently enrolled accounts and, where required, two devices for
one account.

1. Enroll with an administrator invitation and a single-use email link. Verify
   the link cannot be consumed twice and the device appears in both mobile and
   admin device lists.
2. Link a second independently keyed device. Confirm it receives future voice
   but cannot see history created before its link time.
3. Join the same channel on two clients. Hold PTT repeatedly in both
   directions; every press must produce floor-grant/release feedback and live
   speech. Compare the encryption panel on sender and receiver.
4. Compete for the channel floor. Only the authenticated grant holder may send.
   A listen-only member must be unable to request a floor.
5. Send normal and silent SOS. Confirm visible recipient count, priority
   preemption, emergency labeling, and no unencrypted fallback.
6. Disable UDP on one client. Confirm the status reports authenticated TLS
   media fallback and speech continues. Restore UDP and verify a later session
   can bind again.
7. Lock each device, change Wi-Fi/cellular routes, interrupt audio with a call
   or route change, and repeat transmissions. On Android, verify the persistent
   notification, tile/widget/overlay, headset buttons, and tap-to-rearm after
   reboot. On iOS, verify foreground join, system PTT controls, lock-screen push
   wake, interruption, and restoration.
8. Transmit while a recipient is offline, reconnect it, and play the encrypted
   missed item from History. Confirm expired/over-quota history is pruned.
9. Revoke a client from another device or the admin console. Its next
   authenticated request must sign it out and erase local credentials and
   cryptographic state; it must not decrypt later traffic.
10. Exercise account recovery. Approval must come from a different instance
    administrator, old devices must be revoked, and affected channel epochs
    must rotate.
11. Generate a support report on each platform and confirm it contains no
    email, endpoint, raw account/device/mailbox/channel ID, token, key, audio,
    or message content.
12. Test portrait/landscape where supported, dark appearance, VoiceOver or
    TalkBack, largest text, Bluetooth/wired audio, force-stop, reboot, and an
    eight-hour screen-off receive soak on representative physical devices.

## Automated gates

```bash
./scripts/check-proto-contract.sh
./gradlew --no-daemon compileKotlin :crypto:test :floor:test :media:test \
  :loopback:test :net:test :hardware:test :crypto-persistence:lintDebug \
  :talkandroid:lintDebug :talkandroid:assembleDebug
./scripts/two-process.sh
cargo fmt --manifest-path native/Cargo.toml --all -- --check
cargo test --manifest-path native/Cargo.toml --locked
cargo fmt --manifest-path server/Cargo.toml --all -- --check
cargo test --manifest-path server/Cargo.toml --locked
./scripts/test-control-integration.sh
(cd ios/PttWire && swift test)
(cd ios/PttTalk && swift test)
npm run typecheck --prefix admin-web
npm run build --prefix admin-web
helm lint deploy/helm/ptt -f operator-values.yaml
```
