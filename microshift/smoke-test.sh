#!/bin/bash
# Checks that run inside the built image, before it is pushed. Fed to the
# container on stdin by the build workflow:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < microshift/smoke-test.sh
#
# This proves the image was assembled correctly. It proves nothing about the
# GPU or the cluster — only a boot on real hardware does that.
set -euo pipefail

echo "== base image =="
bootc --version
cat /etc/nv_tegra_release
rpm -q nvidia-jetpack-for-rhel-9.8-kmod nvidia-container-toolkit-base
ls /usr/lib/modules/*/extra/drivers/gpu/nvgpu/nvgpu.ko

echo "== microshift =="
rpm -q microshift microshift-release-info
for unit in microshift microshift-make-rshared copy-embedded-images; do
	test -L "/etc/systemd/system/multi-user.target.wants/${unit}.service" \
		|| { echo "not enabled: ${unit}.service"; exit 1; }
done
test -f /usr/lib/systemd/system/microshift.service.d/microshift-copy-images.conf

echo "== nvidia device plugin =="
test -f /etc/crio/crio.conf.d/99-nvidia.conf
test -s /etc/microshift/manifests/nvidia-device-plugin.yml
test -s /etc/microshift/manifests/kustomization.yaml

echo "== embedded images =="
mapping=/usr/lib/containers-image-cache/mapping.txt
test -s "$mapping"
echo "embedded: $(wc -l < "$mapping") images"
while IFS=, read -r img sha; do
	test -f "/usr/lib/containers-image-cache/${sha}/manifest.json" \
		|| { echo "missing embedded image: ${img}"; exit 1; }
done < "$mapping"

# The device plugin pod cannot start on a disconnected node unless its own
# image was embedded alongside MicroShift's.
grep -q 'k8s-device-plugin' "$mapping" \
	|| { echo "device plugin image was not embedded"; exit 1; }

echo "all checks passed"
