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

# Take only the node's architecture: it is aarch64 and so is the builder
# (build-image.yml requires a native runner), so every other platform in a
# manifest list is dead weight. A tag-referenced image is where that bites —
# the device plugin today, application images later, a docker.io manifest list
# carrying six platforms.
#
# Except when the reference is a digest, which names one exact manifest: if that
# manifest is a list, picking an architecture out of it would store the image
# under a digest that is not its own, and the manifest asking for it by digest
# would not find what it asked for. Those stay --multi-arch=all, which costs
# nothing for MicroShift's release images — release-aarch64.json and
# release-x86_64.json pin different digests, so those are single manifests
# already — and keeps a list-pinned image from a rendered manifest intact.
multi_arch=system
if [[ $dst == *@sha256:* ]]; then
	multi_arch=all
fi

mkdir -p "$CACHE_DIR"
skopeo copy --multi-arch="$multi_arch" --preserve-digests "${additional_copy_args[@]}" \
	"docker://$src" "dir:$CACHE_DIR/$fsha"
echo "$dst,$fsha" >> "$CACHE_DIR/mapping.txt"
