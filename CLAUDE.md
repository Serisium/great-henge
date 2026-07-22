# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Overview

**Great Henge** describes Seri's homelab and VPS setups as code. The active
component is `vps/` — a custom **Fedora bootc** OS image for a cloud VPS. CI
builds the image and publishes it to a container registry; a server is then
provisioned by installing that image over an existing root with
`bootc install to-existing-root`.

## Repository layout

- `vps/Containerfile` — the bootc image definition. Base
  `quay.io/fedora/fedora-bootc:43`; installs dev tools (tmux, vim, htop) plus
  `podman`, `tailscale`, `nftables`, and enables the systemd units. Contains
  **no inline file contents** — only `dnf`, `COPY`, `chmod`, and
  `systemctl enable`.
- `vps/etc/`, `vps/usr/` — mirror of the image filesystem, `COPY`'d in
  verbatim (`COPY etc/ /etc/`, `COPY usr/ /usr/`, after `dnf` so packaged
  defaults lose). All config lives here as real files: the hostname,
  `tailscale-auth.service` (oneshot `tailscale up --ssh` on first boot),
  the Pangolin quadlets, nftables rules, sysusers/subuid, tmpfiles.
  Gotcha: `/etc/hostname` is bind-mounted by podman during `RUN` steps —
  writing it inline silently does nothing; it must be a `COPY`'d file.
- **Pangolin** (`pangolin` + `gerbil` + `traefik`, one pod) runs as rootless
  user `pangolin` (uid 2000) via quadlets in
  `/etc/containers/systemd/users/2000/`, serving `auth.seri.dev` (base domain
  `seri.dev`). Rootless can't bind <1024, so the pod publishes 8080/8443 and
  nftables redirects 80/443 to them. First boot: `pangolin-config-init.service`
  seeds `/var/lib/pangolin/config/` from `/usr/share/pangolin/config/` and
  generates `server.secret` (never in repo/image). The `wireguard`/`tun`
  modules are host-loaded via modules-load.d; the user lingers via tmpfiles.d.
- `vps/README.md` — provisioning runbook: install command, verification steps,
  Tailscale authkey seeding, Pangolin overview, and the dev test loop.
- `.github/workflows/build-vps.yml` — GitHub Actions. On pushes to `main` that
  touch `vps/**`, builds `vps/` and pushes to GHCR (`:latest` on the default
  branch, plus branch and `sha-` tags).
- `README.md` — top-level project intro.

## How it works

1. A push to `main` touching `vps/**` triggers the workflow, which builds the
   Containerfile and pushes the image to GHCR.
2. A VPS is provisioned by running the published image with
   `bootc install to-existing-root` (see `vps/README.md`), converting a generic
   Linux root into this bootc image.
3. On boot, `tailscaled` starts and `tailscale-auth.service` joins the tailnet
   using the authkey placed at `/etc/tailscale/authkey.env` on the host.
4. To update a running host: rebuild + push the image, then `bootc upgrade` on
   the server pulls the new image and stages it for the next boot.

## Conventions & guardrails

- **Keep operational secrets out of this repo.** It is published publicly to
  GHCR and meant to be shareable. The live server's IP, SSH/auth details, and
  the Tailscale authkey are not stored here. (Claude: these live in project
  memory — recall before you need to reach or operate the live host.)
- The Tailscale authkey exists only on the host at `/etc/tailscale/authkey.env`;
  never commit it or bake it into the image.
- Image changes flow through `vps/Containerfile` and `vps/systemd/`; CI
  publishes automatically — no manual registry pushes.

## Common tasks

- Build locally: `podman build -t great-henge/vps ./vps`
- Add a package: extend the `dnf install` list in `vps/Containerfile`.
- Add a service: add a unit under `vps/etc/systemd/system/` and
  `systemctl enable` it in the Containerfile.
- Add/change any config file: place it at its real path under `vps/etc/` or
  `vps/usr/` — never write file contents inline in the Containerfile.
- Test image changes on the live host without pushing to GitHub: build and
  push to a dev registry, then `bootc switch`/`bootc upgrade` on the VPS
  (see `vps/README.md` "Dev test loop"; registry details in project memory).
