# CLAUDE.md — jetson-image-builder

Provisioning and image pipeline for NVIDIA Jetson AGX Orin edge nodes running RHEL image mode
(bootc) in a disconnected environment. Read this whole file before touching anything.

**Two repos.** This one holds the image pipeline (`microshift/`, `physically-bound-images/`,
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
- Kubernetes: **MicroShift 4.20** is the primary variant; **k3s** is being prepared beside it as a
  second variant, not as a replacement
- App services on the cluster: PostgreSQL, RabbitMQ
- Inference: KServe serving the image-recognition model
- All container images physically bound into the OS image (zero network at first boot)

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
7. **Three layers, one directory per Kubernetes variant.** `base/` republishes the pinned
   vendor image under our own name and adds nothing — it exists so the pin lives in one file
   and so there is a stable internal name to mirror into the air-gapped registry. `apps/`
   builds `FROM` it with the physically-bound-images machinery and the application images every
   variant needs. `microshift/` builds `FROM` that and adds MicroShift, the device plugin and
   their images. `k3s/` sits beside `microshift/` and reuses `base` and `apps` untouched.
   The split is about rebuild cost: a variant layer pulls a whole control plane (MicroShift's is
   nine images) and that should not be redone whenever an application image or a model changes.
   Each layer is pushed separately as
   `jetson-orin-bootc-<name>` and the next builds on its **digest**, not its tag. CI is two
   reusable workflows — `build-image.yml` (one layer) and `build-iso.yml` — plus a caller per
   variant chaining base → variant → ISO. Shared tooling (`physically-bound-images/`) stays at
   the root and the build context is the repository root so any layer can `COPY` it. Every
   layer registers with subscription-manager, including the two that install no RPMs: one code
   path for every layer beats a per-layer entitlement flag. Layout and the
   reusable-workflow split follow
   `redhat-et/edge-ai-image-pipelines`, whose `Containerfile.podman` is the same idea as our
   `base/`.
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

### bootc image + installer ISO pipeline (`microshift/`, `physically-bound-images/`, `.github/workflows/`)

- `base/Containerfile` — `FROM` the pinned JetPack-for-RHEL image and nothing else, plus
  `bootc container lint`. Republished as `jetson-orin-bootc-base`.
- `apps/Containerfile` — `FROM` the base layer via `ARG BASE_IMAGE`; installs the
  physically-bound-images scripts and `copy-embedded-images.service`, and embeds whatever
  `APP_IMAGES` names (empty today; PostgreSQL, RabbitMQ, KServe and the model server go here).
  No `dnf`, so neither this nor the base build needs entitlement.
- `microshift/Containerfile` — `FROM` the apps layer via `ARG BASE_IMAGE`, then MicroShift 4.20 from
  `rhocp-4.20-for-rhel-9-aarch64-rpms` + `fast-datapath-for-rhel-9-aarch64-rpms`
  (`firewalld jq microshift microshift-release-info openshift-clients` — `oc` comes from
  `openshift-clients`; the `microshift` RPM ships no client), the firewall rules (trusted: pod CIDR
  `10.42.0.0/16`, service CIDR `10.43.0.0/16`, host-endpoint `169.254.169.1`; public: 22, 443,
  6443), the
  `microshift-make-rshared.service` OVN needs, and every MicroShift container image embedded
  into `/usr/lib/containers-image-cache` with a `microshift.service.d` drop-in that orders them
  into containers-storage before the service starts (the unit itself lives in the apps layer;
  this one only orders against it), plus the NVIDIA device plugin
  (`nvidia-ctk runtime configure --runtime=crio` writing
  `/etc/crio/crio.conf.d/99-nvidia.toml`, the plugin manifest and a kustomization in
  `/etc/microshift/manifests`, and the plugin image embedded alongside MicroShift's),
  plus `microshift-gitops` — core Argo CD, no web console, as manifests under
  `/usr/lib/microshift/manifests.d/`. It comes from the **OpenShift GitOps channel**
  (`gitops-<GITOPS_VER>-for-rhel-9-aarch64-rpms`, default `1.19`), a third
  `--enablerepo` on the same `dnf install`, so the subscription needs that entitlement
  too. Argo CD wants ~250 MB beyond MicroShift's own footprint.
  Images are copied into the main store rather than referenced as an additional store, because
  an image upgrade overwrites an additional store (RHEL-75827). **No `dnf upgrade`**: Red Hat's
  own file runs one, but here it could pull a kernel past 5.14.0-687.42.1 and the Tegra kmod is
  built against that exact build. `--enablerepo` rather than `dnf config-manager`, so the build
  does not depend on dnf-plugins-core being in the base. No Containerfile heredocs — everything
  is `printf` or `COPY`, so the build does not depend on the builder's podman being new enough
  to parse `RUN <<EOF`.
- `microshift/manifest-images.sh` — prints every image referenced by the MicroShift
  manifest roots it is given, rendering each with `oc kustomize`. `release-<arch>.json`
  lists the control plane only; the device plugin's image and Argo CD's are named
  nowhere but in the manifests that deploy them, and an `images:` transformer defeats a
  grep. The build embeds what it prints; the smoke test re-runs it against the cache.
- `physically-bound-images/{embed_image.sh,copy_embedded_images.sh}` — adapted from
  `redhat-et/edge-ai-image-pipelines` (Apache-2.0). Cache is `/usr/lib/containers-image-cache`
  with a `mapping.txt` of reference -> sha, replayed once per boot by
  `copy-embedded-images.service` (a standalone oneshot, with `Requires=`/`After=` on
  microshift.service, rather than Red Hat's `ExecStartPre=` — it runs once per boot instead of
  on every MicroShift restart, and later app images share the one mechanism). `embed_image.sh`
  splits `$REPO:$TAG@sha256:$SHA` references, which skopeo rejects and Red Hat's own recipe does
  not handle. The unit deliberately does **not** want `network-online.target`: the copy is
  local-disk only and waiting for a carrier that never comes would add
  NetworkManager-wait-online's timeout to every boot.
- `k3s/Containerfile` — `FROM` the apps layer via `ARG BASE_IMAGE`, then k3s (pinned
  `K3S_VERSION`, default `v1.36.4+k3s1`) as the `k3s-arm64` static binary into `/usr/bin/k3s`
  with the usual `kubectl`/`crictl`/`ctr` argv[0] symlinks — `/usr/local` is machine state on
  bootc, so upstream's install script and its `/usr/local/bin` default are not usable. Only
  `k3s-selinux` comes from Rancher's RPM repo (`rpm.rancher.io/k3s/stable/common/centos/9/noarch`,
  `gpgcheck=1`); without it there are no SELinux types for `/var/lib/rancher` and the cluster does
  not come up enforcing, and the repo file is deleted again in the same layer because the deployed
  node can never reach it. Firewall rules match the microshift layer (k3s defaults to the same pod
  and service CIDRs); traefik's port 80 is deliberately left closed. GPU integration is
  `default-runtime: nvidia` in `/etc/rancher/k3s/config.yaml` rather than
  `nvidia-ctk runtime configure`: k3s generates its own containerd config, finds
  `nvidia-container-runtime` in `$PATH` and adds an `nvidia` runtime, but a pod only reaches it
  through a RuntimeClass unless it is the default — the same choice `--set-as-default` makes under
  CRI-O, and it keeps the stock device-plugin manifest usable unmodified. Images are the release's
  `k3s-airgap-images-arm64.tar.zst` plus the device plugin as a `docker-archive` tarball, both in
  `/usr/share/k3s/agent-images`; **the apps layer's `embed_image.sh` cache is useless here**,
  because it writes into podman's containers-storage and k3s's containerd does not read it, so
  `APP_IMAGES` will need a second staging path before the first application image lands.
- `k3s/stage-assets.sh` + `k3s-stage-assets.service` — `/var` is machine state, so neither
  `/var/lib/rancher/k3s/agent/images` nor `.../server/manifests` exists at first boot. The unit is
  a oneshot ordered `Before=k3s.service` (and `Requires=`d by it) rather than `tmpfiles.d`, so an
  image upgrade actually replaces what is staged. The images directory is a **symlink** into
  `/usr/share/k3s/agent-images` — copying a ~1 GiB tarball onto the eMMC every boot would spend
  space and write endurance duplicating something already on disk, and k3s only reads it. The
  manifests directory has to be a real directory: k3s writes its own bundled coredns, traefik,
  local-storage and metrics-server YAML into it.
- `k3s/config.toml` — the microshift kickstart with one change: root **grows over the whole VG**
  instead of stopping at 40 GiB. k3s provisions PVs from local-path, a directory on the root
  filesystem, so free extents would be space the cluster cannot reach. ISO label
  `JETSON_ORIN_K3S`, distinct from the microshift ISO's — anaconda finds its stage2 by label, and
  two variants sharing one would pick whichever stick enumerated first.
- `.github/workflows/build-k3s.yml` — the microshift caller with the top two jobs repointed;
  `base` and `apps` are identical. A change under `base/` or `apps/` triggers both callers, so
  those two layers are built and pushed once per variant. Accepted: the alternative is one
  workflow fanning out, which couples the variants' release cadence.
- `microshift/config.toml` — bib config with a **custom kickstart** (bib then adds only `ostreecontainer`;
  `[customizations.user]`/`filesystem` cannot be combined with a custom kickstart, so
  everything lives in the kickstart): `text --non-interactive`, `timezone Asia/Jerusalem --utc`,
  static `192.168.1.10/24` gw `192.168.1.1` on link with `--hostname=Jetson`, `ignoredisk
  --only-use=mmcblk0`, `clearpart --all` + `reqpart --add-boot` + one VG `rhel` on the rest of
  the eMMC holding a 40 GiB xfs root and **no swap**, **with the remaining ~16.5 GiB of extents
  left free for MicroShift's LVMS provisioner** (fill the VG and the cluster has no dynamic PV
  source, so PostgreSQL/RabbitMQ/the model store have nowhere to go), root
  locked, user `jetson` in `wheel` from `@JETSON_SSH_PUBKEY@` /
  `@JETSON_PASSWORD_HASH@` placeholders, `reboot --eject`. ISO label `JETSON_ORIN_BOOTC`.
  The static address and hostname are baked into the ISO: two devices imaged from the same ISO
  collide on one segment. `--nameserver` is deliberately absent — the network is air-gapped and
  there is no resolver to point at.
