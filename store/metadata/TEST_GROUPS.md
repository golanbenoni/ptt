# Beta test groups

This is the synchronized internal-test configuration for **0.2.0 (33)**.
Internal distribution begins after the automated exact-commit gates so testers
can produce the remaining physical acoustic, lifecycle, and Android soak evidence.

## Apple TestFlight

- Group: `PTT Internal Testers`
- Build: `0.2.0 (33)`
- Status: internal candidate; production promotion remains gated
- Current membership: 1 tester
- Test focus: repeated live voice in both directions, floor feedback, encrypted
  history, lock-screen return, network changes, SOS, accessibility, device
  linking/revocation, matching encryption details, and one-time admin-console
  approval, encrypted text chat, files, voice notes, video, delivery receipts,
  and attachment playback
- Feedback email: the App Store Connect account contact

## Google Play

- Track: Internal testing
- Release: `PTT Talk 0.2.0 (33)`
- Tester list: `PTT Internal Testers`
- Status: internal candidate; production promotion remains gated
- Current membership: 2 testers
- Release notes: Private production-voice beta with real Opus audio, SFrame
  media encryption, authenticated floor control, encrypted missed history,
  SOS, device management, automatic TLS media fallback, and one-time
  admin-console approval, encrypted text chat, resumable attachments, voice
  notes, video, reactions, replies, and delivery receipts. Build 33 adds encrypted
  1:1 and private-group voice calls for up to eight active participants, plus the
  collaboration workspace, direct and private-group conversations, unified
  activity, operations, templates, user groups, and scoped encrypted
  integrations while preserving the fast authenticated floor path.

Tester membership is intentionally not inferred from other apps. Add only
people who have explicitly agreed to participate in this PTT beta.
