# PTT Talk

Store copy for release candidate **0.1.21 (24)**. This describes product
capabilities; publication still depends on the exact-commit readiness gates in
[`../../docs/CURRENT_STATE.md`](../../docs/CURRENT_STATE.md).

## Short description

Private encrypted push-to-talk for teams.

## Full description

PTT Talk provides live, end-to-end encrypted push-to-talk voice and channel
chat for private teams on a self-hosted server. Hold to request a channel floor,
speak with real microphone audio, receive missed transmissions as encrypted
history, and see the active encryption details on both sides. Between live
transmissions, send encrypted text, files, voice notes, and video in the same
private channel.

Administrators invite members by email, assign channel roles, manage retention,
and revoke devices. Each account can link two independently keyed devices.
Normal and silent SOS can prioritize an urgent transmission for visible channel
recipients. PTT Talk is not a replacement for emergency services.

## Test notes

1. Open the administrator invitation and single-use sign-in link.
2. Tap **Stay connected**, select an assigned channel, and hold **Talk** while
   speaking. Release to end the floor.
3. Repeat in both directions and compare the Encryption details.
4. Test encrypted History after one device has been offline.
5. Test linking and revoking a second device. Newly linked devices receive only
   future transmissions.
6. Send text, a file, a voice note, and a video in Chat, then verify delivery
   and playback on the other enrolled device.

## Category and audience

- Category: Communication
- Target audience: Private adult team members
- Ads: None
- In-app purchases: None
- Account required: Yes, by administrator email invitation
- Tracking: None
- Privacy policy: https://ptttalk.app/privacy
- Data deletion: Available in the app's Device section; operator contact and
  retention details are provided at
  https://ptttalk.app/privacy#deletion
