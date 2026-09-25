# jetson-image-builder

bootc image and unattended installer ISO for NVIDIA Jetson AGX Orin edge nodes running RHEL 9.8
image mode (aarch64), for deployment into a disconnected environment.

The device OS is Red Hat's JetPack-for-RHEL bootc image (RHEL 9.8, JetPack 6.2.2 / L4T r36.5.0,
kernel 5.14.0-687.42.1). Each **variant** is a directory deriving from it and layering on a
Kubernetes distribution, with every container image embedded so the cluster starts with no
registry reachable. One variant builds: `microshift/`. `k3s/` is
still in the tree and reuses the same shared layers, but **nothing builds it** — its caller
workflow was deleted, so reviving it starts with writing `build-k3s.yml` again.

Every layer is published as `ghcr.io/black-cloudlet/jetson-orin-bootc-<layer>`, under four tags
that all name the same manifest: `<YYYYMMDD-sha8>`, which never moves and is what a node is
rolled back to; `latest`; `stable`, so the four layers can be mirrored into the air-gapped
registry as one release set; and the MicroShift minor, `4.20`, on the two layers that contain
MicroShift. The finished variant also uploads an installer ISO as a workflow artifact.

`stable` is what a node is meant to follow for `bootc upgrade`, and it does not work yet: the
ISO installs the services layer **pinned by digest**, so the deployment origin has nothing to
re-resolve, and it names GHCR rather than the air-gapped registry. Closing that needs either a
one-time `bootc switch` on the node or a retag before bootc-image-builder — see CLAUDE.md.

Each layer is pushed separately and builds on the previous one's digest — four for microshift,
three for k3s. The two shared layers share the `base/` directory, as `Containerfile.base` and
`Containerfile.podman`:

```
base           the pinned vendor image republished under our own name, nothing added
  |
bound-images   the image-embedding machinery, plus jtop
  |
microshift   MicroShift 4.20 + NVIDIA device plugin + their images
  |            |
  |          services   cert-manager + External Secrets + their images
 or           |
k3s          k3s + NVIDIA device plugin + their images   (no workflow builds this)
  |
ISO
```

Application images sit **above** the variant layer, not below it: changing a service image
rebuilds `services` alone, and does not re-run the MicroShift RPM install or re-pull a
nine-image control plane. Changing the MicroShift version rebuilds `microshift` and `services`
but not `base` or `bound-images`. `k3s/` would reuse both untouched; it has no services layer,
because `services/` embeds into podman's containers-storage and writes
`/etc/microshift/manifests.d`, and k3s reads neither.

The two shared layers are two `Containerfile`s in one directory. Same directory because both are
infrastructure under every variant rather than a variant of their own; separate images so the
`base` digest stays a pure republish of what Red Hat ships. The file name and the image name
differ: `Containerfile.podman` / `smoke-test.podman.sh` build the image published as
`jetson-orin-bootc-bound-images`, from a CI job spelled `bound_images`.

## Embedded images

The node has no network at first boot, so every container image it will ever run is copied into
`/usr/lib/containers-image-cache` at build time and replayed into containers-storage at boot. The
build cannot simply `podman pull`: storage is overlayfs on overlayfs, and the vfs fallback would
cost image size × layer count.

Each layer embeds its own: `microshift` takes MicroShift's control plane and the device plugin,
`services` takes every image its manifests name. Only the node's architecture is stored
(`--multi-arch=system`), and an upgrade's first boot removes the images the previous OS image
had put in containers-storage and this one no longer names — nothing else prunes that store
until kubelet's image GC does, at 85% of the root filesystem, and what it would delete is
exactly these. **An image a manifest names but nothing embedded
is a pod stuck in `ImagePullBackOff` on a disconnected node**, so both layers derive the list by
rendering the manifests with kustomize (`microshift/manifest-images.sh`) rather than keeping one
by hand, and `services/smoke-test.sh` re-runs the same scan against the finished cache. A
registry-qualified reference is part of that: CRI-O resolves a short name against
`unqualified-search-registries` instead of looking in the local store first, so the smoke test
rejects one. `SERVICE_IMAGES` is still there, for an image no manifest names.

