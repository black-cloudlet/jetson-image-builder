# jetson-image-builder

bootc image and unattended installer ISO for NVIDIA Jetson AGX Orin edge nodes running RHEL 9.8
image mode (aarch64), for deployment into a disconnected environment.

The device OS is Red Hat's JetPack-for-RHEL bootc image (RHEL 9.8, JetPack 6.2.2 / L4T r36.5.0,
kernel 5.14.0-687.42.1). Each **variant** is a directory deriving from it and layering on a
Kubernetes distribution, with every container image embedded so the cluster starts with no
registry reachable. Today there is one variant, `microshift/`; `k3s/` is expected beside it.

Every layer is published as `ghcr.io/black-cloudlet/jetson-orin-bootc-<layer>:<YYYYMMDD-sha8>`,
and the finished variant also uploads an installer ISO as a workflow artifact.

Each variant is built as **three layers**, each pushed separately and each building on the
previous one's digest:

```
base   the pinned vendor image, republished under our own name
  |
apps   physically-bound-images machinery + APP_IMAGES
  |
microshift   MicroShift 4.20 + NVIDIA device plugin + their images
  |
ISO
```

Changing an application image rebuilds `apps` and above but not `base`; changing the MicroShift
version rebuilds only the top layer and does not re-pull the application images. A future `k3s/`
reuses `base` and `apps` untouched.

| Path | Does |
| ---- | ---- |
| `base/Containerfile` | the pinned JetPack-for-RHEL image, republished; adds nothing |
| `base/smoke-test.sh` | checks the vendor image is still what CLAUDE.md says it is |
| `apps/Containerfile` | `FROM` base + physically-bound-images machinery + `APP_IMAGES` |
| `apps/smoke-test.sh` | checks the embedding machinery and any embedded application images |
| `microshift/Containerfile` | `FROM` apps + MicroShift 4.20 + NVIDIA device plugin + their images |
| `microshift/config.toml` | bootc-image-builder config — the unattended kickstart and the ISO label |
| `microshift/smoke-test.sh` | checks run inside the finished image before it is pushed |
| `physically-bound-images/` | shared scripts: embed at build time, replay into containers-storage at boot |
| `.github/workflows/build-image.yml` | reusable — builds and pushes one layer |
| `.github/workflows/build-iso.yml` | reusable — turns a pushed image into an installer ISO |
| `.github/workflows/build-microshift.yml` | caller — chains base → apps → microshift → ISO |

## Adding a variant

Create `<name>/` with a `Containerfile` (`FROM` the apps layer via an `ARG BASE_IMAGE`), a
`config.toml` and a `smoke-test.sh`, then copy `build-microshift.yml` and point its top job and
`iso` job at the new directory. The `base` and `apps` jobs are reused unchanged.

Nothing in the reusable workflows is MicroShift-specific: layer-shaped checks live in each
layer's own `smoke-test.sh`, and the kickstart in the variant's own `config.toml` (MicroShift's
leaves free extents for LVMS; k3s, whose local-path provisioner just uses a directory, would not
need to). A variant that runs no `dnf` against RHEL repos can pass `needs-entitlement: false` and
skip the subscription registration entirely, as the base job does.

