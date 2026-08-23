#!/usr/bin/env bash
# Two OS processes through prekey HTTP + UDP relay (phone architecture, no UI).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/java21-env.sh"
cd "$ROOT"
JNI="$ROOT/native/jni"
GRADLE=(./gradlew --no-daemon)
"${GRADLE[@]}" :net:installDist
DIST="$ROOT/tools/net/build/install/net/bin/net"
export JAVA_OPTS="-Djava.library.path=$JNI"
PREKEY=18088
RELAY=47011
"$DIST" prekey --port "$PREKEY" &
PK=$!
"$DIST" relay --port "$RELAY" &
RL=$!
cleanup() { kill "$PK" "$RL" 2>/dev/null || true; }
trap cleanup EXIT
sleep 0.4
OUT="$ROOT/build/two-process-bob.wav"
"$DIST" recv --prekey "http://127.0.0.1:$PREKEY" --relay "127.0.0.1:$RELAY" --out "$OUT" &
RV=$!
sleep 0.3
"$DIST" send --prekey "http://127.0.0.1:$PREKEY" --relay "127.0.0.1:$RELAY" --ms 400
wait "$RV"
echo "wav=$OUT"
ls -l "$OUT"
