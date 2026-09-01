# Member guide

This guide describes the Android and iOS/iPadOS 0.1.21 private beta. Your team
administrator must invite you before the app can be used.

## Join your team

1. Install PTT Talk from the private TestFlight or Google Play test group.
2. Open the invitation email **on the device you want to enroll**.
3. Tap **Join PTT Talk**. The app verifies the one-time invitation and creates
   this device's encryption keys automatically.
4. If the link opened elsewhere, choose the manual invitation option and enter
   the invitation code. A request ID is not an invitation code.
5. Allow microphone and notification access. On Android, tap **Stay connected**
   when you want background PTT availability.

An invitation or magic link can be used only once and expires. Ask the team
administrator for a new invitation instead of repeatedly retrying an expired
one.

## Talk in a channel

1. Open **Talk** and select a channel where your role permits speaking.
2. Confirm the screen says the channel membership is active and encrypted voice
   is connected.
3. Press and hold **Hold to talk**. Wait for the granted tone/state, then speak.
4. Release the button to finish. The release state closes the authenticated
   floor and completes encrypted history delivery.

Only one member owns a channel floor at a time. A denial means another member
is speaking, your role is listen-only, the channel changed, or the secure
session needs to reconnect. Audio never leaves the device before an
authenticated grant.

On Android, hardware/headset controls, the tile, widget, and overlay follow the
same floor rules as the main button. On iOS, the selected system PTT channel is
the one available for background live voice.

## Receive and replay voice

Live voice plays only after membership, sender key, SFrame authentication, and
replay checks succeed. If a live item cannot play, its encrypted missed copy is
available from **Activity/History** after the device reconnects and receives the
required key material.

Local history is encrypted and limited to 30 days and 1 GB. Server retention is
set by your administrator. A newly linked device cannot decrypt older history.

## Send messages and attachments

Open **Chat** for the selected channel. You can send:

- text and encrypted teammate mentions;
- files and documents;
- voice messages with waveform playback and speed control;
- photos/video with client-generated encrypted previews.

Long-press or open a message's menu for reply, reaction, edit, delete, copy,
share, forward, pin, star, and message information. Search, draft, mute, archive,
retention, and participant controls are in the conversation interface. Delivery
states are **Queued**, **Sending**, **Sent**, **Delivered**, **Read**, **Played**,
or **Failed**. Failed and interrupted transfers can resume without uploading
plaintext.

## Use SOS carefully

Normal SOS requests a priority voice floor and visibly identifies the emergency
to channel recipients. Silent SOS sends the priority emergency state without a
local granted sound. The app shows how many other active devices are targeted.

PTT Talk is not a replacement for emergency services. Use local emergency
services whenever a person or property is in immediate danger.

## Add a second device

An account may have two active devices.

1. On the active device, open **Settings → Devices → Add another device**.
2. Send the setup link to the new device and open it there.
3. The new device claims the request and displays that it is ready.
4. Return to the active device and approve the final security step.

The one-time code is used for the link claim. The request ID identifies the
request; it is not the invitation code. The new device receives future messages
and voice only.

## Recover when every device is lost

Use **Recover an account** only when no active device remains. Recovery requires
a fresh email link and approval by a different team administrator. Approval
revokes the old devices and rotates affected channel keys. It does not restore
old local history.

## Check security and privacy

- Compare **Safety numbers** with a teammate over a trusted channel after a
  device-key change.
- **Encryption details** show the current channel epoch, sender device, media
  key identifier, and authenticated transport without exposing raw keys.
- **Share support report** creates a privacy-redacted diagnostic. It must not
  contain email, endpoint, raw identifiers, tokens, keys, audio, or message
  content.
- **Delete account and server data** revokes devices, removes channel access,
  deletes delivery/key material, and de-identifies the account email, subject to
  the operator's disclosed audit, shared-history, legal, and backup retention.

## Platform lifecycle notes

- Android force-stop disables delivery until you reopen the app and tap **Stay
  connected**. Reboot also requires a visible re-arm.
- iOS can restore its previously joined system channel, but joining or changing
  that channel requires foreground interaction.
- Bluetooth, wired audio, calls, VPN changes, and Wi-Fi/cellular transitions can
  briefly reconnect the secure media route. Release the talk button, wait for
  **Ready to talk**, and hold again.

If audio still does not play after reconnecting, record the sending and
receiving states, the app version/build, device model, OS version, route
(speaker/Bluetooth/wired), and whether the screen was locked. Share only the
privacy-redacted support report with the team administrator.
