# Mobile black-box flows

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
`ios-voice-smoke.yaml`. The smaller transmit/receive flows support lifecycle
tests without repeating the full journey. After rebooting Android, run
`android-rearm-after-reboot.yaml` to prove that microphone-capable background
work requires a fresh user gesture. `android-live-session-transmit.yaml`
verifies an already armed session after a network transition.

`admin-mock-server.mjs` supplies non-sensitive deterministic fixtures for a
responsive browser walkthrough of the administration console. Start it on its
default port, then run Vite with:

```bash
node tests/e2e/admin-mock-server.mjs
PTT_CONTROL_ORIGIN=http://127.0.0.1:39090 npm run dev --prefix admin-web -- \
  --host 127.0.0.1 --port 3002
```

Sign in only with the fixture value `fake-admin-token`. The mock must never be
used as an authentication or backend-security test; those routes are covered
by `scripts/test-control-integration.sh`.