- `.github/workflows/build-image.yml` — **reusable**: register, bind container storage onto the
  runner's disk so podman gets native overlay, write the
  pull secret, build the given Containerfile with the repo root as context, run the given
  smoke-test inside the result, push `ghcr.io/<owner>/jetson-orin-bootc-<name>:<YYYYMMDD-sha8>`
  + `latest`, and output the ref pinned by digest (`podman push --digestfile`).
  `.github/workflows/build-iso.yml` — **reusable**:
  register, substitute the two `@JETSON_*@` placeholders into `<variant>/config.toml` (in bash,
  not `sed`, with the secrets in `env:` — an `&`, a quote or a newline in a value would
  otherwise mangle the kickstart or break the command) after rejecting an empty or
  non-crypt `JETSON_PASSWORD_HASH`, run
  `registry.redhat.io/rhel9/bootc-image-builder --type anaconda-iso` with
  `/etc/pki/entitlement` and `/etc/rhsm` bind-mounted, upload `*.iso` + `SHA256SUMS`.

Secrets: `RH_REGISTRY_USER`, `RH_REGISTRY_PASSWORD` (bib image pull), `RHSM_USERNAME`/`RHSM_PASSWORD`
(both jobs `subscription-manager register` inside the UBI builder, and unregister in an
`if: always()` step), `OPENSHIFT_PULL_SECRET` (pulls MicroShift's and the device plugin's
container images at build time; never written into the OS image), `JETSON_SSH_PUBKEY`,
`JETSON_PASSWORD_HASH` (`openssl passwd -6`). The subscription must carry an
OpenShift GitOps entitlement as well as an OpenShift one, or `microshift-gitops` is
unreachable and the microshift layer fails. The entitlement-certificate tarball
(`RHSM_ENTITLEMENT_TGZ_B64`) was replaced by registration: nothing expires inside a secret and
`redhat.repo` is generated fresh by the registration. Cost is a register/unregister cycle per
job — four per run — and the build stops if the credentials are wrong.
Registration uses an account username and password by maintainer preference; an org ID plus
activation key is the narrower credential and the only option for SSO or 2FA accounts, so revisit
this if the account gains either. Credentials are passed through `env:` rather than interpolated
into the command, so a password containing a quote or `$` cannot break the shell. With Simple
Content Access off, the register call needs `--auto-attach`. The subscription must carry an OpenShift entitlement or
`rhocp-4.20-for-rhel-9-aarch64-rpms` never appears and the build fails at `--enablerepo`.
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

