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
metrics_port="${PTT_METRICS_INTEGRATION_PORT:-28087}"
control_bind="${PTT_INTEGRATION_BIND:-127.0.0.1}"
relay_bind="${PTT_RELAY_INTEGRATION_BIND:-127.0.0.1}"
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
            message=json.loads(body or b"{}").get("message",{})
            kind=message.get("data",{}).get("kind")
            valid=self.headers.get("authorization")=="Bearer mock-fcm-access-token" and kind in ("mailbox","voice")
            self.send_response(200 if valid else 401)
            self.send_header("content-length","0")
            self.end_headers()
            return
        if self.path.startswith("/3/device/"):
            payload=json.loads(body or b"{}")
            push_type=self.headers.get("apns-push-type")
            valid=(push_type=="pushtotalk" and payload.get("kind")=="voice" and "aps" not in payload) or (push_type=="background" and payload.get("kind")=="mailbox" and payload.get("aps",{}).get("content-available")==1)
            self.send_response(200 if valid else 400)
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
token_outsider=integration-token-outsider
ui_invite=integration-ui-invite
hash_a=$(printf '%s' "$token_a" | shasum -a 256 | awk '{print $1}')
hash_b=$(printf '%s' "$token_b" | shasum -a 256 | awk '{print $1}')
hash_b2=$(printf '%s' "$token_b2" | shasum -a 256 | awk '{print $1}')
hash_outsider=$(printf '%s' "$token_outsider" | shasum -a 256 | awk '{print $1}')
ui_invite_hash=$(printf '%s' "$ui_invite" | shasum -a 256 | awk '{print $1}')

PTT_RELAY_BIND="$relay_bind:$relay_port" \
PTT_RELAY_SHARED_SECRET=integration-relay-secret-at-least-32-bytes \
PTT_REDIS_URL="redis://127.0.0.1:$redis_port/" \
cargo run --quiet --manifest-path server/Cargo.toml -p ptt-relay --bin ptt-relay >"$relay_log" 2>&1 &
relay_pid=$!

DATABASE_URL="postgres://postgres:ptt_test@127.0.0.1:$postgres_port/ptt" \
PTT_PUBLIC_BASE_URL="$public_base_url" \
PTT_BOOTSTRAP_TOKEN=integration-bootstrap-token-at-least-32-bytes \
PTT_RELAY_SHARED_SECRET=integration-relay-secret-at-least-32-bytes \
PTT_RELAY_PUBLIC_ADDRESS="${PTT_RELAY_PUBLIC_ADDRESS:-127.0.0.1:$relay_port}" \
PTT_REDIS_URL="redis://127.0.0.1:$redis_port/" \
PTT_OBJECT_STORE_ENDPOINT="http://127.0.0.1:$minio_port" \
PTT_OBJECT_STORE_BUCKET=ptt-history \
PTT_OBJECT_STORE_ACCESS_KEY=ptt \
PTT_OBJECT_STORE_SECRET_KEY=integration-object-store-password \
PTT_APNS_PRODUCTION_KEY_ID=ABCDEFGHIJ \
PTT_APNS_SANDBOX_KEY_ID=UVWXYZ1234 \
PTT_APNS_TEAM_ID=KLMNOPQRST \
PTT_APNS_BUNDLE_ID=app.ptt.talk \
PTT_APNS_PRODUCTION_PRIVATE_KEY="$(cat "$apns_key")" \
PTT_APNS_SANDBOX_PRIVATE_KEY="$(cat "$apns_key")" \
PTT_APNS_PRODUCTION_ENDPOINT="http://127.0.0.1:$push_mock_port/" \
PTT_APNS_SANDBOX_ENDPOINT="http://127.0.0.1:$push_mock_port/" \
PTT_FCM_SERVICE_ACCOUNT_JSON="$fcm_json" \
PTT_FCM_ENDPOINT="http://127.0.0.1:$push_mock_port/" \
PTT_BACKUP_SCHEDULE="15 2 * * *" \
PTT_CONTROL_BIND="$control_bind:$control_port" \
PTT_GRPC_BIND="127.0.0.1:$grpc_port" \
PTT_METRICS_BIND="127.0.0.1:$metrics_port" \
PTT_METRICS_TOKEN=integration-metrics-token-at-least-32-bytes \
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
('33333333-3333-4333-8333-333333333333',1,'cccccccc-cccc-4ccc-8ccc-cccccccccccc','Outsider',decode(repeat('03',32),'hex'),decode('$hash_outsider','hex'),'active');
INSERT INTO channels(channel_id,display_name,kind,distribution_id) VALUES
('44444444-4444-4444-8444-444444444444','Integration','team','dddddddd-dddd-4ddd-8ddd-dddddddddddd');
INSERT INTO memberships(channel_id,aci,role,joined_epoch) VALUES
('44444444-4444-4444-8444-444444444444','11111111-1111-4111-8111-111111111111','talk',1),
('44444444-4444-4444-8444-444444444444','22222222-2222-4222-8222-222222222222','listen',1);
INSERT INTO invitations(id,email,token_sha256,grants_admin,expires_at) VALUES
('77777777-7777-4777-8777-777777777777','ui@example.test',decode('$ui_invite_hash','hex'),false,now()+interval '1 hour');
SQL

