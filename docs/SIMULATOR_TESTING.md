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
adb reverse tcp:8080 tcp:8080
adb shell am start -n app.ptt.talk.debug/app.ptt.talk.TalkActivity \
  --es ptt_server http://127.0.0.1:8080
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

The App ID entitlement is a managed Apple capability. Production packaging must
pass `./scripts/ios-release.sh`; never remove the entitlement to work around a
profile that predates approval.

The simulator installer keeps Xcode's local ad-hoc signature enabled because
the product uses Keychain-backed credentials and libsignal state. An unsigned
simulator app cannot enroll. Debug-only launch arguments can select a local
server and consume a disposable test token without weakening a release build:

```bash
xcrun simctl launch booted app.ptt.talk --args \
  --ptt-server http://127.0.0.1:8080 --ptt-token "$ONE_TIME_TEST_TOKEN"
```

When a headless simulator has no host microphone route, iOS emits silent 20 ms
fixture frames. That simulator-only path exercises Opus, SFrame, relay,
history, and repeated floor transitions; device builds still require a real
microphone and fail closed when capture is unavailable.

## Black-box mobile flows

Install the open-source Maestro CLI and run the enrolled-client flows against
the intended emulator/simulator explicitly:

```bash
maestro test --udid emulator-5554 tests/e2e/android-voice-smoke.yaml
maestro test --udid "$IOS_SIMULATOR_UDID" tests/e2e/ios-voice-smoke.yaml
```

The flows expect two enrolled accounts in a shared `Simulator Team` channel.
They exercise presence, repeated PTT, SOS, local encrypted history, safety
numbers, encryption details, device limits, and privacy-redacted support UI.
The lifecycle helpers in `tests/e2e/` also cover screen-off receive, offline
history restoration, Wi-Fi rebinding, iOS simulator reboot restoration, and
Android's mandatory post-reboot rearm gesture.

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

### Automated Apple physical-device gate

The simulator gate is not evidence that an iPhone or iPad audio route reached
the speaker. A dedicated Debug build signed with the same Push to Talk and APNs
capabilities can run the encrypted product-client matrix on two attached Apple
devices. The automation identity uses a Debug-only Keychain namespace and does
not read or overwrite the enrolled production identity.

Install that build on two dedicated devices, keep both unlocked and trusted by
the build Mac, and provide their CoreDevice identifiers plus the existing E2E
credentials:

```bash
PTT_IOS_DEVICE_1=<coredevice-or-udid> \
PTT_IOS_DEVICE_2=<coredevice-or-udid> \
PTT_E2E_SERVER=https://ptttalk.app \
PTT_E2E_ACI=... \
PTT_E2E_SENDER_MAILBOX=... \
PTT_E2E_RECEIVER_MAILBOX=... \
PTT_E2E_SENDER_TOKEN=... \
PTT_E2E_RECEIVER_TOKEN=... \
PTT_E2E_SENDER_IDENTITY_FIXTURE=... \
PTT_E2E_RECEIVER_IDENTITY_FIXTURE=... \
./scripts/test-ios-two-physical-voice.sh
```

The gate sends in both directions through the production relay and checks text,
file, voice-note, video, thumbnail, reply, reaction, edit, delete, pin, star,
and receipt convergence. A received transmission counts only after
`AVAudioPlayerNode` reports `.dataPlayedBack`; receipt of non-silent decoded PCM
alone is not a pass.

Android has the equivalent dedicated-device gate. It installs only the
`.debug` application ID, provisions the E2E fixture into app-private storage,
and counts a receive only after `AudioTrack.playbackHeadPosition` advances past
the authenticated end frame. The encrypted text/file/voice-note/video mutation
and receipt matrix runs concurrently with repeated PTT:

```bash
PTT_ANDROID_DEVICE_1=<adb-serial> \
PTT_ANDROID_DEVICE_2=<adb-serial> \
PTT_E2E_SERVER=https://ptttalk.app \
PTT_E2E_ACI=... \
PTT_E2E_CHANNEL_ID=... \
PTT_E2E_SENDER_MAILBOX=... \
PTT_E2E_RECEIVER_MAILBOX=... \
PTT_E2E_SENDER_TOKEN=... \
PTT_E2E_RECEIVER_TOKEN=... \
PTT_E2E_SENDER_IDENTITY_FIXTURE=... \
PTT_E2E_RECEIVER_IDENTITY_FIXTURE=... \
./scripts/test-android-two-physical-voice.sh
```

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
