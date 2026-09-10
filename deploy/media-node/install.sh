#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run install.sh as root." >&2
  exit 1
fi

for name in CALLS_DOMAIN TURN_DOMAIN PUBLIC_IP PRIVATE_IP ADMIN_CIDR LIVEKIT_API_KEY \
  LIVEKIT_API_SECRET TURN_USERNAME TURN_PASSWORD REDIS_PASSWORD METRICS_TOKEN; do
  [[ -n "${!name:-}" ]] || { echo "$name is required" >&2; exit 1; }
done

[[ "$CALLS_DOMAIN" =~ ^[a-z0-9.-]+$ && "$TURN_DOMAIN" =~ ^[a-z0-9.-]+$ ]] || {
  echo "Call and TURN domains must be canonical lower-case DNS names." >&2
  exit 1
}
[[ "$PUBLIC_IP" =~ ^[0-9.]+$ && "$PRIVATE_IP" =~ ^[0-9.]+$ ]] || {
  echo "PUBLIC_IP and PRIVATE_IP must be IPv4 addresses." >&2
  exit 1
}
[[ "$ADMIN_CIDR" =~ ^[0-9.]+/[0-9]{1,2}$ ]] || {
  echo "ADMIN_CIDR must be a specific IPv4 CIDR." >&2
  exit 1
}
admin_prefix="${ADMIN_CIDR##*/}"
(( admin_prefix >= 24 && admin_prefix <= 32 )) || {
  echo "ADMIN_CIDR must be restricted to a /24 or smaller range." >&2
  exit 1
}
[[ ${#LIVEKIT_API_SECRET} -ge 32 && ${#TURN_PASSWORD} -ge 24 && \
   ${#REDIS_PASSWORD} -ge 24 && ${#METRICS_TOKEN} -ge 24 ]] || {
  echo "Generated media credentials do not meet the minimum length." >&2
  exit 1
}

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates certbot docker.io docker-compose-v2 gettext-base ufw
systemctl enable --now docker

install -d -m 0750 /opt/ptt-media/runtime
install -d -m 0755 /var/www/certbot
install -m 0644 compose.yaml /opt/ptt-media/compose.yaml

# OCI's Ubuntu images ship a final iptables reject rule even when UFW itself is
# inactive. Establish the explicit host policy before ACME validation so port
# 80 is genuinely reachable during first boot as well as after installation.
while iptables -C INPUT -j REJECT --reject-with icmp-host-prohibited 2>/dev/null; do
  iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited
done
ufw default deny incoming
ufw default allow outgoing
ufw allow from "$ADMIN_CIDR" to any port 22 proto tcp
ufw --force delete allow 22/tcp 2>/dev/null || true
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 7881/tcp
ufw allow 7882/udp
ufw allow 3478/udp
ufw allow 5349/tcp
ufw allow 50000:50100/udp
ufw --force enable

if [[ ! -s "/etc/letsencrypt/live/$CALLS_DOMAIN/fullchain.pem" ]]; then
  systemctl stop nginx 2>/dev/null || true
  docker compose -f /opt/ptt-media/compose.yaml down 2>/dev/null || true
  certbot certonly --standalone --non-interactive --agree-tos \
    --register-unsafely-without-email --preferred-challenges http \
    -d "$CALLS_DOMAIN" -d "$TURN_DOMAIN"
fi

install -m 0640 -o root -g 65534 \
  "/etc/letsencrypt/live/$CALLS_DOMAIN/fullchain.pem" \
  /opt/ptt-media/runtime/turn-fullchain.pem
install -m 0640 -o root -g 65534 \
  "/etc/letsencrypt/live/$CALLS_DOMAIN/privkey.pem" \
  /opt/ptt-media/runtime/turn-privkey.pem

export CALLS_DOMAIN TURN_DOMAIN PUBLIC_IP PRIVATE_IP LIVEKIT_API_KEY \
  LIVEKIT_API_SECRET TURN_USERNAME TURN_PASSWORD REDIS_PASSWORD METRICS_TOKEN
envsubst < livekit.yaml.template > /opt/ptt-media/runtime/livekit.yaml
envsubst < turnserver.conf.template > /opt/ptt-media/runtime/turnserver.conf
# envsubst requires an explicit literal allowlist here.
# shellcheck disable=SC2016
envsubst '${CALLS_DOMAIN} ${TURN_DOMAIN} ${METRICS_TOKEN}' \
  < nginx.conf.template > /opt/ptt-media/runtime/nginx.conf
printf '%s: %s\n' "$LIVEKIT_API_KEY" "$LIVEKIT_API_SECRET" \
  > /opt/ptt-media/runtime/livekit-keys.yaml
printf '%s' "$REDIS_PASSWORD" > /opt/ptt-media/runtime/redis-password
chmod 0600 /opt/ptt-media/runtime/*
chown root:65534 /opt/ptt-media/runtime/turnserver.conf \
  /opt/ptt-media/runtime/turn-fullchain.pem \
  /opt/ptt-media/runtime/turn-privkey.pem
chmod 0640 /opt/ptt-media/runtime/turnserver.conf \
  /opt/ptt-media/runtime/turn-fullchain.pem \
  /opt/ptt-media/runtime/turn-privkey.pem

sysctl -w net.core.rmem_max=5000000
sysctl -w net.core.wmem_max=5000000
sysctl -w vm.overcommit_memory=1
printf '%s\n' 'net.core.rmem_max=5000000' 'net.core.wmem_max=5000000' \
  'vm.overcommit_memory=1' \
  > /etc/sysctl.d/99-ptt-media.conf

docker compose -f /opt/ptt-media/compose.yaml pull
docker compose -f /opt/ptt-media/compose.yaml up -d --force-recreate
docker compose -f /opt/ptt-media/compose.yaml ps

install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
install -m 0755 renew-hook.sh /etc/letsencrypt/renewal-hooks/deploy/ptt-media-reload
systemctl enable --now certbot.timer
