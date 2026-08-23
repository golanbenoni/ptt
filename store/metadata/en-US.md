# PTT Talk

## Short description

Encrypted push-to-talk transport test harness.

## Full description

PTT Talk is an early-access device harness for testing encrypted push-to-talk
transport across Android and iOS. Testers can connect to a configured prekey
service and UDP relay, listen as Bob, and send a generated test tone as Alice.

This build is intended for a private technical test group. It validates
post-quantum session setup, encrypted media framing, relay interoperability,
and cross-platform behavior. It does not yet capture live microphone audio and
is not intended for emergency communication.

## Test notes

1. Enter the prekey HTTP(S) URL and relay host and port supplied by the test
   administrator.
2. On one device, choose **Listen continuously as Bob** once.
3. On another device, choose **Send tone as Alice** twice without restarting
   the listener.
4. Confirm the listener receives and plays both tones, reports 20 frames and
   non-zero energy for each, and logs that it rearmed between tones.
5. Compare the Encryption section on both devices. The talk ID, channel, key
   fingerprint, authenticated-data fingerprint, and frame metadata should
   match. Raw encryption keys are never displayed.

Use **Stop listening** to end the continuous listener. Local-network access to
the supplied test services is required.

## Category and audience

- Category: Tools / Utilities
- Target audience: Adults participating in a private technical beta
- Ads: None
- In-app purchases: None
- Account required: No
- Tracking: None
- Privacy policy: https://golanbenoni.github.io/ptt-talk-privacy/
