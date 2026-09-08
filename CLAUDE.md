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
- Kubernetes: **MicroShift 4.20** (decided; k3s was the alternative and was dropped)
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
                               │ Jetson AGX Orin: first boot from USB (ISO/qcow2),        │
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
3. **QSPI-only flash.** The Jetson boots RHEL bootc from external storage, so the Ubuntu rootfs
   in the BSP is discarded entirely. The working command is:
   ```
   sudo ./flash.sh p3737-0000-p3701-0000-qspi external
   ```
   NOT `jetson-agx-orin-devkit external` — that target builds a recovery ramdisk and fails
   without a populated `rootfs/`.
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
   way. The runner's `/dev/nvme0n1` scratch disk is formatted and `/var/lib/containers`,
   `/var/tmp` and the ISO output are moved onto it — ~10 GB of embedded images plus a
   multi-gigabyte ISO does not fit in the job container's writable layer.
7. **Three layers, one directory per Kubernetes variant.** `base/` republishes the pinned
   vendor image under our own name and adds nothing — it exists so the pin lives in one file
   and so there is a stable internal name to mirror into the air-gapped registry. `apps/`
   builds `FROM` it with the physically-bound-images machinery and the application images every
   variant needs. `microshift/` builds `FROM` that and adds MicroShift, the device plugin and
   their images. `k3s/` is expected beside `microshift/`, reusing `base` and `apps` untouched.
   The split is about rebuild cost: a variant layer pulls a whole control plane (MicroShift's is
   nine images) and that should not be redone whenever an application image or a model changes.
   Each layer is pushed separately as
   `jetson-orin-bootc-<name>` and the next builds on its **digest**, not its tag. CI is two
   reusable workflows — `build-image.yml` (one layer) and `build-iso.yml` — plus a caller per
   variant chaining base → variant → ISO. Shared tooling (`physically-bound-images/`) stays at
   the root and the build context is the repository root so any layer can `COPY` it. A layer
   that runs no `dnf` against RHEL repos passes `needs-entitlement: false` and consumes no
   subscription slot; the base layer does. Layout and the reusable-workflow split follow
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
  (`firewalld jq microshift microshift-release-info`), the firewall rules (trusted: pod CIDR
  `10.42.0.0/16`, service CIDR `10.43.0.0/16`, host-endpoint `169.254.169.1`; public: 22, 443,
  6443), the
  `microshift-make-rshared.service` OVN needs, and every MicroShift container image embedded
  into `/usr/lib/containers-image-cache` with a `microshift.service.d` drop-in that orders them
  into containers-storage before the service starts (the unit itself lives in the apps layer;
  this one only orders against it), plus the NVIDIA device plugin
  (`nvidia-ctk runtime configure --runtime=crio`, the plugin manifest and a kustomization in
  `/etc/microshift/manifests`, and the plugin image embedded alongside MicroShift's).
  Images are copied into the main store rather than referenced as an additional store, because
  an image upgrade overwrites an additional store (RHEL-75827). **No `dnf upgrade`**: Red Hat's
  own file runs one, but here it could pull a kernel past 5.14.0-687.42.1 and the Tegra kmod is
  built against that exact build. `--enablerepo` rather than `dnf config-manager`, so the build
  does not depend on dnf-plugins-core being in the base. No Containerfile heredocs — everything
  is `printf` or `COPY`, so the build does not depend on the builder's podman being new enough
  to parse `RUN <<EOF`.
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
- `microshift/config.toml` — bib config with a **custom kickstart** (bib then adds only `ostreecontainer`;
  `[customizations.user]`/`filesystem` cannot be combined with a custom kickstart, so
  everything lives in the kickstart): `text --non-interactive`, `timezone Asia/Jerusalem --utc`,
  static `192.168.1.10/24` gw `192.168.1.1` on link with `--hostname=Jetson`, `ignoredisk
  --only-use=nvme0n1`, `clearpart --all` + `reqpart --add-boot` + one VG `rhel` on the rest of
  the NVMe holding a 60 GiB xfs root and swap, **with the remaining extents left free for
  MicroShift's LVMS provisioner** (fill the VG and the cluster has no dynamic PV source, so
  PostgreSQL/RabbitMQ/the model store have nowhere to go; assumes an NVMe ≳80 GiB), root
  locked, user `edge` in `wheel` from `@EDGE_SSH_PUBKEY@` /
  `@EDGE_PASSWORD_HASH@` placeholders, `reboot --eject`. ISO label `JETSON_ORIN_BOOTC`.
  The static address and hostname are baked into the ISO: two devices imaged from the same ISO
  collide on one segment. `--nameserver` is deliberately absent — the network is air-gapped and
  there is no resolver to point at.
