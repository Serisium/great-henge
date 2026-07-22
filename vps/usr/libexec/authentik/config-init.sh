#!/bin/sh
# Seed /var/lib/authentik on first boot and generate authentik's credentials
# as rootless podman secrets owned by the pangolin user (see the
# podman-secrets skill). Idempotent: no-op once the .seeded marker exists.
set -eu

STATE=/var/lib/authentik
AS_PANGOLIN="runuser -u pangolin -- env XDG_RUNTIME_DIR=/run/user/2000"

[ -e "$STATE/.seeded" ] && exit 0

# The user manager (and therefore logind's /run/user/2000) is ordered after
# this service, so provide the runtime dir podman needs.
install -d -o pangolin -g pangolin -m 0700 /run/user/2000

install -d -m 0700 "$STATE"
mkdir -p "$STATE/postgres" "$STATE/redis" "$STATE/media" "$STATE/templates" \
    "$STATE/certs"
chown -R pangolin:pangolin "$STATE"

# The authentik server/worker run as uid 1000 inside the container; chown
# through the user namespace so the mapping follows /etc/subuid.
$AS_PANGOLIN podman unshare chown -R 1000:1000 \
    "$STATE/media" "$STATE/templates" "$STATE/certs"

# tr strips openssl's trailing newline: podman stores stdin verbatim, and a
# newline inside the secret breaks HTTP Authorization headers built from it.
for s in authentik-secret-key authentik-pg-password; do
    if ! $AS_PANGOLIN podman secret exists "$s"; then
        openssl rand -hex 32 | tr -d "\n" | $AS_PANGOLIN podman secret create "$s" -
    fi
done

restorecon -R "$STATE" || true
touch "$STATE/.seeded"
