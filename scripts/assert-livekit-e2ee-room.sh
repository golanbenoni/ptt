#!/usr/bin/env bash
# Inspect one active local product-call room through LiveKit's authenticated
# administration API. This proves that the SFU classifies every published
# microphone track as client-side GCM encrypted and sees pseudonymous room and
# participant identities only. It complements, but does not replace, the
# independent packet-capture/unauthorized-observer release proof.
set -euo pipefail

: "${PTT_CALL_LIVEKIT_CONTAINER:?PTT_CALL_LIVEKIT_CONTAINER is required}"
: "${PTT_CALL_LIVEKIT_API_KEY:?PTT_CALL_LIVEKIT_API_KEY is required}"
: "${PTT_CALL_LIVEKIT_API_SECRET:?PTT_CALL_LIVEKIT_API_SECRET is required}"

CLI_IMAGE="${PTT_LIVEKIT_CLI_IMAGE:-livekit/livekit-cli:v2.18.6}"
EXPECTED_PARTICIPANTS="${PTT_CALL_EXPECTED_SFU_PARTICIPANTS:-2}"
REQUIRE_PSEUDONYMOUS_IDENTITIES="${PTT_CALL_REQUIRE_PSEUDONYMOUS_IDENTITIES:-1}"

case "$CLI_IMAGE" in
  livekit/livekit-cli:v2.18.6|livekit/livekit-cli@sha256:*) ;;
  *) echo "Refusing unpinned LiveKit CLI image: $CLI_IMAGE" >&2; exit 1 ;;
esac
case "$PTT_CALL_LIVEKIT_CONTAINER" in
  ptt-android-call-livekit-[0-9]*|ptt-ios-call-livekit-[0-9]*) ;;
  *) echo "Refusing unexpected LiveKit call container name." >&2; exit 1 ;;
esac
if ! [[ "$EXPECTED_PARTICIPANTS" =~ ^[2-8]$ ]]; then
  echo "PTT_CALL_EXPECTED_SFU_PARTICIPANTS must be between 2 and 8." >&2
  exit 1
fi
[[ "$REQUIRE_PSEUDONYMOUS_IDENTITIES" == 0 || "$REQUIRE_PSEUDONYMOUS_IDENTITIES" == 1 ]] || {
  echo "PTT_CALL_REQUIRE_PSEUDONYMOUS_IDENTITIES must be 0 or 1." >&2
  exit 1
}
for command in docker jq; do
  command -v "$command" >/dev/null || {
    echo "Missing SFU-inspection dependency: $command" >&2
    exit 1
  }
done
[[ "$(docker inspect -f '{{.State.Running}}' "$PTT_CALL_LIVEKIT_CONTAINER" 2>/dev/null)" == true ]] || {
  echo "The expected local LiveKit container is not running." >&2
  exit 1
}

run_lk() {
  docker run --rm --network "container:$PTT_CALL_LIVEKIT_CONTAINER" \
    -e LIVEKIT_URL=http://127.0.0.1:7880 \
    -e LIVEKIT_API_KEY="$PTT_CALL_LIVEKIT_API_KEY" \
    -e LIVEKIT_API_SECRET="$PTT_CALL_LIVEKIT_API_SECRET" \
    "$CLI_IMAGE" "$@" 2>/dev/null
}

room_json=""
room_count=0
participant_count=0
publisher_count=0
for _ in $(seq 1 12); do
  room_json="$(run_lk room list --json)"
  room_count="$(jq -r '.rooms | length' <<<"$room_json")"
  if [[ "$room_count" == 1 ]]; then
    participant_count="$(jq -r '.rooms[0].numParticipants // 0' <<<"$room_json")"
    publisher_count="$(jq -r '.rooms[0].numPublishers // 0' <<<"$room_json")"
    if [[ "$participant_count" == "$EXPECTED_PARTICIPANTS" &&
       "$publisher_count" == "$EXPECTED_PARTICIPANTS" ]]; then
      break
    fi
  fi
  sleep 1
done
[[ "$room_count" == 1 ]] || {
  echo "SFU inspection expected one active product-call room; found $room_count." >&2
  exit 1
}
room_name="$(jq -r '.rooms[0].name // ""' <<<"$room_json")"
if [[ "$REQUIRE_PSEUDONYMOUS_IDENTITIES" == 1 && ! "$room_name" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
  echo "The SFU room name is not a random base64url identifier." >&2
  exit 1
fi
[[ "$participant_count" == "$EXPECTED_PARTICIPANTS" &&
   "$publisher_count" == "$EXPECTED_PARTICIPANTS" ]] || {
  echo "SFU inspection expected $EXPECTED_PARTICIPANTS active publishers; found $participant_count participants and $publisher_count publishers." >&2
  exit 1
}
jq -e '(.rooms[0].activeRecording // false) == false and ((.rooms[0].metadata // "") == "")' \
  <<<"$room_json" >/dev/null || {
  echo "The product-call room exposed metadata or recording state." >&2
  exit 1
}

participant_list="$(run_lk room participants list "$room_name")"
participant_ids=()
while IFS= read -r identity; do
  [[ -n "$identity" ]] && participant_ids+=("$identity")
done < <(awk '$2 == "(ACTIVE)" { print $1 }' <<<"$participant_list")
[[ "${#participant_ids[@]}" == "$EXPECTED_PARTICIPANTS" ]] || {
  echo "SFU inspection did not find the expected active participant roster." >&2
  exit 1
}

for identity in "${participant_ids[@]}"; do
  if [[ "$REQUIRE_PSEUDONYMOUS_IDENTITIES" == 1 && ! "$identity" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
    echo "An SFU participant identity was not a random base64url identifier." >&2
    exit 1
  fi
  participant_json="$(run_lk room participants get --room "$room_name" --identity "$identity" "$identity")"
  jq -e --arg identity "$identity" '
    .identity == $identity and
    .state == "ACTIVE" and
    .isPublisher == true and
    (.permission.canSubscribe == true) and
    (.permission.canPublish == true) and
    ((.name // "") == "") and
    ((.metadata // "") == "") and
    ([.tracks[] | select(.source == "MICROPHONE")] | length) >= 1 and
    ([.tracks[] | select(.source == "MICROPHONE" and .encryption != "GCM")] | length) == 0
  ' <<<"$participant_json" >/dev/null || {
    echo "An active SFU publisher exposed metadata or a microphone track without GCM E2EE." >&2
    exit 1
  }
done

for forbidden in \
  "${PTT_CALL_CALLER_ACI:-}" "${PTT_CALL_CALLEE_ACI:-}" \
  "${PTT_CALL_CALLER_MAILBOX:-}" "${PTT_CALL_CALLEE_MAILBOX:-}"; do
  [[ -z "$forbidden" ]] && continue
  if grep -Fq "$forbidden" <<<"$room_json$participant_list"; then
    echo "The SFU exposed a forbidden account or mailbox identifier." >&2
    exit 1
  fi
done

echo "SFU inspection passed: $EXPECTED_PARTICIPANTS pseudonymous publishers exposed only GCM-encrypted microphone tracks."
