# VPS
This repository's pipeline creates a custom bootc image which can be installed to a running VPS via `bootc install to-existing-root`. See [Installing on generic infrastructure](https://docs.fedoraproject.org/en-US/bootc/provisioning-generic/)

The image layout mirrors the target filesystem: everything under `etc/` and
`usr/` is `COPY`'d into the image verbatim. Don't write files inline in the
Containerfile — in particular `/etc/hostname`, which podman bind-mounts during
`RUN` steps, so writes to it silently never reach the image. Also don't put
symlinks in the mirrored trees whose targets only exist in the image (e.g.
into dnf-installed paths): podman silently drops dangling symlinks from the
build context — create those with `ln -s` in the Containerfile instead.

# Pangolin
The image runs [Pangolin](https://docs.pangolin.net/) (`pangolin` + `gerbil` +
`traefik` in one pod) as the **rootless** user `pangolin` (uid/gid 2000) via
Podman quadlets baked into `/etc/containers/systemd/users/2000/`. It serves the
dashboard at `portal.seri.dev` (base domain `seri.dev`) and terminates
WireGuard tunnels from remote Newt clients.

- Rootless processes can't bind ports <1024, so the pod publishes 8080/8443 and
  an nftables rule (`/etc/nftables/pangolin.nft`) redirects 80→8080, 443→8443.
  UDP 51820/21820 are published directly.
- The `wireguard` and `tun` kernel modules are loaded on the host via
  `modules-load.d`; gerbil only needs `NET_ADMIN` inside the pod.
- **First boot:** `pangolin-config-init.service` seeds
  `/var/lib/pangolin/config/` from `/usr/share/pangolin/config/` and generates
  `server.secret` (`openssl rand -hex 32`) — the secret never exists in the
  repo or image. The service is a no-op once `config.yml` exists. The
  `pangolin` user lingers (tmpfiles.d), so the pod starts at boot with no login.
- **Requirements:** DNS `portal.seri.dev` → the VPS public IP, and TCP 80/443
  + UDP 51820/21820 open. Let's Encrypt issuance (HTTP-01) begins working once
  DNS resolves.
- **Initial setup:** `podman logs pangolin` (as the pangolin user) prints a
  one-time setup token; use it at `https://portal.seri.dev/auth/initial-setup`.

# Authentik
The image also runs [authentik](https://goauthentik.io/) (`server` + `worker` +
`postgres` + `redis`) in the same rootless `services` pod, served by Pangolin's
traefik at `auth.seri.dev`. Because the containers share the pod's network
namespace, traefik reaches the authentik server at `localhost:9000` via a
static route in `dynamic_config.yml` — no extra published ports.

- **First boot:** `authentik-config-init.service` creates `/var/lib/authentik/`
  (`postgres`, `redis`, `media`, `templates`, `certs`) and generates three
  rootless podman secrets for the pangolin user — `authentik-secret-key`,
  `authentik-pg-password`, and `authentik-bootstrap-password`. The quadlets
  inject them as env vars via `Secret=`; the values never exist in the repo or
  image. Idempotent via the `/var/lib/authentik/.seeded` marker.
- **Requirements:** DNS `auth.seri.dev` → the VPS public IP. The cert comes
  from the same Let's Encrypt HTTP-01 flow as Pangolin's.
- **Initial setup:** none needed — authentik consumes
  `AUTHENTIK_BOOTSTRAP_PASSWORD`/`AUTHENTIK_BOOTSTRAP_EMAIL` on first startup,
  so `akadmin` is ready immediately. Read the password on the VPS with

  ```
  cd /tmp && sudo -u pangolin XDG_RUNTIME_DIR=/run/user/2000 \
    podman secret inspect --showsecret --format '{{.SecretData}}' \
    authentik-bootstrap-password
  ```

  then log in at `https://auth.seri.dev` as `akadmin` (change the password
  afterwards if you like; the secret is only consumed on first startup).
- Inspect secrets on the VPS:
  `cd /tmp && sudo -u pangolin XDG_RUNTIME_DIR=/run/user/2000 podman secret ls`

## Dev test loop (no GitHub push needed)
Build on an x86 box with a local registry, then point the VPS at it:

