# VPS
This repository's pipeline creates a custom bootc image which can be installed to a running VPS via `bootc install to-existing-root`. See [Installing on generic infrastructure](https://docs.fedoraproject.org/en-US/bootc/provisioning-generic/)

## Installation
Create an single-use Tailscale authkey and insert into the command below.

Sample Ubuntu setup:
```
# Install podman
sudo apt install -y podman

# Install the VPS image
sudo podman run --rm --privileged \
  --pid=host \
  --security-opt label=type:unconfined_t \
  -v /:/target \
  -v /dev:/dev \
  -v /var/lib/containers:/var/lib/containers \
  ghcr.io/serisium/great-henge/vps:latest \
  bootc install to-existing-root --acknowledge-destructive
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

## SSH access
SSH authorized keys for `root` are baked into the image at build time. CI fetches them from <https://github.com/serisium.keys> and a `tmpfiles.d` snippet materialises `/root/.ssh/authorized_keys` (with the correct SELinux context) on every boot. To update the allowed keys: change the GitHub account's keys, then push any commit to `main` that touches `vps/**` to rebuild.

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