#!/bin/sh
set -eu

suffix="$$"
network="ptt-control-test-$suffix"
postgres="ptt-control-postgres-$suffix"
redis="ptt-control-redis-$suffix"
minio="ptt-control-minio-$suffix"
control_log=$(mktemp -t ptt-control-test.XXXXXX)
relay_log=$(mktemp -t ptt-relay-test.XXXXXX)
apns_key=$(mktemp -t ptt-apns-key.XXXXXX)
fcm_key=$(mktemp -t ptt-fcm-key.XXXXXX)
control_pid=""
relay_pid=""
push_mock_pid=""
control_port="${PTT_INTEGRATION_PORT:-28083}"
push_mock_port="${PTT_PUSH_MOCK_PORT:-28084}"
grpc_port="${PTT_GRPC_INTEGRATION_PORT:-28085}"
relay_port="${PTT_RELAY_INTEGRATION_PORT:-28086}"
control_bind="${PTT_INTEGRATION_BIND:-127.0.0.1}"
public_base_url="${PTT_INTEGRATION_PUBLIC_BASE_URL:-http://127.0.0.1:$control_port}"

cleanup() {
  if [ -n "$control_pid" ]; then
    kill "$control_pid" 2>/dev/null || true
  fi
  if [ -n "$push_mock_pid" ]; then
    kill "$push_mock_pid" 2>/dev/null || true
  fi
  if [ -n "$relay_pid" ]; then
    kill "$relay_pid" 2>/dev/null || true
  fi
  docker rm -f "$postgres" "$redis" "$minio" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  unlink "$control_log" 2>/dev/null || true
  unlink "$relay_log" 2>/dev/null || true
  unlink "$apns_key" 2>/dev/null || true
  unlink "$fcm_key" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

docker network create "$network" >/dev/null
docker run -d --rm --name "$postgres" --network "$network" \
  -e POSTGRES_PASSWORD=ptt_test -e POSTGRES_DB=ptt \
  -p 127.0.0.1::5432 postgres:17-alpine >/dev/null
docker run -d --rm --name "$redis" --network "$network" \
  -p 127.0.0.1::6379 redis:7-alpine >/dev/null
docker run -d --rm --name "$minio" --network "$network" --network-alias minio \
  -e MINIO_ROOT_USER=ptt \
  -e MINIO_ROOT_PASSWORD=integration-object-store-password \
  -p 127.0.0.1::9000 \
  minio/minio:RELEASE.2025-07-23T15-54-02Z server /data >/dev/null

for _ in $(seq 1 60); do
  docker exec "$postgres" pg_isready -U postgres -d ptt >/dev/null 2>&1 && break
  sleep 1
done
for _ in $(seq 1 60); do
  docker exec "$minio" curl -fsS http://127.0.0.1:9000/minio/health/ready >/dev/null 2>&1 && break
  sleep 1
done

docker run --rm --entrypoint /bin/sh --network "$network" \
  -e MC_CONFIG_DIR=/tmp/.mc minio/mc:RELEASE.2025-07-21T05-28-08Z -c \
  'mc alias set test http://minio:9000 ptt integration-object-store-password >/dev/null && mc mb test/ptt-history >/dev/null'

postgres_port=$(docker port "$postgres" 5432/tcp | awk -F: '{print $NF}')
redis_port=$(docker port "$redis" 6379/tcp | awk -F: '{print $NF}')
minio_port=$(docker port "$minio" 9000/tcp | awk -F: '{print $NF}')

openssl ecparam -name prime256v1 -genkey -noout | \
  openssl pkcs8 -topk8 -nocrypt -out "$apns_key" 2>/dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$fcm_key" 2>/dev/null
python3 -c 'from http.server import BaseHTTPRequestHandler,HTTPServer
from urllib.parse import parse_qs
import json
class Handler(BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    def do_POST(self):
        body=self.rfile.read(int(self.headers.get("content-length","0")))
        if self.path=="/token":
            form=parse_qs(body.decode())
            valid=form.get("grant_type")==["urn:ietf:params:oauth:grant-type:jwt-bearer"] and len(form.get("assertion",[""])[0].split("."))==3
            payload=json.dumps({"access_token":"mock-fcm-access-token","expires_in":3600}).encode() if valid else b"{}"
            self.send_response(200 if valid else 400)
            self.send_header("content-type","application/json")
            self.send_header("content-length",str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path.startswith("/v1/projects/"):
            valid=self.headers.get("authorization")=="Bearer mock-fcm-access-token"
            self.send_response(200 if valid else 401)
            self.send_header("content-length","0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("content-length","0")
        self.end_headers()
    def log_message(self, format, *args): pass
HTTPServer(("127.0.0.1", int(__import__("sys").argv[1])), Handler).serve_forever()' \
  "$push_mock_port" &
push_mock_pid=$!
sleep 1
fcm_json=$(jq -nc --rawfile key "$fcm_key" --arg uri "http://127.0.0.1:$push_mock_port/token" \
  '{type:"service_account",project_id:"ptt-integration",private_key_id:"integration-key",private_key:$key,client_email:"ptt-integration@example.test",token_uri:$uri}')

token_a=integration-token-a
token_b=integration-token-b
token_b2=integration-token-b2
ui_invite=integration-ui-invite
hash_a=$(printf '%s' "$token_a" | shasum -a 256 | awk '{print $1}')
hash_b=$(printf '%s' "$token_b" | shasum -a 256 | awk '{print $1}')
hash_b2=$(printf '%s' "$token_b2" | shasum -a 256 | awk '{print $1}')
ui_invite_hash=$(printf '%s' "$ui_invite" | shasum -a 256 | awk '{print $1}')

PTT_RELAY_BIND="127.0.0.1:$relay_port" \
PTT_RELAY_SHARED_SECRET=integration-relay-secret-at-least-32-bytes \
cargo run --quiet --manifest-path server/Cargo.toml -p ptt-relay --bin ptt-relay >"$relay_log" 2>&1 &
relay_pid=$!

DATABASE_URL="postgres://postgres:ptt_test@127.0.0.1:$postgres_port/ptt" \
PTT_PUBLIC_BASE_URL="$public_base_url" \
PTT_BOOTSTRAP_TOKEN=integration-bootstrap-token-at-least-32-bytes \
PTT_RELAY_SHARED_SECRET=integration-relay-secret-at-least-32-bytes \
PTT_RELAY_PUBLIC_ADDRESS="127.0.0.1:$relay_port" \
PTT_REDIS_URL="redis://127.0.0.1:$redis_port/" \
PTT_OBJECT_STORE_ENDPOINT="http://127.0.0.1:$minio_port" \
PTT_OBJECT_STORE_BUCKET=ptt-history \
PTT_OBJECT_STORE_ACCESS_KEY=ptt \
PTT_OBJECT_STORE_SECRET_KEY=integration-object-store-password \
PTT_APNS_KEY_ID=ABCDEFGHIJ \
PTT_APNS_TEAM_ID=KLMNOPQRST \
PTT_APNS_BUNDLE_ID=app.ptt.talk \
PTT_APNS_PRIVATE_KEY="$(cat "$apns_key")" \
PTT_APNS_ENDPOINT="http://127.0.0.1:$push_mock_port/" \
PTT_FCM_SERVICE_ACCOUNT_JSON="$fcm_json" \
PTT_FCM_ENDPOINT="http://127.0.0.1:$push_mock_port/" \
PTT_CONTROL_BIND="$control_bind:$control_port" \
PTT_GRPC_BIND="127.0.0.1:$grpc_port" \
cargo run --quiet --manifest-path server/Cargo.toml -p ptt-control --bin ptt-control >"$control_log" 2>&1 &
control_pid=$!

for _ in $(seq 1 90); do
  if curl -fsS "http://127.0.0.1:$control_port/readyz" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$control_pid" 2>/dev/null; then
    cat "$control_log"
    exit 1
  fi
  sleep 1
done
if ! curl -fsS "http://127.0.0.1:$control_port/readyz" >/dev/null; then
  cat "$control_log"
  exit 1
fi

docker exec -i "$postgres" psql -v ON_ERROR_STOP=1 -U postgres -d ptt >/dev/null <<SQL
INSERT INTO accounts(aci,email) VALUES
('11111111-1111-4111-8111-111111111111','sender@example.test'),
('22222222-2222-4222-8222-222222222222','recipient@example.test'),
('33333333-3333-4333-8333-333333333333','outsider@example.test');
UPDATE accounts SET is_admin=true WHERE aci='11111111-1111-4111-8111-111111111111';
INSERT INTO devices(aci,device_id,mailbox_id,display_name,identity_key,access_token_sha256,status) VALUES
('11111111-1111-4111-8111-111111111111',1,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Sender',decode(repeat('01',32),'hex'),decode('$hash_a','hex'),'active'),
('22222222-2222-4222-8222-222222222222',1,'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Recipient',decode(repeat('02',32),'hex'),decode('$hash_b','hex'),'active'),
('33333333-3333-4333-8333-333333333333',1,'cccccccc-cccc-4ccc-8ccc-cccccccccccc','Outsider',decode(repeat('03',32),'hex'),decode(repeat('04',32),'hex'),'active');
INSERT INTO channels(channel_id,display_name,kind,distribution_id) VALUES
('44444444-4444-4444-8444-444444444444','Integration','team','dddddddd-dddd-4ddd-8ddd-dddddddddddd');
INSERT INTO memberships(channel_id,aci,role,joined_epoch) VALUES
('44444444-4444-4444-8444-444444444444','11111111-1111-4111-8111-111111111111','talk',1),
('44444444-4444-4444-8444-444444444444','22222222-2222-4222-8222-222222222222','listen',1);
INSERT INTO invitations(id,email,token_sha256,grants_admin,expires_at) VALUES
('77777777-7777-4777-8777-777777777777','ui@example.test',decode('$ui_invite_hash','hex'),false,now()+interval '1 hour');
SQL

# Device/UI tests can ask this disposable stack to pause here. Removing the ready file resumes
# the normal integration suite, so the same process still verifies and cleans up every resource.
if [ -n "${PTT_INTEGRATION_READY_FILE:-}" ]; then
  : > "$PTT_INTEGRATION_READY_FILE"
  while [ -e "$PTT_INTEGRATION_READY_FILE" ]; do
    sleep 1
  done
fi

expires_at=$(date -u -v+5M '+%Y-%m-%dT%H:%M:%SZ')
push_token=$(printf '01234567890123456789012345678901' | base64 | tr '+/' '-_' | tr -d '=')
push_payload=$(jq -nc --arg token "$push_token" '{provider:"apns",token:$token}')
curl -fsS -H "Authorization: Bearer $token_b" -H 'Content-Type: application/json' \
  -d "$push_payload" "http://127.0.0.1:$control_port/v1/push/registrations" >/dev/null
fcm_token=$(printf 'integration-fcm-registration-token' | base64 | tr '+/' '-_' | tr -d '=')
fcm_payload=$(jq -nc --arg token "$fcm_token" '{provider:"fcm",token:$token}')
curl -fsS -H "Authorization: Bearer $token_b" -H 'Content-Type: application/json' \
  -d "$fcm_payload" "http://127.0.0.1:$control_port/v1/push/registrations" >/dev/null
token_reuse_status=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d "$push_payload" "http://127.0.0.1:$control_port/v1/push/registrations")
test "$token_reuse_status" = 409
mailbox_ciphertext=$(printf 'opaque-mailbox-ciphertext' | base64 | tr '+/' '-_' | tr -d '=')
mailbox_payload=$(jq -nc --arg expiry "$expires_at" --arg envelope "$mailbox_ciphertext" \
  '{messageId:"55555555-5555-4555-8555-555555555555",recipients:[{aci:"22222222-2222-4222-8222-222222222222",deviceId:1,envelope:$envelope}],expiresAt:$expiry}')
first=$(curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d "$mailbox_payload" "http://127.0.0.1:$control_port/v1/mailbox/envelopes")
duplicate=$(curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d "$mailbox_payload" "http://127.0.0.1:$control_port/v1/mailbox/envelopes")
test "$(printf '%s' "$first" | jq -r .acceptedRecipients)" = 1
test "$(printf '%s' "$duplicate" | jq -r .acceptedRecipients)" = 0
items=$(curl -fsS -H "Authorization: Bearer $token_b" \
  "http://127.0.0.1:$control_port/v1/mailbox/items?limit=10")
test "$(printf '%s' "$items" | jq 'length')" = 1
item_id=$(printf '%s' "$items" | jq -r '.[0].itemId')
ack=$(jq -nc --arg item "$item_id" '{itemIds:[$item]}' | \
  curl -fsS -H "Authorization: Bearer $token_b" -H 'Content-Type: application/json' \
  -d @- "http://127.0.0.1:$control_port/v1/mailbox/ack")
test "$(printf '%s' "$ack" | jq -r .acknowledged)" = 1
push_outbox_count=$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
  "SELECT count(*) FROM push_outbox WHERE message_id='55555555-5555-4555-8555-555555555555' AND aci='22222222-2222-4222-8222-222222222222' AND provider='apns'")
test "$push_outbox_count" = 1
fcm_outbox_count=$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
  "SELECT count(*) FROM push_outbox WHERE message_id='55555555-5555-4555-8555-555555555555' AND aci='22222222-2222-4222-8222-222222222222' AND provider='fcm'")
test "$fcm_outbox_count" = 1
for _ in $(seq 1 20); do
  push_sent=$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
    "SELECT count(*) FROM push_outbox WHERE message_id='55555555-5555-4555-8555-555555555555' AND sent_at IS NOT NULL")
  test "$push_sent" = 2 && break
  sleep 1
done
test "$push_sent" = 2

relay_request=$(jq -nc '{channelId:"44444444-4444-4444-8444-444444444444"}')
relay_credential=$(curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d "$relay_request" "http://127.0.0.1:$control_port/v1/relay/credentials")
sender_demux=$(printf '%s' "$relay_credential" | jq -r .senderDemux)
test "$sender_demux" -gt 0
recipient_credential=$(curl -fsS -H "Authorization: Bearer $token_b" -H 'Content-Type: application/json' \
  -d "$relay_request" "http://127.0.0.1:$control_port/v1/relay/credentials")

PTT_RELAY_TEST_PORT="$relay_port" \
PTT_RELAY_SENDER_CREDENTIAL="$relay_credential" \
PTT_RELAY_RECIPIENT_CREDENTIAL="$recipient_credential" \
python3 -c 'import base64,hashlib,hmac,json,os,socket,struct,time
port=int(os.environ["PTT_RELAY_TEST_PORT"])
sender=json.loads(os.environ["PTT_RELAY_SENDER_CREDENTIAL"])
recipient=json.loads(os.environ["PTT_RELAY_RECIPIENT_CREDENTIAL"])
target=("127.0.0.1",port)
def decode(value):
    return base64.urlsafe_b64decode(value+"="*((4-len(value)%4)%4))
def bind(sock,credential):
    sock.sendto(b"PTTB"+credential["ticket"].encode(),target)
    data,_=sock.recvfrom(64)
    assert data==b"PTTA"+struct.pack(">I",credential["senderDemux"])
def media(credential,seq,tamper=False):
    packet=bytearray(160)
    packet[0]=1
    packet[1]=8
    packet[2:6]=struct.pack(">I",credential["senderDemux"])
    packet[6:10]=struct.pack(">I",seq)
    packet[-8:]=hmac.new(decode(credential["demuxToken"]),packet[:-8],hashlib.sha256).digest()[:8]
    if tamper: packet[40]^=1
    return bytes(packet)
talker=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
listener=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
attacker=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
for value in (talker,listener,attacker): value.settimeout(0.4)
bind(talker,sender)
bind(listener,recipient)
attacker.sendto(media(sender,1),target)
try: listener.recvfrom(256); raise AssertionError("unbound source was relayed")
except socket.timeout: pass
talker.sendto(media(sender,2,True),target)
try: listener.recvfrom(256); raise AssertionError("bad HMAC was relayed")
except socket.timeout: pass
expected=media(sender,3)
talker.sendto(expected,target)
assert listener.recvfrom(256)[0]==expected
replacement=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
replacement.settimeout(0.5)
bind(replacement,recipient)
expected=media(sender,4)
talker.sendto(expected,target)
assert replacement.recvfrom(256)[0]==expected
try: listener.recvfrom(256); raise AssertionError("old tuple survived rebinding")
except socket.timeout: pass
for value in (talker,listener,attacker,replacement): value.close()'

PTT_GRPC_ENDPOINT="http://127.0.0.1:$grpc_port" \
PTT_GRPC_SENDER_ACI=11111111-1111-4111-8111-111111111111 \
PTT_GRPC_SENDER_DEVICE_ID=1 \
PTT_GRPC_SENDER_MAILBOX_ID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa \
PTT_GRPC_SENDER_TOKEN="$token_a" \
PTT_GRPC_RECIPIENT_ACI=22222222-2222-4222-8222-222222222222 \
PTT_GRPC_RECIPIENT_DEVICE_ID=1 \
PTT_GRPC_RECIPIENT_MAILBOX_ID=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb \
PTT_GRPC_RECIPIENT_TOKEN="$token_b" \
PTT_GRPC_CHANNEL_ID=44444444-4444-4444-8444-444444444444 \
PTT_GRPC_SENDER_DEMUX="$sender_demux" \
cargo run --quiet --manifest-path server/Cargo.toml -p ptt-control --bin grpc-smoke

started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
history_ciphertext=$(printf 'encrypted-history-object' | base64 | tr '+/' '-_' | tr -d '=')
history_payload=$(jq -nc --arg started "$started_at" --arg ciphertext "$history_ciphertext" \
  '{talkId:"66666666-6666-4666-8666-666666666666",channelId:"44444444-4444-4444-8444-444444444444",membershipEpoch:1,mediaKid:"18446744073709551615",startedAt:$started,durationMs:2000,ciphertext:$ciphertext}')
created=$(curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d "$history_payload" "http://127.0.0.1:$control_port/v1/history/objects")
object_id=$(printf '%s' "$created" | jq -r .objectId)
test "$object_id" != null
repeated=$(curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d "$history_payload" "http://127.0.0.1:$control_port/v1/history/objects")
test "$(printf '%s' "$repeated" | jq -r .objectId)" = "$object_id"
different=$(printf '%s' "$history_payload" | jq '.ciphertext="ZGlmZmVyZW50"')
different_status=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d "$different" "http://127.0.0.1:$control_port/v1/history/objects")
test "$different_status" = 409
listed=$(curl -fsS -G -H "Authorization: Bearer $token_b" \
  --data-urlencode channelId=44444444-4444-4444-8444-444444444444 \
  --data-urlencode limit=10 "http://127.0.0.1:$control_port/v1/history/objects")
