# Beta test groups

This is the active synchronized internal-test configuration for **0.1.28
(31)**, published September 3, 2026 from source commit `fc31ec7`. The exact
commit passed CI and the production two-client voice/collaboration gate before
distribution. Physical acoustic and lifecycle testing remains the purpose of
these groups.

## Apple TestFlight

- Group: `PTT Internal Testers`
- Build: `0.1.28 (31)`
- Status: processed as valid and assigned to the group
- Current membership: 1 tester
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
- Status: release edit committed successfully with `completed` status
- Current membership: 2 testers
- Release notes: Private production-voice beta with real Opus audio, SFrame
  media encryption, authenticated floor control, encrypted missed history,
  SOS, device management, automatic TLS media fallback, and one-time
  admin-console approval, encrypted text chat, resumable attachments, voice
  notes, video, reactions, replies, and delivery receipts. Build 31 adds the
  collaboration workspace, direct and private-group conversations, unified
  activity, operations, templates, user groups, and scoped encrypted
  integrations while preserving the fast authenticated floor path.

Tester membership is intentionally not inferred from other apps. Add only
people who have explicitly agreed to participate in this PTT beta.
