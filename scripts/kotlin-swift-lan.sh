#!/usr/bin/env bash
# Kotlin Alice (this Linux host) <-> Swift Bob (SuperMac01) through LAN prekey+relay.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-$HOME/.local/opt/jdk-21}"
export PATH="$JAVA_HOME/bin:${PATH}"
cd "$ROOT"

HOST="${HOST:-192.168.1.229}"
PREKEY="${PREKEY:-8088}"
RELAY="${RELAY:-47000}"
MAC="${MAC:-supermac01}"
PTT_MAC="${PTT_MAC:-/Users/golanbenoni/src/ptt}"
JNI="$ROOT/native/jni"

./gradlew --no-daemon :net:installDist
DIST="$ROOT/tools/net/build/install/net/bin/net"
export JAVA_OPTS="-Djava.library.path=$JNI"

"$DIST" prekey --bind 0.0.0.0 --port "$PREKEY" &
PK=$!
"$DIST" relay --bind 0.0.0.0 --port "$RELAY" &
RL=$!
cleanup() {
  kill "$PK" "$RL" 2>/dev/null || true
  ssh "$MAC" 'pkill -f "PttTalk recv" 2>/dev/null || true' || true
}
trap cleanup EXIT
sleep 0.4

OUT_MAC=/tmp/ptt-bob.wav
ssh "$MAC" "rm -f $OUT_MAC; export PATH=\"\$HOME/.cargo/bin:/opt/homebrew/bin:\$PATH\"; \
  export LIBSIGNAL_SWIFT=\$HOME/src/libsignal/swift; \
  export LIBSIGNAL_FFI=\$HOME/src/libsignal/target/debug; \
  cd $PTT_MAC/ios/PttTalk && \
  BIN=\$(swift build -c debug --show-bin-path)/PttTalk && \
  exec \"\$BIN\" recv --prekey http://$HOST:$PREKEY --relay $HOST:$RELAY --out $OUT_MAC" \
  > /tmp/ptt-swift-recv.log 2>&1 &
RV=$!

for i in $(seq 1 60); do
  if grep -q listening /tmp/ptt-swift-recv.log 2>/dev/null; then
    break
  fi
  if ! kill -0 "$RV" 2>/dev/null; then
    echo "swift recv exited early:" >&2
    cat /tmp/ptt-swift-recv.log >&2
    exit 1
  fi
  sleep 0.5
done
if ! grep -q listening /tmp/ptt-swift-recv.log 2>/dev/null; then
  echo "swift recv never printed listening:" >&2
  cat /tmp/ptt-swift-recv.log >&2
  exit 1
fi

"$DIST" send --prekey "http://127.0.0.1:$PREKEY" --relay "127.0.0.1:$RELAY" \
  --ms 400 --pace-ms 5 --bind-wait-ms 300
wait "$RV"
echo "---- swift recv ----"
cat /tmp/ptt-swift-recv.log

# Reverse: Swift Alice -> Kotlin Bob (Swift is the PQXDH initiator).
OUT_KV="$ROOT/build/kotlin-swift-bob.wav"
mkdir -p "$ROOT/build"
"$DIST" recv --prekey "http://127.0.0.1:$PREKEY" --relay "127.0.0.1:$RELAY" --out "$OUT_KV" \
  > /tmp/ptt-kotlin-recv.log 2>&1 &
KR=$!
sleep 0.8
ssh "$MAC" "export PATH=\"\$HOME/.cargo/bin:/opt/homebrew/bin:\$PATH\"; \
  cd $PTT_MAC/ios/PttTalk && BIN=\$(swift build -c debug --show-bin-path)/PttTalk && \
  \"\$BIN\" send --prekey http://$HOST:$PREKEY --relay $HOST:$RELAY --ms 400 --pace-ms 5 --bind-wait-ms 300"
wait "$KR"
echo "---- kotlin recv ----"
cat /tmp/ptt-kotlin-recv.log
echo "ok kotlin-swift-lan"
