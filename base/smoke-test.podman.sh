#!/bin/bash
# Checks run inside the podman/bound-images layer before it is pushed. Fed on
# stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < base/smoke-test.podman.sh
#
# Only what the build cannot fail on by itself: the COPYs and `systemctl enable`
# in the Containerfile already fail the build if their file is missing.
set -euo pipefail

echo "== physically bound images =="
# The machinery only — a cache here is an image every variant would pay for.
if [[ -e /usr/lib/containers-image-cache ]]; then
	echo "unexpected image cache in the bound-images layer:"
	ls -la /usr/lib/containers-image-cache | sed 's/^/   /'
	exit 1
fi

echo "== jetson-stats =="
# pip installs into /usr here rather than /usr/local, which is machine state on
# bootc and would not survive into the deployed image.
command -v jtop

echo "all checks passed"
