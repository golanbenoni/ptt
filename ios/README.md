# iOS client

`TalkApp` is the production SwiftUI client for iOS 16 and later. It uses
Apple's Push to Talk framework on physical devices, native `AVAudioEngine`
capture/playback, Keychain-backed libsignal state, the shared Rust Opus/SFrame
engine, encrypted local history, two-device management, SOS, and authenticated
UDP with automatic TLS media fallback. The simulator uses the same voice and
crypto code without the unavailable system PTT channel manager.

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

`PttWire` retains the frozen cross-platform vectors. The `PttTalk` command-line
target and generated-tone helpers are protocol regression fixtures, not the
product experience.
