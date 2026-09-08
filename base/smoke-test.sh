#!/bin/bash
# Checks run inside the base image before it is pushed. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < base/smoke-test.sh
set -euo pipefail

echo "== base image =="
bootc --version
cat /etc/nv_tegra_release
rpm -q nvidia-jetpack-for-rhel-9.8-kmod nvidia-container-toolkit-base
ls /usr/lib/modules/*/extra/drivers/gpu/nvgpu/nvgpu.ko

echo "== physically bound images machinery =="
test -x /opt/physically-bound-images/embed_image.sh
test -x /opt/physically-bound-images/copy_embedded_images.sh
test -L /etc/systemd/system/multi-user.target.wants/copy-embedded-images.service

# APP_IMAGES is empty today, so a mapping file may legitimately not exist. If it
# does, every entry must have been fetched.
mapping=/usr/lib/containers-image-cache/mapping.txt
if [[ -s $mapping ]]; then
	echo "embedded: $(wc -l < "$mapping") application images"
	while IFS=, read -r img sha; do
		test -f "/usr/lib/containers-image-cache/${sha}/manifest.json" \
			|| { echo "missing embedded image: ${img}"; exit 1; }
	done < "$mapping"
else
	echo "no application images embedded"
fi

echo "all checks passed"
