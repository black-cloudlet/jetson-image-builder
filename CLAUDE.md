# CLAUDE.md — jetson-image-builder

Provisioning and image pipeline for NVIDIA Jetson AGX Orin edge nodes running RHEL image mode
(bootc) in a disconnected environment. Read this whole file before touching anything.

**Two repos.** This one holds the image pipeline (`base/`, `microshift/`, `services/`, `k3s/`,
`.github/workflows/`). The flashing-station tooling — `mirror.sh`,
`install-offline.sh` and the station-side flashing docs — lives in
`black-cloudlet/jetson-installer-config`. The split is deliberate: mirroring RPMs and flashing
QSPI are a different job from building an image, and they run on different machines. This file
describes the whole system because both halves have to agree on the L4T line, but only the image
pipeline is editable from here.

## What this project is

Edge AI nodes (image recognition inference) deployed on Jetson AGX Orin. Nodes run fully
disconnected during missions and are attached to the organisation's **air-gapped network** only
between missions for maintenance, upgrades and deployments. Nothing on a device or on the
flashing station ever reaches the internet.

Target stack on the device:

- RHEL 9.8 image mode (bootc), aarch64
- Kubernetes: **MicroShift 4.20** is the only variant that builds. `k3s/` is still in the tree —
  Containerfile, kickstart, staging unit, smoke test — but **nothing builds it**: its caller
  workflow was deleted, so picking it back up means writing `build-k3s.yml` again (see below)
- On the cluster today: cert-manager and External Secrets, from `services/`
- Still to come on the cluster: PostgreSQL, RabbitMQ, and whatever serves the model
- All container images physically bound into the OS image (zero network at first boot)

**Inference is not in the pipeline right now.** KServe, the Triton serving runtime and their
kustomize roots were removed from `services/` (`bba9d10 delete kserve`); the layer that replaced
them installs cert-manager and External Secrets. The reason is not recorded here, and neither is
what serves the model instead — treat both as open.

### Hardware

| Part  | Role |
|-------|------|
| P3701 | System on Module — CPU/GPU/RAM (32 GB for the POC; larger SOM for production) |
| P3737 | Carrier board — I/O, networking, power |
| P3730 | The assembled Jetson AGX Orin Developer Kit (P3737 + P3701 + thermal solution) |

`flash.sh` targets are named after carrier + SOM, hence `p3737-0000-p3701-0000-*`.

### Three machines, three roles

```
┌──────────────────────────┐   ┌──────────────────────────────┐   ┌──────────────────────────┐
│ Online RHEL host         │   │ Flashing station (RHEL, x86) │   │ GitHub Actions (internet) │
│ subscription-registered  │   │ standalone, NO network        │   │ ubuntu-24.04-arm runners  │
│                          │   │                              │   │                          │
│ mirror.sh ──► USB key ───┼──►│ install-offline.sh           │   │ Containerfile ──► GHCR    │
│ (BaseOS+AppStream tars)  │   │ flash.sh …-qspi external     │   │ bootc-image-builder       │
└──────────────────────────┘   └──────────┬───────────────────┘   └──────────┬───────────────┘
                                          │ QSPI/UEFI only                    │ ISO / qcow2
                                          ▼                                   ▼
                               ┌──────────────────────────────────────────────────────────┐
                               │ Jetson AGX Orin: install from USB (ISO) onto the eMMC,   │
                               │ later `bootc switch/upgrade` from the air-gapped registry │
                               └──────────────────────────────────────────────────────────┘
```

## Decisions already made (do not reopen without a reason)

1. **Flashing station is RHEL, not Ubuntu.** Ubuntu + NVIDIA SDK Manager was the original plan
   and was evaluated and dropped. We flash from a RHEL x86 host using a direct BSP download and an
   offline RPM bundle. NVIDIA validates `flash.sh` only on Ubuntu; QSPI-only flashing works on
   RHEL and is confirmed on our hardware, but it is an unsupported configuration — say so in docs.
2. **RHEL 9.8 + JetPack 6.x (L4T r36.4) is the only GA combination.** RHEL 10 is not viable:
   no NVIDIA RHEL 10 L4T repo, kmod built against 5.14 will not load on 6.12. Do not propose
   RHEL 10 as a base.
3. **QSPI-only flash, then RHEL bootc on the on-board eMMC.** The QSPI carries UEFI and boot
   firmware only; RHEL is installed to `mmcblk0`, the devkit's 64 GB eMMC, by the anaconda ISO.
   Either way the Ubuntu rootfs in the BSP is discarded entirely — nothing NVIDIA ships lands on
   the device's storage. The working command is:
   ```
   sudo ./flash.sh p3737-0000-p3701-0000-qspi external
   ```
   NOT `jetson-agx-orin-devkit external` — that target builds a recovery ramdisk and fails
   without a populated `rootfs/`. The trailing `external` is kept because that is the invocation
   confirmed on our hardware, and a `-qspi` target writes only the QSPI regardless; what actually
   selects the boot device is the UEFI boot order, so confirm the eMMC is in it (ESC at the NVIDIA
   logo → Boot Maintenance Manager → Boot Options). If UEFI refuses to boot the eMMC, re-flashing
   the QSPI with `internal` is the thing to try before anything else.
   eMMC was not the original plan — external NVMe was — and it is a real constraint, not just a
   different device name: ~58 GiB of user area against an NVMe's arbitrary size, and eMMC write
   endurance and latency under etcd's fsync pattern and write-heavy PVCs. Fitting an M.2 NVMe and
   re-imaging with `ignoredisk --only-use=nvme0n1` plus a larger root is the upgrade path, and is
   worth doing before real application images and a model store land on the node.
