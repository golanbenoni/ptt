# iOS client

`TalkApp` is the 0.1.21 (24) private-beta SwiftUI client for iOS/iPadOS 16 and
later. It uses
Apple's Push to Talk framework on physical devices, native `AVAudioEngine`
capture/playback, Keychain-backed libsignal state, the shared Rust Opus/SFrame
engine, encrypted local history, two-device management, SOS, and authenticated
UDP with automatic TLS media fallback. The simulator uses the same voice and
crypto code without the unavailable system PTT channel manager.

The product UI also includes invitation enrollment, second-device linking,
administrator-approved recovery, Talk, Activity/History, encrypted channel chat
with resumable files/voice messages/video, message actions and receipts,
presence, safety numbers, device revocation, account deletion, and the
administrator-console handoff. See
[`../docs/CURRENT_STATE.md`](../docs/CURRENT_STATE.md) for proof still required
before a build is described as production-ready.

Build on a Mac with Xcode and the pinned libsignal v0.101.0 checkout:

```bash
export LIBSIGNAL_ROOT=/Users/you/src/libsignal
./scripts/build-libsignal-ios-sim.sh
./scripts/build-apple-native.sh
(cd ios/PttWire && swift test)
LIBSIGNAL_SWIFT=$LIBSIGNAL_ROOT/swift \
LIBSIGNAL_FFI=$LIBSIGNAL_ROOT/target/debug \
  swift test --package-path ios/PttTalk
xcodebuild -project ios/TalkApp/TalkApp.xcodeproj -scheme TalkApp \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ios/TalkApp/.derived CODE_SIGNING_ALLOWED=NO build
```

Install the latest simulator build with `ios/TalkApp/install-sim.sh`. Physical
device/TestFlight archives require the Apple team signing assets, the Push to
Talk entitlement, APNs PTT configuration, and a public HTTPS instance. Apple
permits one joined system PTT channel at a time and joining requires foreground
user interaction; secondary channels remain encrypted-history targets.

After Apple approves the managed Push to Talk capability for `app.ptt.talk`,
enable it on the App ID and create a fresh App Store provisioning profile. With
that profile and the distribution certificate installed, build a signed App
Store Connect IPA with:

```bash
./scripts/ios-release.sh
```

Set `PTT_IOS_PROFILE` if the approved profile has a different name. The script
refuses to archive when the selected profile lacks the Push to Talk entitlement.

The script archives, exports, verifies the embedded app signature and
entitlements, and writes an adjacent SHA-256 checksum. Upload the resulting IPA
through the release workflow only after the exact commit passes CI, physical
four-device voice/acoustic proof, production push readiness, and store
readiness. The target is explicitly unavailable on Apple-silicon Mac because
PushToTalk.framework is not a macOS framework.

`PttWire` retains the frozen cross-platform vectors. The `PttTalk` command-line
target and generated-tone helpers are protocol regression fixtures, not the
product experience.

## Production voice probe

`ProductionVoiceProbe` exercises two isolated automation devices through the
same libsignal, Sender Key, Opus, RFC 9605 SFrame, floor-control, mailbox, and
TLS-relay code used by the app. Build it after `build-apple-native.sh`, then run
`ProductionVoiceProbe identities` once to create fresh Keychain identities.
Register those public identities and two freshly generated device-token hashes
on a dedicated test account before invoking `ProductionVoiceProbe run` with:

```text
PTT_E2E_SERVER
PTT_E2E_ACI
PTT_E2E_CHANNEL_ID
PTT_E2E_SENDER_MAILBOX
PTT_E2E_SENDER_TOKEN
PTT_E2E_RECEIVER_MAILBOX
PTT_E2E_RECEIVER_TOKEN
```

The probe fails unless the receiver opens the encrypted media epoch, receives
the completed live transmission, and decodes a non-silent one-second audio
fixture. Never point it at a user account: the identity bootstrap intentionally
resets its two probe-only Keychain namespaces.