| Path | Does |
| ---- | ---- |
| `base/Containerfile.base` | the pinned JetPack-for-RHEL image, republished; adds nothing |
| `base/smoke-test.base.sh` | checks the vendor image is still what CLAUDE.md says it is |
| `base/Containerfile.podman` | `FROM` base + the physically-bound-images machinery + jtop |
| `base/smoke-test.podman.sh` | checks the machinery, and that no image was embedded in this layer |
| `base/physically-bound-images/embed_image.sh` | build time: copy one image into the cache baked into the OS image |
| `base/physically-bound-images/copy_embedded_images.sh` | boot time: replay that cache into containers-storage, and drop the set a previous OS image left there |
| `base/physically-bound-images/copy-embedded-images.service` | the unit that runs it, once per boot |
| `microshift/Containerfile` | `FROM` bound-images + MicroShift 4.20 + NVIDIA device plugin + their images |
| `microshift/manifest-images.sh` | renders manifest roots and prints every image they name |
| `microshift/config.toml` | bootc-image-builder config — the unattended kickstart and the ISO label |
| `microshift/smoke-test.sh` | checks run inside the finished image before it is pushed |
| `services/Containerfile` | `FROM` microshift + cert-manager, External Secrets and their images |
| `services/manifests/` | one kustomize root per component, applied by MicroShift at every start |
| `services/smoke-test.sh` | renders every root, checks the patches took, the ratios hold and the cache is whole |
| `k3s/*` | the k3s variant — still here, built by nothing |
| `.github/workflows/build-image.yml` | reusable — builds and pushes one layer |
| `.github/workflows/build-iso.yml` | reusable — turns a pushed image into an installer ISO |
| `.github/workflows/build-microshift.yml` | the only caller — chains base → bound-images → microshift → services → ISO |

The bound-images job is spelled `bound_images` in the callers: a hyphen in a job id makes
`needs.bound-images` parse as a subtraction, which resolves to nothing instead of failing. The
image it publishes keeps the hyphen.

## Services on the cluster

`services/manifests/` holds one kustomize root per component under
`/etc/microshift/manifests.d/`. MicroShift sorts them, applies each with the equivalent of
`kubectl apply -k` at every start, and retries a root that fails every 10s for ten minutes — so
the number prefixes are the ordering, and a CRD applied in one root but not yet established when
the next one needs it sorts itself out.

| root | what it is |
|---|---|
| `010-cert-manager` | upstream's static manifest, pinned by `CERT_MANAGER_VER`. Three Deployments, no Helm and no `startupapicheck` Job. Patched only for resources |
| `020-external-secrets` | upstream's static manifest, pinned by `EXTERNAL_SECRETS_VER`. Three Deployments, patched for resources, to drop the UID upstream pins, and into namespace `external-secrets` |

Both upstream installs are `curl`'d at build time, not vendored, and patched from the roots —
never forked. One strategic-merge patch file per Deployment: the kustomize inside `oc` is older
than the standalone tool, and a multi-document patch file makes some of those versions panic. A
patch that matches nothing fails the build, which is what catches a rename upstream.

**The UID.** External Secrets pins `runAsUser: 1000` on all three of its containers. MicroShift's
`restricted-v2` SCC assigns a UID out of the namespace's `openshift.io/sa.scc.uid-range` and
refuses a pod that names its own, so without the patch the Deployments are admitted and every
pod they create is refused — a failure that shows up in `oc describe rs`, not in the Deployment.
The patches delete the field; `runAsNonRoot: true` stays, so the SCC still only chooses *which*
non-root UID.