test "$(printf '%s' "$listed" | jq 'length')" = 1
downloaded=$(curl -fsS -H "Authorization: Bearer $token_b" \
  "http://127.0.0.1:$control_port/v1/history/objects/$object_id")
test "$(printf '%s' "$downloaded" | jq -r .ciphertext)" = "$history_ciphertext"

recovery_request=$(jq -nc '{email:"recipient@example.test"}')
curl -fsS -H 'Content-Type: application/json' -d "$recovery_request" \
  "http://127.0.0.1:$control_port/v1/auth/recovery/request" >/dev/null
recovery_url=$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
  "SELECT payload->>'url' FROM email_outbox WHERE template='recovery_link' ORDER BY created_at DESC LIMIT 1")
recovery_email_token=${recovery_url##*token=}
test -n "$recovery_email_token"
recovery_identity=$(printf 'recovered-device-identity-key-32' | base64 | tr '+/' '-_' | tr -d '=')
recovery_consume=$(jq -nc --arg token "$recovery_email_token" --arg key "$recovery_identity" \
  '{token:$token,deviceName:"Recovered Device",identityKey:$key}' | \
  curl -fsS -H 'Content-Type: application/json' -d @- \
    "http://127.0.0.1:$control_port/v1/auth/recovery/consume")
recovery_id=$(printf '%s' "$recovery_consume" | jq -r .requestId)
recovered_token=$(printf '%s' "$recovery_consume" | jq -r .claimToken)
pending_recovery=$(jq -nc --arg id "$recovery_id" --arg token "$recovered_token" \
  '{requestId:$id,claimToken:$token}' | \
  curl -fsS -H 'Content-Type: application/json' -d @- \
    "http://127.0.0.1:$control_port/v1/auth/recovery/status")
test "$(printf '%s' "$pending_recovery" | jq -r .status)" = pending_admin
recovery_count=$(curl -fsS -H "Authorization: Bearer $token_a" \
  "http://127.0.0.1:$control_port/v1/admin/recoveries" | jq 'length')
test "$recovery_count" = 1
recovery_decision=$(jq -nc --arg id "$recovery_id" '{requestId:$id,approve:true}')
curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d "$recovery_decision" "http://127.0.0.1:$control_port/v1/admin/recoveries/decision" >/dev/null
approved_recovery=$(jq -nc --arg id "$recovery_id" --arg token "$recovered_token" \
  '{requestId:$id,claimToken:$token}' | \
  curl -fsS -H 'Content-Type: application/json' -d @- \
    "http://127.0.0.1:$control_port/v1/auth/recovery/status")
test "$(printf '%s' "$approved_recovery" | jq -r .status)" = approved
test "$(printf '%s' "$approved_recovery" | jq -r .deviceId)" = 1
old_token_status=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token_b" \
  "http://127.0.0.1:$control_port/v1/devices")
test "$old_token_status" = 401
recovered_history=$(curl -fsS -G -H "Authorization: Bearer $recovered_token" \
  --data-urlencode channelId=44444444-4444-4444-8444-444444444444 \
  "http://127.0.0.1:$control_port/v1/history/objects")
test "$(printf '%s' "$recovered_history" | jq 'length')" = 0

docker exec -i "$postgres" psql -v ON_ERROR_STOP=1 -U postgres -d ptt >/dev/null <<SQL
INSERT INTO devices(aci,device_id,mailbox_id,display_name,identity_key,access_token_sha256,status) VALUES
('22222222-2222-4222-8222-222222222222',2,'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','New Device',decode(repeat('05',32),'hex'),decode('$hash_b2','hex'),'active');
SQL
new_device_list=$(curl -fsS -G -H "Authorization: Bearer $token_b2" \
  --data-urlencode channelId=44444444-4444-4444-8444-444444444444 \
  "http://127.0.0.1:$control_port/v1/history/objects")
test "$(printf '%s' "$new_device_list" | jq 'length')" = 0

docker exec "$postgres" psql -v ON_ERROR_STOP=1 -U postgres -d ptt -c \
  "UPDATE memberships SET left_epoch=2 WHERE channel_id='44444444-4444-4444-8444-444444444444' AND aci='22222222-2222-4222-8222-222222222222'" >/dev/null
removed_status=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $recovered_token" \
  "http://127.0.0.1:$control_port/v1/history/objects/$object_id")
test "$removed_status" = 403

link_start=$(curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d '{}' "http://127.0.0.1:$control_port/v1/devices/link/start")
link_request_id=$(printf '%s' "$link_start" | jq -r .requestId)
link_code=$(printf '%s' "$link_start" | jq -r .linkCode)
linked_identity=$(printf 'linked-device-identity-key-value' | base64 | tr '+/' '-_' | tr -d '=')
link_claim=$(jq -nc --arg id "$link_request_id" --arg code "$link_code" --arg key "$linked_identity" \
  '{requestId:$id,linkCode:$code,deviceName:"Sender Tablet",identityKey:$key}' | \
  curl -fsS -H 'Content-Type: application/json' -d @- \
    "http://127.0.0.1:$control_port/v1/devices/link/claim")
linked_token=$(printf '%s' "$link_claim" | jq -r .claimToken)
test "$(printf '%s' "$link_claim" | jq -r .deviceId)" = 2
pending_link=$(jq -nc --arg token "$linked_token" '{claimToken:$token}' | \
  curl -fsS -H 'Content-Type: application/json' -d @- \
    "http://127.0.0.1:$control_port/v1/devices/link/status")
test "$(printf '%s' "$pending_link" | jq -r .status)" = pending
curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg id "$link_request_id" '{requestId:$id}')" \
  "http://127.0.0.1:$control_port/v1/devices/link/approve" >/dev/null