4. **Base image is Red Hat's JetPack-for-RHEL bootc image**, not a hand-rolled
   `rhel9/rhel-bootc:9.8` + NVIDIA RPMs:
   ```
   quay.io/redhat-user-workloads/jetpack-for-rhel-tenant/rhel-98-bootc:6.2.2_5.14.0-687.42.1_090326003719
   ```
   Tag decodes as JetPack `6.2.2`, kernel `5.14.0-687.42.1.el9_8`, build `090326003719`.
   Inspected 2026-09-03 — the image contains (arm64 only, bootc 1.16.4):
   - `/etc/nv_tegra_release`: **R36 REVISION 5.0** ⇒ L4T r36.5.0, kernel variant `oot`
   - `nvidia-jetpack-for-rhel-9.8-{kmod,core,cuda,cuda-utils,nvml,multimedia,gstreamer,camera,
     pva,dla-compiler,firmware,nvpmodel,nvfancontrol,tools,x11,wayland,gbm,vulkan-sc-sdk,...}`
   - `nvidia-container-toolkit-base` (`nvidia-ctk`, `nvidia-container-runtime`; no
     `nvidia-container-cli` hook — CDI is the integration path)
   - `nvgpu.ko` in `/usr/lib/modules/<kver>/extra/drivers/gpu/nvgpu/`, `nvidia.ko` +
     `nvidia-drm.ko` in `updates/opensrc-disp/`
   - `nvidia-ctk.service` (enabled; generates `/etc/cdi/nvidia.yaml` at boot),
     `nvidia-cdi-refresh.{path,service}`, `nvpmodel.service`, `load-nvidia-drm.service`
   - `/usr/lib/bootc/kargs.d/00-console.toml`: `console=ttyTCU0 pd_ignore_unused`
   - `podman`, `skopeo`, `subscription-manager`, `selinux-policy-targeted`; default target
     `multi-user`
   Therefore the derived `Containerfile` adds **no** NVIDIA packages, no CDI unit, no kargs, and
   no `nvgpu.ko` guard. Pin the full tag; never use `latest`. Upstream source:
   `gitlab.com/redhat/rhel/sst/orin-sidecar/rhel-jetpack-for-jetson-bootc`.
5. **BSP revision must match the base image's L4T line.** The image is L4T **r36.5.0**, so the
   QSPI must be flashed from a Jetson Linux **R36.5.x** BSP (the staged R36.5.2 is fine).
   Do not flash from r36.4.x — mismatched UEFI/firmware vs. modules causes boot hangs.
