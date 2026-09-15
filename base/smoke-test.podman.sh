#!/bin/bash
# Checks run inside the podman/bound-images layer before it is pushed. Fed on
# stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < base/smoke-test.podman.sh
#
# Only what this layer adds; base/smoke-test.base.sh covered the vendor image.
set -euo pipefail

# A bare `test` under `set -e` exits 1 with no output, which says nothing about
# which check failed. Name the path, and list where it should have been.
have() {
	flag=$1 path=$2
	shift 2
	test "$flag" "$path" && return 0
	echo "missing: $path"
	for dir in "$@"; do
		echo "-- $dir"
		ls -la "$dir" 2>&1 | sed 's/^/   /'
	done
	exit 1
}

echo "== physically bound images =="
have -x /opt/physically-bound-images/embed_image.sh /opt/physically-bound-images
have -x /opt/physically-bound-images/copy_embedded_images.sh \
	/opt/physically-bound-images
have -L /etc/systemd/system/multi-user.target.wants/copy-embedded-images.service \
	/etc/systemd/system/multi-user.target.wants /usr/lib/systemd/system

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
getent group jtop

echo "all checks passed"
