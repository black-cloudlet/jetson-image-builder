# jetson-image-builder

bootc image and unattended installer ISO for NVIDIA Jetson AGX Orin edge nodes running RHEL 9.8
image mode (aarch64), for deployment into a disconnected environment.

The device OS is Red Hat's JetPack-for-RHEL bootc image (RHEL 9.8, JetPack 6.2.2 / L4T r36.5.0,
kernel 5.14.0-687.42.1). `Containerfile` derives from it and layers MicroShift 4.20 on top, with
every MicroShift container image embedded so the cluster starts with no registry reachable. `.github/workflows/build-bootc.yml` builds the image on a native arm64
runner, pushes it to `ghcr.io/black-cloudlet/jetson-orin-bootc:<YYYYMMDD-sha8>`, then runs
`bootc-image-builder --type anaconda-iso` and uploads the ISO as a workflow artifact.

| File | Does |
| ---- | ---- |
| `Containerfile` | pinned JetPack-for-RHEL base + MicroShift 4.20 + embedded container images |
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
| `RHSM_ENTITLEMENT_TGZ_B64` | `tar -C / -czf - etc/pki/entitlement etc/rhsm etc/yum.repos.d/redhat.repo \| base64 -w0` on a subscribed RHEL host — the MicroShift RPMs and bib's Anaconda depsolve both need it |
| `OPENSHIFT_PULL_SECRET` | pull secret JSON from console.redhat.com/openshift/install/pull-secret — pulls MicroShift's container images at build time |
| `EDGE_SSH_PUBKEY` | public key for the `edge` user |
| `EDGE_PASSWORD_HASH` | `openssl passwd -6` output for the `edge` user |

`redhat.repo` is what defines the `rhocp-4.20-for-rhel-9-aarch64-rpms` and
`fast-datapath-for-rhel-9-aarch64-rpms` repos. An entitlement tarball built without it will fail
the build with a clear error — if you created the secret before MicroShift was added, regenerate
it with the command above. The subscription also has to actually carry an OpenShift entitlement,
or those repos will not appear in `redhat.repo` at all.

The pull secret is used only during the build; it is not written into the OS image.

## Install

The kickstart in `config.toml` is fully unattended: it wipes `nvme0n1` only (the USB key and
eMMC are ignored), creates `edge` in `wheel`, locks root, and reboots ejecting the media.
Booting it on a device with data on the NVMe is destructive.

The network is **static**: the device comes up as `Jetson` on `192.168.1.10/24` via
`192.168.1.1`. Every device imaged from a given ISO gets that same address and hostname, so a
second node on the same segment collides — change them here and rebuild, or fix up per device
after the first boot. Timezone is `Asia/Jerusalem` with the hardware clock in UTC.

1. Flash QSPI on the station from a **R36.5.x** BSP (same L4T line as the image):
   `sudo ./flash.sh p3737-0000-p3701-0000-qspi external`
2. `dd` the ISO to a USB key, plug it in with the NVMe fitted, ESC at the NVIDIA logo, pick USB.
3. Wait for the reboot, then over serial (`ttyTCU0`) or `ssh edge@192.168.1.10`:
   ```
   bootc status
   cat /etc/nv_tegra_release
   lsmod | grep nvgpu
   systemctl status nvidia-ctk && nvidia-ctk cdi list     # nvidia.com/gpu=all
   ```
4. Then MicroShift. First boot is slow — `microshift-copy-images` loads every embedded image
   into CRI-O storage before the service starts, and the cluster settles after that:
   ```
   systemctl status microshift
   export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig
   sudo -E oc get pods -A                 # openshift-ovn-kubernetes, -dns, -service-ca, -storage
   sudo vgs                               # VG rhel, with free extents left for LVMS
   sudo -E oc get sc                      # topolvm provisioner
   ```
   Pods stuck in `ImagePullBackOff` mean the embedding did not take — check
   `/usr/lib/containers/storage/image-list.txt` and the `microshift-copy-images` run in
   `journalctl -u microshift`.

## Storage layout

The kickstart puts `/boot` and the ESP outside LVM, then gives the rest of the NVMe to one volume
group named `rhel`: a 60 GiB xfs root, swap, and **the remainder left free on purpose**.
MicroShift's LVMS provisioner carves PVCs out of that free space, so PostgreSQL, RabbitMQ and the
model store have somewhere to live. Filling the VG would leave the cluster with no dynamic
provisioner. This assumes an NVMe of roughly 80 GiB or more; adjust `logvol / --size` if the root
filesystem needs to be bigger.

## Local build (subscribed RHEL 9 aarch64 host)

The container build now needs entitlement and a pull secret, so it no longer works on an
unsubscribed host:

```
sudo podman build \
  -v /etc/pki/entitlement:/etc/pki/entitlement:ro \
  -v /etc/rhsm:/etc/rhsm:ro \
  -v /etc/yum.repos.d/redhat.repo:/etc/yum.repos.d/redhat.repo:ro \
  --secret id=pullsecret,src=$HOME/pull-secret.json \
  -t localhost/jetson-orin-bootc:dev .
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
