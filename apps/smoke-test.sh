#!/bin/bash
# Checks run inside the apps image before it is pushed. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < apps/smoke-test.sh
#
# Only what this layer adds. The vendor image underneath was checked by
# base/smoke-test.sh, and this layer builds on that base by digest.
set -euo pipefail

test -x /opt/physically-bound-images/embed_image.sh
test -x /opt/physically-bound-images/copy_embedded_images.sh
test -L /etc/systemd/system/multi-user.target.wants/copy-embedded-images.service

# APP_IMAGES is empty today, so a mapping file may legitimately not exist. If it
# does, every entry must actually have been fetched.
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