test "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$metrics_port/metrics")" = 401
metrics=$(curl -fsS -H 'Authorization: Bearer integration-metrics-token-at-least-32-bytes' \
  "http://127.0.0.1:$metrics_port/metrics")
test "$(printf '%s' "$metrics" | awk '$1 == "ptt_accounts" { print $2 }')" = 3
test "$(printf '%s' "$metrics" | awk '$1 == "ptt_active_devices" { print $2 }')" = 3
if printf '%s' "$metrics" | grep -Eq '(aci|email=|channel_id|device_id)'; then
  echo 'metrics exposed identifying labels' >&2
  exit 1
fi

# Device/UI tests can ask this disposable stack to pause here. Removing the ready file resumes
# the normal integration suite, so the same process still verifies and cleans up every resource.
if [ -n "${PTT_INTEGRATION_READY_FILE:-}" ]; then
  : > "$PTT_INTEGRATION_READY_FILE"
  while [ -e "$PTT_INTEGRATION_READY_FILE" ]; do
    sleep 1
  done
fi

prekey_bundle=$(printf 'opaque-signed-prekey-bundle-at-least-32-bytes' | base64 | tr '+/' '-_' | tr -d '=')
x25519_key=$(printf '01234567890123456789012345678901' | base64 | tr '+/' '-_' | tr -d '=')
kyber_key=$(python3 -c 'import base64; print(base64.urlsafe_b64encode(bytes(range(64))).decode().rstrip("="))')
prekey_upload=$(jq -nc --arg bundle "$prekey_bundle" --arg x "$x25519_key" --arg k "$kyber_key" \
  '{opaqueBundle:$bundle,oneTimePrekeys:[{kind:"x25519",keyId:7,publicKey:$x},{kind:"kyber",keyId:8,publicKey:$k}]}')
curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d "$prekey_upload" "http://127.0.0.1:$control_port/v1/prekeys/upload" >/dev/null
prekey_fetch=$(jq -nc '{devices:[{aci:"11111111-1111-4111-8111-111111111111",deviceId:1}]}' | \
  curl -fsS -H "Authorization: Bearer $token_b" -H 'Content-Type: application/json' -d @- \
    "http://127.0.0.1:$control_port/v1/prekeys/fetch")
test "$(printf '%s' "$prekey_fetch" | jq -r '.[0].opaqueBundle')" = "$prekey_bundle"
test "$(printf '%s' "$prekey_fetch" | jq -r '[.[0].oneTimePrekeys[].keyId] | sort | join(",")')" = "7,8"
prekey_second=$(jq -nc '{devices:[{aci:"11111111-1111-4111-8111-111111111111",deviceId:1}]}' | \
  curl -fsS -H "Authorization: Bearer $token_b" -H 'Content-Type: application/json' -d @- \
    "http://127.0.0.1:$control_port/v1/prekeys/fetch")
test "$(printf '%s' "$prekey_second" | jq '.[0].oneTimePrekeys | length')" = 0
different_x=$(printf 'abcdefghijklmnopqrstuvwxyzABCDEF' | base64 | tr '+/' '-_' | tr -d '=')
prekey_reuse=$(printf '%s' "$prekey_upload" | jq --arg x "$different_x" '.oneTimePrekeys=[{kind:"x25519",keyId:7,publicKey:$x}]')
prekey_reuse_status=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d "$prekey_reuse" "http://127.0.0.1:$control_port/v1/prekeys/upload")
test "$prekey_reuse_status" = 409
channel_devices=$(curl -fsS -H "Authorization: Bearer $token_a" \
  "http://127.0.0.1:$control_port/v1/channels/44444444-4444-4444-8444-444444444444/devices")