**The namespace.** Upstream installs External Secrets into `default` and ships no namespace of
its own — all ten of its namespaced objects, the ServiceAccount subjects of both
ClusterRoleBindings and of the leaderelection RoleBinding, and the `clientConfig` of both
ValidatingWebhookConfigurations name it. `020` adds a `Namespace` resource and a `namespace:`
line, and the kustomize namespace transformer moves all of that. It does not reach a namespace
spelled inside a container argument, of which there are three — cert-controller's
`--service-namespace` and `--secret-namespace`, and the webhook's `--dns-name`, which is the
Service DNS name `external-secrets-webhook.<namespace>.svc`. Those are two JSON patches
(`cert-controller-args.yaml`, `webhook-args.yaml`): `args` is a list of strings with no merge
key, so a strategic merge would replace the list whole and drop whatever upstream adds to it
later. Each replacement carries a `test` op on the string it expects, so an upstream reorder
fails the build. Miss any of the three and cert-controller writes the webhook's serving
certificate where nothing reads it, the webhook never serves, and no `ExternalSecret` can be
created. The strategic-merge patches keep saying `namespace: default` on purpose: patches run
before the namespace transformer, so that is how the resource is still spelled when they
select it.

**Requests and limits**, on every container in both roots, to one rule: **memory request equals
the limit (1:1), and the CPU limit is four times the request (1:4)**.

| root | Deployment | container | CPU req → limit | memory req = limit |
|---|---|---|---|---|
| `010` | `cert-manager` | `cert-manager-controller` | 50m → 200m | 128Mi |
| `010` | `cert-manager-cainjector` | `cert-manager-cainjector` | 50m → 200m | 256Mi |
| `010` | `cert-manager-webhook` | `cert-manager-webhook` | 25m → 100m | 64Mi |
| `020` | `external-secrets` | `external-secrets` | 50m → 200m | 256Mi |
| `020` | `external-secrets-webhook` | `webhook` | 25m → 100m | 128Mi |
| `020` | `external-secrets-cert-controller` | `cert-controller` | 25m → 100m | 128Mi |

Upstream ships almost none of this — cert-manager sets nothing at all, External Secrets sets
`10m`/`32Mi` on one of its three — which makes every one of these pods BestEffort and the first
thing evicted under pressure. Memory 1:1 means a pod is never evicted for growing past a request
it was never going to stay under; it is OOM-killed at its own ceiling instead, which is a
container problem rather than a node one. CPU 1:4 leaves burst room for the reconcile storm at
start-up, and is why these stay Burstable rather than Guaranteed. The smoke test enforces the
ratios by arithmetic over the render, so an edit cannot quietly break one; the sizes themselves
are estimates and want a look under load.

To add a component (PostgreSQL, RabbitMQ, whatever serves the model), add a numbered directory
with a `kustomization.yaml`; the build embeds whatever images it renders.

Two things are not settled. Nothing here creates a `SecretStore` or `ClusterSecretStore`, so
External Secrets has no source to read from yet. And cert-manager
was installed for KServe's webhook certificates; KServe is gone and External Secrets issues its
own from `cert-controller`, so what still needs cert-manager is an open question.

The embedded cache is paid for twice on the eMMC — once in `/usr`, once when it is replayed into
containers-storage under `/var` — so check the `du -sh` the smoke test prints against the 40 GiB
root before flashing.

## Adding a variant

Create `<name>/` with a `Containerfile` (`FROM` the bound-images layer via an `ARG BASE_IMAGE`), a
`config.toml` and a `smoke-test.sh`, then copy `build-microshift.yml` and point its variant job
and `iso` job at the new directory. The `base` and `bound_images` jobs are reused unchanged.
That is also how the k3s variant comes back: everything under `k3s/` is still here, only its
caller was deleted.

Nothing in the reusable workflows is MicroShift-specific: layer-shaped checks live in each
layer's own `smoke-test.sh`, and the kickstart in the variant's own `config.toml` — MicroShift's
leaves free extents for LVMS, while the k3s one grows root over the whole VG because local-path
provisions out of a directory on the root filesystem.