6. **Builds run in GitHub Actions on `ubuntu-24.04-arm`, inside a UBI 9 container.** GitHub
   offers no RHEL-hosted runner, so the runner label buys the architecture (native aarch64; qemu
   emulation of an arm64 `dnf`/`skopeo` build is not viable) and the `container:` buys the
   distro. podman/buildah/skopeo come from RHEL rather than Ubuntu's archive, and
   `subscription-manager register` inside the container supplies entitlement. Images are pushed
   to GHCR, then mirrored into the air-gapped registry by hand. Pattern taken from
   `redhat-et/edge-ai-image-pipelines` (Apache-2.0), which builds Tegra bootc images the same
   way. The host's `/mnt` is bind-mounted into the job container as `/scratch`, and
   `/var/lib/containers`, `/var/tmp` and the ISO output are bound onto it unconditionally. Space
   is one reason; the other is that the job container's `/` is overlayfs, which the kernel refuses
   as an overlay upperdir, so podman left there cannot use the native layer diff and every commit
   walks the whole rootfs (~2 min per instruction, ~20 of the microshift job's 24 build minutes).
   RHEL's `storage.conf` then defeats the bind on its own: it mounts overlay with `metacopy=on`,
   which also forces the naive diff, so the step strips that option too. It fails unless
   `podman info` reports `Native Overlay Diff:true`.
7. **Four layers for microshift, one directory per Kubernetes variant.**
   The two shared layers share the `base/` directory and are two images.
   `base/Containerfile.base` republishes the pinned vendor image under our own name — the pin
   lives in one file, the air-gapped mirror gets a name we control, and the digest stays a pure
   republish of what Red Hat ships.
   `base/Containerfile.podman` builds `FROM` it with the physically-bound-images machinery —
   the two scripts and the boot-time unit, all three `COPY`d from
   `base/physically-bound-images/` — plus `jetson-stats` (`jtop`). One directory because both
   are infrastructure under every variant rather than a variant of their own; two images because
   a bare republish is worth being able to point at. It was a directory of its own once
   (`apps/`), which also held the application images, below the variant layers, where changing
   one re-ran the whole MicroShift install.
   The file suffix and the published image name differ on purpose and have to be kept straight:
   `Containerfile.podman` / `smoke-test.podman.sh` build the image published as
   `jetson-orin-bootc-bound-images`, from the CI job `bound_images` — an underscore, because
   `needs.bound-images` parses as a subtraction and would resolve to nothing rather than fail.
   `microshift/` builds `FROM` bound-images and adds MicroShift, the device plugin and their
   images.
   `services/` builds `FROM` **that** and holds what runs on the cluster: one kustomize root
   per component, numbered, and every image any of those roots names embedded. Today that is
   cert-manager and External Secrets.
   `k3s/` still sits beside `microshift/` and would reuse both shared layers untouched, but no
   workflow builds it: `build-k3s.yml` was deleted, and re-enabling the variant means writing
   that caller again (`base/Containerfile.base` → `base/Containerfile.podman` →
   `k3s/Containerfile` → ISO from `k3s/config.toml`). It would still have no services layer,
   because `services/` embeds for podman's containers-storage and writes
   `/etc/microshift/manifests.d`, and k3s reads neither.
   The split that remains is about rebuild cost: a variant layer pulls a whole control plane
   (MicroShift's is nine images) and that should not be redone whenever a service image
   changes. That is why those images sit **above** the variant layer. They used to be below it,
   where changing one re-ran the MicroShift RPM install and re-pulled all nine — the layer split
   was there but pointing the wrong way.
   Each layer is pushed separately as `jetson-orin-bootc-<name>` and the next builds on its
   **digest**, not its tag. CI is two reusable workflows — `build-image.yml` (one layer) and
   `build-iso.yml` — plus a caller per variant, of which `build-microshift.yml` is now the only
   one, chaining base → bound-images → microshift → services → ISO, the ISO built from the top
   of the chain.
   The build context is the repository root, so any layer can `COPY` from any directory — the
   embedding scripts sit in `base/` beside the Containerfile that installs them, and the path
   they are installed to (`/opt/physically-bound-images/`) keeps the full name because the unit
   and both variant layers call it. Every layer registers with subscription-manager, including
   `base/Containerfile.base`, which installs nothing at all: one code path for every layer
   beats a per-layer entitlement flag. Layout and the reusable-workflow split follow
   `redhat-et/edge-ai-image-pipelines` (Apache-2.0), whose `Containerfile.podman` is the same
   idea as our shared layers, and whose naming this repo now follows.
8. **NVIDIA BSP download stays manual** and is documented in `README.md`. Scripting it was tried;
   NVIDIA's version-string and URL-path (`release/` vs `releases/`) inconsistencies made it fragile.

## What is done and working

### Flashing station provisioning (`mirror.sh`, `install-offline.sh`) — in `jetson-installer-config`

- `mirror.sh` — runs on an **online, subscription-registered RHEL host**. Launches a UBI
  container with the host's entitlement bind-mounted (`/etc/pki/entitlement`, `/etc/rhsm`,
  `/etc/yum.repos.d/redhat.repo`, read-only, `--security-opt label=disable`), runs
  `dnf reposync --download-metadata --newest-only` for BaseOS and AppStream, tars them into
  `dist/`. Flags: `-r 9|10`, `-A arch`, `-o dist`, `-m mirror` (incremental work dir),
  `-c podman|docker`, `-a` all versions, `-z` gzip (off by default; RPMs are already
  zstd-compressed, gzip saves 2–3% for a lot of CPU). Has an `rpm -K --nosignature` pre-check
  because a disk-full mid-reposync leaves truncated RPMs that confuse librepo on resume.
- `install-offline.sh` — runs **as root on the air-gapped station** from the bundle dir.
  Extracts tars to `/srv/repos/{baseos,appstream}`, writes `offline.repo` with `file://`
  baseurls and `gpgcheck=1`, disables the subscription-manager dnf plugin, installs the flash
  host dependencies: `dtc cpp binutils usbutils lz4` (`-P` skips the install). Repos only —
  no BSP handling, no udev, no flashing.
- `README.md` — BSP download links, station-side extract / recovery-mode / `flash.sh` steps.

Both scripts are idempotent and re-runnable. They have been exercised end to end: the station
was provisioned from the bundle and the devkit was flashed with the QSPI command above.

### bootc image + installer ISO pipeline (`base/`, `microshift/`, `services/`, `k3s/`, CI)

- `base/Containerfile.base` — `FROM` the pinned JetPack-for-RHEL image and nothing else, plus
  `bootc container lint`. Republished as `jetson-orin-bootc-base`. The only layer that installs
  nothing at all, so its smoke test is really about the vendor image: it asserts `skopeo` and
  `podman` (the embedding machinery needs both) and `lvm2` — root is on an LV in both
  kickstarts and MicroShift's LVMS shells out to `vgs`, only warning when it is missing, and
  nothing here installs it.
- `base/Containerfile.podman` — `FROM` that via `ARG BASE_IMAGE`. Published as
  `jetson-orin-bootc-bound-images` (file name and image name differ; see decision 7). Two
  things:
  - **The physically-bound-images machinery**: `embed_image.sh`, `copy_embedded_images.sh` and
    `copy-embedded-images.service`, all three `COPY`d from `base/physically-bound-images/`
    rather than written by `printf` — the unit is a real file now, which is what lets an editor
    and `systemd-analyze verify` see it.
  - **`jetson-stats`** (`jtop`), pinned by `JTOP_VER`, installed with
    `pip3 install --prefix=/usr`: `/usr/local` is machine state on bootc, so pip's default
    prefix would not survive into the deployed image. `python3`/`python3-pip` come from the RHEL
    repos, so **this layer needs entitlement** — it is no longer true that the two shared layers
    install no RPMs. `groupadd -r jtop` creates the group jetson-stats expects; nothing here
    enables a `jtop.service`, so whether `jtop` can actually reach the driver as installed is
    unverified.
  Its smoke test fails if an image cache exists in this layer at all: anything embedded here is
  paid for by every variant, which is the cost `services/` exists to avoid.
- `base/physically-bound-images/{embed_image.sh,copy_embedded_images.sh}` — adapted from
  `redhat-et/edge-ai-image-pipelines` (Apache-2.0). Cache is `/usr/lib/containers-image-cache`
  with a `mapping.txt` of reference -> sha, replayed once per boot by
  `copy-embedded-images.service` (a standalone oneshot, with `Requires=`/`After=` on
  microshift.service, rather than Red Hat's `ExecStartPre=` — it runs once per boot instead of
  on every MicroShift restart, and later app images share the one mechanism). `embed_image.sh`
  splits `$REPO:$TAG@sha256:$SHA` references, which skopeo rejects and Red Hat's own recipe does
  not handle, and is idempotent: a reference whose `manifest.json` is already in the cache exits
  0 without copying. Callers concatenate lists that nothing dedupes across — release-info plus
  the manifest scan in the microshift layer, that scan plus `SERVICE_IMAGES` in `services/` —
  and a second copy of a reference already embedded **one layer down** would ship both, since
  the write is a copy-up and overlay keeps what it copied from. The unit deliberately does
  **not** want `network-online.target`: the copy is local-disk only and waiting for a carrier
  that never comes would add NetworkManager-wait-online's timeout to every boot.
  Two things keep the cache from costing more than it has to. The copy is
  `--multi-arch=system`, not `all`: the builder is native aarch64 and so is the node, so every
  other platform in a manifest list is dead weight — the device plugin now, application images
  later, where a docker.io manifest list can carry six platforms. A reference pinned to a
  manifest-list digest still resolves on the node even though only one architecture was stored
  under it, because containers-storage looks an image up by its explicit name before it looks by
  digest (`storage/storage_reference.go:114-121`), and that name is what the copy recorded.
  Deduplicating the cache itself was tried and removed: the `dir:` transport names each blob
  after its digest, so a layer two embedded images share is the same file twice and hardlinking
  them is easy — but it frees nothing on the node, because `/usr` is an ostree checkout and
  stores by content, so those two files are already one object there. Only the layer tar carries
  both copies, so what it would buy is ISO size and upgrade bandwidth, and neither was the
  problem. And `copy_embedded_images.sh` removes images an earlier version of the OS image put
  in containers-storage and this one no longer names, recording what it applied in
  `/var/lib/physically-bound-images/applied.txt` (containers-storage is machine state, the cache
  is not, so nothing else remembers). Nothing else prunes that store: the first thing that would
  is kubelet's image GC at 85% of the root filesystem, and what it deletes is exactly the
  physically-bound images, on a node with no registry to pull them back from. The prune runs
  **before** the copy, so a superseded set frees space for its replacement; an image CRI-O still
  holds through a container from the previous boot cannot be removed yet, so that entry stays on
  the list and the next boot tries again instead of losing track of it. A removal that fails is
  logged, never fatal — the unit is `Requires=`d by microshift.service.
- `microshift/Containerfile` — `FROM` the bound-images layer via `ARG BASE_IMAGE`, then
  MicroShift 4.20 from `rhocp-4.20-for-rhel-9-aarch64-rpms` +
  `fast-datapath-for-rhel-9-aarch64-rpms`
  (`firewalld jq microshift microshift-release-info openshift-clients` — `oc` comes from
  `openshift-clients`; the `microshift` RPM ships no client), the firewall rules (trusted: pod
  CIDR `10.42.0.0/16`, service CIDR `10.43.0.0/16`, host-endpoint `169.254.169.1`; public: 22,
  443, 6443), the `microshift-make-rshared.service` OVN needs, and every MicroShift container
  image embedded into `/usr/lib/containers-image-cache` with a `microshift.service.d` drop-in
  that orders them into containers-storage before the service starts (the unit itself lives in
  the bound-images layer; this one only orders against it), plus the NVIDIA device plugin
  (`nvidia-ctk runtime configure --runtime=crio` writing
  `/etc/crio/crio.conf.d/99-nvidia.toml`, the plugin manifest and a kustomization in
  `/etc/microshift/manifests`, and the plugin image embedded alongside MicroShift's),
  configured for **GPU time slicing**. `microshift/manifests/` holds the kustomization, a
  `nvidia-device-plugin-config` ConfigMap carrying
  `sharing.timeSlicing.resources[nvidia.com/gpu].replicas` (4) and a strategic-merge patch
  mounting it and setting `CONFIG_FILE`; the directory is `COPY`d over
  `/etc/microshift/manifests` and only `nvidia-device-plugin.yml` is still curl'd, so the
  upstream manifest is patched, never forked. The Orin has one iGPU, so without replicas
  exactly one pod can hold `nvidia.com/gpu` and every other GPU workload waits for it. No
  memory isolation between replicas, so the count is a claim about what fits in the SOM's
  RAM — 32 GB on the POC module — and 1 disables sharing. `renameByDefault` stays off, so
  the resource is plain `nvidia.com/gpu` and stock pod specs need no change.
  A patch that stops matching is a silent no-op in kustomize, so the smoke test runs
  `oc kustomize` and checks the render for both the added fields and the upstream ones it
  must not have replaced.
  **No `microshift-gitops`**: core Argo CD was installed here from the OpenShift GitOps channel
  and has been removed, so the subscription no longer needs that entitlement and the smoke test
  no longer looks for its manifests.
  Images are copied into the main store rather than referenced as an additional store, because
  an image upgrade overwrites an additional store (RHEL-75827). **No `dnf upgrade`**: Red Hat's
  own file runs one, but here it could pull a kernel past 5.14.0-687.42.1 and the Tegra kmod is
  built against that exact build. `--enablerepo` rather than `dnf config-manager`, so the build
  does not depend on dnf-plugins-core being in the base. The two systemd units it writes are
  `COPY <<'EOF'` heredocs — this reverses an earlier rule against them, which existed so the
  build would not depend on the builder's podman being new enough to parse one; RHEL 9's podman
  is, and the UBI 9 builder container is the only thing that builds this.
- `microshift/manifest-images.sh` — prints every image referenced by the MicroShift
  manifest roots it is given, rendering each with `oc kustomize`. `release-<arch>.json`
  lists the control plane only; the device plugin's image is named nowhere but in the
  manifest that deploys it, and an `images:` transformer defeats a grep. The build embeds
  what it prints; the smoke test re-runs it against the cache. `services/` uses the same
  script from `/opt/microshift/manifest-images.sh`.
- `services/Containerfile` — `FROM` the microshift layer via `ARG BASE_IMAGE`. Two kustomize
  roots under `/etc/microshift/manifests.d/`, numbered, plus every image they name embedded.
  No `dnf`, so no entitlement needed for the RPM side. The numbers are load-bearing:
  MicroShift's kustomizer scans the default paths, **sorts** the glob matches and applies each
  root in turn with the equivalent of `kubectl apply -k`, retrying a root that fails **every
  10s for up to 10 minutes** before giving up on it (`pkg/kustomize/kustomize.go`, server-side
  apply with `--force-conflicts`). That is both the ordering and the reason a CRD applied in
  one root but not yet established when the next asks for it resolves itself instead of needing
  a unit to sequence it.
  - `010-cert-manager/` — upstream's static `cert-manager.yaml`, `curl`'d at build time
    (`CERT_MANAGER_VER`, v1.21.2). The static manifest is the whole install: three Deployments,
    no Helm and no `startupapicheck` Job. Patched only for resources, one file per Deployment
    (`resources-controller.yaml`, `resources-cainjector.yaml`, `resources-webhook.yaml`).
    **What now consumes cert-manager is an open question** — it was installed for KServe's
    webhook certificates, and KServe is gone; External Secrets issues its own webhook
    certificate from its `cert-controller` and does not use it.
  - `020-external-secrets/` — upstream's `external-secrets.yaml`, `curl`'d
    (`EXTERNAL_SECRETS_VER`, v0.19.2), patched from three strategic-merge files, one per
    Deployment (`controller.yaml`, `webhook.yaml`, `cert-controller.yaml`). Each does two
    things:
    deletes the `runAsUser: 1000` upstream pins with an explicit null, and adds requests and
    limits. The UID matters: restricted-v2 assigns one out of the namespace's
    `openshift.io/sa.scc.uid-range` (allocated by MicroShift's cluster-policy-controller,
    ~1000650000/10000) and refuses a pod that names its own, so the Deployments would be
    admitted and every pod they create refused. `runAsNonRoot: true` is left in place, so the
    SCC only chooses *which* non-root UID.
    **It installs into namespace `external-secrets`, not `default`.** Upstream pins the whole
    install to `default` — all ten namespaced objects, the ServiceAccount subjects of both
    ClusterRoleBindings and of the leaderelection RoleBinding, and
    `clientConfig.service.namespace` in both ValidatingWebhookConfigurations — and ships no
    namespace of its own, the way cert-manager does. So the root adds `namespace.yaml` (a bare
    Namespace; kustomize sorts it to the front of the render, so the one apply creates it
    before what goes in it) and a `namespace:` line, which moves all of the above.
    What the transformer does **not** reach is a namespace spelled inside a container
    argument, and there are three: cert-controller's `--service-namespace` and
    `--secret-namespace`, and the webhook's `--dns-name=external-secrets-webhook.<ns>.svc`.
    Those are `cert-controller-args.yaml` and `webhook-args.yaml`, JSON patches rather than
    strategic merges because `args` is a list of strings with no merge key and a strategic
    merge would replace the whole list, silently dropping whatever a later release adds. Each
    replacement is guarded by a `test` op on the string it expects at that index, so an
    upstream reorder fails the build instead of rewriting the wrong argument. Getting any of
    the three wrong is the same failure: cert-controller issues the webhook's serving
    certificate into a namespace nothing reads or for a DNS name the webhook rejects, the
    webhook never serves, and with `failurePolicy: Fail` on the ExternalSecret webhook no
    ExternalSecret can be created at all.
    The strategic-merge patches still say `namespace: default` and have to: patches run
    **before** the namespace transformer, so they select each resource as the upstream file
    still spells it — `namespace: external-secrets` there matches nothing and fails the build.
    Still **not** settled: nothing in the tree creates a `SecretStore` or `ClusterSecretStore`,
    so which provider External Secrets reads from on a disconnected node is unrecorded.
  Resources on both roots follow one rule: **memory request equals limit (1:1) and the CPU
  limit is four times the request (1:4)**. Memory 1:1 means a pod is never evicted for growing
  past a request it was never going to stay under — it is OOM-killed at its own ceiling, a
  container problem rather than a node one. CPU 1:4 keeps burst room for the reconcile storm at
  start-up. This leaves the pods Burstable, not Guaranteed: Guaranteed needs the CPU request to
  equal the limit, which is the burst room itself. Upstream ships almost none of this —
  cert-manager sets nothing on any of its three, External Secrets sets `10m`/`32Mi` on one of
  its three — so without the patches every one of these pods is BestEffort and first in line
  for eviction.
  The images embedded are **derived from the render**, not listed beside it: the build runs
  `manifest-images.sh` over the roots and embeds what it prints, so the version ARGs are the
  only pin. `SERVICE_IMAGES` remains for an image no manifest names. Four today: cert-manager
  ×3 (`quay.io/jetstack/...`) and one for External Secrets
  (`oci.external-secrets.io/external-secrets/external-secrets`, shared by all three of its
  Deployments).
  The smoke test renders every root with `oc kustomize` — MicroShift will render the same roots
  at start-up, and a root that does not render is a component that is silently never applied —
  then checks: the workload set each root may contain (kustomize already fails the build on a
  patch that matches nothing, so this is aimed at a workload upstream *adds*), that no
  `runAsUser` survives in the External Secrets render and `runAsNonRoot: true` still does, that
  the External Secrets render creates the `external-secrets` namespace and that **nothing
  outside its CRDs still says `default`** in any spelling — metadata, a subject, a webhook
  clientConfig, a service DNS name inside an argument — since which namespaces a namespace
  transformer reaches depends on the kustomize version linked into whatever renders the root,
  and a field spec a version does not carry is a silent no-op rather than an error, that
  every container has requests and limits **and that the ratios hold** (checked by arithmetic
  over the render rather than by grepping the numbers, so an edit cannot quietly break one),
  and that every image is registry-qualified and embedded. It prints `du -sh` of the cache:
  the cache is paid for twice on the eMMC, once in `/usr` and once when
  `copy-embedded-images.service` replays it into containers-storage under `/var`.
- `k3s/` — `Containerfile`, `config.toml`, `stage-assets.sh`, `smoke-test.sh`, all still here
  and **built by nothing**: `build-k3s.yml` was deleted. What they do is unchanged: k3s
  (pinned `K3S_VERSION`) as the `k3s-arm64` static binary into `/usr/bin/k3s` with the usual
  `kubectl`/`crictl`/`ctr` argv[0] symlinks — `/usr/local` is machine state on bootc, so
  upstream's install script is not usable; `k3s-selinux` from Rancher's RPM repo, whose repo
  file is deleted again in the same layer because the deployed node can never reach it;
  firewall rules matching the microshift layer; GPU integration as `default-runtime: nvidia` in
  `/etc/rancher/k3s/config.yaml` rather than `nvidia-ctk runtime configure`, because a pod only
  reaches a non-default runtime through a RuntimeClass; images as the release's
  `k3s-airgap-images-arm64.tar.zst` plus the device plugin as a `docker-archive` tarball in
  `/usr/share/k3s/agent-images`, staged by `k3s-stage-assets.service` before `k3s.service`
  (the images directory is a symlink into `/usr/share`, the manifests directory a real one
  because k3s writes its own bundled YAML into it); a kickstart that is the microshift one with
  two changes — root grows over the whole VG, because k3s provisions PVs from local-path on the
  root filesystem and free extents would be space the cluster cannot reach, and ISO label
  `JETSON_ORIN_K3S`, because anaconda finds its stage2 by label and two variants sharing one
  would pick whichever stick enumerated first. **`embed_image.sh`'s
  cache is useless here**, because it writes into podman's containers-storage and k3s's
  containerd does not read it. Reviving the variant means writing `build-k3s.yml` again.
- `microshift/config.toml` — bib config with a **custom kickstart** (bib then adds only
  `ostreecontainer`; `[customizations.user]`/`filesystem` cannot be combined with a custom
  kickstart, so everything lives in the kickstart): `text --non-interactive`,
  `timezone Asia/Jerusalem --utc`, static `192.168.1.10/24` gw `192.168.1.254` on `eth0` with
  `--nameserver=192.168.1.1`, `--domain=cloudlet.local` and `--hostname=jetson-1`,
  `ignoredisk --only-use=mmcblk0`,
  `clearpart --all` + `reqpart --add-boot` + one VG `rhel` on the rest of the eMMC holding a
  40 GiB xfs root and **no swap**, **with the remaining ~16.5 GiB of extents left free for
  MicroShift's LVMS provisioner** (fill the VG and the cluster has no dynamic PV source, so
  PostgreSQL/RabbitMQ/a model store have nowhere to go), root locked, user `cloudlet` in
  `wheel` from `@JETSON_SSH_PUBKEY@` / `@JETSON_PASSWORD_HASH@` placeholders, `reboot --eject`.
  ISO label `JETSON_ORIN_BOOTC`. The address and hostname are baked into the ISO: two devices
  imaged from the same ISO collide on one segment. `--nameserver=192.168.1.1` and
  `--domain=cloudlet.local`, the same in `k3s/config.toml`; the resolver must answer, because an
  unreachable one blocks every lookup for the glibc timeout instead of failing at once.
- `.github/workflows/build-image.yml` — **reusable**: register, bind container storage onto the
  runner's disk so podman gets native overlay, write the
  pull secret, build the given Containerfile with the repo root as context, run the given
  smoke-test inside the result, push `ghcr.io/<owner>/jetson-orin-bootc-<name>` under every
  tag the caller asked for, and output the ref pinned by digest
  (`podman push --digestfile`), with each layer's size as a `::notice` — roughly what the
  deployment occupies on the node, per layer, so the differences say where the bytes went.
  Tags are one immutable `<YYYYMMDD-sha8>` plus `latest` plus the
  `extra-tags` input, all naming the same manifest: today `stable` on all four layers, so the
  release set can be mirrored as one, and the MicroShift minor `4.20` on the two layers that
  contain MicroShift. The caller passes that minor as a tag and as `USHIFT_VER` to the build
  from the same two lines — a `4.20` tag on an image built from another channel would be a
  claim nothing enforces. They are written twice because the `env` context is not available to
  a reusable workflow's `with:`. Tags are validated before the build rather than after it: a
  name podman would reject should not cost twenty minutes first.

  **What a node follows is not settled yet.** `bootc upgrade` re-resolves the reference in the
  deployment's origin, and that origin is whatever bib was given — `build-iso.yml` passes the
  services layer **pinned by digest**, so there is nothing to re-resolve, and the reference
  names GHCR, which an air-gapped node cannot reach anyway. `ostreecontainer` has no
  `--target-imgref`, so anaconda cannot install from one reference and record another. `stable`
  exists to be the reference a node eventually follows — in the air-gapped registry, not
  GHCR — but getting the origin there still needs either a one-time `bootc switch` on the node
  (the unit in the later-layers list) or retagging the image to its air-gapped name before bib
  and having bib install that. Until one of those lands, a deployed node cannot upgrade at all.
  Whichever it is, the node also needs `/etc/ostree/auth.json` for the air-gapped registry, and
  `bootc-fetch-apply-updates.timer` is worth checking on the first boot: a timer pulling daily
  from a registry that is only reachable between missions fails every day it is not.
  `.github/workflows/build-iso.yml` — **reusable**:
  register, substitute the two `@JETSON_*@` placeholders into `<variant>/config.toml` (in bash,
  not `sed`, with the secrets in `env:` — an `&`, a quote or a newline in a value would
  otherwise mangle the kickstart or break the command) after rejecting an empty or
  non-crypt `JETSON_PASSWORD_HASH`, run
  `registry.redhat.io/rhel9/bootc-image-builder --type anaconda-iso` with
  `/etc/pki/entitlement` and `/etc/rhsm` bind-mounted, upload `*.iso` + `SHA256SUMS`.
  `.github/workflows/build-microshift.yml` — the only caller: base → bound-images → microshift
  → services → ISO, on push to `main` under `base/**`, `microshift/**`, `services/**` or the
  workflows themselves, and on `workflow_dispatch`. **Nothing runs on a pull request**, so a
  branch is built only by dispatching it by hand.

Secrets: `RH_REGISTRY_USER`, `RH_REGISTRY_PASSWORD` (bib image pull), `RHSM_USERNAME`/`RHSM_PASSWORD`
(both jobs `subscription-manager register` inside the UBI builder, and unregister in an
`if: always()` step), `OPENSHIFT_PULL_SECRET` (pulls MicroShift's and the device plugin's
container images at build time; never written into the OS image), `JETSON_SSH_PUBKEY`,
`JETSON_PASSWORD_HASH` (`openssl passwd -6`). The entitlement-certificate tarball
(`RHSM_ENTITLEMENT_TGZ_B64`) was replaced by registration: nothing expires inside a secret and
`redhat.repo` is generated fresh by the registration. Cost is a register/unregister cycle per
job — four per run — and the build stops if the credentials are wrong.
Registration uses an account username and password by maintainer preference; an org ID plus
activation key is the narrower credential and the only option for SSO or 2FA accounts, so revisit
this if the account gains either. Credentials are passed through `env:` rather than interpolated
into the command, so a password containing a quote or `$` cannot break the shell. With Simple
Content Access off, the register call needs `--auto-attach`. The subscription must carry an
OpenShift entitlement or `rhocp-4.20-for-rhel-9-aarch64-rpms` never appears and the build fails
at `--enablerepo`; a GitOps entitlement is no longer needed, `microshift-gitops` having been
removed. Registration is not only for the variant layer any more: the bound-images layer
installs `python3`/`python3-pip` for jetson-stats, so it needs the RHEL repos too.
A self-hosted registered RHEL 9 aarch64 runner would remove the registration step too.

Notes on bib: upstream `bootc-image-builder` was merged into `osbuild/image-builder`, but
`registry.redhat.io/rhel9/bootc-image-builder` remains the supported path for RHEL content and
is what the workflow uses. Output lands at `output/bootiso/install.iso`. `anaconda-iso` boots
the stock RHEL kernel (no Tegra modules) for the installer, and the deployed image brings its own
kernel. That was safe while the target was NVMe, which needs only generic PCIe plus `nvme`. The
eMMC does not: `mmcblk0` appears only if that kernel carries the Tegra-specific `sdhci-tegra`
driver. If the installer shows no `mmcblk0`, this is the first thing to check (`lsblk`,
`modprobe sdhci-tegra` on the installer console, Ctrl-Alt-F2) — not the kickstart. Unverified on
hardware as of this writing.

## Next step: validate on hardware, then the app services

1. Run `build-microshift.yml` (dispatch — there is no PR build), `dd` the ISO, boot the devkit
   from USB with QSPI flashed from R36.5.x.
   Confirm `bootc status`, `lsmod | grep nvgpu`, `nvidia-ctk cdi list` → `nvidia.com/gpu=all`,
   and a GPU container (`podman run --device nvidia.com/gpu=all …`). `bootc status` is also
   where the origin problem above becomes visible: expect a GHCR reference pinned by digest,
   which is exactly what cannot upgrade. Check `systemctl is-enabled
   bootc-fetch-apply-updates.timer` in the same pass. `jtop` in the same pass:
   nothing enables a jtop service, so expect to find out there whether it works as installed.
2. Same boot, confirm MicroShift: `systemctl status microshift`, `oc get pods -A` all running
   with no registry reachable (that is what the embedding buys), `vgs` showing free extents in
   VG `rhel`, and a PVC binding against the topolvm storage class.
3. Confirm the device plugin: `oc get ds -n kube-system nvidia-device-plugin-daemonset` and
   `nvidia.com/gpu` in the node's allocatable resources — with time slicing that should read
   the ConfigMap's replica count, not 1. Then schedule that many GPU pods at once and watch
   for the OOM that says the count is above what the SOM's RAM can hold.
4. Confirm the services layer came up, in the order the roots are numbered and with no
   registry reachable: `oc get pods -n cert-manager` (three, Running) and
   `oc get pods -n external-secrets` (three, Running).
   The External Secrets pods are the ones to watch: if the `runAsUser` patch ever stops
   applying, the Deployments still exist and create nothing, and
   `oc describe rs` is where the SCC refusal shows up. Check the resource patches survived the
   round trip too — `oc get deploy -A -o jsonpath` over `resources` — since nothing between the
   render and the node re-checks them.
   `journalctl -u microshift | grep -i kustomization` is where a root that is still
   retrying says so; it retries for ten minutes and then gives up quietly.
5. Decide what serves the model, now that KServe and Triton are out of the tree, and what
   External Secrets reads from on a node with no network — until there is a `SecretStore` it is
   three pods that do nothing.
6. k3s variant — dead in CI. Reviving it starts with writing `build-k3s.yml` again; then
   confirm `k3s.service` comes up enforcing, that `k3s-stage-assets.service` staged the images
   before it, that `k3s ctr images ls` shows the airgap set with no registry reachable, and
   that a GPU pod schedules through the default `nvidia` runtime.
7. Later layers (separate Containerfiles `FROM` the k8s image, not this one): `bootc switch`
   unit pointing at the air-gapped registry, greenboot health checks, image signature policy in
   `/etc/containers/policy.json`.

Open decisions to confirm with the maintainer before implementing: what replaces KServe and
Triton for serving the model, and whether cert-manager still has a consumer once they are gone;
which provider External Secrets reads from on a disconnected node;
whether the NVMe upgrade in decision 3 happens before real application images and a model store
land on the node; whether to keep the entitlement-secret approach or stand up a self-hosted RHEL
runner; whether the static `192.168.1.10` / hostname `jetson-1` baked into the ISO becomes
per-device before a second node joins the air-gapped network; whether the k3s node's kubeconfig
(`/etc/rancher/k3s/k3s.yaml`, root-only) should be opened to the `cloudlet` user the way
`openshift-clients` opens the microshift one; whether the k3s
variant comes back at all, and if so how service images reach k3s's containerd, given that a
second copy as `docker-archive` would put every application layer in `/usr` twice; how a
deployed node's origin gets pointed at the air-gapped registry's `stable` tag — a `bootc switch`
unit or a retag before bib — and whether `stable` should keep moving on every green build of
`main` or only when a build has been booted on hardware, which is the difference between an
upgrade channel and a bookmark; and whether
the resource numbers in `services/manifests/` (the ratios are enforced by the smoke test, the
sizes are guesses) survive contact with the hardware.

## How to work in this repo

**Style — this matters as much as correctness.**

- Scripts are lean and minimal. Do not add features nobody asked for: no EPEL, no container
  entitlement plumbing beyond what is needed, no SHA256 verification (tried, failed in practice,
  removed), no rootfs download, no "helpful" extras. If a feature is not required for the stated
  job, leave it out and mention it in the reply instead.
- One script, one job. Flashing, repo mirroring, offline installation and image building are
  separate concerns and separate files. Never fold flashing setup into a package installer.
- No stray side effects: no empty directories, nothing installed on the build host, no changes
  outside the script's declared output dir.
- Validate inputs before expensive work (reposync, podman build, bib) — fail early, fail loud.
  `set -euo pipefail` everywhere.
- Keep `gpgcheck=1` on the offline host. Use `reposync --download-metadata`, not
  `createrepo_c`, so the signed AppStream modular metadata survives.
- Bash: `getopts` with short flags and a `usage()`; sensible defaults shown in usage. Prefer
  `bash -n` + a real run over unit-test frameworks.
- Explanations in replies should be deep and line-by-line, not headline summaries.

**Things that bit us — do not repeat.**

- RHEL packages the C preprocessor separately as `cpp`; `flash.sh` dies with
  `FileNotFoundError: cpp` without it.
- `apt-get --download-only install` skips already-installed packages — any Debian-side bundle
  must be built in a clean container with separate download and index stages (legacy note from
  the Ubuntu evaluation; keep in mind if an Ubuntu path ever returns).
- `rockylinux:9`, not UBI, is the base for any RPM-bundling builder container; UBI lacks the
  needed packages.
- Every base-image bump is a potential GPU break because the kmod is tied to a kernel build. A
  container smoke test proves nothing about the GPU; boot on real hardware before promoting a tag.
- `nvidia-ctk runtime configure --config=<dir>/99-nvidia.conf` writes `99-nvidia.toml` instead and
  still exits 0 — the build cannot tell you it renamed the file. CRI-O walks `crio.conf.d` and
  reads every file regardless of extension, so the drop-in works either way; only a check spelling
  the name notices. Ask for the `.toml` path.
- A bare `test` in a smoke test exits 1 with no output, so the log cannot say which path was
  missing. Every check names what it looked for and lists the directory.
- podman in a `container:` job silently loses the native overlay diff — storage on overlayfs, or
  RHEL's `metacopy=on` mount option — and every layer commit then takes minutes. Keep the
  `/scratch` bind, the `metacopy` strip and the `Native Overlay Diff:true` check.
- A `kind: Deployment` patch that matches nothing fails the kustomize build, which is the
  safety net under every patch in `services/`. An `images:` transformer that matches nothing
  does not, and neither does a field the patch no longer needs to delete — those need a check
  on the render.
- An apostrophe inside an `awk` program ends the single-quoted shell word around it, and the
  error arrives as a bash syntax error pointing at `$0`. No contractions in awk comments.

**Git / delivery.** Work lands on a branch and a pull request, not by hand-copying files:
develop on the branch named in the session, commit with a message that says *why*, push, and
open the PR only when asked. Always state which files changed. Nothing runs CI on a PR —
`build-microshift.yml` triggers on push to `main` and on `workflow_dispatch` — so a branch is
validated by dispatching the workflow against it, and a claim that something is tested should
say which of the two it means.

## Quick reference

```bash
# Online RHEL host — build the repo bundle (incremental)
./mirror.sh -o /run/media/$USER/USBKEY/dist

# Air-gapped station — provision (as root, from the bundle dir)
sudo ./install-offline.sh

# Air-gapped station — flash QSPI (devkit in recovery: hold Force Recovery, tap Reset, release)
lsusb | grep 0955
cd /opt/nvidia/Linux_for_Tegra && sudo ./flash.sh p3737-0000-p3701-0000-qspi external

# Local image build on a subscribed RHEL 9 aarch64 box, from the repo root (the build context
# is the root for every layer, and the vendor base on quay.io is public). Each layer FROM the
# one before it; --build-arg BASE_IMAGE is what the workflow passes as a digest.
sudo podman build -f base/Containerfile.base     -t localhost/jetson-base:dev .
sudo podman build -f base/Containerfile.podman   -t localhost/jetson-podman:dev \
    --build-arg BASE_IMAGE=localhost/jetson-base:dev .
sudo podman build -f microshift/Containerfile    -t localhost/jetson-microshift:dev \
    --secret id=pullsecret,src=$HOME/pull-secret.json \
    --build-arg BASE_IMAGE=localhost/jetson-podman:dev .
sudo podman build -f services/Containerfile      -t localhost/jetson-orin-bootc:dev \
    --secret id=pullsecret,src=$HOME/pull-secret.json \
    --build-arg BASE_IMAGE=localhost/jetson-microshift:dev .
# Smoke tests are fed on stdin, the same way the workflow runs them
podman run --rm -i localhost/jetson-orin-bootc:dev bash -s < services/smoke-test.sh

# ISO from the top of the chain
sed -e "s|@JETSON_SSH_PUBKEY@|$(cat ~/.ssh/id_ed25519.pub)|" \
    -e "s|@JETSON_PASSWORD_HASH@|$(openssl passwd -6)|" \
    microshift/config.toml > /tmp/config.toml
sudo podman run --rm --privileged --pull=newer --security-opt label=type:unconfined_t \
  -v /tmp/config.toml:/config.toml:ro -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  registry.redhat.io/rhel9/bootc-image-builder:latest \
  --type anaconda-iso --config /config.toml localhost/jetson-orin-bootc:dev
# -> output/bootiso/install.iso

# On the device
cat /etc/nv_tegra_release      # R36 REVISION 5.0
lsmod | grep nvgpu
systemctl status nvidia-ctk && nvidia-ctk cdi list   # expect nvidia.com/gpu=all
bootc status

# On a k3s node (nothing builds this variant — build-k3s.yml was deleted)
systemctl status k3s-stage-assets k3s
k3s ctr images ls | grep -c .        # airgap set + device plugin, imported with no registry
k3s kubectl get nodes -o jsonpath='{.items[0].status.allocatable}'   # expect nvidia.com/gpu
```
