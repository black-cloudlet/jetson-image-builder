#!/bin/bash
# Replay the baked-in image cache into containers-storage. Runs once per boot
# from copy-embedded-images.service, before MicroShift starts.
#
# Adapted from redhat-et/edge-ai-image-pipelines (Apache-2.0),
# tegra/physically-bound-images/copy_embedded_images.sh.
set -euxo pipefail

CACHE_DIR=/usr/lib/containers-image-cache
MAPPING="$CACHE_DIR/mapping.txt"

# An image built with nothing embedded is not an error; exit rather than
# failing the unit and, through Requires=, MicroShift with it.
if [[ ! -s $MAPPING ]]; then
	echo "no embedded images at $MAPPING, nothing to copy"
	exit 0
fi

while IFS="," read -r image sha; do
	skopeo copy --preserve-digests "dir:$CACHE_DIR/$sha" "containers-storage:$image"
done < "$MAPPING"
