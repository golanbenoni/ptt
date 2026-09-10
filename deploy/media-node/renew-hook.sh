#!/bin/sh
set -eu
calls_domain=$(sed -n 's/^server_name \([^ ]*\).*/\1/p' /opt/ptt-media/runtime/nginx.conf | tail -n 1)
test -n "$calls_domain"
install -m 0640 -o root -g 65534 \
  "/etc/letsencrypt/live/$calls_domain/fullchain.pem" \
  /opt/ptt-media/runtime/turn-fullchain.pem
install -m 0640 -o root -g 65534 \
  "/etc/letsencrypt/live/$calls_domain/privkey.pem" \
  /opt/ptt-media/runtime/turn-privkey.pem
docker compose -f /opt/ptt-media/compose.yaml restart nginx coturn
