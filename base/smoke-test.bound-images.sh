#!/bin/bash
# Checks run inside the bound-images layer before it is pushed. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < base/smoke-test.bound-images.sh
#
# Only what this layer adds; base/smoke-test.sh covered the vendor image.
set -euo pipefail

test -x /opt/physically-bound-images/embed_image.sh
test -x /opt/physically-bound-images/copy_embedded_images.sh
test -L /etc/systemd/system/multi-user.target.wants/copy-embedded-images.service

# The machinery only — a cache here is an image every variant would pay for.
if [[ -e /usr/lib/containers-image-cache ]]; then
	echo "unexpected image cache in the bound-images layer:"
	ls -la /usr/lib/containers-image-cache | sed 's/^/   /'
	exit 1
fi

echo "all checks passed"
