#!/bin/bash
# Checks run inside the republished vendor image. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < base/smoke-test.base.sh
#
# The layer adds nothing, so this is really about the vendor image: a base bump
# that breaks one of these breaks the GPU on every variant.
set -euo pipefail

bootc --version
cat /etc/nv_tegra_release
rpm -q nvidia-jetpack-for-rhel-9.8-kmod nvidia-container-toolkit-base
ls /usr/lib/modules/*/extra/drivers/gpu/nvgpu/nvgpu.ko

# skopeo is used by embed_image.sh at build time and by copy_embedded_images.sh
# at boot; it comes from the vendor image rather than being installed.
command -v skopeo

echo "all checks passed"
