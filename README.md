# jetson-image-builder

bootc image and unattended installer ISO for NVIDIA Jetson AGX Orin edge nodes running RHEL 9.8
image mode (aarch64), for deployment into a disconnected environment.

The device OS is Red Hat's JetPack-for-RHEL bootc image (RHEL 9.8, JetPack 6.2.2 / L4T r36.5.0,
kernel 5.14.0-687.42.1). `Containerfile` derives from it and adds nothing yet; the Kubernetes
layer goes there next. `.github/workflows/build-bootc.yml` builds the image on a native arm64
runner, pushes it to `ghcr.io/black-cloudlet/jetson-orin-bootc:<YYYYMMDD-sha8>`, then runs
`bootc-image-builder --type anaconda-iso` and uploads the ISO as a workflow artifact.

| File | Does |
| ---- | ---- |
| `Containerfile` | derives from the pinned JetPack-for-RHEL base; `bootc container lint` |
| `config.toml` | bootc-image-builder config — the unattended kickstart and the ISO label |
| `.github/workflows/build-bootc.yml` | build + smoke test + push to GHCR, then build the ISO |

Provisioning the flashing station and flashing the Jetson QSPI are a separate concern and live in
**[black-cloudlet/jetson-installer-config](https://github.com/black-cloudlet/jetson-installer-config)**
(`mirror.sh`, `install-offline.sh`). The QSPI must be flashed from an **R36.5.x** BSP — the same
L4T line as the image built here — before a device can boot this ISO.

## Secrets

| secret | purpose |
|---|---|
| `RH_REGISTRY_USER` / `RH_REGISTRY_TOKEN` | pull `registry.redhat.io/rhel9/bootc-image-builder` (Registry Service Account) |
| `RHSM_ENTITLEMENT_TGZ_B64` | `tar -C / -czf - etc/pki/entitlement etc/rhsm \| base64 -w0` on a subscribed RHEL host — lets bib depsolve Anaconda |
| `EDGE_SSH_PUBKEY` | public key for the `edge` user |
| `EDGE_PASSWORD_HASH` | `openssl passwd -6` output for the `edge` user |

The base image on quay.io is public; no Red Hat credentials are needed to build the container.

## Install

The kickstart in `config.toml` is fully unattended: it wipes `nvme0n1` only (the USB key and
eMMC are ignored), creates `edge` in `wheel`, locks root, and reboots ejecting the media.
Booting it on a device with data on the NVMe is destructive.

1. Flash QSPI on the station from a **R36.5.x** BSP (same L4T line as the image):
   `sudo ./flash.sh p3737-0000-p3701-0000-qspi external`
2. `dd` the ISO to a USB key, plug it in with the NVMe fitted, ESC at the NVIDIA logo, pick USB.
3. Wait for the reboot, then over serial (`ttyTCU0`) or ssh:
   ```
   bootc status
   cat /etc/nv_tegra_release
   lsmod | grep nvgpu
   systemctl status nvidia-ctk && nvidia-ctk cdi list     # nvidia.com/gpu=all
   ```

## Local build (subscribed RHEL 9 aarch64 host)

```
sudo podman build -t localhost/jetson-orin-bootc:dev .
sed -e "s|@EDGE_SSH_PUBKEY@|$(cat ~/.ssh/id_ed25519.pub)|" \
    -e "s|@EDGE_PASSWORD_HASH@|$(openssl passwd -6)|" config.toml > /tmp/config.toml
mkdir output
sudo podman run --rm --privileged --pull=newer --security-opt label=type:unconfined_t \
  -v /tmp/config.toml:/config.toml:ro -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  registry.redhat.io/rhel9/bootc-image-builder:latest \
  --type anaconda-iso --config /config.toml localhost/jetson-orin-bootc:dev
```
On a registered RHEL host podman mounts the entitlement into the container by itself.
