# Beta test groups

This is the intended synchronized internal-test configuration for release
candidate 0.1.28 (31). Assign the build only after the same commit passes the
release gates; a store upload or processed build is not by itself approval for
human testing.

## Apple TestFlight

- Group: `PTT Internal Testers`
- Build: `0.1.28 (31)`
- Test focus: repeated live voice in both directions, floor feedback, encrypted
  history, lock-screen return, network changes, SOS, accessibility, device
  linking/revocation, matching encryption details, and one-time admin-console
  approval, encrypted text chat, files, voice notes, video, delivery receipts,
  and attachment playback
- Feedback email: the App Store Connect account contact

## Google Play

- Track: Internal testing
- Release: `PTT Talk 0.1.28 (31)`
- Tester list: `PTT Internal Testers`
- Release notes: Private production-voice beta with real Opus audio, SFrame
  media encryption, authenticated floor control, encrypted missed history,
  SOS, device management, automatic TLS media fallback, and one-time
  admin-console approval, encrypted text chat, resumable attachments, voice
  notes, video, reactions, replies, and delivery receipts. Build 27 preserves
  Apple's system-owned audio graph and removes database-delay outliers from the
  authenticated floor path while retaining immediate membership invalidation.

Tester membership is intentionally not inferred from other apps. Add only
people who have explicitly agreed to participate in this PTT beta.