Provisioning the flashing station and flashing the Jetson QSPI are a separate concern and live in
**[black-cloudlet/jetson-installer-config](https://github.com/black-cloudlet/jetson-installer-config)**
(`mirror.sh`, `install-offline.sh`). The QSPI must be flashed from an **R36.5.x** BSP — the same
L4T line as the image built here — before a device can boot this ISO.

## Secrets

| secret | purpose |
|---|---|
| `RH_REGISTRY_USER` / `RH_REGISTRY_PASSWORD` | pull `registry.redhat.io/rhel9/bootc-image-builder` |
| `RHSM_USERNAME` / `RHSM_PASSWORD` | Red Hat account — both jobs register with subscription-manager for the MicroShift RPMs and bib's Anaconda depsolve |
| `OPENSHIFT_PULL_SECRET` | pull secret JSON from console.redhat.com/openshift/install/pull-secret — pulls MicroShift's and the device plugin's container images at build time. The services layer's images (`quay.io/jetstack`, `oci.external-secrets.io`) are public and pulled anonymously |
| `JETSON_SSH_PUBKEY` | public key for the `cloudlet` user |
| `JETSON_PASSWORD_HASH` | `openssl passwd -6` output for the `cloudlet` user — the hash, not the password |

Both `JETSON_*` secrets are validated before bib runs: unset, empty, multi-line, or a plaintext
password where a `$6$salt$hash` is expected fails the ISO job at the render step. The kickstart
uses `--iscrypted`, so a plaintext value would install an account nobody can log into, and an
empty one an account with no password at all — neither is visible until the ISO is booted.

Entitlement comes from registering inside the build container, not from a certificate tarball —
nothing expires in a secret, and `redhat.repo` is generated fresh by the registration. Each run
job registers and releases the slot again in an `if: always()` unregister step — every job,
including `base`, which installs nothing at all, so that all layers share one code path. The
subscription has to carry an OpenShift entitlement or `rhocp-4.20-for-rhel-9-aarch64-rpms` never
appears and the build fails at `--enablerepo`. The bound-images layer needs the plain RHEL repos
too, since it installs `python3`/`python3-pip` for jtop.

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

The kickstart in `microshift/config.toml` is fully unattended: it wipes the on-board eMMC
`mmcblk0` only (the USB key and any fitted NVMe are ignored), creates `cloudlet` in `wheel`,
locks root, and reboots ejecting the media. Booting it on a devkit whose eMMC still holds the factory
L4T install is destructive — that is the point, but there is no confirmation prompt.

The network is **static**: the device comes up as `jetson-1` on `192.168.1.10/24` via
`192.168.1.254`, on `eth0`, with `192.168.1.1` as its resolver and `cloudlet.local` as the search
domain. That resolver has to answer — an unreachable one blocks every lookup for the glibc
timeout rather than failing at once. Every device imaged from a given ISO gets the same address
and hostname, so a second node on the same segment collides — change them here and rebuild, or
fix up per device after the first boot. Timezone is `Asia/Jerusalem` with the hardware clock in
UTC.

1. Flash QSPI on the station from a **R36.5.x** BSP (same L4T line as the image):
   `sudo ./flash.sh p3737-0000-p3701-0000-qspi external`
2. `dd` the ISO to a USB key, plug it in, ESC at the NVIDIA logo, pick USB. Pull any SD card
   first, so the eMMC cannot enumerate as anything but `mmcblk0`.
3. Wait for the reboot, then over serial (`ttyTCU0`) or `ssh cloudlet@192.168.1.10`:
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
   sudo -E oc get pods -n cert-manager     # three, Running
   sudo -E oc get pods -n external-secrets  # three, Running
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
ssh -N -L 6443:127.0.0.1:6443 cloudlet@192.168.1.10 &
ssh cloudlet@192.168.1.10 sudo cat /var/lib/microshift/resources/kubeadmin/kubeconfig > ~/.kube/jetson
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
`server:` already names the address. The hostname file (`jetson-1/kubeconfig`) works as well, but
the client has to resolve `jetson-1` itself — through the segment resolver, or
`192.168.1.10 jetson-1` in its own `/etc/hosts`. None of this is baked into the image: the
address is per device and still an open question (see CLAUDE.md).

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

The host's `/mnt` is bind-mounted into the job container as `/scratch`, and `/var/lib/containers`,
`/var/tmp` and the ISO output directory are bound onto it: partly for space, mainly because the
container's own writable layer is overlayfs, on which podman cannot use the native layer diff and
every commit takes about two minutes. RHEL's `metacopy=on` mount option has the same effect and
is stripped from `storage.conf`. The step fails unless podman reports `Native Overlay Diff:true`.

## Storage layout

The install target is the devkit's **on-board 64 GB eMMC** (`mmcblk0`), not an NVMe. The kickstart
puts `/boot` and the ESP outside LVM, then gives the rest of the device to one volume group named
`rhel`: a 40 GiB xfs root, no swap, and **the remainder left free on purpose**. MicroShift's LVMS
provisioner carves PVCs out of that free space, so PostgreSQL, RabbitMQ and the model store have
somewhere to live. Filling the VG would leave the cluster with no dynamic provisioner.

The budget: ~58 GiB of eMMC user area, ~1.6 GiB of it spent on the ESP and `/boot`, ~56.5 GiB in
the VG, 40 GiB root, **~16.5 GiB free for PVCs**. The root figure is set by what has to fit in it —
the embedded images in `/usr` — MicroShift's control plane, the device plugin, cert-manager and
External Secrets — the copy `copy-embedded-images.service` replays into `/var/lib/containers`,
and a second deployment staged by `bootc upgrade`. xfs grows but never
shrinks, so an undersized root is the recoverable mistake. Confirm the exact device size with
`lsblk -bdno SIZE /dev/mmcblk0` before trusting the free-space figure.

Two consequences of the eMMC target worth knowing. It contradicts the "boots from external storage"
half of the QSPI-only flash decision, so the UEFI boot order has to list the eMMC — check it in the
UEFI menu on first boot. And eMMC is slower and far less write-durable than NVMe, which etcd's
fsync pattern and write-heavy PVCs (PostgreSQL, RabbitMQ) will feel; fitting an NVMe to the M.2
slot and re-imaging with `--only-use=nvme0n1` and a larger root is the upgrade path.

There is no swap on purpose. kubelet's `failSwapOn` defaults to true, so an active swap device is a
plausible reason for `microshift.service` never to come up; and `logvol swap --recommended` sizes
swap from RAM rather than from the disk — half of it in the 8–64 GiB band, so ~15 GiB on the 32 GB
SOM and ~31 GiB on a 64 GB one — taken out of the same extents LVMS provisions from. On this device
that alone overran the disk.

## Local build (subscribed RHEL 9 aarch64 host)

Everything above `base` needs entitlement, so this does not work on an unsubscribed host. On a
registered host podman injects it, so only the pull secret has to be passed:

```
sudo podman build -t localhost/jetson-orin-bootc-base:dev -f base/Containerfile.base .
sudo podman build \
  --build-arg BASE_IMAGE=localhost/jetson-orin-bootc-base:dev \
  -t localhost/jetson-orin-bootc-bound-images:dev -f base/Containerfile.podman .
sudo podman build \
  --secret id=pullsecret,src=$HOME/pull-secret.json \
  --build-arg BASE_IMAGE=localhost/jetson-orin-bootc-bound-images:dev \
  -t localhost/jetson-orin-bootc-microshift:dev -f microshift/Containerfile .
sudo podman build \
  --secret id=pullsecret,src=$HOME/pull-secret.json \
  --build-arg BASE_IMAGE=localhost/jetson-orin-bootc-microshift:dev \
  -t localhost/jetson-orin-bootc-services:dev -f services/Containerfile .
sed -e "s|@JETSON_SSH_PUBKEY@|$(cat ~/.ssh/id_ed25519.pub)|" \
    -e "s|@JETSON_PASSWORD_HASH@|$(openssl passwd -6)|" microshift/config.toml > /tmp/config.toml
mkdir output
sudo podman run --rm --privileged --pull=newer --security-opt label=type:unconfined_t \
  -v /tmp/config.toml:/config.toml:ro -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  registry.redhat.io/rhel9/bootc-image-builder:latest \
  --type anaconda-iso --config /config.toml localhost/jetson-orin-bootc-services:dev
```