test "$(printf '%s' "$channel_devices" | jq 'length')" = 2
test "$(printf '%s' "$channel_devices" | jq -r 'map(.deviceId) | sort | join(",")')" = "1,1"
device_channels=$(curl -fsS -H "Authorization: Bearer $token_b" \
  "http://127.0.0.1:$control_port/v1/channels")
test "$(printf '%s' "$device_channels" | jq 'length')" = 1
test "$(printf '%s' "$device_channels" | jq -r '.[0].distributionId | test("^[0-9a-f-]{36}$")')" = true
test "$(printf '%s' "$device_channels" | jq -r '.[0].membershipEpoch')" = 1
outsider_devices_status=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $token_outsider" \
  "http://127.0.0.1:$control_port/v1/channels/44444444-4444-4444-8444-444444444444/devices")
test "$outsider_devices_status" = 403
curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d '{"mode":"busy"}' "http://127.0.0.1:$control_port/v1/presence" >/dev/null
presence_value=$(docker exec "$redis" redis-cli GET \
  ptt:v1:presence:11111111-1111-4111-8111-111111111111:1 | tr -d '\r')
test "$presence_value" = 2
invalid_presence_status=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d '{"mode":"invisible"}' "http://127.0.0.1:$control_port/v1/presence")
test "$invalid_presence_status" = 400

admin_devices=$(curl -fsS -H "Authorization: Bearer $token_a" \
  "http://127.0.0.1:$control_port/v1/admin/devices")
test "$(printf '%s' "$admin_devices" | jq 'length')" = 3
operations=$(curl -fsS -H "Authorization: Bearer $token_a" \
  "http://127.0.0.1:$control_port/v1/admin/operations")
test "$(printf '%s' "$operations" | jq -r .fcmConfigured)" = true
test "$(printf '%s' "$operations" | jq -r .apnsConfigured)" = true
test "$(printf '%s' "$operations" | jq -r .backupConfigured)" = true
test "$(printf '%s' "$operations" | jq -r '.configurationFingerprint | length')" = 24
updated_channel=$(jq -nc '{channelId:"44444444-4444-4444-8444-444444444444",displayName:"Integration Ops",retentionDays:45}' | \
  curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' -d @- \
    "http://127.0.0.1:$control_port/v1/admin/channels/config")
test "$(printf '%s' "$updated_channel" | jq -r .displayName)" = "Integration Ops"
test "$(printf '%s' "$updated_channel" | jq -r .retentionDays)" = 45
channel_members=$(curl -fsS -H "Authorization: Bearer $token_a" \
  "http://127.0.0.1:$control_port/v1/admin/channels/members?channelId=44444444-4444-4444-8444-444444444444")
test "$(printf '%s' "$channel_members" | jq 'length')" = 2
test "$(printf '%s' "$channel_members" | jq -r 'map(.role) | sort | join(",")')" = "listen,talk"
unknown_channel_members_status=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $token_a" \
  "http://127.0.0.1:$control_port/v1/admin/channels/members?channelId=99999999-9999-4999-8999-999999999999")
test "$unknown_channel_members_status" = 400
invalid_direct_status=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d '{"displayName":"Invalid direct","kind":"direct","retentionDays":30,"members":[{"aci":"11111111-1111-4111-8111-111111111111","role":"talk"}]}' \
  "http://127.0.0.1:$control_port/v1/admin/channels")
test "$invalid_direct_status" = 400
direct_channel=$(curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d '{"displayName":"Sender and recipient","kind":"direct","retentionDays":30,"members":[{"aci":"11111111-1111-4111-8111-111111111111","role":"talk"},{"aci":"22222222-2222-4222-8222-222222222222","role":"talk"}]}' \
  "http://127.0.0.1:$control_port/v1/admin/channels")
test "$(printf '%s' "$direct_channel" | jq -r .kind)" = direct
test "$(printf '%s' "$direct_channel" | jq -r .activeMembers)" = 2
last_admin_status=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d '{"aci":"11111111-1111-4111-8111-111111111111","deviceId":1}' \
  "http://127.0.0.1:$control_port/v1/admin/devices/revoke")
test "$last_admin_status" = 409
curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d '{"aci":"33333333-3333-4333-8333-333333333333","deviceId":1}' \
  "http://127.0.0.1:$control_port/v1/admin/devices/revoke" >/dev/null