active_link=$(jq -nc --arg token "$linked_token" '{claimToken:$token}' | \
  curl -fsS -H 'Content-Type: application/json' -d @- \
    "http://127.0.0.1:$control_port/v1/devices/link/status")
test "$(printf '%s' "$active_link" | jq -r .status)" = active
linked_history=$(curl -fsS -G -H "Authorization: Bearer $linked_token" \
  --data-urlencode channelId=44444444-4444-4444-8444-444444444444 \
  "http://127.0.0.1:$control_port/v1/history/objects")
test "$(printf '%s' "$linked_history" | jq 'length')" = 0
test "$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
  "SELECT membership_epoch FROM channels WHERE channel_id='44444444-4444-4444-8444-444444444444'")" = 3

printf '%s\n' \
  'fresh migration: ok' \
  'mailbox delivery and acknowledgement: ok' \
  'bidirectional gRPC envelope, floor lifecycle, and TLS media fallback: ok' \
  'UDP relay binding, HMAC, source rejection, fan-out, and rebinding: ok' \
  'APNs/FCM JWT dispatch, registration uniqueness, and wake deduplication: ok' \
  'S3 Signature V4 ciphertext round trip: ok' \
  'idempotency and talk-id reuse protection: ok' \
  'email plus independent-admin recovery, revocation, and epoch rotation: ok' \
  'new-device old-history exclusion: ok' \
  'removed-member history denial: ok' \
  'two-device approval, activation, epoch rotation, and no-old-history access: ok'
