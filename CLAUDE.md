# CLAUDE.md — jetson-image-builder

Provisioning and image pipeline for NVIDIA Jetson AGX Orin edge nodes running RHEL image mode
(bootc) in a disconnected environment. Read this whole file before touching anything.

**Two repos.** This one holds the image pipeline (`Containerfile`, `config.toml`,
`.github/workflows/build-bootc.yml`). The flashing-station tooling — `mirror.sh`,
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
- Kubernetes: k3s **or** MicroShift — not yet decided
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
6. **Builds run in GitHub Actions on `ubuntu-24.04-arm`** for native aarch64; images are pushed
   to GHCR, then mirrored into the air-gapped registry by hand.
7. **NVIDIA BSP download stays manual** and is documented in `README.md`. Scripting it was tried;
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

### bootc image + installer ISO pipeline (`Containerfile`, `config.toml`, `build-bootc.yml`)

- `Containerfile` — `FROM` the pinned JetPack-for-RHEL image + `bootc container lint`. Nothing
  else yet; the Kubernetes layer is the next addition.
- `config.toml` — bib config with a **custom kickstart** (bib then adds only `ostreecontainer`;
  `[customizations.user]`/`filesystem` cannot be combined with a custom kickstart, so
  everything lives in the kickstart): `text --non-interactive`, DHCP on link, `ignoredisk
  --only-use=nvme0n1`, `clearpart --all` + `autopart --noswap --type=plain --fstype=xfs`,
  root locked, user `edge` in `wheel` from `@EDGE_SSH_PUBKEY@` / `@EDGE_PASSWORD_HASH@`
  placeholders, `reboot --eject`. ISO label `JETSON_ORIN_BOOTC`.
- `.github/workflows/build-bootc.yml` — job `image` on `ubuntu-24.04-arm`: build, smoke test
  (`bootc --version`, `/etc/nv_tegra_release`, `rpm -q` kmod + toolkit-base, `nvgpu.ko`
  present), push `ghcr.io/<owner>/jetson-orin-bootc:<YYYYMMDD-sha8>` + `latest`. Job `iso`:
  restore entitlement certs from a secret, `sed` the two placeholders, run
  `registry.redhat.io/rhel9/bootc-image-builder --type anaconda-iso` with
  `/etc/pki/entitlement` and `/etc/rhsm` bind-mounted, upload `*.iso` + `SHA256SUMS`.

Secrets: `RH_REGISTRY_USER`, `RH_REGISTRY_TOKEN` (bib image pull), `RHSM_ENTITLEMENT_TGZ_B64`
(`tar -C / -czf - etc/pki/entitlement etc/rhsm | base64 -w0` from a subscribed RHEL host — bib
must depsolve Anaconda RPMs from RHEL repos), `EDGE_SSH_PUBKEY`, `EDGE_PASSWORD_HASH`
(`openssl passwd -6`). `RHSM_ORG`/`RHSM_ACTIVATION_KEY` are no longer used — the container
build does no `dnf`. They return when the Kubernetes layer needs RHEL/MicroShift repos.
A self-hosted registered RHEL 9 aarch64 runner would remove the entitlement secret.

Notes on bib: upstream `bootc-image-builder` was merged into `osbuild/image-builder`, but
`registry.redhat.io/rhel9/bootc-image-builder` remains the supported path for RHEL content and
is what the workflow uses. Output lands at `output/bootiso/install.iso`. `anaconda-iso` boots
the stock RHEL kernel (no Tegra modules) for the installer — that is fine, the installer only
needs NVMe/USB/NIC, and the deployed image brings its own kernel.

## Next step: validate the ISO on hardware, then the Kubernetes layer

1. Run `build-bootc.yml`, `dd` the ISO, boot the devkit from USB with QSPI flashed from R36.5.x.
   Confirm `bootc status`, `lsmod | grep nvgpu`, `nvidia-ctk cdi list` → `nvidia.com/gpu=all`,
   and a GPU container (`podman run --device nvidia.com/gpu=all …`).
2. Add the Kubernetes layer — k3s or MicroShift (open decision; MicroShift is the Red Hat
   supported path on RHEL for Edge, k3s is lighter and has fewer entitlement dependencies).
   Whichever is chosen: enable the NVIDIA device plugin via CDI, and use **physically bound
   images** (`/usr/lib/containers/storage` + `containers-storage` transport) so PostgreSQL,
   RabbitMQ, KServe and the model server start with no registry reachable.
3. Re-run the pipeline; the ISO now carries the cluster. Verify a GPU pod schedules and KServe
   answers an inference request with no network attached.
4. Later layers (separate Containerfiles `FROM` the k8s image, not this one): `bootc switch`
   unit pointing at the air-gapped registry, greenboot health checks, image signature policy in
   `/etc/containers/policy.json`.

Open decisions to confirm with the maintainer before implementing: k3s vs MicroShift;
whether to keep the entitlement-secret approach or stand up a self-hosted RHEL runner.

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
