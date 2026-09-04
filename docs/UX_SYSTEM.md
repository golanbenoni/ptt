# PTT Talk interface system

This document records the product interface baseline for the 0.1.29 (32)
private beta. It applies to the Android and iOS clients.

## Product hierarchy

The four persistent destinations are **Talk**, **Chat**, **Activity**, and
**Settings**. Talk is the default and keeps the current channel, secure
connection state, and hold-to-talk control together. Chat opens directly into
the selected channel. Activity contains saved transmissions and verification.
Settings contains device, account, privacy, and technical information.

The app name is brand identity, not a screen title. Screen titles describe the
user's current task or channel.

## Interaction rules

- The primary PTT control remains visually dominant and requires press, hold,
  speak, and release. Its state is also communicated by text and haptics.
- Connection and floor feedback appears next to the control it affects. Errors
  explain the next useful action; microphone failures provide a Settings link.
- Search, refresh, mute, pin, archive, participant, and retention tools remain
  available without competing with the conversation.
- Message attachments share a single add affordance. Voice recording remains a
  distinct hold gesture because it is time-sensitive.
- Security is stated in plain language first. Protocol names, identifiers, key
  epochs, and fingerprints are available under deliberate disclosure.
- Enrollment presents the invitation-email path first. Manual codes, linking a
  second device, and recovery are clearly labeled fallbacks.

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
