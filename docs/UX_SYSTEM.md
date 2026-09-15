# PTT Talk interface system

This document records the product interface baseline for the 0.2.0 (44)
private beta. It applies to the Android and iOS clients.

## Product hierarchy

The four persistent destinations are **Home**, **Calls**, **Activity**, and
**You**. Home is the default and puts the conversation list first. Device-local
search covers conversation names, topics, decrypted message text, and attachment
names; a content result shows a short **Match** preview and opens the source
conversation with the same search already applied. **All**, **Unread**,
**Mentions**, and **Pinned** filters help a person find work without exposing a
query or message content to the server. Opening a conversation also makes it the
current PTT context so the person cannot accidentally transmit to an older
channel.

PTT is an action, not a navigation destination. Home does not repeat a large
radio card above the conversation list. A compact hold-to-talk accessory remains
directly above the primary navigation while a person reads a conversation or
scans Home. It always names the destination and connection state. Tapping its
channel summary opens the full radio console for channel selection, presence,
emergency voice, and detailed connection feedback.

Activity contains cross-channel attention, starred messages saved for later,
saved transmissions, and structured operations. Saved-message rows return to
their encrypted source conversation and remain local to the device. Calls
contains ringing, active, recent, and missed calls. You owns
identity, linked devices, preferences, privacy, support, and administrator
handoff.

The app name is brand identity, not a screen title. Screen titles describe the
user's current task or channel.

## Interaction rules

- The compact PTT control remains one gesture away and requires press, hold,
  speak, and release. The full radio console remains available for focused
  field use. Both surfaces use the same floor controller and state.
- Connection and floor feedback appears next to the control it affects. Errors
  explain the next useful action; microphone failures provide a Settings link.
- Search, refresh, mute, pin, archive, participant, and retention tools remain
  available without competing with the conversation.
- Message attachments share a single add affordance. Voice recording remains a
  distinct hold gesture because it is time-sensitive.
- Security is stated in plain language first. Protocol names, identifiers, key
  epochs, and fingerprints are available under deliberate disclosure.
- Enrollment presents only the invitation-email path initially. Manual codes,
  linking a second device, and recovery appear after opening **Other setup
  options**.

## Accessibility baseline

- Interactive targets are at least 44 points on Apple platforms and 48 dp on
  Android wherever the platform control does not already provide a larger hit
  area.
- Status never relies on color or sound alone. Text labels and system semantics
  accompany icons, tones, and haptics.
- Every primary screen is tested in light and dark appearance at standard and
  maximum supported text sizes.
- Layouts scroll rather than clipping controls, and destructive device/account
  actions remain explicitly labeled and confirmed.

## Reference applications and guidance

The September 2026 review used Signal and WhatsApp as conversation-interface
references, Zello and ProPTT2 as PTT references, and the native Apple and
Material design systems as the platform baseline. PTT Talk adopts their proven
task hierarchy—context title, message timeline, compact composer, stable bottom
navigation, and secondary tools in menus—without copying brand assets or hiding
PTT-specific floor state.

- [Signal on the App Store](https://apps.apple.com/us/app/signal-private-messenger/id874139669)
- [WhatsApp on the App Store](https://apps.apple.com/us/app/whatsapp-messenger/id310633997)
- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [Material 3 navigation bar](https://m3.material.io/components/navigation-bar/overview)
- [Zello](https://zello.com/)
- [ProPTT2](https://www.proptt2.com/)
