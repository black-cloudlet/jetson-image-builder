# CLAUDE.md — jetson-image-builder

Provisioning and image pipeline for NVIDIA Jetson AGX Orin edge nodes running RHEL image mode
(bootc) in a disconnected environment. Read this whole file before touching anything.

**Two repos.** This one holds the image pipeline (`base/`, `microshift/`, `services/`, `k3s/`,
`.github/workflows/`). The flashing-station tooling (`mirror.sh`, `install-offline.sh`, the
station-side flashing docs) lives in `black-cloudlet/jetson-installer-config`: different job,
different machines. This file describes both because they must agree on the L4T line, but only
the image pipeline is editable from here.

## What this project is

Edge AI nodes (image recognition inference) on Jetson AGX Orin. Nodes run fully disconnected
during missions and join the organisation's **air-gapped network** only between missions for
maintenance, upgrades and deployments. Nothing on a device or the flashing station ever
reaches the internet.

- RHEL 9.8 image mode (bootc), aarch64
- **MicroShift 4.20** is the only variant that builds. `k3s/` is still in the tree but nothing
  builds it: `build-k3s.yml` was deleted
- On the cluster: cert-manager, External Secrets, KServe (Standard mode) and a Triton
  `ClusterServingRuntime`, from `services/`. Still to come: PostgreSQL, RabbitMQ, the first
  `InferenceService`
- Every container image physically bound into the OS image (zero network at first boot)

**Model serving is upstream KServe, not Red Hat's**: `microshift-ai-model-serving` is x86_64
only. KServe was removed once before (`bba9d10`, reason unrecorded).

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

1. **Flashing station is RHEL, not Ubuntu.** Ubuntu + SDK Manager was evaluated and dropped.
   NVIDIA validates `flash.sh` only on Ubuntu; QSPI-only flashing works on RHEL and is
   confirmed on our hardware, but it is unsupported — say so in docs.
2. **RHEL 9.8 + JetPack 6.x is the only GA combination.** RHEL 10 is not viable (no NVIDIA
   RHEL 10 L4T repo; a kmod built for 5.14 will not load on 6.12). Do not propose it.
3. **QSPI-only flash, then RHEL bootc on the eMMC.** QSPI carries UEFI and boot firmware only;
   the anaconda ISO installs RHEL to `mmcblk0` (64 GB eMMC). Nothing from the BSP rootfs lands
   on the device. The working command:
   ```
   sudo ./flash.sh p3737-0000-p3701-0000-qspi external
   ```
   Not `jetson-agx-orin-devkit external` — that builds a recovery ramdisk and fails without a
   populated `rootfs/`. `external` is kept because it is what was confirmed; the UEFI boot order
   picks the boot device (ESC at the NVIDIA logo → Boot Maintenance Manager → Boot Options). If
   UEFI will not boot the eMMC, re-flash the QSPI with `internal` first.
   The eMMC is a real constraint: ~58 GiB usable, and poor endurance and latency under etcd's
   fsyncs and write-heavy PVCs. The upgrade path is an M.2 NVMe (`ignoredisk
   --only-use=nvme0n1`, larger root), worth doing before real apps and a model store land.
4. **Base image is Red Hat's JetPack-for-RHEL bootc image**, not `rhel-bootc` + NVIDIA RPMs:
   ```
   quay.io/redhat-user-workloads/jetpack-for-rhel-tenant/rhel-98-bootc:6.2.2_5.14.0-687.42.1_090326003719
   ```
   JetPack 6.2.2, kernel `5.14.0-687.42.1.el9_8`. Inspected 2026-09-03 (arm64 only, bootc
   1.16.4): `/etc/nv_tegra_release` is **R36 REVISION 5.0** (L4T r36.5.0); it carries the
   `nvidia-jetpack-for-rhel-9.8-*` packages, `nvidia-container-toolkit-base` (CDI, no
   `nvidia-container-cli`), `nvgpu.ko`, `nvidia-ctk.service` (writes `/etc/cdi/nvidia.yaml` at
   boot), `nvpmodel`, the console kargs, `podman`, `skopeo` and `subscription-manager`. So our
   layers add **no** NVIDIA packages, CDI unit, kargs or `nvgpu.ko` guard. Pin the full tag,
   never `latest`. Source: `gitlab.com/redhat/rhel/sst/orin-sidecar/rhel-jetpack-for-jetson-bootc`.
