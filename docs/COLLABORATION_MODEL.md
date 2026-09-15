# Collaboration model

PTT Talk borrows the parts of modern team messengers that make communication
easy to find and act on, while keeping push-to-talk as the fastest path through
the product. The model is intentionally smaller than Slack or Mattermost and
preserves PTT Talk's device-to-device encryption boundary.

## Information architecture

- **Home** lists channels, direct messages, and small private groups before any
  radio detail. Pinned conversations sort first; drafts, mentions, unread
  counts, mute state, and local archive state remain visible. Local search covers
  names, topics, decrypted message text, and attachment names, and continues the
  query inside a matching source conversation. All/Unread/Mentions/Pinned
  filters operate only on decrypted device state. Opening a conversation makes
  it the explicit context for the persistent PTT control.
- **PTT** is a persistent action above primary navigation, not a separate
  destination. Its label always names the selected channel; tapping the label
  opens the full radio console.
- Every conversation is a workspace with **Messages**, **Media**, **Brief**,
  **Members**, and **Security** views. Brief is built from pinned encrypted
  messages; Media collects encrypted files, voice messages, and video.
- **Activity** is the cross-channel inbox for mentions, unread work, locally
  starred messages saved for later, voice history, and structured operations.
- **You** owns identity, linked devices, notification behavior, support,
  and administrator handoff.

## Channels and access

Administrators can set a topic, retention, posting mode, and role for each
channel. Announcement channels are readable by every member but accept posts
only from dispatch or barge roles. Channel templates make repeated team spaces
consistent. User groups let an administrator add a maintained roster to a
non-direct channel in one membership-epoch rotation.

Accounts are members, time-limited guests, or automation identities. Guests
stop authenticating after expiry. Direct conversations are idempotent and
limited to two accounts; private group conversations support three to eight
accounts. There is no public workspace directory.

## Operations

Dispatch and barge roles can start a structured operation in a channel, choose
a routine, priority, or critical severity, change its state from active to
monitoring and resolved, hand command to another active member, and archive the
record. Channel members can acknowledge operation events. Operation state is
routing metadata; narrative, attachments, and pinned brief items remain
ordinary end-to-end encrypted channel messages.

## Secure automation

An integration is enrolled as a real, channel-scoped account and device. The
administrator supplies its public identity key and receives its ACI, device ID,
mailbox ID, and access token exactly once. It uses the same prekey, pairwise
envelope, attachment, and chat APIs as a mobile device. This lets an external
system post ciphertext without giving the server plaintext or an administrator
credential.

Integration creation and revocation rotate the channel membership epoch.
Revocation disables the automation account and device. Tokens can expire and
capabilities are explicit. Store one-time credentials in a secret manager,
never in source control or logs.

## Deliberate differences from general-purpose messengers

- Live PTT floor state remains cryptographically separate from chat delivery,
  while both use the same user-visible conversation context.
- No public channels, cross-tenant federation, bots with plaintext access,
  server-side search, analytics, or compliance export.
- Search, drafts, stars, archives, media indexes, and message previews are
  local to an enrolled device.
- The server can route membership, operation status, delivery state, and
  ciphertext, but cannot render message, file, video, or voice contents.
