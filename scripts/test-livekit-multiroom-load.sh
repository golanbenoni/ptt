#!/usr/bin/env bash
# Drive the pinned LiveKit SFU with independent eight-person call rooms.
# The default ten-room shape covers the product acceptance case. Set
# PTT_LIVEKIT_LOAD_ROOMS=32 for the complete 256-device coordination shape.
set -euo pipefail

SERVER_IMAGE="${PTT_LIVEKIT_SERVER_IMAGE:-livekit/livekit-server:v1.13.6}"
CLI_IMAGE="${PTT_LIVEKIT_CLI_IMAGE:-livekit/livekit-cli:v2.18.6}"
ROOMS="${PTT_LIVEKIT_LOAD_ROOMS:-10}"
DURATION="${PTT_LIVEKIT_LOAD_DURATION:-20s}"
MAX_STARTS_PER_SECOND="${PTT_LIVEKIT_LOAD_STARTS_PER_SECOND:-8}"
MAX_CPU_PERCENT="${PTT_LIVEKIT_LOAD_MAX_CPU_PERCENT:-70}"
REQUIRE_CPU_PROBE="${PTT_LIVEKIT_LOAD_REQUIRE_CPU_PROBE:-0}"
CPU_PROBE="${PTT_LIVEKIT_LOAD_CPU_PROBE:-}"
REMOTE_URL="${PTT_LIVEKIT_LOAD_URL:-}"
suffix="$$"
network="ptt-livekit-load-$suffix"
server="ptt-livekit-load-server-$suffix"
work_dir="$(mktemp -d -t ptt-livekit-load.XXXXXX)"
api_key="${PTT_LIVEKIT_LOAD_API_KEY:-ptt-load}"
api_secret="${PTT_LIVEKIT_LOAD_API_SECRET:-ptt-livekit-load-secret-at-least-32-bytes}"
server_started=0
monitor_pid=""
cpu_probe_pid=""
client_names=()

cleanup() {
  local exit_code=$?
  if [[ -n "$monitor_pid" ]]; then
    kill "$monitor_pid" >/dev/null 2>&1 || true
    wait "$monitor_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$cpu_probe_pid" ]]; then
    kill "$cpu_probe_pid" >/dev/null 2>&1 || true
    wait "$cpu_probe_pid" >/dev/null 2>&1 || true
  fi
  for name in "${client_names[@]}"; do
    docker rm -f "$name" >/dev/null 2>&1 || true
  done
  if [[ "$server_started" == 1 ]]; then
    docker rm -f "$server" >/dev/null 2>&1 || true
  fi
  docker network rm "$network" >/dev/null 2>&1 || true
  find "$work_dir" -depth -delete
  return "$exit_code"
}
trap cleanup EXIT INT TERM

case "$SERVER_IMAGE" in
  livekit/livekit-server:v1.13.6|livekit/livekit-server@sha256:*) ;;
  *) echo "Refusing unpinned LiveKit server image: $SERVER_IMAGE" >&2; exit 1 ;;
esac
case "$CLI_IMAGE" in
  livekit/livekit-cli:v2.18.6|livekit/livekit-cli@sha256:*) ;;
  *) echo "Refusing unpinned LiveKit CLI image: $CLI_IMAGE" >&2; exit 1 ;;
esac
if ! [[ "$ROOMS" =~ ^[1-9][0-9]*$ ]] || (( ROOMS > 32 )); then
  echo "PTT_LIVEKIT_LOAD_ROOMS must be between 1 and 32" >&2
  exit 1
