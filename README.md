# jetson-image-builder

bootc image and unattended installer ISO for NVIDIA Jetson AGX Orin edge nodes running RHEL 9.8
image mode (aarch64), for deployment into a disconnected environment.

The device OS is Red Hat's JetPack-for-RHEL bootc image (RHEL 9.8, JetPack 6.2.2 / L4T r36.5.0,
kernel 5.14.0-687.42.1). Each **variant** is a directory deriving from it and layering on a
Kubernetes distribution, with every container image embedded so the cluster starts with no
registry reachable. Today there is one variant, `microshift/`; `k3s/` is expected beside it.

Building a variant pushes `ghcr.io/black-cloudlet/jetson-orin-bootc-<variant>:<YYYYMMDD-sha8>`
and uploads an installer ISO as a workflow artifact.

| Path | Does |
| ---- | ---- |
| `microshift/Containerfile` | pinned JetPack-for-RHEL base + MicroShift 4.20 + NVIDIA device plugin + embedded images |
| `microshift/config.toml` | bootc-image-builder config — the unattended kickstart and the ISO label |
| `microshift/smoke-test.sh` | checks run inside the built image before it is pushed |
| `physically-bound-images/` | shared: embed images at build time, replay them into containers-storage at boot |
| `.github/workflows/build-bootc-image.yml` | reusable — builds any variant and its ISO |
| `.github/workflows/build-microshift.yml` | thin caller for the `microshift` variant |

### Adding a variant

Create `<name>/` with a `Containerfile`, a `config.toml` and a `smoke-test.sh`, then add a caller
workflow mirroring `build-microshift.yml` with `variant: <name>`. The build context is the
repository root, so a variant's Containerfile can `COPY physically-bound-images/...` the way the
MicroShift one does. Nothing in the reusable workflow is MicroShift-specific: variant-shaped
checks live in the variant's own `smoke-test.sh`, and the kickstart in its own `config.toml`
(MicroShift's leaves free extents for LVMS; k3s, whose local-path provisioner just uses a
directory, would not need to).

Provisioning the flashing station and flashing the Jetson QSPI are a separate concern and live in
**[black-cloudlet/jetson-installer-config](https://github.com/black-cloudlet/jetson-installer-config)**
(`mirror.sh`, `install-offline.sh`). The QSPI must be flashed from an **R36.5.x** BSP — the same
L4T line as the image built here — before a device can boot this ISO.

## Secrets

| secret | purpose |
|---|---|
| `RH_REGISTRY_USER` / `RH_REGISTRY_TOKEN` | pull `registry.redhat.io/rhel9/bootc-image-builder` (Registry Service Account) |
| `RHT_ORGID` / `RHT_ACT_KEY` | organisation ID and activation key — both jobs register with subscription-manager for the MicroShift RPMs and bib's Anaconda depsolve |
| `OPENSHIFT_PULL_SECRET` | pull secret JSON from console.redhat.com/openshift/install/pull-secret — pulls MicroShift's and the device plugin's container images at build time |
| `EDGE_SSH_PUBKEY` | public key for the `edge` user |
| `EDGE_PASSWORD_HASH` | `openssl passwd -6` output for the `edge` user |

Entitlement comes from registering inside the build container, not from a certificate tarball —
nothing expires in a secret, and `redhat.repo` is generated fresh by the registration. Each run
consumes a subscription slot and releases it again in an `if: always()` unregister step. The
subscription has to carry an OpenShift entitlement or `rhocp-4.20-for-rhel-9-aarch64-rpms` never
appears and the build fails at `--enablerepo`.

The pull secret is used only during the build; it is not written into the OS image.

## Install

The kickstart in `microshift/config.toml` is fully unattended: it wipes `nvme0n1` only (the USB key and
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
4. Then MicroShift. First boot is slow — `copy-embedded-images.service` replays every embedded
   image into containers-storage before MicroShift starts, and the cluster settles after that:
   ```
   systemctl status microshift
   export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig
   sudo -E oc get pods -A                 # openshift-ovn-kubernetes, -dns, -service-ca, -storage
   sudo vgs                               # VG rhel, with free extents left for LVMS
   sudo -E oc get sc                      # topolvm provisioner
   sudo -E oc get ds -n kube-system nvidia-device-plugin-daemonset
   sudo -E oc get nodes -o jsonpath='{.items[0].status.allocatable}'   # expect nvidia.com/gpu
   ```
   Pods stuck in `ImagePullBackOff` mean the embedding did not take — check
   `/usr/lib/containers-image-cache/mapping.txt` and
   `journalctl -u copy-embedded-images`.

## Where the build runs

`build-bootc-image.yml` is reusable (`workflow_call`) and takes a `variant` input; each variant
gets a thin caller. `runs-on: ubuntu-24.04-arm` for a native arm64 machine, but every step
executes inside `registry.access.redhat.com/ubi9/ubi`: podman, buildah and skopeo come from RHEL
rather than Ubuntu's archive, and `subscription-manager register` inside that container supplies
entitlement. GitHub offers no RHEL-hosted runner, so this is the closest thing to building on RHEL
without standing up a self-hosted machine. Both the split and the UBI-builder pattern follow
[redhat-et/edge-ai-image-pipelines](https://github.com/redhat-et/edge-ai-image-pipelines).

The runner's scratch disk (`/dev/nvme0n1`) is formatted and `/var/lib/containers`, `/var/tmp` and
the ISO output directory are moved onto it. Roughly 10 GB of embedded container images plus a
multi-gigabyte ISO does not fit in the container's default writable layer. If that device is
already mounted the step warns and continues rather than reformatting something in use.

## Storage layout

The kickstart puts `/boot` and the ESP outside LVM, then gives the rest of the NVMe to one volume
group named `rhel`: a 60 GiB xfs root, swap, and **the remainder left free on purpose**.
MicroShift's LVMS provisioner carves PVCs out of that free space, so PostgreSQL, RabbitMQ and the
model store have somewhere to live. Filling the VG would leave the cluster with no dynamic
provisioner. This assumes an NVMe of roughly 80 GiB or more; adjust `logvol / --size` if the root
filesystem needs to be bigger.

## Local build (subscribed RHEL 9 aarch64 host)

The container build now needs entitlement and a pull secret, so it no longer works on an
unsubscribed host. On a registered host podman injects the entitlement itself, so only the pull
secret has to be passed:

```
sudo podman build \
  --secret id=pullsecret,src=$HOME/pull-secret.json \
  -t localhost/jetson-orin-bootc-microshift:dev -f microshift/Containerfile .
sed -e "s|@EDGE_SSH_PUBKEY@|$(cat ~/.ssh/id_ed25519.pub)|" \
    -e "s|@EDGE_PASSWORD_HASH@|$(openssl passwd -6)|" microshift/config.toml > /tmp/config.toml
mkdir output
sudo podman run --rm --privileged --pull=newer --security-opt label=type:unconfined_t \
  -v /tmp/config.toml:/config.toml:ro -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  registry.redhat.io/rhel9/bootc-image-builder:latest \
  --type anaconda-iso --config /config.toml localhost/jetson-orin-bootc-microshift:dev
```
On a registered RHEL host podman mounts the entitlement into the container by itself.
