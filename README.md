# jetson-image-builder

Builds the operating system for **NVIDIA Jetson AGX Orin edge AI nodes** that run fully
disconnected. The output is a RHEL 9.8 image-mode (bootc) container image with a Kubernetes
cluster and every service it runs baked in, plus an unattended installer ISO that puts it on the
device.

- [What this is for](#what-this-is-for)
- [The platform](#the-platform)
- [The layers](#the-layers)
- [How a node runs with no registry](#how-a-node-runs-with-no-registry)
- [CI](#ci)
- [Secrets](#secrets)
- [Installing a node](#installing-a-node)
- [Building locally](#building-locally)
- [Extending it](#extending-it)
- [Not settled yet](#not-settled-yet)
- [Repository layout](#repository-layout)

## What this is for

The nodes run image-recognition inference on a Jetson AGX Orin. During a mission a node has **no
network at all**. Between missions it joins the organisation's **air-gapped network** for
maintenance, upgrades and new deployments. Neither network ever reaches the internet.

That rules out anything that pulls at run time. So everything a node needs is decided at build
time and shipped inside one OS image:

- the OS, kernel and NVIDIA drivers (JetPack for RHEL);
- the Kubernetes distribution (MicroShift 4.20) and its GPU device plugin;
- the services that run on the cluster (cert-manager, External Secrets, KServe and a Triton
  model server);
- a kiosk: Firefox fullscreen on the DisplayPort output, drawn on the GPU it shares with the
  model;
- **every container image** any of the above will ever start, so the cluster comes up with no
  registry reachable.

Upgrades follow the same path: build a new image here, carry it into the air-gapped registry,
and the node moves to it with `bootc`, the whole OS as one atomic unit, with rollback.

The flashing station, which writes the Jetson's boot firmware, is a separate repository:
**[black-cloudlet/jetson-installer-config](https://github.com/black-cloudlet/jetson-installer-config)**
(`mirror.sh`, `install-offline.sh`).

## The platform

### Hardware

| Part  | Role |
|-------|------|
| P3701 | System on Module: CPU, GPU, RAM (32 GB on the POC; a larger module for production) |
| P3737 | Carrier board: I/O, networking, power |
| P3730 | The assembled Jetson AGX Orin Developer Kit (P3737 + P3701 + cooling) |

The OS installs to the devkit's **on-board 64 GB eMMC** (`mmcblk0`). An M.2 NVMe is the planned
upgrade (see [Storage layout](#storage-layout)).

### Software

| | |
|---|---|
| OS | RHEL 9.8, image mode (bootc), aarch64 |
| Base image | Red Hat's JetPack-for-RHEL bootc image, pinned: `quay.io/redhat-user-workloads/jetpack-for-rhel-tenant/rhel-98-bootc:6.2.2_5.14.0-687.42.1_090326003719` |
| JetPack / L4T | JetPack 6.2.2, L4T **r36.5.0**, kernel `5.14.0-687.42.1.el9_8` |
| GPU integration | Ships in the base image: the Tegra kernel modules, `nvidia-container-toolkit`, CDI (`/etc/cdi/nvidia.yaml` generated at boot) |
| Kubernetes | MicroShift 4.20. A k3s variant is still in the tree, but nothing builds it |
| Boot firmware | Flashed separately onto the Jetson's QSPI from a Jetson Linux **R36.5.x** BSP, which must match the image's L4T line |

### Three machines, three roles

```
┌──────────────────────────┐   ┌──────────────────────────────┐   ┌──────────────────────────┐
│ Online RHEL host         │   │ Flashing station (RHEL, x86) │   │ GitHub Actions (internet) │
│ subscription-registered  │   │ standalone, NO network        │   │ ubuntu-24.04-arm runners  │
│                          │   │                              │   │                          │
│ mirror.sh ──► USB key ───┼──►│ install-offline.sh           │   │ Containerfile ──► GHCR    │
│ (BaseOS+AppStream tars)  │   │ flash.sh …-qspi external     │   │ bootc-image-builder       │
└──────────────────────────┘   └──────────┬───────────────────┘   └──────────┬───────────────┘
                                          │ QSPI/UEFI only                    │ ISO
                                          ▼                                   ▼
                               ┌──────────────────────────────────────────────────────────┐
                               │ Jetson AGX Orin: install from USB (ISO) onto the eMMC,   │
                               │ later `bootc switch/upgrade` from the air-gapped registry │
                               └──────────────────────────────────────────────────────────┘
```

This repository is the right-hand column.

## The layers

The image is built as a chain of five container images. Each is `FROM` the one before it, by
digest, and each is pushed to GHCR on its own as `ghcr.io/black-cloudlet/jetson-orin-bootc-<name>`:

```
 base            Red Hat's JetPack-for-RHEL image, republished under our name
   │
 bound-images    image-embedding machinery + jtop
   │
 kiosk           Firefox on the DisplayPort output (GNOME Kiosk, Wayland, GPU)
   │
 microshift      MicroShift 4.20 + NVIDIA device plugin (GPU time slicing) + their images
   │
 services        cert-manager, External Secrets, KServe, Triton runtime + their images
   │
 ISO             unattended installer (bootc-image-builder), built from services
```

| Layer | Built from | Published as | Adds | Needs RHEL entitlement |
|---|---|---|---|---|
| base | `base/Containerfile.base` | `jetson-orin-bootc-base` | nothing: a pure republish of the vendor image | no (registers anyway, one code path) |
| bound-images | `base/Containerfile.podman` | `jetson-orin-bootc-bound-images` | the scripts and boot unit that embed and restore container images; `jtop` | yes (`python3-pip`) |
| kiosk | `kiosk/Containerfile` | `jetson-orin-bootc-kiosk` | GNOME Kiosk, Firefox, the kiosk service | yes (AppStream) |
| microshift | `microshift/Containerfile` | `jetson-orin-bootc-microshift` | MicroShift, firewall, node networking, GPU device plugin, 9+ embedded images | yes (`rhocp` + `fast-datapath` repos) |
| services | `services/Containerfile` | `jetson-orin-bootc-services` | four kustomize roots applied by MicroShift, 7 embedded images | no RPMs |

**Why a chain instead of one Containerfile:** rebuild cost. The microshift layer installs RPMs
and pulls MicroShift's whole control plane (nine images); the services layer changes far more
often. With services on top, changing a service rebuilds and re-pushes only that layer. Changing
the MicroShift version rebuilds `microshift` and `services`, never the three shared layers.
Changing the kiosk rebuilds everything above it, including MicroShift's image pulls; it
changes rarely, and putting it on top instead would reinstall Firefox on every service change.

### base: the vendor image, republished

`base/Containerfile.base` is `FROM` the pinned JetPack-for-RHEL tag plus `bootc container lint`,
nothing else. It exists so the pin lives in exactly one file, so the air-gapped registry gets a
name we control, and so its digest stays a pure republish of what Red Hat ships.

The vendor image already contains everything the GPU needs: the Tegra kernel modules
(`nvgpu.ko`), the JetPack user space, `nvidia-container-toolkit`, the service that writes the CDI
spec at boot, the console kernel arguments, and `podman`/`skopeo`. So no layer here adds NVIDIA
packages. The tag is pinned in full and never `latest`, because the kernel modules are built
against that exact kernel.

**Smoke test** (`base/smoke-test.base.sh`) checks the vendor image still is what we expect: bootc,
`/etc/nv_tegra_release`, the kmod and container-toolkit packages, `nvgpu.ko`, `skopeo`, `podman`,
and `lvm2` (the root filesystem is on LVM and MicroShift's storage needs `vgs`).

### bound-images: embedding machinery and jtop

`base/Containerfile.podman`. It shares `base/` because it is infrastructure under every
variant, not a variant of its own. Two things:

- **Physically bound images.** Three files from `base/physically-bound-images/`:
  `embed_image.sh` (build time: copy one image into a cache inside `/usr`),
  `copy_embedded_images.sh` and `copy-embedded-images.service` (boot time: restore that cache
  into the container store). How they work is in
  [How a node runs with no registry](#how-a-node-runs-with-no-registry).
- **`jtop`** (jetson-stats, pinned by `JTOP_VER`), installed with `pip3 install --prefix=/usr`:
  on bootc, `/usr/local` is per-machine state and would not ship in the image.

Its smoke test checks the machinery is installed and enabled and `jtop` is present. It also
fails if this layer embedded any image, since anything embedded here would be paid for by every
variant.

The file name and the image name differ: `Containerfile.podman` builds the image published as
`jetson-orin-bootc-bound-images`, from a CI job spelled `bound_images`. The underscore matters:
`needs.bound-images` would parse as a subtraction.

### kiosk: Firefox on the DisplayPort output

`kiosk/Containerfile`. Plug a monitor into the Jetson and the frontend opens fullscreen; unplug it
and the browser stops. It is shared, below the variant, because nothing in it is about the
cluster.

**Drawn on the GPU.** GNOME Kiosk is the Wayland compositor, driving the display directly through
NVIDIA's EGL and GBM; Firefox is its only window, a native Wayland client with hardware WebRender
(whether Firefox's blocklist lets it use the Tegra driver shows in `about:support`). There is no
Xorg, no Xwayland (`--no-x11`) and no GDM. The GPU is shared with Triton **unmetered**: the
screen runs outside Kubernetes, so the device plugin's time slices cannot count it. This was the
maintainer's call, because live video drawn on the CPU costs cores the pods need. Video
decoding stays on the CPU either way: Firefox has no hardware decoder on Jetson.

**How it runs.** `jetson-kiosk.service` runs `kiosk.sh` as the `kiosk` user (from `sysusers.d`:
no password, no shell) on tty1, which gives the session the seat's display and input devices
without root:
1. It waits until a DRM connector reports `connected`. With no monitor, nothing runs: no
   compositor, no Firefox decoding video for an empty port.
2. It waits until `KIOSK_URL` answers with anything but a 5xx, since MicroShift needs minutes
   after boot. The screen stays black meanwhile.
3. It starts `gnome-kiosk --wayland --display-server --no-x11`, waits up to 30 s for its socket,
   then starts Firefox in kiosk mode on a fresh profile on tmpfs (no state between sessions, no
   profile writes on the eMMC).
4. Ten seconds without a monitor, Firefox exiting, or GNOME Kiosk dying ends the session.
   systemd starts it again, back at step 1.

**Who loses when the CPU runs short: the screen.** The unit has `CPUWeight=20` (pods win under
contention), `CPUQuota=300%` and `MemoryMax=2G`. Starved, the video on screen drops frames and
detection runs at full speed. Both sizes are guesses until the busiest screen is measured. GPU
time has no such control.

**Configuration.**
- `/etc/jetson-kiosk.conf` holds `KIOSK_URL`. It is in `/etc` so one device can point elsewhere
  without a rebuild. The default, `http://jetson-1.cloudlet.local/`, is a placeholder until the
  frontend's Route host is known; the name resolves to `10.44.0.1` through the kickstart's
  `/etc/hosts` line.
- `/etc/firefox/policies/policies.json`: no updates, telemetry, studies or safe-browsing
  downloads (all would try the internet), no OpenH264 download, no disk cache, no crash-restore
  page, no developer tools, `about:config` or private windows.
- Ctrl-Alt-Fn is off: mutter's VT-switch key bindings are emptied in a schema override.
  Administration is over SSH.

**What the frontend has to live with** on this screen: no H.264 video (RHEL's Firefox has no
decoder for it, and the OpenH264 plugin is a download), nothing loaded from the internet, and
reconnecting its own streams, since nobody can press reload.

Its smoke test checks the service is enabled, that its user is the one `sysusers.d` creates, that
every command the script calls exists and the script parses, that the image carries NVIDIA's EGL
vendor file and a GBM library (without them there is no GPU path, so the layer fails), that the
VT-switch override applied, and that the policy file parses.

### microshift: Kubernetes and the GPU

`microshift/Containerfile` turns the OS into a single-node cluster:

- **MicroShift 4.20** from `rhocp-4.20-for-rhel-9-aarch64-rpms` and
  `fast-datapath-for-rhel-9-aarch64-rpms`, with `openshift-clients` (`oc`), `firewalld` and `jq`.
  No `dnf upgrade`: it could pull a kernel the Tegra modules were not built for.
- **Firewall.** The pod (`10.42.0.0/16`) and service (`10.43.0.0/16`) networks and
  `169.254.169.1` are trusted. SSH (22), the router (443) and the API server (6443) are open on
  the public zone.
- **A stable node IP on `lo`.** `stable-microshift.nmconnection` puts `10.44.0.1/32` on the
  loopback interface, and `config.d/10-node-ip.yaml` tells MicroShift to use it. Otherwise
  MicroShift binds to `eth0`'s address and restarts whenever it disappears, which pulling the
  cable at every mission does. This is Red Hat's procedure for fully disconnected hosts.
- **The NVIDIA device plugin**, so pods can request `nvidia.com/gpu`. CRI-O gets the NVIDIA
  runtime as its default (`/etc/crio/crio.conf.d/99-nvidia.toml`). The upstream plugin manifest
  (v0.20.0) is patched from `microshift/manifests/` for **GPU time slicing**: the Orin has one
  integrated GPU, so the plugin advertises it as **4** `nvidia.com/gpu` so four pods can share
  it. There is no memory isolation between them, so 4 is a claim about what fits in the
  module's RAM. A second patch runs the plugin as SELinux type `spc_t`: as `container_t` it
  cannot connect to kubelet's registration socket and logs `context deadline exceeded`.
- **Every image MicroShift and the plugin run**, embedded: the control-plane list from
  `microshift-release-info`, plus whatever the manifests name, found by rendering them with
  `microshift/manifest-images.sh`.

Its smoke test checks the units are enabled, that the `lo` address and `nodeIP` agree, the CRI-O
NVIDIA drop-in, how the time-slicing patch is wired in the rendered manifest, and that every
image is embedded.

### services: what runs on the cluster

`services/Containerfile` copies `services/manifests/` into `/etc/microshift/manifests.d/`,
downloads the upstream installs (version-pinned ARGs), and embeds every image the rendered
manifests name. MicroShift applies these kustomize roots itself at every start, **in name order**,
retrying a failing root every 10 s for up to 10 minutes. That is how a root that needs another
root's CRDs or webhook (`040` needs `030`) settles without anything sequencing it.

| Root | Service | What it does here | Namespace | Pods |
|---|---|---|---|---|
| `010-cert-manager` | cert-manager v1.21.2 | Issues KServe's webhook serving certificates (self-signed issuer, no ACME) | `cert-manager` | 3 |
| `020-external-secrets` | External Secrets v0.19.2 | Syncs secrets from an external store. **No store configured yet** | `external-secrets` (moved off `default`) | 3 |
| `030-kserve` | KServe v0.20.0, Standard (raw Deployment) mode | Turns an `InferenceService` into a model-serving Deployment + Service | `kserve` | 1 |
| `040-triton-runtime` | NVIDIA Triton (`25.02-py3-igpu`) | The `ClusterServingRuntime` every InferenceService uses: TensorRT and ONNX models on the iGPU | cluster-scoped | one per InferenceService |

Upstream manifests are downloaded at build time and **patched, never forked**. A patch that
stops matching fails the build.

**cert-manager.** Upstream's static manifest, patched only to add resource requests and limits.

**External Secrets.**
- Upstream pins `runAsUser: 1000`, which MicroShift's `restricted-v2` security policy refuses
  (it assigns each pod a UID from the namespace's range). The patches remove it;
  `runAsNonRoot: true` stays.
- Upstream installs into `default`. The root moves everything into `external-secrets`, including
  three namespace names inside container arguments. Those are JSON patches, each guarded by a
  `test` op, so an upstream reorder fails the build rather than rewriting the wrong argument.

**KServe.**
- Only `kserve-controller-manager` runs. It serves every webhook used here.
- Deleted, which also keeps their images out of the OS image:
  - `llmisvc-controller-manager`: LLM serving, and it pins `runAsUser: 1000`.
  - the local-model-cache controller and node agent: off upstream, and the agent mounts a
    hostPath.
  - the `ClusterStorageContainer`: its storage initializer downloads models over the network,
    which never happens here.
- `inferenceservice-config` is patched:
  - Standard mode instead of Serverless, which would need Knative and Istio.
  - No per-model Ingress.
  - No `uidModelcar`. KServe would stamp that fixed UID on every model pod, and `restricted-v2`
    would refuse them all.
- InferenceServices must **not** be created in `kserve`: the webhook that injects the model skips
  that namespace.

**Triton runtime.**
- The `-igpu` build is NVIDIA's Triton for Tegra's integrated GPU.
- Each predictor requests one `nvidia.com/gpu` time slice.
- No fixed UID; the restricted security context is spelled out in full.
- Memory request equals limit, because the iGPU allocates from the same RAM the container is
  charged for.

**How models get onto the node.** Two ways, both offline:
- **`oci://`** (a *modelcar*): the model packaged as a container image with the repository at
  `/models`, embedded like every other image. The image needs `sh`, `ln` and `sleep`.
- **`pvc://`**: a model repository copied into a volume on the node's LVM storage.

A TensorRT `.plan` only loads in the TensorRT version inside the Triton image, so build engines
with that image's `trtexec`, on an Orin.

**Resources rule.** Every container in every root has **memory request = limit** (a pod is
OOM-killed at its own ceiling rather than evicted for outgrowing its request) and **CPU limit =
4 × request** (burst room at start-up). Upstream sets almost none of this.

| Root | Workload | Container | CPU request → limit | Memory |
|---|---|---|---|---|
| `010` | `cert-manager` | `cert-manager-controller` | 50m → 200m | 128Mi |
| `010` | `cert-manager-cainjector` | `cert-manager-cainjector` | 50m → 200m | 256Mi |
| `010` | `cert-manager-webhook` | `cert-manager-webhook` | 25m → 100m | 64Mi |
| `020` | `external-secrets` | `external-secrets` | 50m → 200m | 256Mi |
| `020` | `external-secrets-webhook` | `webhook` | 25m → 100m | 128Mi |
| `020` | `external-secrets-cert-controller` | `cert-controller` | 25m → 100m | 128Mi |
| `030` | `kserve-controller-manager` | `manager` | 100m → 400m | 300Mi |
| `030` | `kserve-controller-manager` | `kube-rbac-proxy` | 10m → 40m | 64Mi |
| `040` | `triton-igpu` (per predictor) | `kserve-container` | 1 → 4 | 8Gi |

The ratios are enforced by the smoke test; the sizes are estimates until measured on hardware.
The model sidecar KServe injects stays at 10m/15Mi: KServe sets its request and limit from one
value.

**Smoke test** (`services/smoke-test.sh`). It renders every root with `oc`, converts the
render to JSON and queries it with `jq`, then checks:
- the workload set in each root;
- External Secrets: no `runAsUser`, `runAsNonRoot` everywhere, and `default` named nowhere
  outside its CRDs;
- the three `inferenceservice-config` values;
- every pod template and serving-runtime container admissible under `restricted-v2`: no fixed
  UID/GID/`fsGroup`, no host access or privilege, all capabilities dropped, `runAsNonRoot` and
  seccomp `RuntimeDefault`;
- every resource ratio;
- every image registry-qualified and embedded;
- no `ClusterStorageContainer`, and one KServe version throughout.

### k3s: in the tree, built by nothing

`k3s/` holds a second variant: k3s as a static binary, `k3s-selinux`, the same firewall rules, the
NVIDIA runtime as containerd's default, and its images as tarballs staged into k3s's image
directory at boot by `k3s-stage-assets.service`. Its kickstart grows the root over the whole disk
(k3s stores volumes on the root filesystem) and uses the ISO label `JETSON_ORIN_K3S`.

Its caller workflow was deleted, so nothing builds it. It would reuse both shared layers but have
no services layer: `services/` writes to MicroShift's manifest directory and embeds into podman's
container store, and k3s reads neither.

## How a node runs with no registry

Every container image the node will ever start is copied **into the OS image** at build time and
restored into the container store at boot:

1. **Build time.** Each layer runs `embed_image.sh` for every image it needs. The script copies
   the image (node architecture only, `--multi-arch=system`) into `/usr/lib/containers-image-cache/<sha>/`
   and records `reference,sha` in `mapping.txt`. It skips references already cached, and handles
   `repo:tag@sha256:…` references, which `skopeo` itself rejects.
2. **Boot time.** `copy-embedded-images.service` runs once per boot, **before MicroShift**,
   through a drop-in: `Requires=` and `After=`. It copies every cached image into
   containers-storage. It also removes images a previous OS version put there that this one no
   longer names, because nothing else would prune them except kubelet's image garbage
   collection at 85% disk, which would delete exactly the images the node cannot re-pull. It
   does not wait for the network: the copy is local.

The image list is **derived, not maintained**. Each layer renders its own manifests with
`microshift/manifest-images.sh` and embeds whatever `image:` fields they contain, so the pinned
versions in the Containerfiles are the only list. `SERVICE_IMAGES` in `services/Containerfile`
covers images named nowhere in a manifest, such as a model's `oci://` image. Every reference must
be registry-qualified: CRI-O resolves a short name by trying registries on the network, not the
local store.

The cache is paid for twice on the eMMC (in `/usr`, and again in `/var` once restored), so the
services smoke test prints its size.

Seven images come from the services layer today: cert-manager ×3, External Secrets,
`kserve-controller`, `kube-rbac-proxy`, and Triton, the largest by far.

## CI

### Workflows

| Workflow | Kind | Does |
|---|---|---|
| `.github/workflows/build-image.yml` | reusable (`workflow_call`) | builds, tests and pushes **one layer** |
| `.github/workflows/build-iso.yml` | reusable (`workflow_call`) | turns a pushed image into an **installer ISO** |
| `.github/workflows/build-microshift.yml` | caller | chains them: `base` → `bound_images` → `kiosk` → `microshift` → `services` → `iso` |

`build-microshift.yml` runs on **push to `main`** that touches `base/`, `kiosk/`, `microshift/`,
`services/` or the workflows, and on **manual dispatch** (`workflow_dispatch`). **Nothing runs
on a pull request**: to validate a branch, dispatch the workflow against it from the Actions tab.

### Where it runs

GitHub has no RHEL runner, so each job runs on **`ubuntu-24.04-arm`** (native arm64; emulating
arm64 is not viable) **inside a `registry.access.redhat.com/ubi9/ubi` container**. The container
supplies RHEL's `podman`, `buildah` and `skopeo`, and a `subscription-manager register` inside it
supplies entitlement for the RHEL and OpenShift repos.

The runner's `/mnt` disk is mounted as `/scratch`, and container storage, `/var/tmp` and the ISO
output go there. That is for space (the embedded images run to gigabytes), and so podman can use
the kernel's native overlay diff: on the job container's own overlay filesystem, or with RHEL's
default `metacopy=on`, every layer commit walks the whole filesystem (~2 minutes each). The job
strips `metacopy` and fails unless `podman info` reports `Native Overlay Diff:true`.

### One layer (`build-image.yml`)

1. Install podman/buildah/skopeo/jq in the UBI container and register with Red Hat.
2. Move container storage onto `/scratch`.
3. Compute tags and validate them *before* the build.
4. Log in to GHCR and write the OpenShift pull secret (build-time only, never in the image).
5. Build the layer with the **repository root as context**, `BASE_IMAGE` set to the previous
   layer's **digest**.
6. Report the layer's size as a `::notice`.
7. Run the layer's **smoke test inside the built image** (`podman run -i … bash -s <
   smoke-test.sh`); a failure stops the chain before anything is pushed.
8. Push under every tag and output the image pinned by digest for the next job.
9. Unregister, even on failure.

Every layer is published under these tags, all naming the same manifest:

| Tag | Meaning |
|---|---|
| `<YYYYMMDD>-<sha8>` | immutable: what a node rolls back to, what a mirror keeps |
| `latest` | the last build |
| `stable` | the release set: all five layers from one run, mirrored together |
| `4.20` | the MicroShift minor, on `microshift` and `services` only; set from the same line as the build's `USHIFT_VER`, so the tag cannot claim a version it was not built from |

### The ISO (`build-iso.yml`)

1. Register, move storage onto `/scratch`, log in to GHCR and `registry.redhat.io`.
2. Render `microshift/config.toml`, substituting `@JETSON_SSH_PUBKEY@` and
   `@JETSON_PASSWORD_HASH@` in bash (not `sed`, which breaks on `&`, quotes and newlines). It
   first rejects an empty value, a line break, a password that is not a `$6$…` crypt hash, and
   a key that is not an OpenSSH public key. Each of those would otherwise produce an ISO nobody
   can log into.
3. Run RHEL's `ksvalidator -v RHEL9` on the rendered kickstart. bib does not parse it, and an
   option anaconda rejects would stop the installer on the device with no visible error.
4. Run `registry.redhat.io/rhel9/bootc-image-builder --type anaconda-iso` on the `services` image.
5. Upload `jetson-orin-bootc-microshift-<tag>.iso` and `SHA256SUMS` as the artifact
   `jetson-orin-bootc-microshift-iso-<tag>`, kept for **7 days**.

The installer boots the stock RHEL kernel, not the Tegra one. The eMMC appears as `mmcblk0` only
if that kernel has the `sdhci-tegra` driver. If the installer finds no disk, check that first
(`lsblk`, `modprobe sdhci-tegra` on Ctrl-Alt-F2), not the kickstart.

## Secrets

| Secret | Used for |
|---|---|
| `RHSM_USERNAME` / `RHSM_PASSWORD` | Red Hat account: every job registers with subscription-manager and unregisters in an `if: always()` step |
| `OPENSHIFT_PULL_SECRET` | Pull secret JSON from console.redhat.com/openshift/install/pull-secret. Pulls MicroShift's and the device plugin's images at build time; never written into the image |
| `RH_REGISTRY_USER` / `RH_REGISTRY_PASSWORD` | Pull `registry.redhat.io/rhel9/bootc-image-builder` |
| `JETSON_SSH_PUBKEY` | Public key for the `cloudlet` user (the key itself, not a path) |
| `JETSON_PASSWORD_HASH` | `openssl passwd -6` output for `cloudlet`: the hash, not the password |

The services layer's images (`quay.io/jetstack`, `oci.external-secrets.io`, `docker.io/kserve`,
`quay.io/brancz`, `nvcr.io/nvidia`) are public and pulled anonymously.

Notes on registration:
- **The subscription must include OpenShift**, or `rhocp-4.20-for-rhel-9-aarch64-rpms` never
  appears and the microshift build fails at `--enablerepo`.
- **With Simple Content Access off,** registering needs `--auto-attach`.
- **A username and password is the broader credential.** An organisation ID plus activation key
  is narrower, and it is the only option for accounts with SSO or two-factor.
- **The two pull credentials can be one secret.** A pull secret from console.redhat.com usually
  covers `registry.redhat.io` too (`jq -r '.auths | keys[]' pull-secret.json`). `RH_REGISTRY_*`
  is kept separate so it can hold a narrower Registry Service Account.

## Installing a node

The kickstart is **fully unattended and destructive**. It wipes the on-board eMMC with no
prompt, ignores the USB key and any NVMe, creates the user `cloudlet` in `wheel`, locks root, and
reboots ejecting the media.

1. **Flash the QSPI** on the flashing station from an **R36.5.x** BSP, the same L4T line as the
   image. Mismatched firmware and modules hang at boot:
   ```
   sudo ./flash.sh p3737-0000-p3701-0000-qspi external
   ```
   This writes only boot firmware. Check the UEFI boot order lists the eMMC (ESC at the NVIDIA
   logo → Boot Maintenance Manager → Boot Options).
2. **Boot the ISO.** `dd` it to a USB key, press ESC at the NVIDIA logo, pick USB. Remove any SD
   card first, so the eMMC can only be `mmcblk0`. The installer menu starts on its own after 5 s.
   No network cable is needed: the image is inside the ISO. If the screen stops on the systemd
   boot log, Ctrl-Alt-F2 gives a shell: `systemctl list-jobs` shows what is waiting and
   `/tmp/anaconda.log` what the installer is doing.
3. **First login** over serial (`ttyTCU0`) or `ssh cloudlet@192.168.1.10`:
   ```
   bootc status
   cat /etc/nv_tegra_release                          # R36 REVISION 5.0
   lsmod | grep nvgpu
   systemctl status nvidia-ctk && nvidia-ctk cdi list # nvidia.com/gpu=all
   ```
4. **MicroShift.** The first boot is slow: `copy-embedded-images.service` restores every
   embedded image before MicroShift starts. The kubeconfig is root-only, so use `sudo -E` (plain
   `sudo` drops `KUBECONFIG`):
   ```
   journalctl -u copy-embedded-images     # finishes before microshift starts
   systemctl status microshift
   export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig
   sudo -E oc get pods -A                 # everything Running, no registry reachable
   sudo vgs                               # VG rhel, with free extents for LVMS
   sudo -E oc get sc                      # topolvm
   sudo -E oc get ds -n kube-system nvidia-device-plugin-daemonset
   sudo -E oc get nodes -o jsonpath='{.items[0].status.allocatable}'   # nvidia.com/gpu: 4
   ```
5. **Services**:
   ```
   sudo -E oc get pods -n cert-manager      # 3 Running
   sudo -E oc get pods -n external-secrets  # 3 Running
   sudo -E oc get pods -n kserve            # 1 Running
   sudo -E oc get clusterservingruntime triton-igpu
   journalctl -u microshift | grep -i kustomization   # a root still retrying shows here
   ```

6. **Kiosk**, with a monitor on the DisplayPort socket:
   ```
   lsmod | grep -E 'nvidia_drm|nvidia_modeset'   # the display driver; without it nothing shows
   cat /sys/class/drm/card*-*/status             # flips to connected/disconnected with the cable
   journalctl -u jetson-kiosk -f                 # waiting for a monitor / for the URL / compositor
   tegrastats                                    # GR3D_FREQ: the screen's share of the GPU
   ```

A pod in `ImagePullBackOff` means an image was not embedded: check
`/usr/lib/containers-image-cache/mapping.txt` and `journalctl -u copy-embedded-images`. A
Deployment that creates no pods is usually a security-policy refusal, visible in
`oc describe rs`.

### Network

The address is **static and baked into the ISO**:

| | |
|---|---|
| Interface | `eth0`, `192.168.1.10/24`, gateway `192.168.1.254` |
| DNS | `192.168.1.1`, search domain `cloudlet.local` (the resolver must answer, or every lookup waits out the timeout) |
| Hostname | `jetson-1` |
| Cluster node IP | `10.44.0.1` on `lo`, so pulling the cable does not restart MicroShift |
| Timezone | `Asia/Jerusalem`, hardware clock in UTC |

Every device imaged from one ISO gets the same address and hostname, so two on one segment
collide. Change `microshift/config.toml` and rebuild per device, or fix it up after first boot.

### Reaching the cluster from another machine

The kickstart's `%post` adds `jetson-1.cloudlet.local` to the API server's certificate and maps
it to `10.44.0.1` in the node's own `/etc/hosts`. MicroShift writes a kubeconfig for that name,
whose `server:` is `https://jetson-1.cloudlet.local:6443`. From a laptop on the air-gapped
network:

1. Make `jetson-1.cloudlet.local` resolve to `192.168.1.10`: an A record on `192.168.1.1`, or a
   line in the laptop's `/etc/hosts`.
2. Copy the kubeconfig off the node:
   ```bash
   ssh cloudlet@192.168.1.10 \
     sudo cat /var/lib/microshift/resources/kubeadmin/jetson-1.cloudlet.local/kubeconfig > ~/.kube/jetson
   KUBECONFIG=~/.kube/jetson oc get pods -A
   ```

With no DNS change at all, tunnel instead and use the node's loopback kubeconfig:
```bash
ssh -N -L 6443:127.0.0.1:6443 cloudlet@192.168.1.10 &
ssh cloudlet@192.168.1.10 sudo cat /var/lib/microshift/resources/kubeadmin/kubeconfig > ~/.kube/jetson
```

The kubeconfig holds a client certificate: whoever has the file is cluster-admin. The `oc` client
has to cross the air gap on the USB key with the ISO, unless you run the node's own `oc` over SSH.

A node that was first installed on `192.168.1.10`, before the `lo` address existed, needs
`microshift-cleanup-data --ovn` (after stopping `microshift` and `kubepods.slice`) or a re-image.

### Storage layout

The kickstart uses the **eMMC only** (`ignoredisk --only-use=mmcblk0`):

| | Size |
|---|---|
| eMMC user area | ~58 GiB |
| ESP + `/boot` (outside LVM) | ~1.6 GiB |
| VG `rhel` | ~56.5 GiB |
| ├ root, xfs | 40 GiB |
| └ **left free for LVMS** | ~16.5 GiB |
| swap | none |

- **Free space in the VG is deliberate.** MicroShift's LVMS provisions PVCs from it; filling the
  VG would leave the cluster no dynamic storage for PostgreSQL, RabbitMQ or a model store.
- **The root has to hold three things:** the embedded images in `/usr`, their restored copy in
  `/var`, and a second deployment staged by `bootc upgrade`. xfs grows but never shrinks.
  Confirm the device with `lsblk -bdno SIZE /dev/mmcblk0`.
- **No swap:** kubelet refuses to start with swap on by default, and `--recommended` would have
  sized it from RAM (~15 GiB) out of the same extents LVMS uses.
- **eMMC is slower and far less write-durable than NVMe**, which etcd's fsyncs and write-heavy
  PVCs will feel. The upgrade path is an M.2 NVMe and re-imaging with
  `ignoredisk --only-use=nvme0n1` and a larger root.

## Building locally

On a **subscribed RHEL 9 aarch64** host (every layer above `base` needs entitlement, which podman
injects on a registered host), from the repository root:

```bash
sudo podman build -f base/Containerfile.base   -t localhost/jetson-orin-bootc-base:dev .
sudo podman build -f base/Containerfile.podman -t localhost/jetson-orin-bootc-bound-images:dev \
  --build-arg BASE_IMAGE=localhost/jetson-orin-bootc-base:dev .
sudo podman build -f kiosk/Containerfile       -t localhost/jetson-orin-bootc-kiosk:dev \
  --build-arg BASE_IMAGE=localhost/jetson-orin-bootc-bound-images:dev .
sudo podman build -f microshift/Containerfile  -t localhost/jetson-orin-bootc-microshift:dev \
  --secret id=pullsecret,src=$HOME/pull-secret.json \
  --build-arg BASE_IMAGE=localhost/jetson-orin-bootc-kiosk:dev .
sudo podman build -f services/Containerfile    -t localhost/jetson-orin-bootc-services:dev \
  --secret id=pullsecret,src=$HOME/pull-secret.json \
  --build-arg BASE_IMAGE=localhost/jetson-orin-bootc-microshift:dev .

# Smoke tests run inside the image, fed on stdin, as CI runs them
sudo podman run --rm -i localhost/jetson-orin-bootc-services:dev bash -s < services/smoke-test.sh

# ISO
sed -e "s|@JETSON_SSH_PUBKEY@|$(cat ~/.ssh/id_ed25519.pub)|" \
    -e "s|@JETSON_PASSWORD_HASH@|$(openssl passwd -6)|" microshift/config.toml > /tmp/config.toml
mkdir -p output
sudo podman run --rm --privileged --pull=newer --security-opt label=type:unconfined_t \
  -v /tmp/config.toml:/config.toml:ro -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  registry.redhat.io/rhel9/bootc-image-builder:latest \
  --type anaconda-iso --config /config.toml localhost/jetson-orin-bootc-services:dev
# -> output/bootiso/install.iso
```

## Extending it

**A service on the cluster** (PostgreSQL, RabbitMQ, a model): add a numbered directory under
`services/manifests/` with a `kustomization.yaml`. The build embeds whatever images it renders.
Give every container requests and limits at the house ratios, keep it admissible under
`restricted-v2`, and add its workloads to the smoke test's expected set. Images named outside an
`image:` field, such as a model's `oci://` image, go in `SERVICE_IMAGES`.

**A variant:** create `<name>/` with a `Containerfile` (`FROM` kiosk via `ARG BASE_IMAGE`), a
`config.toml` and a `smoke-test.sh`. Then copy `build-microshift.yml` and point its variant and
`iso` jobs at it. `base`, `bound_images` and `kiosk` are reused unchanged. That is also how k3s
would come back (its `Containerfile` still defaults to bound-images).

## Not settled yet

- **Nothing has been booted on hardware** with the current image: the device plugin, the
  services and first boot are all unverified on the device.
- **Triton's `25.02-py3-igpu` tag is unverified** against JetPack 6.2.2. Whether a predictor pod
  can open the GPU as its assigned UID also has to be checked on the device. If not, add
  `supplementalGroups` on the InferenceService, or turn on CRI-O's
  `device_ownership_from_security_context`.
- **No model is deployed yet.** Nothing creates an `InferenceService`, and where they will live is
  open.
- **External Secrets has nothing to read from.** No `SecretStore` is configured.
- **A node cannot upgrade yet.** The ISO installs the services image pinned by digest from GHCR,
  which an air-gapped node cannot reach. Pointing it at the air-gapped registry's `stable` tag
  needs a one-time `bootc switch` or a retag before the ISO is built, plus registry credentials
  in `/etc/ostree/auth.json`.
- **The address and hostname are per ISO, not per device.**
- **The kiosk is unverified on hardware.** Whether the base image carries the Jetson display
  driver, whether mutter 40 runs on NVIDIA's GBM, how much GPU the screen takes from Triton, and
  the CPU cost of the frontend's video all need the device. `KIOSK_URL` is a placeholder, and
  nothing reserves the screen's CPU and RAM from the kubelet yet.

The design record, with every decision and why, is `CLAUDE.md`.

## Repository layout

| Path | What it is |
|---|---|
| `base/Containerfile.base` | layer 1: the pinned JetPack-for-RHEL image, republished |
| `base/smoke-test.base.sh` | checks the vendor image is what we expect |
| `base/Containerfile.podman` | layer 2: embedding machinery + jtop |
| `base/smoke-test.podman.sh` | checks the machinery and jtop, and that nothing was embedded here |
| `base/physically-bound-images/embed_image.sh` | build time: copy one image into the cache in `/usr` |
| `base/physically-bound-images/copy_embedded_images.sh` | boot time: restore the cache, prune what an older OS left |
| `base/physically-bound-images/copy-embedded-images.service` | runs it once per boot, before MicroShift |
| `kiosk/Containerfile` | layer 3: GNOME Kiosk, Firefox, the kiosk service |
| `kiosk/kiosk.sh` | waits for a monitor and the URL, then the compositor and Firefox |
| `kiosk/jetson-kiosk.service` | runs it as `kiosk` on tty1, restarts it, caps its CPU and RAM |
| `kiosk/jetson-kiosk.conf` | `KIOSK_URL` |
| `kiosk/policies.json`, `kiosk/sysusers.conf` | Firefox lockdown, the `kiosk` user |
| `kiosk/jetson-kiosk.gschema.override` | no Ctrl-Alt-Fn VT switching |
| `kiosk/smoke-test.sh` | checks the layer is wired together |
| `microshift/Containerfile` | layer 4: MicroShift, firewall, node IP, GPU device plugin, their images |
| `microshift/manifests/` | device-plugin kustomization and the GPU time-slicing config |
| `microshift/stable-microshift.nmconnection` | `10.44.0.1/32` on `lo` |
| `microshift/config.d/10-node-ip.yaml` | tells MicroShift to use it |
| `microshift/manifest-images.sh` | renders manifest roots, prints every image they name |
| `microshift/config.toml` | installer config: the kickstart, ISO label, boot menu timeout |
| `microshift/smoke-test.sh` | checks for the microshift layer |
| `services/Containerfile` | layer 5: the manifest roots, upstream installs, their images |
| `services/manifests/0x0-*/` | one kustomize root per service, applied by MicroShift in order |
| `services/smoke-test.sh` | render, admission, resource and image checks |
| `k3s/` | the k3s variant, built by nothing |
| `.github/workflows/build-image.yml` | reusable: build, test and push one layer |
| `.github/workflows/build-iso.yml` | reusable: build the installer ISO |
| `.github/workflows/build-microshift.yml` | the pipeline: base → bound-images → kiosk → microshift → services → ISO |
| `CLAUDE.md` | the design record: decisions, rationale, open questions |