5. **The BSP must match the image's L4T line**: flash the QSPI from **R36.5.x** (the staged
   R36.5.2 is fine), never r36.4.x — mismatched firmware and modules hang at boot.
6. **Builds run in GitHub Actions on `ubuntu-24.04-arm`, inside a UBI 9 container.** The
   runner gives native aarch64 (qemu is not viable), the container gives RHEL's
   podman/buildah/skopeo, and `subscription-manager register` gives entitlement. Images go to
   GHCR, then into the air-gapped registry by hand. Pattern from
   `redhat-et/edge-ai-image-pipelines` (Apache-2.0). The host's `/mnt` is mounted as
   `/scratch`, with `/var/lib/containers`, `/var/tmp` and the ISO output bound onto it — for
   space, and because on the container's overlayfs `/` podman loses the native overlay diff
   and every commit walks the rootfs (~20 of 24 build minutes). RHEL's `storage.conf` sets
   `metacopy=on`, which defeats it too, so the step strips it and fails unless `podman info`
   reports `Native Overlay Diff:true`.
7. **Four layers for microshift, one directory per Kubernetes variant.**
   - `base/Containerfile.base` republishes the pinned vendor image under our name.
   - `base/Containerfile.podman` adds the physically-bound-images machinery and `jtop`.
     Published as `jetson-orin-bootc-bound-images` from CI job `bound_images` (an underscore:
     `needs.bound-images` parses as a subtraction and resolves to nothing).
   - `microshift/` adds MicroShift, the device plugin and their images.
   - `services/` holds what runs on the cluster, one numbered kustomize root per component,
     with every image they name embedded.
   Service images sit **above** the variant layer so changing one does not re-run the
   MicroShift install and re-pull its nine images. Each layer is pushed as
   `jetson-orin-bootc-<name>` and the next builds on its **digest**. CI is two reusable
   workflows (`build-image.yml`, `build-iso.yml`) plus `build-microshift.yml`, chaining base →
   bound-images → microshift → services → ISO. The build context is the repo root. Every layer
   registers with subscription-manager, even the one that installs nothing: one code path.
   `k3s/` would reuse both shared layers, but it has no services layer: `services/` embeds into
   podman's containers-storage and writes `/etc/microshift/manifests.d`, and k3s reads neither.
8. **NVIDIA BSP download stays manual** (documented in `README.md`). Scripting it was fragile.

## What is done and working

### Flashing station (`jetson-installer-config`)

- `mirror.sh` — on an **online, registered RHEL host**: a UBI container with the host's
  entitlement bind-mounted read-only runs `dnf reposync --download-metadata --newest-only` for
  BaseOS and AppStream and tars them into `dist/`. Flags: `-r 9|10`, `-A arch`, `-o dist`,
  `-m mirror`, `-c podman|docker`, `-a` all versions, `-z` gzip (off: RPMs are already
  compressed). An `rpm -K --nosignature` pre-check catches RPMs truncated by a full disk.
- `install-offline.sh` — **as root on the station**: extracts to `/srv/repos/{baseos,appstream}`,
  writes `offline.repo` (`file://`, `gpgcheck=1`), disables the subscription-manager plugin,
  installs `dtc cpp binutils usbutils lz4` (`-P` skips). Repos only.
- `README.md` — BSP links, extract, recovery mode, `flash.sh`.

Both are idempotent and have been run end to end: station provisioned, devkit QSPI flashed.

### Image + ISO pipeline

- `base/Containerfile.base` — the pinned vendor image plus `bootc container lint`. Its smoke
  test checks the vendor image: `skopeo`, `podman`, and `lvm2` (root is on an LV and LVMS
  needs `vgs`; nothing here installs it).
