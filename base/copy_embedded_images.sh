#!/bin/bash
# Replay the baked-in image cache into containers-storage, and remove what an
# earlier version of this OS image left there. Runs once per boot from
# copy-embedded-images.service, before MicroShift starts.
#
# Adapted from redhat-et/edge-ai-image-pipelines (Apache-2.0),
# tegra/physically-bound-images/copy_embedded_images.sh.
set -euxo pipefail

CACHE_DIR=/usr/lib/containers-image-cache
MAPPING="$CACHE_DIR/mapping.txt"

# containers-storage is machine state and the cache is not, so the only record
# of what a previous boot put there is one this script keeps itself.
APPLIED=/var/lib/physically-bound-images/applied.txt

mkdir -p "${APPLIED%/*}"
keep="$APPLIED.new"
if [[ -s $MAPPING ]]; then
	cp "$MAPPING" "$keep"
else
	# An image built with nothing embedded is not an error; there may still be
	# a previous version's images to clear out.
	echo "no embedded images at $MAPPING, nothing to copy"
	: > "$keep"
fi

# Images left over from an image set we have since replaced are reclaimed by
# nothing: the first thing that would is kubelet's image GC at 85% of the root
# filesystem, and what it deletes is exactly these — on a node with no registry
# to pull them back from. Only references this script recorded are touched.
#
# Before the copy, not after: freeing the superseded set first is the point, and
# the source is local disk, so a copy cannot fail for want of an upstream. An
# image CRI-O still holds through a container from the previous boot cannot be
# removed yet, so that entry stays on the list and the next boot tries again
# rather than losing track of it.
if [[ -f $APPLIED ]]; then
	while IFS=, read -r image sha; do
		if grep -qxF "$image,$sha" "$keep"; then
			continue
		fi
		if podman rmi --ignore "$image"; then
			continue
		fi
		echo "leaving $image in containers-storage: could not remove it"
		echo "$image,$sha" >> "$keep"
	done < "$APPLIED"
fi

if [[ -s $MAPPING ]]; then
	while IFS="," read -r image sha; do
		skopeo copy --preserve-digests "dir:$CACHE_DIR/$sha" "containers-storage:$image"
	done < "$MAPPING"
fi

mv "$keep" "$APPLIED"
