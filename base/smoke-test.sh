#!/bin/bash
# Checks run inside the republished vendor image. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < base/smoke-test.sh
#
# The layer adds nothing, so this is really about the vendor image: a base bump
# that breaks one of these breaks the GPU on every variant.
set -euo pipefail

bootc --version
cat /etc/nv_tegra_release
rpm -q nvidia-jetpack-for-rhel-9.8-kmod nvidia-container-toolkit-base
ls /usr/lib/modules/*/extra/drivers/gpu/nvgpu/nvgpu.ko

# skopeo is used by embed_image.sh at build time and by copy_embedded_images.sh
# at boot; podman by the latter, to drop a superseded image set. Both come from
# the vendor image rather than being installed.
command -v skopeo
command -v podman

# Both kickstarts put the root filesystem on a logical volume, so an image
# without lvm2 does not boot at all — and MicroShift's LVMS finds its volume
# group by running vgs, then only logs a warning and skips the CSI driver when
# the binary is missing, so the failure would otherwise arrive as a node with no
# storage class and nothing saying why. Nothing here installs it: the microshift
# RPM does not even require it, so it is the vendor image's to provide.
rpm -q lvm2
for cmd in lvm vgs; do
	command -v "$cmd" || { echo "missing: $cmd, from lvm2"; exit 1; }
done

echo "all checks passed"