- `base/Containerfile.podman` — `FROM` that via `ARG BASE_IMAGE`:
  - `embed_image.sh`, `copy_embedded_images.sh` and `copy-embedded-images.service`, `COPY`d
    from `base/physically-bound-images/`.
  - `jetson-stats` (`jtop`, pinned `JTOP_VER`) via `pip3 install --prefix=/usr` (`/usr/local`
    is machine state on bootc). `python3-pip` comes from RHEL repos, so this layer needs
    entitlement. Whether `jtop` reaches the driver as installed is unverified.
  - `flightctl-agent` from `rhacm-${ACM_VER}-for-rhel-9-$(uname -m)-rpms`
    (`ACM_VER=2.15`, match the hub), no weak deps (keeps greenboot out). Drop-ins key both
    the agent and `bootc-fetch-apply-updates.service` on `/etc/flightctl/config.yaml`: agent
    idle and bootc upgrading before enrollment, the reverse after. Unverified until dispatched.
  Its smoke test fails if this layer has an image cache: anything here is paid by every variant.
- `base/physically-bound-images/` — adapted from `redhat-et/edge-ai-image-pipelines`. Cache is
  `/usr/lib/containers-image-cache` with `mapping.txt` (reference → sha), copied into
  containers-storage once per boot by `copy-embedded-images.service` (a oneshot `Requires=`d by
  microshift.service, not an `ExecStartPre=`, so it runs once per boot). No
  `network-online.target`: the copy is local, and waiting for a carrier would stall every boot.
  - `embed_image.sh` splits `repo:tag@sha256:…` references, which skopeo rejects, and skips a
    reference already cached. Nothing dedupes across layers: re-embedding an image one layer
    down ships it twice.
  - Copies use `--multi-arch=system`: only aarch64 is stored. A reference pinned to a
    manifest-list digest still resolves, because containers-storage looks up by name first.
  - Hardlinking duplicate blobs was tried and removed: `/usr` is ostree, already
    content-addressed on the node.
  - `copy_embedded_images.sh` removes images a previous OS version put in containers-storage
    and this one no longer names, tracked in `/var/lib/physically-bound-images/applied.txt`.
    Otherwise the first thing to prune would be kubelet's image GC at 85% disk, deleting
    exactly the images there is no registry to re-pull. Prune runs before copy; an image still
    held by a container stays on the list for next boot; failures are logged, never fatal.
  - **Pinned in CRI-O** (`microshift/crio.conf.d/20-pinned-images.conf`): kubelet's image GC
    and disk-pressure reclaim skip embedded images (an unused Triton would otherwise be gone
    until the next boot); the prune still removes them, since podman ignores CRI-O pins.
    Registry prefixes; `services/` appends `docker.io/*` and `oci.external-secrets.io/*` with
    `sed`. **One list**: a second drop-in replaces it. **Never pin a pulled image**: nothing
    would delete it. So no `registries.conf` mirror for a pinned registry, and air-gapped app
    layers embed from `<registry>/embedded/*`, pull from `<registry>/apps/*`. Both smoke tests
    check every `mapping.txt` reference against `crio config`. GC thresholds are untouched.
- `microshift/Containerfile` — MicroShift 4.20 from `rhocp-4.20-for-rhel-9-aarch64-rpms` +
  `fast-datapath-for-rhel-9-aarch64-rpms` (`firewalld jq microshift microshift-release-info
  openshift-clients`; `oc` is in `openshift-clients`), firewall rules (trusted: `10.42.0.0/16`,
  `10.43.0.0/16`, `169.254.169.1`; public: 22, 443, 6443), `microshift-make-rshared.service`,
  the node IP on `lo` (below), every MicroShift image embedded with a `microshift.service.d`
  drop-in ordering the copy first, and the NVIDIA device plugin:
  - `nvidia-ctk runtime configure --runtime=crio --set-as-default` →
    `/etc/crio/crio.conf.d/99-nvidia.toml`.
  - `microshift/manifests/`: kustomization, a ConfigMap with **GPU time slicing** (4 replicas
    of `nvidia.com/gpu`), and a patch mounting it via `CONFIG_FILE`; only
    `nvidia-device-plugin.yml` is curl'd. One iGPU means one GPU pod without slicing. No memory
    isolation between replicas, so the count is a claim about the SOM's RAM; 1 disables it.
    `renameByDefault` stays off, so the resource is plain `nvidia.com/gpu`.
  - A second patch sets the container's `seLinuxOptions.type: spc_t`. As `container_t`,
    SELinux denies the connect to `kubelet.sock` and the plugin loops on `Could not register
    device plugin: context deadline exceeded` (seen on hardware). Capabilities stay dropped.
    No SCC: OpenShift's apiserver skips SCC admission in `kube-system` (run-level 0 by name),
    which is also why upstream's hostPath is admitted. Moving the plugin out needs one.
  - The smoke test checks how the render is **wired** (one container, `CONFIG_FILE` into a
    mounted ConfigMap with a replica count, `/var/lib/kubelet/device-plugins` mounted), never
    upstream field names: those change between tags and broke an earlier version of the check.
  - No `microshift-gitops` (removed). Images go into the main store, not an additional store,
    which an upgrade overwrites (RHEL-75827). **No `dnf upgrade`**: it could pull a kernel the
    Tegra kmod was not built for. `--enablerepo`, not `dnf config-manager`. Units are
    `COPY <<'EOF'` heredocs; RHEL 9's podman parses them.