revoked_outsider_status=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $token_outsider" "http://127.0.0.1:$control_port/v1/devices")
test "$revoked_outsider_status" = 401
audit_events=$(curl -fsS -H "Authorization: Bearer $token_a" \
  "http://127.0.0.1:$control_port/v1/admin/audit?limit=20")
test "$(printf '%s' "$audit_events" | jq '[.[].action] | contains(["channel.config_changed","device.revoked"])')" = true

expires_at=$(date -u -v+5M '+%Y-%m-%dT%H:%M:%SZ')
push_token=$(printf '01234567890123456789012345678901' | base64 | tr '+/' '-_' | tr -d '=')
push_payload=$(jq -nc --arg token "$push_token" '{provider:"apns",token:$token}')
curl -fsS -H "Authorization: Bearer $token_b" -H 'Content-Type: application/json' \
  -d "$push_payload" "http://127.0.0.1:$control_port/v1/push/registrations" >/dev/null
sandbox_push_token=$(printf 'sandbox-ptt-01234567890123456789' | base64 | tr '+/' '-_' | tr -d '=')
sandbox_push_payload=$(jq -nc --arg token "$sandbox_push_token" \
  '{provider:"apns-ptt-sandbox",token:$token,channelId:"44444444-4444-4444-8444-444444444444"}')
curl -fsS -H "Authorization: Bearer $token_b" -H 'Content-Type: application/json' \
  -d "$sandbox_push_payload" "http://127.0.0.1:$control_port/v1/push/registrations" >/dev/null
test "$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
  "SELECT channel_id FROM push_registrations WHERE aci='22222222-2222-4222-8222-222222222222' AND device_id=1 AND provider='apns-ptt-sandbox'")" = "44444444-4444-4444-8444-444444444444"
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
sandbox_outbox_count=$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
  "SELECT count(*) FROM push_outbox WHERE message_id='55555555-5555-4555-8555-555555555555' AND aci='22222222-2222-4222-8222-222222222222' AND provider='apns-ptt-sandbox'")
test "$sandbox_outbox_count" = 0
mailbox_kind_count=$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
  "SELECT count(*) FROM push_outbox WHERE message_id='55555555-5555-4555-8555-555555555555' AND kind='mailbox'")
test "$mailbox_kind_count" = 2
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
sender_demux_token=$(printf '%s' "$relay_credential" | jq -r .demuxToken)
test "$sender_demux" -gt 0
recipient_credential=$(curl -fsS -H "Authorization: Bearer $token_b" -H 'Content-Type: application/json' \
  -d "$relay_request" "http://127.0.0.1:$control_port/v1/relay/credentials")

normal_floor_token=$(printf 'normal-floor-001' | base64 | tr '+/' '-_' | tr -d '=')
normal_floor=$(jq -nc --arg token "$normal_floor_token" --argjson demux "$sender_demux" \
  '{channelId:"44444444-4444-4444-8444-444444444444",requestToken:$token,senderDemux:$demux,membershipEpoch:1,requestedTotMs:30000,sos:false}' | \
  curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' -d @- \
    "http://127.0.0.1:$control_port/v1/floor/request")
test "$(printf '%s' "$normal_floor" | jq -r .granted)" = true
test "$(printf '%s' "$normal_floor" | jq -r .priority)" = 0
duplicate_normal_floor=$(jq -nc --arg token "$normal_floor_token" --argjson demux "$sender_demux" \
  '{channelId:"44444444-4444-4444-8444-444444444444",requestToken:$token,senderDemux:$demux,membershipEpoch:1,requestedTotMs:30000,sos:false}' | \
  curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' -d @- \
    "http://127.0.0.1:$control_port/v1/floor/request")
test "$(printf '%s' "$duplicate_normal_floor" | jq -r .granted)" = true
for _ in $(seq 1 20); do
  voice_outbox_count=$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
    "SELECT count(*) FROM push_outbox WHERE kind='voice' AND aci='22222222-2222-4222-8222-222222222222'")
  test "$voice_outbox_count" = 2 && break
  sleep 1
done
test "$voice_outbox_count" = 2
test "$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
  "SELECT string_agg(provider,',' ORDER BY provider) FROM push_outbox WHERE kind='voice' AND aci='22222222-2222-4222-8222-222222222222'")" = "apns-ptt-sandbox,fcm"
for _ in $(seq 1 20); do
  voice_push_sent=$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
    "SELECT count(*) FROM push_outbox WHERE kind='voice' AND aci='22222222-2222-4222-8222-222222222222' AND sent_at IS NOT NULL")
  test "$voice_push_sent" = 2 && break
  sleep 1
