# Beta test groups

This is the intended synchronized internal-test configuration for **0.1.29
(32)**. The candidate is not yet uploaded; its exact-commit software, physical
acoustic, lifecycle, and Android soak gates must pass before these group records
are updated.

## Apple TestFlight

- Group: `PTT Internal Testers`
- Build: `0.1.29 (32)`
- Status: candidate; upload and group assignment pending release gates
- Current membership: 1 tester
- Test focus: repeated live voice in both directions, floor feedback, encrypted
  history, lock-screen return, network changes, SOS, accessibility, device
  linking/revocation, matching encryption details, and one-time admin-console
  approval, encrypted text chat, files, voice notes, video, delivery receipts,
  and attachment playback
- Feedback email: the App Store Connect account contact

## Google Play

- Track: Internal testing
- Release: `PTT Talk 0.1.29 (32)`
- Tester list: `PTT Internal Testers`
- Status: candidate; internal-track upload pending release gates
- Current membership: 2 testers
- Release notes: Private production-voice beta with real Opus audio, SFrame
  media encryption, authenticated floor control, encrypted missed history,
  SOS, device management, automatic TLS media fallback, and one-time
  admin-console approval, encrypted text chat, resumable attachments, voice
  notes, video, reactions, replies, and delivery receipts. Build 32 adds the
  collaboration workspace, direct and private-group conversations, unified
  activity, operations, templates, user groups, and scoped encrypted
  integrations while preserving the fast authenticated floor path.

Tester membership is intentionally not inferred from other apps. Add only
people who have explicitly agreed to participate in this PTT beta.
