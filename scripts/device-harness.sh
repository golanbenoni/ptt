#!/usr/bin/env bash
# Start LAN prekey+relay for Android Talk APK + iOS TalkApp (device harness).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-$HOME/.local/opt/jdk-21}"
export PATH="$JAVA_HOME/bin:${PATH}"
cd "$ROOT"
JNI="$ROOT/native/jni"
./gradlew --no-daemon :net:installDist
DIST="$ROOT/tools/net/build/install/net/bin/net"
export JAVA_OPTS="-Djava.library.path=$JNI"
PREKEY="${PREKEY:-8088}"
RELAY="${RELAY:-47000}"
"$DIST" prekey --bind 0.0.0.0 --port "$PREKEY" &
PK=$!
"$DIST" relay --bind 0.0.0.0 --port "$RELAY" &
RL=$!
cleanup() { kill "$PK" "$RL" 2>/dev/null || true; }
trap cleanup EXIT
echo "prekey http://0.0.0.0:$PREKEY  (LAN: http://192.168.1.229:$PREKEY)"
echo "relay  0.0.0.0:$RELAY"
echo "Android/iOS: Listen as Bob on one, Send tone as Alice on the other."
echo "Ctrl-C to stop."
wait