done
test "$voice_push_sent" = 2
sos_floor_token=$(printf 'sos-floor-token1' | base64 | tr '+/' '-_' | tr -d '=')
recipient_demux=$(printf '%s' "$recipient_credential" | jq -r .senderDemux)
docker exec "$postgres" psql -v ON_ERROR_STOP=1 -U postgres -d ptt -c \
  "UPDATE memberships SET role='talk' WHERE channel_id='44444444-4444-4444-8444-444444444444' AND aci='22222222-2222-4222-8222-222222222222'" >/dev/null
sos_floor=$(jq -nc --arg token "$sos_floor_token" --argjson demux "$recipient_demux" \
  '{channelId:"44444444-4444-4444-8444-444444444444",requestToken:$token,senderDemux:$demux,membershipEpoch:1,requestedTotMs:1000,sos:true}' | \
  curl -fsS -H "Authorization: Bearer $token_b" -H 'Content-Type: application/json' -d @- \
    "http://127.0.0.1:$control_port/v1/floor/request")
test "$(printf '%s' "$sos_floor" | jq -r .granted)" = true
test "$(printf '%s' "$sos_floor" | jq -r .priority)" = 3
curl -fsS -H "Authorization: Bearer $token_b" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg token "$sos_floor_token" '{channelId:"44444444-4444-4444-8444-444444444444",requestToken:$token}')" \
  "http://127.0.0.1:$control_port/v1/floor/release" >/dev/null
docker exec "$postgres" psql -v ON_ERROR_STOP=1 -U postgres -d ptt -c \
  "UPDATE memberships SET role='listen' WHERE channel_id='44444444-4444-4444-8444-444444444444' AND aci='22222222-2222-4222-8222-222222222222'" >/dev/null

# SOS preemption ends the prior speaker's floor lease. The original speaker must
# request a fresh grant before the relay is allowed to fan out any more media.
resumed_floor_token=$(printf 'normal-floor-002' | base64 | tr '+/' '-_' | tr -d '=')
resumed_floor=$(jq -nc --arg token "$resumed_floor_token" --argjson demux "$sender_demux" \
  '{channelId:"44444444-4444-4444-8444-444444444444",requestToken:$token,senderDemux:$demux,membershipEpoch:1,requestedTotMs:30000,sos:false}' | \
  curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' -d @- \
    "http://127.0.0.1:$control_port/v1/floor/request")
test "$(printf '%s' "$resumed_floor" | jq -r .granted)" = true

if ! kill -0 "$relay_pid" 2>/dev/null; then
  cat "$relay_log"
  exit 1
fi

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

curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg token "$resumed_floor_token" '{channelId:"44444444-4444-4444-8444-444444444444",requestToken:$token}')" \
  "http://127.0.0.1:$control_port/v1/floor/release" >/dev/null

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
PTT_GRPC_SENDER_DEMUX_TOKEN="$sender_demux_token" \
PTT_WS_ENDPOINT="ws://127.0.0.1:$control_port/v1/media/tunnel?channelId=44444444-4444-4444-8444-444444444444" \
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

for _ in $(seq 1 5); do
  rate_status=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    -d '{"email":"rate-limit@example.test"}' \
    "http://127.0.0.1:$control_port/v1/auth/recovery/request")
  test "$rate_status" = 200
done
rate_status=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -d '{"email":"rate-limit@example.test"}' \
  "http://127.0.0.1:$control_port/v1/auth/recovery/request")
test "$rate_status" = 429

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

docker exec -i "$postgres" psql -v ON_ERROR_STOP=1 -U postgres -d ptt >/dev/null <<'SQL'
WITH generated AS (
  SELECT ('50000000-0000-4000-8000-' || lpad(value::text, 12, '0'))::uuid AS aci, value
  FROM generate_series(1, 62) AS value
)
INSERT INTO accounts(aci,email)
SELECT aci, 'load-' || value || '@example.test' FROM generated;
WITH generated AS (
  SELECT ('50000000-0000-4000-8000-' || lpad(value::text, 12, '0'))::uuid AS aci,
         ('60000000-0000-4000-8000-' || lpad(value::text, 12, '0'))::uuid AS mailbox_id,
         value
  FROM generate_series(1, 62) AS value
)
INSERT INTO devices(aci,device_id,mailbox_id,display_name,identity_key,access_token_sha256,status)
SELECT aci,1,mailbox_id,'Load device ' || value,decode(repeat('06',32),'hex'),decode(md5(aci::text) || md5('ptt-load-' || aci::text),'hex'),'active'
FROM generated;
SQL
load_members=$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
  "SELECT json_agg(json_build_object('aci',aci,'role','talk')) FROM (SELECT aci FROM accounts WHERE aci IN ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222') OR aci::text LIKE '50000000-0000-4000-8000-%' ORDER BY aci) members")
