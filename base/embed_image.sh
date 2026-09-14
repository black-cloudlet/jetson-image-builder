#!/bin/bash
# Copy one container image into the image cache baked into the OS image.
#
# Adapted from redhat-et/edge-ai-image-pipelines (Apache-2.0),
# tegra/physically-bound-images/embed_image.sh.
#
# Images land in /usr/lib/containers-image-cache/<sha of reference> and
# mapping.txt records reference -> sha. copy_embedded_images.sh replays that
# into containers-storage at boot. A separate cache directory is used rather
# than /usr/lib/containers/storage because an image upgrade overwrites an
# additional container store (RHEL-75827).
set -euxo pipefail

CACHE_DIR=/usr/lib/containers-image-cache

image=$1
additional_copy_args=("${@:2}")

fsha="$(echo "$image" | sha256sum | awk '{ print $1 }')"

src=$image
dst=$image

# skopeo rejects references of the form $REPO:$TAG@sha256:$SHA, so split them:
# pull by digest, record under the tagged name the manifests will ask for.
# Two images differing only by digest under one tag would collide here; nothing
# in MicroShift's release list does that today.
if [[ $image =~ .*:.*@sha256:.* ]]; then
	repo="${image%%:*}"
	spec="${image#*:}"
	tag="${spec%%@*}"
	sha="${spec#*@}"

	src=$repo@$sha
	dst=$repo:$tag
fi

# Only the node's architecture; builder and node are both aarch64. A reference
# pinned to a manifest-list digest still resolves: containers-storage looks an
# image up by its explicit name before it looks by digest.
mkdir -p "$CACHE_DIR"
skopeo copy --multi-arch=system --preserve-digests "${additional_copy_args[@]}" \
	"docker://$src" "dir:$CACHE_DIR/$fsha"
echo "$dst,$fsha" >> "$CACHE_DIR/mapping.txt"
