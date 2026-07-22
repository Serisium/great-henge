# VPS
This repository's pipeline creates a custom bootc image which can be installed to a running VPS via `bootc install to-existing-root`. See [Installing on generic infrastructure](https://docs.fedoraproject.org/en-US/bootc/provisioning-generic/)

The image layout mirrors the target filesystem: everything under `etc/` and
`usr/` is `COPY`'d into the image verbatim. Don't write files inline in the
Containerfile — in particular `/etc/hostname`, which podman bind-mounts during
`RUN` steps, so writes to it silently never reach the image.

# Pangolin
The image runs [Pangolin](https://docs.pangolin.net/) (`pangolin` + `gerbil` +
`traefik` in one pod) as the **rootless** user `pangolin` (uid/gid 2000) via
Podman quadlets baked into `/etc/containers/systemd/users/2000/`. It serves the
dashboard at `auth.seri.dev` (base domain `seri.dev`) and terminates WireGuard
tunnels from remote Newt clients.

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
- **Requirements:** DNS `auth.seri.dev` → the VPS public IP, and TCP 80/443 +
  UDP 51820/21820 open. Let's Encrypt issuance (HTTP-01) begins working once
  DNS resolves.
- **Initial setup:** `podman logs pangolin` (as the pangolin user) prints a
  one-time setup token; use it at `https://auth.seri.dev/auth/initial-setup`.

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

# SSH access
SSH authorized keys for `root` are baked into the image at installtime via the `--root-ssh-authorized-keys` flag.

## Installation
Create an single-use Tailscale authkey and insert into the command below.

Sample Ubuntu setup:

```
# Fetch SSH keys into root's authorized_keys on the host
sudo mkdir -p -m 0700 /root/.ssh
sudo wget -O /root/.ssh/authorized_keys https://github.com/serisium.keys

# Install podman
sudo apt install -y podman

# Install the VPS image
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

## Verification
The following should print the following mounts: `/root -> var/roothome`, `/home -> var/home`
```
sudo podman run --rm ghcr.io/serisium/great-henge/vps:latest ls -ld /root /home
```

Verify the bootc /boot directory exists
```
ls /boot
cat /boot/loader/entries/*.conf 2>/dev/null || ls /boot/loader/
```


## Set the tailscale authkey
```
sudo install -d -m 0700 /etc/tailscale
echo "TAILSCALE_AUTHKEY=tskey-..." | sudo tee /etc/tailscale/authkey.env >/dev/null
sudo chmod 0600 /etc/tailscale/authkey.env
```

# Reboot
```
sudo reboot
```