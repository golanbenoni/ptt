# Mobile black-box flows

These flows target the 0.1.28 (31) private-beta UI. They are one layer of the
release proof described in [`../../docs/CURRENT_STATE.md`](../../docs/CURRENT_STATE.md),
not a substitute for physical acoustic, push-wake, lifecycle, or soak testing.

These Maestro flows drive the actual Android and iOS product UIs. They do not
contain credentials and intentionally do not clear app state.

Prerequisites:

- a running Android emulator or iOS simulator with the current app installed;
- two independently enrolled accounts assigned `talk` in a channel named
  `Simulator Team`;
- both clients connected long enough to publish their independent prekeys;
- microphone permission granted (a headless iOS simulator may use the
  simulator-only silent-frame fixture).

Always pass `--udid`; running without it can select the wrong local device.
See `docs/SIMULATOR_TESTING.md` for enrollment and backend setup.

The primary journeys are `android-voice-smoke.yaml` and
`ios-voice-smoke.yaml`. Separate accessibility automation also validates the
manual invitation, second-device, and recovery routes in light/dark appearance
and standard/maximum text sizes. The smaller transmit/receive flows support lifecycle
tests without repeating the full journey. After rebooting Android, run
`android-rearm-after-reboot.yaml` to prove that microphone-capable background
work requires a fresh user gesture. `android-live-session-transmit.yaml`
verifies an already armed session after a network transition.

## Voice release gate

UI automation is not evidence that audio worked. The internal beta must pass
layers 1–4 before distribution; layer 5 uses the signed internal builds and is
mandatory before general-production promotion:

1. `VoiceMediaPipelineTests` injects a continuous non-silent PCM tone and fails
   unless Opus → SFrame → datagram → SFrame → Opus produces audible decoded
   energy. Packet counts alone are intentionally insufficient.
2. The Cloudflare integration suite provisions two independently authenticated
   devices, grants one device the floor, and verifies authenticated binary media
   is delivered byte-for-byte to the other device.
3. The deployed-media probe repeats the two-device relay test against the exact
   staging or production Worker under test. Tokens must be supplied through the
   environment and are never printed or stored:

   ```bash
   PTT_E2E_SERVER=https://staging.example.test \
   PTT_E2E_CHANNEL_ID=00000000-0000-4000-8000-000000000000 \
   PTT_E2E_SENDER_TOKEN=... \
   PTT_E2E_RECEIVER_TOKEN=... \
   npm run test:deployed-media --prefix cloudflare
   ```

4. Two isolated iOS Simulator devices launch the actual product app with two
   independently authenticated automation devices. Each device performs five
   real hold/grant/release cycles in turn with a non-silent microphone fixture,
   for ten bidirectional transmissions across fresh app processes. The opposite
   device must decrypt each distinct transmission and enqueue non-silent PCM
   through `AVAudioEngine`; packet delivery or a "Receiving" label alone cannot
   pass this gate. CI runs this with `scripts/test-ios-two-simulator-voice.sh`.
5. Two dedicated physical devices run a bidirectional acoustic test. Each sends
   a known spoken/tone fixture through its real microphone while a calibrated
   external microphone records the other device's speaker. The gate checks
   non-silent energy, the expected tone band, start latency, truncation, and the
   wired/Bluetooth/speaker route selected by the test. Simulator UI flows remain
   useful for state transitions, but cannot replace this hardware check.

The two access tokens used by layer 3 must belong to different active devices
in the same channel. Use a dedicated test account, revoke its tokens after a
production probe, and never pass tokens as command-line arguments because they
can appear in process listings.

The iOS and Android internal-handoff workflows run
`scripts/verify-release-gates.sh` before producing artifacts. They require
complete CI and the production voice gate for the exact commit, synchronized
mobile version/build numbers, push readiness, signing, and store readiness.
Those workflows explicitly defer `physical-release` and `android-soak` because
the signed internal builds are the inputs to those downstream gates. General
production promotion does not defer either physical workflow.

Store screenshots are captured from the actual current app, flattened to
non-alpha RGB PNGs, and checked for exact Apple/Google dimensions by
`scripts/verify-store-readiness.mjs`. Website release screenshots are synced
from the same source assets.

`admin-mock-server.mjs` supplies non-sensitive deterministic fixtures for a
responsive browser walkthrough of the administration console. Start it on its
default port, then run Vite with:

```bash
node tests/e2e/admin-mock-server.mjs
PTT_CONTROL_ORIGIN=http://127.0.0.1:39090 npm run dev --prefix admin-web -- \
  --host 127.0.0.1 --port 3002
```

Open `http://127.0.0.1:3002/admin/#handoff=FAKE-APPROVAL`. The fragment is a
synthetic single-use fixture and is erased before redemption. The mock must
never be used as an authentication or backend-security test; those routes are
covered by `scripts/test-control-integration.sh`. The complete browser journey
is automated by `scripts/test-admin-browser.mjs` and orchestrated by the
Promptfoo nightly campaign.
