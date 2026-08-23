# PTT Talk Privacy Policy

Effective date: August 23, 2026

PTT Talk is an early encrypted push-to-talk test application. It does not use
advertising, analytics, tracking SDKs, or developer-operated user accounts.

## Data handled by the app

The beta exchanges public cryptographic prekey material and encrypted test
audio packets with the prekey and relay endpoints selected by the tester. The
current beta generates a test tone rather than recording microphone audio.
Endpoints may temporarily hold prekey material or relay encrypted packets as
needed to complete a test. PTT Talk does not sell personal data or use it for
advertising or profiling.

The app stores received test audio and cryptographic session state only in its
local app container. Removing the app removes that local data.

## Network operators

Testers or test administrators may configure endpoints operated by a third
party. Data sent to those endpoints is governed by that operator's practices.
Audio payloads are encrypted in transit, but endpoint addresses and basic
network metadata may be visible to network and relay operators.

## Children

This technical beta is not directed to children under 13.

## Changes and contact

This policy will be updated before microphone capture, account services,
analytics, or other data practices are added. Questions may be opened as an
issue at <https://github.com/golanbenoni/ptt/issues>.
