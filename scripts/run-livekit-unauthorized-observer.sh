#!/usr/bin/env bash
# Join an active local product-call room as a subscriber-only client with
# deliberately wrong frame keys. The pinned Swift probe must receive encrypted
# track state, fail decryption, and render no non-silent PCM.
set -euo pipefail

: "${PTT_CALL_LIVEKIT_CONTAINER:?PTT_CALL_LIVEKIT_CONTAINER is required}"
: "${PTT_CALL_LIVEKIT_API_KEY:?PTT_CALL_LIVEKIT_API_KEY is required}"
: "${PTT_CALL_LIVEKIT_API_SECRET:?PTT_CALL_LIVEKIT_API_SECRET is required}"
: "${PTT_CALL_LIVEKIT_OBSERVER_URL:?PTT_CALL_LIVEKIT_OBSERVER_URL is required}"
: "${PTT_CALL_LIVEKIT_OBSERVER_BINARY:?PTT_CALL_LIVEKIT_OBSERVER_BINARY is required}"

CLI_IMAGE="${PTT_LIVEKIT_CLI_IMAGE:-livekit/livekit-cli:v2.18.6}"
EXPECTED_TRACKS="${PTT_OBSERVER_EXPECTED_TRACKS:-2}"
DURATION_SECONDS="${PTT_OBSERVER_DURATION_SECONDS:-8}"

case "$CLI_IMAGE" in
  livekit/livekit-cli:v2.18.6|livekit/livekit-cli@sha256:*) ;;
  *) echo "Refusing unpinned LiveKit CLI image: $CLI_IMAGE" >&2; exit 1 ;;
esac
case "$PTT_CALL_LIVEKIT_CONTAINER" in
  ptt-android-call-livekit-[0-9]*) ;;
  *) echo "Refusing unexpected LiveKit call container name." >&2; exit 1 ;;
esac
[[ -x "$PTT_CALL_LIVEKIT_OBSERVER_BINARY" ]] || {
  echo "The built ciphertext-observer probe is unavailable." >&2
  exit 1
}
[[ "$EXPECTED_TRACKS" =~ ^[2-8]$ ]] || {
  echo "PTT_OBSERVER_EXPECTED_TRACKS must be between 2 and 8." >&2
  exit 1
}
[[ "$DURATION_SECONDS" =~ ^([3-9]|[12][0-9]|30)$ ]] || {
  echo "PTT_OBSERVER_DURATION_SECONDS must be between 3 and 30." >&2
  exit 1
}
for command in docker jq openssl ruby; do
  command -v "$command" >/dev/null || {
    echo "Missing unauthorized-observer dependency: $command" >&2
    exit 1
  }
done

run_lk() {
  docker run --rm --network "container:$PTT_CALL_LIVEKIT_CONTAINER" \
    -e LIVEKIT_URL=http://127.0.0.1:7880 \
    -e LIVEKIT_API_KEY="$PTT_CALL_LIVEKIT_API_KEY" \
    -e LIVEKIT_API_SECRET="$PTT_CALL_LIVEKIT_API_SECRET" \
    "$CLI_IMAGE" "$@" 2>/dev/null
}

room_json="$(run_lk room list --json)"
[[ "$(jq -r '.rooms | length' <<<"$room_json")" == 1 ]] || {
  echo "The observer expected exactly one active call room." >&2
  exit 1
}
room_name="$(jq -r '.rooms[0].name // ""' <<<"$room_json")"
[[ "$room_name" =~ ^[A-Za-z0-9_-]{43}$ ]] || {
  echo "The observer refuses a non-pseudonymous room." >&2
  exit 1
}
identity="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"
[[ "$identity" =~ ^[A-Za-z0-9_-]{43}$ ]] || {
  echo "Could not create a pseudonymous observer identity." >&2
  exit 1
}
token="$(run_lk token create --join --room "$room_name" --identity "$identity" \
  --grant '{"canPublish":false,"canSubscribe":true,"canPublishData":false}' \
  --valid-for 1m --token-only)"
[[ "$token" == *.*.* ]] || {
  echo "Could not mint the bounded subscriber-only observer token." >&2
  exit 1
}
claims="$(PTT_OBSERVER_JWT="$token" ruby -rjson -rbase64 -e '
  part = ENV.fetch("PTT_OBSERVER_JWT").split(".").fetch(1)
  part += "=" * ((4 - part.length % 4) % 4)
  print JSON.generate(JSON.parse(Base64.urlsafe_decode64(part)))
')"
jq -e --arg room "$room_name" --arg identity "$identity" '
  .sub == $identity and .identity == $identity and
  .video.roomJoin == true and .video.room == $room and
  .video.canSubscribe == true and .video.canPublish == false and
  .video.canPublishData == false and
  ((.video.roomAdmin // false) == false) and
  ((.video.roomCreate // false) == false) and
  ((.video.roomList // false) == false) and
  ((.video.roomRecord // false) == false) and
  ((.video.ingressAdmin // false) == false) and
  ((.video.egressAdmin // false) == false) and
  ((.video.sipAdmin // false) == false)
' <<<"$claims" >/dev/null || {
  echo "The observer token exceeded the required subscriber-only grant." >&2
  exit 1
}
unset claims

PTT_OBSERVER_LIVEKIT_URL="$PTT_CALL_LIVEKIT_OBSERVER_URL" \
PTT_OBSERVER_LIVEKIT_TOKEN="$token" \
PTT_OBSERVER_EXPECTED_TRACKS="$EXPECTED_TRACKS" \
PTT_OBSERVER_DURATION_SECONDS="$DURATION_SECONDS" \
  "$PTT_CALL_LIVEKIT_OBSERVER_BINARY"

unset token
echo "Unauthorized observer proof passed: encrypted tracks failed decryption and exposed no non-silent PCM."