fi
[[ "$DURATION" =~ ^[1-9][0-9]*s$ ]] || {
  echo "PTT_LIVEKIT_LOAD_DURATION must be a positive whole number of seconds" >&2
  exit 1
}
[[ "$MAX_STARTS_PER_SECOND" =~ ^[1-9][0-9]*$ ]] || {
  echo "PTT_LIVEKIT_LOAD_STARTS_PER_SECOND must be a positive integer" >&2
  exit 1
}
if ! [[ "$MAX_CPU_PERCENT" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
   ! awk -v limit="$MAX_CPU_PERCENT" 'BEGIN { exit !(limit > 0 && limit <= 100) }'; then
  echo "PTT_LIVEKIT_LOAD_MAX_CPU_PERCENT must be greater than 0 and at most 100" >&2
  exit 1
fi
[[ "$REQUIRE_CPU_PROBE" =~ ^[01]$ ]] || {
  echo "PTT_LIVEKIT_LOAD_REQUIRE_CPU_PROBE must be 0 or 1" >&2
  exit 1
}
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

if [[ -n "$REMOTE_URL" ]]; then
  [[ "$REMOTE_URL" == https://* || "$REMOTE_URL" == wss://* ]] || {
    echo "A remote LiveKit load target must use trusted TLS" >&2
    exit 1
  }
  [[ -n "${PTT_LIVEKIT_LOAD_API_KEY:-}" && -n "${PTT_LIVEKIT_LOAD_API_SECRET:-}" ]] || {
    echo "Remote load testing requires protected LiveKit API credential injection" >&2
    exit 1
  }
  if [[ "$REQUIRE_CPU_PROBE" == 1 && ! -x "$CPU_PROBE" ]]; then
    echo "Remote release load testing requires an executable PTT_LIVEKIT_LOAD_CPU_PROBE" >&2
    exit 1
  fi
  livekit_url="$REMOTE_URL"
else
  docker network create "$network" >/dev/null
  docker run -d --rm --name "$server" --network "$network" \
    "$SERVER_IMAGE" --dev --bind 0.0.0.0 --udp-port 7882 \
    --keys "$api_key: $api_secret" >/dev/null
  server_started=1
  livekit_url="http://$server:7880"
  ready=0
  for _ in $(seq 1 45); do
    if docker run --rm --network "$network" \
      -e LIVEKIT_URL="$livekit_url" -e LIVEKIT_API_KEY="$api_key" \
      -e LIVEKIT_API_SECRET="$api_secret" "$CLI_IMAGE" room list >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  [[ "$ready" == 1 ]] || {
    docker logs --tail 80 "$server" >&2 || true
    echo "Pinned LiveKit node did not become ready" >&2
    exit 1
  }
  server_version="$(docker exec "$server" /livekit-server --version 2>/dev/null || true)"
  [[ "$server_version" == *"1.13.6"* ]] || {
    echo "Unexpected LiveKit server version: $server_version" >&2
    exit 1
  }
  (
    while docker inspect "$server" >/dev/null 2>&1; do
      docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' "$server" \
        >>"$work_dir/server-stats.txt" 2>/dev/null || true
      sleep 1
    done
  ) &
  monitor_pid=$!
fi

if ! docker network inspect "$network" >/dev/null 2>&1; then
  docker network create "$network" >/dev/null
fi

if [[ -n "$REMOTE_URL" && -n "$CPU_PROBE" ]]; then
  "$CPU_PROBE" "$DURATION" >"$work_dir/remote-cpu-percent.txt" &
  cpu_probe_pid=$!
fi

pids=()
for room_index in $(seq 1 "$ROOMS"); do
  room_name="ptt-eight-person-$suffix-$room_index"
  client_name="ptt-livekit-load-client-$suffix-$room_index"
  client_names+=("$client_name")
  docker run --rm --name "$client_name" --network "$network" \
    -e LIVEKIT_URL="$livekit_url" -e LIVEKIT_API_KEY="$api_key" \
    -e LIVEKIT_API_SECRET="$api_secret" "$CLI_IMAGE" perf load-test \
    --room "$room_name" --duration "$DURATION" --audio-publishers 2 \
    --subscribers 6 --num-per-second "$MAX_STARTS_PER_SECOND" --simulate-speakers \
    >"$work_dir/room-$room_index.txt" 2>&1 &
  pids+=("$!")
done

failed=0
for index in "${!pids[@]}"; do
  if ! wait "${pids[$index]}"; then
    echo "LiveKit load client $((index + 1)) failed" >&2
    failed=1
  fi
done

healthy_rooms=0
for room_index in $(seq 1 "$ROOMS"); do
  result="$(<"$work_dir/room-$room_index.txt")"
  total_line="$(grep '│ Total ' <<<"$result" | tail -n 1 || true)"
  if [[ "$total_line" == *"12/12"* && "$total_line" == *"0 (0%)"* && "$total_line" == *"│ 0     │"* ]]; then
    healthy_rooms=$((healthy_rooms + 1))
  else
    printf '%s\n' "$result" >&2
    echo "Room $room_index did not deliver both audio tracks to all six subscribers" >&2
    failed=1
  fi
done

if [[ "$failed" != 0 || "$healthy_rooms" != "$ROOMS" ]]; then
  exit 1
fi

if [[ "$server_started" == 1 ]]; then
  if [[ -n "$monitor_pid" ]]; then
    kill "$monitor_pid" >/dev/null 2>&1 || true
    wait "$monitor_pid" >/dev/null 2>&1 || true
    monitor_pid=""
  fi
  container_peak_cpu="$(awk '
    { value=$1; sub(/%$/, "", value); if (value+0 > max) max=value+0; samples++ }
    END { if (samples == 0) exit 1; printf "%.4f", max+0 }
  ' "$work_dir/server-stats.txt")" || {
    echo "No local LiveKit CPU samples were captured" >&2
    exit 1
  }
  cpu_cores="${PTT_LIVEKIT_MEDIA_CPU_CORES:-$(docker info --format '{{.NCPU}}')}"
  [[ "$cpu_cores" =~ ^[1-9][0-9]*$ ]] || {
    echo "Could not determine the positive LiveKit CPU capacity" >&2
    exit 1
  }
  normalized_cpu="$(awk -v used="$container_peak_cpu" -v cores="$cpu_cores" \
    'BEGIN { printf "%.2f", used / cores }')"
  awk -v actual="$normalized_cpu" -v limit="$MAX_CPU_PERCENT" \
    'BEGIN { exit !(actual <= limit) }' || {
    echo "LiveKit normalized peak CPU ${normalized_cpu}% exceeded ${MAX_CPU_PERCENT}%" >&2
    exit 1
  }
  echo "Pinned LiveKit 1.13.6 sustained $ROOMS eight-person rooms ($((ROOMS * 8)) clients, $((ROOMS * 12)) healthy subscriptions); normalized peak CPU was ${normalized_cpu}% across ${cpu_cores} cores (limit ${MAX_CPU_PERCENT}%)."
else
  if [[ -n "$cpu_probe_pid" ]]; then
    if ! wait "$cpu_probe_pid"; then
      cpu_probe_pid=""
      echo "The remote LiveKit CPU probe failed" >&2
      exit 1
    fi
    cpu_probe_pid=""
    normalized_cpu="$(tr -d '[:space:]' <"$work_dir/remote-cpu-percent.txt")"
    [[ "$normalized_cpu" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
      echo "The remote LiveKit CPU probe did not return one numeric percentage" >&2
      exit 1
    }
    awk -v actual="$normalized_cpu" -v limit="$MAX_CPU_PERCENT" \
      'BEGIN { exit !(actual <= limit) }' || {
      echo "LiveKit normalized sustained CPU ${normalized_cpu}% exceeded ${MAX_CPU_PERCENT}%" >&2
      exit 1
    }
    cpu_summary="; normalized sustained CPU was ${normalized_cpu}% (limit ${MAX_CPU_PERCENT}%)"
  elif [[ "$REQUIRE_CPU_PROBE" == 1 ]]; then
    echo "The required remote LiveKit CPU probe did not run" >&2
    exit 1
  else
    cpu_summary="; CPU evidence was not requested"
  fi
  echo "Remote LiveKit sustained $ROOMS eight-person rooms ($((ROOMS * 8)) clients, $((ROOMS * 12)) healthy subscriptions)${cpu_summary}."
fi
