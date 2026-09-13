#!/bin/bash
# Checks run inside the services image before it is pushed. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < services/smoke-test.sh
#
# Two jobs: what this layer added is there, and the cluster underneath it still
# is — this layer's only real risk is breaking what it is stacked on.
set -euo pipefail

echo "== microshift underneath =="
rpm -q microshift openshift-clients
for unit in microshift microshift-make-rshared copy-embedded-images; do
	test -L "/etc/systemd/system/multi-user.target.wants/${unit}.service" \
		|| { echo "not enabled: ${unit}.service"; exit 1; }
done

echo "== service manifests =="
# Empty until the first component lands; say which, rather than pass silently.
roots=$(find /etc/microshift/manifests.d -maxdepth 1 -mindepth 1 -type d \
	2>/dev/null || true)
if [[ -z $roots ]]; then
	echo "no service manifest roots under /etc/microshift/manifests.d"
else
	echo "$roots" | sed 's/^/   /'
fi

# A manifest naming an image SERVICE_IMAGES does not means ImagePullBackOff on
# a node with no registry. Check the scanner exists first: process substitution
# that fails leaves the loop reading nothing and this section passing blind.
scan=/opt/microshift/manifest-images.sh
if [[ ! -x $scan ]]; then
	echo "missing: $scan — it comes from the microshift layer below"
	ls -la /opt/microshift 2>&1 | sed 's/^/   /'
	exit 1
fi

# embed_image.sh keys the cache on `echo "$ref" | sha256sum`, newline included.
while read -r img; do
	fsha="$(echo "$img" | sha256sum | awk '{ print $1 }')"
	if [[ ! -f /usr/lib/containers-image-cache/${fsha}/manifest.json ]]; then
		echo "a manifest names ${img}, which is not embedded"
		echo "add it to SERVICE_IMAGES"
		exit 1
	fi
	echo "   embedded: ${img}"
done < <("$scan" /etc/microshift/manifests.d/*/)

echo "== embedded images =="
# Cumulative: the control plane and device plugin came from the layer below.
mapping=/usr/lib/containers-image-cache/mapping.txt
if [[ ! -s $mapping ]]; then
	echo "no mapping at $mapping; the microshift layer should have written one"
	ls -la /usr/lib/containers-image-cache 2>&1 | sed 's/^/   /'
	exit 1
fi
echo "embedded: $(wc -l < "$mapping") images"
while IFS=, read -r img sha; do
	test -f "/usr/lib/containers-image-cache/${sha}/manifest.json" \
		|| { echo "missing embedded image: ${img}"; exit 1; }
done < "$mapping"

echo "all checks passed"