Provisioning the flashing station and flashing the Jetson QSPI are a separate concern and live in
**[black-cloudlet/jetson-installer-config](https://github.com/black-cloudlet/jetson-installer-config)**
(`mirror.sh`, `install-offline.sh`). The QSPI must be flashed from an **R36.5.x** BSP — the same
L4T line as the image built here — before a device can boot this ISO.

## Secrets

| secret | purpose |
|---|---|
| `RH_REGISTRY_USER` / `RH_REGISTRY_PASSWORD` | pull `registry.redhat.io/rhel9/bootc-image-builder` |
| `RHSM_USERNAME` / `RHSM_PASSWORD` | Red Hat account — both jobs register with subscription-manager for the MicroShift RPMs and bib's Anaconda depsolve |
| `OPENSHIFT_PULL_SECRET` | pull secret JSON from console.redhat.com/openshift/install/pull-secret — pulls MicroShift's and the device plugin's container images at build time |
| `EDGE_SSH_PUBKEY` | public key for the `edge` user |
| `EDGE_PASSWORD_HASH` | `openssl passwd -6` output for the `edge` user |

Entitlement comes from registering inside the build container, not from a certificate tarball —
nothing expires in a secret, and `redhat.repo` is generated fresh by the registration. Each run
consumes a subscription slot and releases it again in an `if: always()` unregister step. The
subscription has to carry an OpenShift entitlement or `rhocp-4.20-for-rhel-9-aarch64-rpms` never
appears and the build fails at `--enablerepo`.

Three things to know about registering with an account password. It is a broader credential than
an organisation ID plus activation key, which can only attach subscriptions — if it leaks, so
does portal access. An account with SSO or two-factor cannot register this way at all; that is
the case where activation keys are the only option. And if the organisation has Simple Content
Access turned off, the register command needs `--auto-attach` or nothing will be entitled.

The pull secret is used only during the build; it is not written into the OS image. It covers
`quay.io/openshift-release-dev`, where MicroShift's control-plane images live; the separate
`RH_REGISTRY_*` pair covers `registry.redhat.io`, where bootc-image-builder lives. A pull secret
downloaded from console.redhat.com normally carries a `registry.redhat.io` entry too
(`jq -r '.auths | keys[]' pull-secret.json` to check), so the two can be collapsed into one
secret — kept separate so `RH_REGISTRY_*` can hold a narrow Registry Service Account instead.

## Install

The kickstart in `microshift/config.toml` is fully unattended: it wipes `nvme0n1` only (the USB
key and eMMC are ignored), creates `edge` in `wheel`, locks root, and reboots ejecting the media.
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
   image into containers-storage before MicroShift starts, and the cluster settles after that.
   `oc` is on the node (`openshift-clients`, installed with MicroShift; the `microshift` RPM
   ships no client). The kubeconfig is root-owned `0600`, hence `sudo -E` — plain `sudo` drops
   `KUBECONFIG` and `oc` falls back to port 8080:
   ```
   journalctl -u copy-embedded-images     # finishes before microshift is started
   systemctl status microshift            # wait for "MICROSHIFT READY"
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

### Reaching the cluster from another machine

The firewall opens 22, 443 and 6443 on the public zone, so the API server and the router are
reachable from the air-gapped LAN and not only from the node. The credential is a client
certificate inside the kubeconfig: there is no `oc login` and no token, and whoever holds the
file is cluster-admin. The client itself has to cross the air gap on the USB key alongside the
ISO, unless you drive the node's own `oc` over SSH.

The default kubeconfig points at loopback, so an SSH tunnel matches the serving certificate as
generated and needs no change on the device:

```bash
ssh -N -L 6443:127.0.0.1:6443 edge@192.168.1.10 &
ssh edge@192.168.1.10 sudo cat /var/lib/microshift/resources/kubeadmin/kubeconfig > ~/.kube/jetson
KUBECONFIG=~/.kube/jetson oc get pods -A
```

Talking to `192.168.1.10:6443` directly needs that address *in* the serving certificate — copying
the loopback kubeconfig and editing its `server:` line fails with `x509: certificate is valid for
localhost, ... not 192.168.1.10`. MicroShift writes one kubeconfig per name the certificate
covers under `/var/lib/microshift/resources/kubeadmin/`: the flat file for loopback, then
`<name>/kubeconfig` for the node hostname and for every `apiServer.subjectAltNames` entry.
`sudo ls` that directory to see which names you got. To add the address, create
`/etc/microshift/config.yaml` (the image ships only `config.yaml.default`):

```yaml
apiServer:
  subjectAltNames:
    - 192.168.1.10
```

then `sudo systemctl restart microshift` and copy `192.168.1.10/kubeconfig` off the node — its
`server:` already names the address. The hostname file (`Jetson/kubeconfig`) works as well, but
the kickstart sets no `--nameserver`, so the client needs `192.168.1.10 Jetson` in its own
`/etc/hosts`. None of this is baked into the image: the address is per device and still an open
question (see CLAUDE.md).

## Where the build runs

`build-image.yml` builds one layer and `build-iso.yml` turns the final image into an ISO; both
are reusable (`workflow_call`), and `build-microshift.yml` chains them. Each layer is pushed and
handed to the next **by digest**, not by tag, so a layer builds on exactly what was pushed.

`runs-on: ubuntu-24.04-arm` for a native arm64 machine, but every step executes inside
`registry.access.redhat.com/ubi9/ubi`: podman, buildah and skopeo come from RHEL rather than
Ubuntu's archive, and `subscription-manager register` inside that container supplies
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

The MicroShift layer needs entitlement, so this does not work on an unsubscribed host. On a
registered host podman injects the entitlement itself, so only the pull secret has to be
passed — and the base layer needs neither:

```
sudo podman build -t localhost/jetson-orin-bootc-base:dev -f base/Containerfile .
sudo podman build \
  --secret id=pullsecret,src=$HOME/pull-secret.json \
  --build-arg BASE_IMAGE=localhost/jetson-orin-bootc-base:dev \
  -t localhost/jetson-orin-bootc-apps:dev -f apps/Containerfile .
sudo podman build \
  --secret id=pullsecret,src=$HOME/pull-secret.json \
  --build-arg BASE_IMAGE=localhost/jetson-orin-bootc-apps:dev \
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
