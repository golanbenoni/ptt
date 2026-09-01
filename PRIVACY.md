# PTT Talk Privacy Policy

Effective date: August 31, 2026

PTT Talk is a private, end-to-end encrypted push-to-talk and channel messaging
service for teams. It does not use advertising, analytics, cross-app tracking,
or profiling, and it does not sell personal data.

PTT Talk is self-hosted. The organization that operates the PTT Talk instance
you join (the "Instance Operator") controls the service records on that
instance and chooses its infrastructure providers and retention settings. This
policy describes the data handled by the PTT Talk software. Your Instance
Operator may provide additional terms or privacy information.

## Data handled by PTT Talk

- **Account and team data:** email address, invitation and recovery status,
  administrator status, channel memberships and roles, device display names,
  and random account, device, mailbox, channel, and request identifiers.
- **Security data:** public identity keys and prekeys, hashed access and
  invitation tokens, device status, key and membership epochs, safety-number
  material, and security audit events. Private encryption keys remain in the
  operating system's protected storage on the device.
- **Push and delivery data:** Apple or Google push tokens, encrypted mailbox
  and chat envelopes, delivery status, and timestamps. Push messages contain
  only a privacy-minimized wake signal; they do not contain voice audio, email
  addresses, channel names, message text, filenames, or captions.
- **Voice, chat, attachments, and history:** the app uses the microphone only
  while you actively transmit or record a voice note. Live voice, text, files,
  voice notes, and video are encrypted on the sending device. Relays and object
  storage receive ciphertext, not plaintext content or the keys needed to
  decrypt it. Eligible team devices may store and play encrypted missed
  transmissions, messages, attachments, and history.
- **Operational data:** IP addresses and network source tuples used to route
  traffic and reject forged packets; floor, presence, relay, authentication,
  error, and rate-limit events; timestamps; service health; and aggregate
  operational counts. PTT Talk's supported metrics and support exports omit
  email addresses, raw account/device/mailbox/channel identifiers, access
  tokens, encryption keys, and audio contents.

## How data is used

PTT Talk uses this data to authenticate invited members, link or revoke up to
two independently keyed devices, deliver encrypted voice, chat, attachments,
and history, enforce channel membership and floor control, send
privacy-minimized reconnect notifications, recover accounts with administrator
approval, prevent abuse, diagnose failures, back up the instance, and maintain
service security. It is not used for advertising or tracking.

## Storage, retention, and recipients

Account, membership, device, and audit records are stored by the Instance
Operator. Encrypted history and attachments are retained on the server for the
channel's operator-selected period, from 1 to 365 days. Local encrypted history
and attachment caches are limited to 30 days and 1 GB per device. Newly linked
devices can receive future communications only and are not given earlier
attachments or history.

Data is disclosed only as needed to provide the service: to the Instance
Operator and its hosting, storage, email, backup, and network providers; to
Apple or Google for privacy-minimized push delivery; and to authorized members'
devices for the channels to which they belong. Network and relay operators can
observe addresses, timing, and traffic volume even though communication content
is encrypted. The software does not provide content to PTT Talk's developers.

The Instance Operator selects where the service is hosted. Data may therefore
be processed in the countries where the operator and its providers run their
systems. Server backups may retain deleted records until the operator's backup
cycle expires.

## Your choices and deletion

You may stop microphone, photo-library, or notification access in system
settings. You may revoke a linked device from the app; revocation removes that
device's server access, and deleting the app removes its local keys and local
history.

You can request deletion of your account and associated server data from the
Device section in the app, or contact your Instance Operator or administrator.
Deletion removes the member from all channels, revokes the member's devices,
de-identifies the account email, and deletes account delivery and key material.
Security audit records, shared encrypted channel history, legal records, and
backups may remain for their applicable retention periods. Removing a member
rotates affected channel key epochs. Previously delivered ciphertext or data
stored on other members' devices cannot be remotely erased by the server. If
you cannot reach the operator, open a request at
<https://github.com/golanbenoni/ptt/issues>.

## Security

PTT Talk uses end-to-end encryption, protected device key storage,
authenticated transport, access controls, and replay and source validation.
No security measure is perfect. If you believe an account, device, or instance
has been compromised, contact the Instance Operator promptly so it can revoke
access and rotate affected keys.

## Children

PTT Talk is intended for private organizations and is not directed to children
under 13. Instance Operators are responsible for choosing eligible members and
for any additional consent requirements that apply to their organization.

## Changes and contact

This policy may change as the product or applicable requirements change. The
effective date above identifies the current version. Privacy and security
questions may be opened at <https://github.com/golanbenoni/ptt/issues> or sent
to the administrator of your PTT Talk instance.