## Next step: validate on hardware, then the NVIDIA device plugin

1. Run `build-microshift.yml`, `dd` the ISO, boot the devkit from USB with QSPI flashed from R36.5.x.
   Confirm `bootc status`, `lsmod | grep nvgpu`, `nvidia-ctk cdi list` → `nvidia.com/gpu=all`,
   and a GPU container (`podman run --device nvidia.com/gpu=all …`).
2. Same boot, confirm MicroShift: `systemctl status microshift`, `oc get pods -A` all running
   with no registry reachable (that is what the embedding buys), `vgs` showing free extents in
   VG `rhel`, and a PVC binding against the topolvm storage class.
3. Confirm the device plugin: `oc get ds -n kube-system nvidia-device-plugin-daemonset` and
   `nvidia.com/gpu` in the node's allocatable resources.
   Confirm GitOps in the same pass: `oc get pods -n openshift-gitops` running with no
   registry reachable, and `argocd` CLI access if the RPM ships one.
4. Add the bound app images (PostgreSQL, RabbitMQ, KServe, the model server) through
   `embed_image.sh`, and their manifests to `/etc/microshift/manifests/kustomization.yaml`.
5. Verify a GPU pod schedules and KServe answers an inference request with no network attached.
6. k3s variant, unvalidated on hardware and behind the microshift one: confirm `k3s.service`
   comes up enforcing, that `k3s-stage-assets.service` staged the images before it, that
   `k3s ctr images ls` shows the airgap set and the device plugin with no registry reachable, and
   that a GPU pod schedules through the default `nvidia` runtime.