- `microshift/manifest-images.sh` — prints every image the given manifest roots name, rendered
  with `oc kustomize` (release-info lists only the control plane, and `images:` transformers
  defeat a grep). The build embeds what it prints; `services/` uses it too.
- `services/Containerfile` — four numbered roots under `/etc/microshift/manifests.d/`, plus
  every image they name. MicroShift **sorts** the roots and applies each with the equivalent of
  `kubectl apply -k`, retrying a failing one **every 10 s for 10 minutes**
  (`pkg/kustomize/kustomize.go`) — that is the ordering and what covers a CRD not yet served.
  - `010-cert-manager/` — upstream static manifest (`CERT_MANAGER_VER`, v1.21.2), patched for
    resources only. KServe's webhook certificate comes from it.
  - `020-external-secrets/` — upstream manifest (`EXTERNAL_SECRETS_VER`, v0.19.2):
    - Each Deployment's patch deletes the `runAsUser: 1000` upstream pins (restricted-v2 assigns
      a UID from the namespace range and refuses a pinned one) and adds resources.
      `runAsNonRoot: true` stays.
    - Moved from `default` to namespace `external-secrets` via `namespace.yaml` and a
      `namespace:` line. The transformer misses three namespaces inside container args
      (`--service-namespace`, `--secret-namespace`, `--dns-name=…<ns>.svc`), so those are JSON
      patches, each guarded by a `test` op. Getting one wrong leaves the webhook without a
      valid certificate, and no ExternalSecret can be created.
    - The strategic-merge patches still say `namespace: default`: patches run before the
      namespace transformer.
    - No `SecretStore` yet, so what it reads from is unsettled.
  - `030-kserve/` — upstream `kserve.yaml` (`KSERVE_VER`, v0.20.0; v0.21.0 had no release
    assets and adds a DaemonSet with no nodeSelector). `kserve-cluster-resources.yaml` is not
    fetched: fourteen runtimes' images would be embedded. Only `kserve-controller-manager`
    runs; its manager is patched to `imagePullPolicy: IfNotPresent` (upstream says `Always`,
    which was ErrImagePull on hardware with the image embedded). Deleted, which also keeps their images out: `llmisvc-controller-manager` (LLM
    serving, pins `runAsUser: 1000`), both local-model-cache workloads (off; the agent mounts a
    hostPath), and the `ClusterStorageContainer` (only downloading URIs use it). Their CRDs and
    webhooks stay; each matches only its own kinds.
    `inferenceservice-config.yaml` rewrites three JSON keys whole: `deploy` → `Standard`,
    `ingress` → `disableIngressCreation: true`, and `storageInitializer` → qualified image,
    1:1 / 1:4, **no `uidModelcar`** (KServe sets it as `runAsUser` on the modelcar sidecar and
    `kserve-container`, and restricted-v2 refuses 1010; unset, the pod gets one UID, which the
    sidecar's `/proc/<pid>/root` needs). A modelcar image needs `sh`, `ln`, `sleep` and a
    non-empty `/models`. `namespace.yaml` keeps upstream's `control-plane` label, which the pod
    mutator skips, so no InferenceService may live in `kserve`. No Pod Security labels: one was
    tried and removed, since it only differs from restricted-v2 once a wider SCC is granted.
  - `040-triton-runtime/` — `triton-igpu`: `-py3-igpu` image (`25.02`, **unverified against
    JetPack 6.2.2**), one `nvidia.com/gpu`, no `runAsUser`, restricted security context
    spelled out, 8Gi 1:1, CPU 1 → 4, TensorRT and ONNX. Pod-wide settings such as
    `supplementalGroups` go on the InferenceService. Plans load only in this image's TensorRT:
    build them with its `trtexec` on an Orin, and rebuild when the tag moves.
  **Resources rule**, every root: memory request = limit (OOM-killed at its own ceiling, never
  evicted for outgrowing a request), CPU limit = 4 × request (burst room at start-up). Pods
  stay Burstable. Upstream sets almost none of this.
  **Images are derived from the render**: the version ARGs are the only pin. Seven today:
  cert-manager ×3, External Secrets, `kserve-controller`, `kube-rbac-proxy`, and
  `tritonserver:25.02-py3-igpu` (the largest). The scan reads only `image:` fields, so a
  model's `oci://` image, and images named inside `inferenceservice-config`, go in
  `SERVICE_IMAGES` when used.
  **Smoke test**: renders every root with `oc kustomize` and checks the workload set per root;
  External Secrets without `runAsUser`, with `runAsNonRoot`, in its own namespace and naming
  `default` nowhere outside its CRDs; `inferenceservice-config` values; every pod template and
  serving-runtime container admissible under restricted-v2; requests, limits and ratios; no
  container whose pull policy is, or defaults to, `Always`; every image qualified and embedded;
  every `mapping.txt` reference pinned by `crio config`; no `ClusterStorageContainer`; one KServe tag. It prints
  `du -sh` of the cache, which the eMMC pays for twice (`/usr` and containers-storage). Pods
  KServe builds at run time are in no render: their admission and GPU access are hardware
  questions.
- `k3s/` — `Containerfile`, `config.toml`, `stage-assets.sh`, `smoke-test.sh`, **built by
  nothing**. k3s (`K3S_VERSION`) as the static binary in `/usr/bin` with argv[0] symlinks
  (`/usr/local` is machine state, so the install script is unusable); `k3s-selinux` from
  Rancher's repo, whose repo file is removed in the same layer; matching firewall rules;
  `default-runtime: nvidia` in `/etc/rancher/k3s/config.yaml` (a non-default runtime needs a
  RuntimeClass); the airgap image tarball plus the device plugin as a `docker-archive`,
  staged by `k3s-stage-assets.service`. Its kickstart grows root over the whole VG
  (local-path lives on root) and uses label `JETSON_ORIN_K3S` (anaconda finds stage2 by label).
  `embed_image.sh`'s cache is useless here: containerd does not read containers-storage.
- `microshift/config.toml` — bib config with a **custom kickstart** (bib then adds only
  `ostreecontainer`; `[customizations.user]`/`filesystem` cannot be combined with it):
  `text --non-interactive`, `timezone Asia/Jerusalem --utc`, static `192.168.1.10/24` gw
  `192.168.1.254` on `eth0`, `--nameserver=192.168.1.1` (must answer, or every lookup waits out
  the glibc timeout), `--no-activate` (anaconda otherwise brings up the first `network` device
  and waits for it; the install reads only the ISO, so no cable is needed),
  `--ipv4-dns-search=cloudlet.local` (there is no `--domain`; an unknown option fails the parse
  and stops the installer before its UI), `--hostname=jetson-1`,
  `ignoredisk --only-use=mmcblk0`, `clearpart --all`, `reqpart --add-boot`, VG `rhel` with a
  40 GiB xfs root, **no swap**, and **~16.5 GiB left free for LVMS** (fill the VG and the
  cluster has no dynamic PVs). Root locked; user `cloudlet` in `wheel` from
  `@JETSON_SSH_PUBKEY@`/`@JETSON_PASSWORD_HASH@`; `reboot --eject`. ISO label
  `JETSON_ORIN_BOOTC`. Address and hostname are baked in, so two devices from
  one ISO collide. A `%post` writes `10.44.0.1 jetson-1.cloudlet.local jetson-1` into
  `/etc/hosts` and `/etc/microshift/config.d/20-subject-alt-names.yaml` with
  `jetson-1.cloudlet.local` as the only extra SAN. The laptop reaches 6443 by name (needs an A
  record on 192.168.1.1) with
  `/var/lib/microshift/resources/kubeadmin/jetson-1.cloudlet.local/kubeconfig`. bib appends our
  kickstart verbatim, so a trailing `%post … %end` works.
- **Node IP on `lo`** (`microshift/stable-microshift.nmconnection`,
  `microshift/config.d/10-node-ip.yaml`) — Red Hat's fully-disconnected procedure. Without
  `nodeIP`, MicroShift uses the default-route address and `sysconfwatch` restarts it whenever
  that changes, which pulling the cable does. The keyfile puts `10.44.0.1/32` on `lo` with a
  placeholder nameserver `10.44.1.1` at `dns-priority=200`; it was generated once with
  `nmcli --offline` (fixed UUID) and is `COPY`d `0600` (NM ignores readable keyfiles).
  `ignore-carrier` was rejected: it keeps MicroShift tied to `eth0`. A node initialised on
  `192.168.1.10` needs `microshift-cleanup-data --ovn` or a re-image. A clock step over 10 s
  (first chrony sync) can still cost one restart.
- `.github/workflows/build-image.yml` — **reusable**: register, bind storage for native
  overlay, write the pull secret, build, run the smoke test inside the result, push
  `ghcr.io/<owner>/jetson-orin-bootc-<name>`, output the digest-pinned ref, and report the
  layer size as a `::notice`. Tags: `<YYYYMMDD-sha8>`, `latest`, and `extra-tags` (`stable`
  on all four layers; `4.20` on the two with MicroShift, passed from the same lines as
  `USHIFT_VER` so the tag cannot lie). Tags are validated before the build.
  **What a node follows is not settled.** bib installs the services layer pinned by digest
  from GHCR, so `bootc upgrade` has nothing to re-resolve and could not reach it anyway.
  `ostreecontainer` has no `--target-imgref`. Pointing the origin at the air-gapped `stable`
  needs a one-time `bootc switch` or a retag before bib; the node also needs
  `/etc/ostree/auth.json`. Until then a node cannot upgrade. Check
  `bootc-fetch-apply-updates.timer`: it fails every day the registry is unreachable.
- `.github/workflows/build-iso.yml` — **reusable**: register, substitute the `@JETSON_*@`
  placeholders in bash with secrets in `env:` (a `&`, quote or newline would break `sed`),
  reject an empty or non-crypt password hash, validate the rendered kickstart with RHEL's
  `ksvalidator -v RHEL9` (bib does not, and a parse failure only shows on hardware), run
  `registry.redhat.io/rhel9/bootc-image-builder --type anaconda-iso`, then rewrite the ISO's
  GRUB menu timeout from 60 s to 5 s with `xorriso`/`mtools`: in `/EFI/BOOT/grub.cfg` and in
  the copy inside `images/efiboot.img`, which is the one UEFI GRUB reads
  (`-boot_image any replay` keeps the El Torito entry and volume ID). The rewrite drops the
  implanted md5, so "Test this media" cannot verify the stick; unused, not restored. Upload
  the `*.iso` alone (no checksum file) at zip `compression-level: 9`, the maintainer's call; it is
  mostly gzip'd layers and squashfs, so the saving is small and the upload slower.
- `.github/workflows/build-microshift.yml` — the only caller, on push to `main` under
  `base/**`, `microshift/**`, `services/**` or the workflows, and on `workflow_dispatch`.
  **Nothing runs on a pull request.**

**Secrets**: `RH_REGISTRY_USER`/`RH_REGISTRY_PASSWORD` (bib pull), `RHSM_USERNAME`/`RHSM_PASSWORD`
(every job registers, and unregisters in `if: always()`), `OPENSHIFT_PULL_SECRET` (build-time
image pulls, never in the image), `JETSON_SSH_PUBKEY`, `JETSON_PASSWORD_HASH`
(`openssl passwd -6`). Registration replaced an entitlement-cert tarball. Username/password is
maintainer preference; an org ID + activation key is narrower and needed for SSO/2FA accounts.
Credentials go through `env:`. With Simple Content Access off, register needs `--auto-attach`.
The subscription needs OpenShift and ACM entitlements, or `rhocp` and `rhacm` never appear. A self-hosted registered RHEL 9 aarch64 runner would remove registration entirely.

**bib**: `registry.redhat.io/rhel9/bootc-image-builder` is the supported path for RHEL
content; output is `output/bootiso/install.iso`. The installer boots the stock RHEL kernel, and
the eMMC appears only if it has `sdhci-tegra`. If the installer shows no `mmcblk0`, check that
first (`lsblk`, `modprobe sdhci-tegra` on Ctrl-Alt-F2), not the kickstart. Unverified on
hardware.

## Next step: validate on hardware, then the app services

1. Dispatch `build-microshift.yml`, `dd` the ISO, boot the devkit (QSPI from R36.5.x). Check
   `bootc status` (expect a digest-pinned GHCR origin, which cannot upgrade), `lsmod | grep
   nvgpu`, `nvidia-ctk cdi list` → `nvidia.com/gpu=all`, a GPU container, `systemctl
   is-enabled bootc-fetch-apply-updates.timer`, whether `jtop` works, and that
   `flightctl-agent` is skipped on its condition, not restarting.
2. MicroShift: `systemctl status microshift`, `oc get pods -A` all running with no registry,
   `vgs` shows free extents, a PVC binds on topolvm. `ip addr show lo` has `10.44.0.1/32` and
   `oc get node -o wide` shows it; pull the cable for a minute and `NRestarts` must not move.
   Then `oc` from the laptop. Pins: `crictl images -o json | jq '.images[] | {repoTags,
   repoDigests, pinned}'` shows `pinned: true` for every embedded image (digest-only names
   included), `crio config | grep -A12 pinned_images` shows our list and nothing from the
   MicroShift RPM was replaced, and an image a new OS drops is still removed by the prune.
3. Device plugin: the DaemonSet runs and allocatable `nvidia.com/gpu` equals the replica
   count. Run that many GPU pods at once and watch for OOM.
4. Services: pods Running in `cert-manager` (3), `external-secrets` (3) and `kserve` (1), with
   no registry. A failing `runAsUser` patch shows in `oc describe rs`. Check resources survived
   (`oc get deploy -A -o jsonpath`). `journalctl -u microshift | grep -i kustomization` shows a
   root still retrying — watch `040`. Every services pod's `openshift.io/scc` annotation should
   be `restricted-v2`.
5. Serve a model: first `pvc://` (model repository `oc cp`'d into a topolvm PVC), proving the
   Triton tag runs on r36.5 and an SCC-assigned UID can open the GPU (`id`, `ls -ln
   /dev/nvhost-ctrl-gpu /dev/nvmap`; if `root:video 0660`, add `supplementalGroups` on the
   InferenceService or CRI-O's `device_ownership_from_security_context`). Then `oci://` with an
   embedded modelcar image, proving the `uidModelcar` change.
6. k3s: revive only by writing `build-k3s.yml`, then check it runs enforcing, images staged
   first, the airgap set present with no registry, and a GPU pod on the default runtime.
7. Later layers `FROM` the k8s image: a `bootc switch` unit for the air-gapped registry,
   greenboot health checks, a signature policy in `/etc/containers/policy.json`.

**Open decisions** (confirm with the maintainer first): the Triton `-igpu` tag for JetPack
6.2.2 and the 8Gi slice size; where InferenceServices live, and whether models get their own
layer above `services/`; what External Secrets reads from; NVMe before real apps land;
registration vs. a self-hosted runner; per-device address and hostname before a second node;
opening the k3s kubeconfig to `cloudlet`; how `/etc/flightctl/config.yaml` reaches a node, and
greenboot; whether k3s comes back, and how service images would reach containerd without
doubling `/usr`; `bootc switch` vs. retag for the node's origin, and
whether `stable` moves on every green build or only after a hardware boot; lowering kubelet's
image GC thresholds below the eviction line (only matters once images are pulled); whether the
`services/` resource sizes survive hardware (the ratios are enforced, the sizes are guesses).

## How to work in this repo

**Style — this matters as much as correctness.**

- Lean and minimal. No features nobody asked for: no EPEL, no extra entitlement plumbing, no
  SHA256 verification (tried, removed), no rootfs download. Mention omissions in the reply.
- One script, one job. Flashing, mirroring, offline install and image building stay separate.
- No stray side effects: no empty directories, nothing installed on the build host, nothing
  outside the declared output dir.
- Validate inputs before expensive work. `set -euo pipefail` everywhere.
- Keep `gpgcheck=1` offline. Use `reposync --download-metadata`, not `createrepo_c`, so signed
  modular metadata survives.
- Bash: `getopts` with short flags and a `usage()` showing defaults. `bash -n` + a real run over
  test frameworks.
- Explanations in replies should be deep and line-by-line, not headline summaries.

**Things that bit us — do not repeat.**

- bib's `[customizations.installer.bootloader.grub2] menu-timeout` parses but does nothing for
  `anaconda-iso`: osbuild/images honours it for bootc ISOs only from v80, and bib vendors
  v0.251. The GRUB menu sat at 60 s on hardware. A bib key is proven only by the built ISO.
- RHEL ships the C preprocessor as `cpp`; `flash.sh` dies with `FileNotFoundError: cpp`
  without it.
- `apt-get --download-only install` skips installed packages; a Debian bundle needs a clean
  container with separate download and index stages (legacy, from the Ubuntu evaluation).
- `rockylinux:9`, not UBI, for any RPM-bundling builder; UBI lacks packages.
- Every base-image bump can break the GPU (the kmod is tied to one kernel). A container smoke
  test proves nothing about the GPU; boot hardware before promoting a tag.
- `nvidia-ctk runtime configure --config=…/99-nvidia.conf` writes `99-nvidia.toml` and exits 0.
  CRI-O reads either; only a check spelling the name notices. Ask for `.toml`.
- A kickstart option anaconda does not know (`--domain` was one) stops the installer at the
  systemd log with no visible error, and bib builds the ISO anyway. `build-iso.yml` runs
  `ksvalidator -v RHEL9` on the rendered `contents`; locally, pip `pykickstart` does the same.
- A bare `test` exits 1 silently. Every check names what it looked for and lists the directory.
- podman in a `container:` job silently loses the native overlay diff (overlayfs storage, or
  `metacopy=on`). Keep the `/scratch` bind, the `metacopy` strip and the check.
- A Deployment patch matching nothing fails kustomize — the safety net under `services/`. An
  `images:` entry matching nothing does not, nor does a field a patch no longer needs to
  delete; those need a check on the render.
- An apostrophe inside an `awk` program ends the shell quoting and surfaces as a syntax error
  at `$0`. No contractions in awk comments.
- Smoke tests parse renders with `oc patch --local -f - --type=merge -p '{}' -o json` and query
  them with `jq`, not awk over YAML (which broke on list shapes). They do not re-check what
  already fails the build or a lower layer's test — except `systemctl enable`, which only warns
  on a bad `[Install]`, and agreement between separately copied files (keyfile address vs.
  `nodeIP`).
- `imagePullPolicy: Always` pulls even with the image in containers-storage, so on a node with
  no registry an embedded image still ends in ImagePullBackOff. Unset, it defaults to `Always`
  for `:latest` or no tag. Upstream KServe's manager ships with it; check each new upstream.
- jq's `a // b` treats `false` as missing. Where an explicit `false` must win over a fallback,
  test for `null`.
- A render-time check cannot see what a webhook injects. For KServe's `uidModelcar` the only
  handle is the ConfigMap key.

**Git / delivery.** Develop on the session's branch, commit with a message that says *why*,
push, and open a PR only when asked. Always state which files changed. Nothing runs CI on a PR,
so a branch is validated by dispatching `build-microshift.yml` against it; a claim that
something is tested should say whether that means locally or dispatched.

## Quick reference

```bash
# Online RHEL host — build the repo bundle (incremental)
./mirror.sh -o /run/media/$USER/USBKEY/dist

# Air-gapped station — provision (as root, from the bundle dir)
sudo ./install-offline.sh

# Air-gapped station — flash QSPI (devkit in recovery: hold Force Recovery, tap Reset, release)
lsusb | grep 0955
cd /opt/nvidia/Linux_for_Tegra && sudo ./flash.sh p3737-0000-p3701-0000-qspi external

# Local image build on a subscribed RHEL 9 aarch64 box, from the repo root. Each layer FROM the
# one before it; the workflow passes BASE_IMAGE as a digest.
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