```
podman build -t <registry-host>:5000/serisium/great-henge/vps:dev ./vps
podman push <registry-host>:5000/serisium/great-henge/vps:dev
# on the VPS:
bootc switch <registry-host>:5000/serisium/great-henge/vps:dev && reboot
# iterate with:
bootc upgrade && reboot
# when done, return to CI images:
bootc switch ghcr.io/serisium/great-henge/vps:latest
```

Debugging the rootless stack on the VPS:

```
cd /tmp && sudo -u pangolin XDG_RUNTIME_DIR=/run/user/2000 podman ps
journalctl _UID=2000        # user manager + container logs
```

(`cd /tmp` matters: root's home is unreadable to pangolin, so `runuser`/`sudo`
from `/var/roothome` fails with "cannot chdir".)

If a container is missing from `podman ps -a` and its unit is
"inactive (dead)" with "Dependency failed" in the journal: a `Requires=`
dependency's first start exceeded its start timeout, and systemd never
retries dependency-failed jobs. Start the unit manually
(`systemctl --user start <unit>`). The quadlets use `Wants=` +
`TimeoutStartSec=900` precisely to avoid this; keep new units on that
pattern.

# SSH access
Primary access is **Tailscale SSH**: the host joins the tailnet on first boot
(`tailscale up --ssh`, using the authkey seeded during provisioning), so
`tailscale ssh root@great-henge` works from any tailnet device. As a
non-tailnet fallback, inject public keys into root's `authorized_keys` at
install time with `--root-ssh-authorized-keys` — no keys are stored in this
repo or the image.

# Provisioning
Steps 1–4 run **on the stock OS of the fresh VPS** (Ubuntu shown). During
these steps you are still on the old root filesystem: the installed bootc
deployment has its own separate `/etc`, and everything written to the old
root remains visible to the new OS at `/sysroot` after the reboot.

Prerequisite: create a single-use Tailscale authkey for step 2.

## 1. Install the image

```
# Fallback SSH keys for root (Tailscale SSH is the primary access path)
sudo mkdir -p -m 0700 /root/.ssh
sudo wget -O /root/.ssh/authorized_keys https://github.com/serisium.keys

# Install podman
sudo apt install -y podman

# Install the VPS image over the running root
sudo podman run --rm --privileged \
  --pid=host \
  --security-opt label=type:unconfined_t \
  -v /:/target \
  -v /dev:/dev \
  -v /var/lib/containers:/var/lib/containers \
  -v /root/.ssh/authorized_keys:/authorized_keys:ro \
  ghcr.io/serisium/great-henge/vps:latest \
  bootc install to-existing-root --acknowledge-destructive \
  --root-ssh-authorized-keys=/authorized_keys
```

## 2. Seed the tailscale authkey

```
sudo install -d -m 0700 /etc/tailscale
echo "TAILSCALE_AUTHKEY=tskey-..." | sudo tee /etc/tailscale/authkey.env >/dev/null
sudo chmod 0600 /etc/tailscale/authkey.env
```

This intentionally writes to the **old** root's `/etc` — on first boot,
`tailscale-authkey-import.service` copies it from
`/sysroot/etc/tailscale/authkey.env` into the deployment's `/etc` before
`tailscale-auth.service` joins the tailnet. (Forgot this step before
rebooting? On the booted system either write `/etc/tailscale/authkey.env`
directly or run the `install -D` from `/sysroot` yourself, then
`systemctl start tailscale-auth.service`.)

## 3. Verify the install (optional)
The following should print the mounts `/root -> var/roothome`,
`/home -> var/home`:
```
sudo podman run --rm ghcr.io/serisium/great-henge/vps:latest ls -ld /root /home
```

Verify the bootc /boot directory exists:
```
ls /boot
cat /boot/loader/entries/*.conf 2>/dev/null || ls /boot/loader/
```

## 4. Reboot into the image
```
sudo reboot
```

## 5. After first boot
- The host joins the tailnet automatically; `tailscale ssh root@great-henge`
  should work (fallback: `ssh root@<IP>` via the install-time keys).
- Point DNS A records for `portal.seri.dev` and `auth.seri.dev` at the VPS
  IP; Let's Encrypt certs issue automatically once they resolve.
- Pangolin and authentik seed themselves on first boot (see their sections
  above): fetch the Pangolin setup token from `podman logs pangolin`, and
  read authentik's `akadmin` password from the
  `authentik-bootstrap-password` secret.