- `.github/workflows/build-image.yml` — **reusable**: register (unless
  `needs-entitlement: false`), move container storage onto the runner's scratch disk, write the
  pull secret, build the given Containerfile with the repo root as context, run the given
  smoke-test inside the result, push `ghcr.io/<owner>/jetson-orin-bootc-<name>:<YYYYMMDD-sha8>`
  + `latest`, and output the ref pinned by digest (`podman push --digestfile`).
  `.github/workflows/build-iso.yml` — **reusable**:
  register, `sed` the two placeholders into `<variant>/config.toml`, run
  `registry.redhat.io/rhel9/bootc-image-builder --type anaconda-iso` with
  `/etc/pki/entitlement` and `/etc/rhsm` bind-mounted, upload `*.iso` + `SHA256SUMS`.

Secrets: `RH_REGISTRY_USER`, `RH_REGISTRY_TOKEN` (bib image pull), `RHSM_USERNAME`/`RHSM_PASSWORD`
(both jobs `subscription-manager register` inside the UBI builder, and unregister in an
`if: always()` step), `OPENSHIFT_PULL_SECRET` (pulls MicroShift's and the device plugin's
container images at build time; never written into the OS image), `EDGE_SSH_PUBKEY`,
`EDGE_PASSWORD_HASH` (`openssl passwd -6`). The entitlement-certificate tarball
(`RHSM_ENTITLEMENT_TGZ_B64`) was replaced by registration: nothing expires inside a secret and
`redhat.repo` is generated fresh by the registration. Cost is a subscription slot per run.
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
the stock RHEL kernel (no Tegra modules) for the installer — that is fine, the installer only
needs NVMe/USB/NIC, and the deployed image brings its own kernel.

## Next step: validate on hardware, then the NVIDIA device plugin

1. Run `build-microshift.yml`, `dd` the ISO, boot the devkit from USB with QSPI flashed from R36.5.x.
   Confirm `bootc status`, `lsmod | grep nvgpu`, `nvidia-ctk cdi list` → `nvidia.com/gpu=all`,
   and a GPU container (`podman run --device nvidia.com/gpu=all …`).
2. Same boot, confirm MicroShift: `systemctl status microshift`, `oc get pods -A` all running
   with no registry reachable (that is what the embedding buys), `vgs` showing free extents in
   VG `rhel`, and a PVC binding against the topolvm storage class.
3. Confirm the device plugin: `oc get ds -n kube-system nvidia-device-plugin-daemonset` and
   `nvidia.com/gpu` in the node's allocatable resources.
4. Add the bound app images (PostgreSQL, RabbitMQ, KServe, the model server) through
   `embed_image.sh`, and their manifests to `/etc/microshift/manifests/kustomization.yaml`.
5. Verify a GPU pod schedules and KServe answers an inference request with no network attached.
4. Later layers (separate Containerfiles `FROM` the k8s image, not this one): `bootc switch`
   unit pointing at the air-gapped registry, greenboot health checks, image signature policy in
   `/etc/containers/policy.json`.

Open decisions to confirm with the maintainer before implementing: whether to keep the
entitlement-secret approach or stand up a self-hosted RHEL runner; whether the static
192.168.1.10 / hostname `Jetson` baked into the ISO becomes per-device before a second node
joins the air-gapped network.

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
sed -e "s|@EDGE_SSH_PUBKEY@|$(cat ~/.ssh/id_ed25519.pub)|" \
    -e "s|@EDGE_PASSWORD_HASH@|$(openssl passwd -6)|" config.toml > /tmp/config.toml
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
```
