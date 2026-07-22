#!/bin/sh
# Seed /var/lib/pangolin/config from /usr/share/pangolin/config on first boot
# and generate server.secret. Idempotent: no-op once config.yml exists.
set -eu

CONFIG=/var/lib/pangolin/config
SEED=/usr/share/pangolin/config

[ -e "$CONFIG/config.yml" ] && exit 0

mkdir -p "$CONFIG/db" "$CONFIG/letsencrypt" "$CONFIG/traefik/logs"
cp "$SEED/traefik/traefik_config.yml" "$CONFIG/traefik/traefik_config.yml"
cp "$SEED/traefik/dynamic_config.yml" "$CONFIG/traefik/dynamic_config.yml"
cp "$SEED/config.yml" "$CONFIG/config.yml"

SECRET=$(openssl rand -hex 32)
sed -i "s/__PANGOLIN_SECRET__/$SECRET/" "$CONFIG/config.yml"
chmod 600 "$CONFIG/config.yml"

chown -R pangolin:pangolin /var/lib/pangolin
restorecon -R /var/lib/pangolin || true