7. Later layers (separate Containerfiles `FROM` the k8s image, not this one): `bootc switch`
   unit pointing at the air-gapped registry, greenboot health checks, image signature policy in
   `/etc/containers/policy.json`.

Open decisions to confirm with the maintainer before implementing: whether to keep the
entitlement-secret approach or stand up a self-hosted RHEL runner; whether the static
192.168.1.10 / hostname `Jetson` baked into the ISO becomes per-device before a second node
joins the air-gapped network; how `APP_IMAGES` reach k3s's containerd, given that a second copy as
`docker-archive` would put every application layer in `/usr` twice; and whether the k3s node's
kubeconfig (`/etc/rancher/k3s/k3s.yaml`, root-only) should be opened to the `jetson` user the way
`openshift-clients` opens the microshift one.

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

**Git / delivery.** Claude has no push access. Produce files; the maintainer copies them into the
local checkout and pushes. Always state which files changed and give the `cp` + `git` commands.

## Quick reference

```bash
# Online RHEL host — build the repo bundle (incremental)
./mirror.sh -o /run/media/$USER/USBKEY/dist

# Air-gapped station — provision (as root, from the bundle dir)
sudo ./install-offline.sh

# Air-gapped station — flash QSPI (devkit in recovery: hold Force Recovery, tap Reset, release)
lsusb | grep 0955
cd /opt/nvidia/Linux_for_Tegra && sudo ./flash.sh p3737-0000-p3701-0000-qspi external

# Local image + ISO build on a subscribed RHEL 9 aarch64 box (base on quay.io is public)
sudo podman build -t localhost/jetson-orin-bootc:dev .
sed -e "s|@JETSON_SSH_PUBKEY@|$(cat ~/.ssh/id_ed25519.pub)|" \
    -e "s|@JETSON_PASSWORD_HASH@|$(openssl passwd -6)|" config.toml > /tmp/config.toml
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

# On a k3s node
systemctl status k3s-stage-assets k3s
k3s ctr images ls | grep -c .        # airgap set + device plugin, imported with no registry
k3s kubectl get nodes -o jsonpath='{.items[0].status.allocatable}'   # expect nvidia.com/gpu
```