load_payload=$(jq -nc --argjson members "$load_members" \
  '{displayName:"64-member load gate",kind:"team",retentionDays:1,members:$members}')
load_channel=$(curl -fsS -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d "$load_payload" "http://127.0.0.1:$control_port/v1/admin/channels")
test "$(printf '%s' "$load_channel" | jq -r .activeMembers)" = 64
load_channel_id=$(printf '%s' "$load_channel" | jq -r .channelId)
load_devices=$(curl -fsS -H "Authorization: Bearer $token_a" \
  "http://127.0.0.1:$control_port/v1/channels/$load_channel_id/devices")
test "$(printf '%s' "$load_devices" | jq 'map(.aci) | unique | length')" = 64

last_admin_delete_status=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $token_a" -H 'Content-Type: application/json' \
  -d '{"confirmation":"DELETE"}' "http://127.0.0.1:$control_port/v1/account/delete")
test "$last_admin_delete_status" = 409
docker exec "$postgres" psql -v ON_ERROR_STOP=1 -U postgres -d ptt -c \
  "UPDATE memberships SET joined_epoch=3,left_epoch=NULL WHERE channel_id='44444444-4444-4444-8444-444444444444' AND aci='22222222-2222-4222-8222-222222222222'" >/dev/null
recipient_epoch_before=$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
  "SELECT membership_epoch FROM channels WHERE channel_id='44444444-4444-4444-8444-444444444444'")
curl -fsS -H "Authorization: Bearer $recovered_token" -H 'Content-Type: application/json' \
  -d '{"confirmation":"DELETE"}' "http://127.0.0.1:$control_port/v1/account/delete" >/dev/null
test "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $recovered_token" \
  "http://127.0.0.1:$control_port/v1/devices")" = 401
test "$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
  "SELECT email LIKE 'deleted+%@invalid.ptt' AND disabled_at IS NOT NULL FROM accounts WHERE aci='22222222-2222-4222-8222-222222222222'")" = t
test "$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
  "SELECT count(*) FROM devices WHERE aci='22222222-2222-4222-8222-222222222222'")" = 0
test "$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
  "SELECT left_epoch IS NOT NULL FROM memberships WHERE channel_id='44444444-4444-4444-8444-444444444444' AND aci='22222222-2222-4222-8222-222222222222'")" = t
recipient_epoch_after=$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
  "SELECT membership_epoch FROM channels WHERE channel_id='44444444-4444-4444-8444-444444444444'")
test "$recipient_epoch_after" -eq $((recipient_epoch_before + 1))
test "$(docker exec "$postgres" psql -At -U postgres -d ptt -c \
  "SELECT count(*) FROM audit_events WHERE action='account.deleted'")" = 1

printf '%s\n' \
  'fresh migration: ok' \
  'authenticated metadata-safe operational metrics: ok' \
  'one-time prekey IDs, single consumption, and reuse rejection: ok' \
  'member-scoped channel device discovery: ok' \
  'authenticated expiring presence modes: ok' \
  'admin membership, operations, retention, audit, and device revocation: ok' \
  'mailbox delivery and acknowledgement: ok' \
  'bidirectional gRPC envelope, floor lifecycle, and TLS media fallback: ok' \
  'SOS floor priority and preemption: ok' \
  'UDP relay binding, HMAC, source rejection, fan-out, and rebinding: ok' \
  'APNs/FCM JWT dispatch, registration uniqueness, and wake deduplication: ok' \
  'S3 Signature V4 ciphertext round trip: ok' \
  'idempotency and talk-id reuse protection: ok' \
  'privacy-keyed authentication rate limiting: ok' \
  'email plus independent-admin recovery, revocation, and epoch rotation: ok' \
  'new-device old-history exclusion: ok' \
  'removed-member history denial: ok' \
  'two-device approval, activation, epoch rotation, and no-old-history access: ok' \
  '64-member channel discovery and key fan-out boundary: ok' \
  'in-app account deletion, de-identification, revocation, and epoch rotation: ok'
