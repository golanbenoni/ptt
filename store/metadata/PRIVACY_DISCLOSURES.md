# Store privacy disclosures for PTT Talk 0.1.4 (5)

These answers describe the production-voice build and the supported
single-tenant self-hosted deployment. They intentionally use the conservative
answer when encrypted or pseudonymous data is associated with an account or
device. Recheck them if an Instance Operator adds analytics, recording,
directory, or support SDKs.

## URLs

- Privacy policy: <https://golanbenoni.github.io/ptt-talk-privacy/>
- Account/data deletion: <https://golanbenoni.github.io/ptt-talk-privacy/#deletion>
- Privacy contact: <https://github.com/golanbenoni/ptt/issues>

The apps also expose **Privacy policy and data choices** and **Delete account
and server data** in the Device section.

## Google Play Data safety

### Collection and security

- Does the app collect or share required user data types? **Yes**
- Is all collected user data encrypted in transit? **Yes**
- Can users request deletion? **Yes, in-app and through the web resource above**
- Does the app use an independent security review badge? **No** until an
  eligible external review is complete.
- Is the app intended for children? **No**

### Data types

| Google Play data type | Collected | Shared | Required | Purposes |
| --- | --- | --- | --- | --- |
| Personal info · Email address | Yes | No | Required for invited accounts | App functionality; account management; security |
| Personal info · User IDs | Yes | No | Required | App functionality; account management; security |
| Audio · Voice or sound recordings | Yes | No | Optional per transmission, core to PTT | App functionality |
| Device or other IDs | Yes | No | Required | App functionality; security; fraud/abuse prevention |
| App activity · App interactions | Yes | No | Required while using the service | App functionality; security; fraud/abuse prevention |
| App info and performance · Diagnostics | Yes | No | Required for reliable operation | App functionality; security; diagnostics |

“Shared: No” assumes the operator's hosting, object storage, SMTP, backup, APNs,
and FCM vendors act only as service providers. If an operator permits a vendor
to use data for its own purposes, that operator must change the affected answer
to **Shared: Yes**. Audio is end-to-end encrypted before relay or history
storage, but it is still declared because ciphertext is transmitted off-device
and may be retained.

Do not select advertising, personalization, developer communications,
financial, health, location, contacts, messages, photos/videos, web browsing,
calendar, or installed-app data for this build.

### Retention and deletion statement

Account deletion removes channel access, revokes devices, deletes delivery and
key material, and de-identifies the account email. Shared encrypted channel
history, security audit records, legally required records, and backups may
remain for their disclosed retention periods. Local app deletion removes local
keys and history. Server history retention is 1–365 days per channel; local
history is limited to 30 days and 1 GB.

## Apple App Privacy

Select **Yes, data is collected**. Use these answers at app level for both iOS
and any future Apple platforms:

| Apple data type | Linked to user | Used for tracking | Purposes |
| --- | --- | --- | --- |
| Contact Info · Email Address | Yes | No | App Functionality |
| Identifiers · User ID | Yes | No | App Functionality |
| Identifiers · Device ID | Yes | No | App Functionality |
| User Content · Audio Data | Yes | No | App Functionality |
| Usage Data · Product Interaction | Yes | No | App Functionality |
| Diagnostics · Other Diagnostic Data | Yes | No | App Functionality |

IP addresses and authenticated operational events are treated conservatively
as linked identifiers/diagnostics. Do not declare third-party advertising,
developer advertising, analytics, product personalization, or tracking.

Enter the privacy policy URL above in App Store Connect. The optional Privacy
Choices URL can use the deletion anchor above.

## Permission disclosures

- **Microphone:** used only while the member actively transmits PTT voice.
- **Notifications / Push to Talk:** carries privacy-minimized wake signals and
  reconnects encrypted delivery; push payloads do not contain audio, email,
  channel names, or message text.
- **Bluetooth / nearby audio devices (Android):** selects an authorized audio
  route or hardware PTT input; it is not used for a public nearby-device
  directory.
- **Foreground service (Android):** maintains the user-armed encrypted session,
  floor, audio, and network state with a persistent notification.

## Accuracy gate

Before publishing a new build, compare these answers with the app permissions,
mobile dependencies, server environment, privacy policy, and the operator's
actual vendors. Store answers and the public policy must be updated before a
new data practice ships.
