#!/bin/bash
# Checks that run inside the built image, before it is pushed. Fed to the
# container on stdin by the build workflow:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < microshift/smoke-test.sh
#
# This proves the image was assembled correctly. It proves nothing about the
# GPU or the cluster — only a boot on real hardware does that. The base image
# was checked by the layers below, and what the Containerfile COPYs, enables or
# installs fails the build by itself, so neither is re-checked here.
set -euo pipefail

fail() { echo "$*"; exit 1; }

echo "== nvidia runtime for cri-o =="
# nvidia-ctk renames a .conf drop-in to .toml and still exits 0, so only a check
# spelling the name notices. On a miss, list the directory.
f=/etc/crio/crio.conf.d/99-nvidia.toml
[[ -s $f ]] || { echo "missing: $f"; ls -la "${f%/*}"; exit 1; }

echo "== gpu time slicing =="
# A patch that stops matching is a no-op in kustomize, not an error, and a
# strategic merge whose list key stops matching is worse: it appends an entry
# instead of merging into upstream one. Both render cleanly here and fail on
# the node, where the kustomizer retries for ten minutes and then gives up in
# one journal line.
#
# So the render is checked for how it is wired, never for which line upstream
# happens to write. The plugin manifest is fetched by tag and upstream renames
# fields between tags - v0.18.0 dropped FAIL_ON_INIT_ERROR, v0.20.0 renamed the
# kubelet socket volume - and none of that is a broken patch. What has to hold:
# one container, CONFIG_FILE pointing into a mount that resolves to the
# replicas ConfigMap, and the kubelet socket directory mounted.
#
# `oc patch --local` with an empty patch never contacts a server; it parses the
# render and prints it back as JSON, which jq can then query.
r=$(oc kustomize /etc/microshift/manifests |
	oc patch --local -f - --type=merge -p '{}' -o json | jq -s .) \
	|| fail "does not render: /etc/microshift/manifests"

# Prefixed to the jq programs below: the device plugin's pod spec.
P='def pod: .[] | select(.kind == "DaemonSet") | .spec.template.spec;'
n=$(jq "$P"' [pod | .containers[]] | length' <<<"$r")
[[ $n == 1 ]] || fail "the pod has $n containers, expected 1: a merge key" \
	"that stopped matching appends one instead of patching upstream"

cfg=$(jq -r "$P"' pod | .containers[0].env[]? | select(.name == "CONFIG_FILE") | .value' <<<"$r")
[[ -n $cfg ]] || fail "no CONFIG_FILE in the render: the patch never reached the container"

vol=$(jq -r --arg dir "${cfg%/*}" "$P"' pod
	| .containers[0].volumeMounts[]? | select(.mountPath == $dir) | .name' <<<"$r")
[[ -n $vol ]] || fail "CONFIG_FILE is $cfg but no volumeMount covers ${cfg%/*}"

cm=$(jq -r --arg vol "$vol" "$P"' pod
	| .volumes[]? | select(.name == $vol) | .configMap.name // empty' <<<"$r")
[[ -n $cm ]] || fail "the volume mounted at ${cfg%/*} is not a configMap"

# The count printed is the one the plugin will read: the key the mount turns
# into the file CONFIG_FILE names.
replicas=$(jq -r --arg cm "$cm" --arg key "${cfg##*/}" '.[]
	| select(.kind == "ConfigMap" and .metadata.name == $cm)
	| .data[$key] // empty | capture("replicas: *(?<n>[0-9]+)").n' <<<"$r")
[[ -n $replicas ]] || fail "configMap $cm is not in the render, or its ${cfg##*/}" \
	"names no replica count"
echo "   time-slicing replicas: $replicas"

# Upstream ships this one, but it is checked because the plugin cannot register
# with kubelet without it, not to prove a merge merged.
jq -e "$P"' pod | .containers[0].volumeMounts[]?
	| select(.mountPath == "/var/lib/kubelet/device-plugins")' >/dev/null <<<"$r" \
	|| fail "nothing mounts /var/lib/kubelet/device-plugins: the plugin cannot register with kubelet"

echo "== embedded images =="
cache=/usr/lib/containers-image-cache
[[ -s $cache/mapping.txt ]] || { echo "missing: $cache/mapping.txt"; ls -la "$cache"; exit 1; }
echo "embedded: $(wc -l < "$cache/mapping.txt") images"
while IFS=, read -r img sha; do
	[[ -f $cache/$sha/manifest.json ]] || fail "missing embedded image: $img"
done < "$cache/mapping.txt"

# Whether the images the manifests will ask for are actually in the cache.
# embed_image.sh names the directory after `echo "$ref" | sha256sum`, newline
# and all, so recompute it rather than match the mapping's rewritten name.
# Captured first: a scan that fails inside `< <(...)` leaves the loop reading
# nothing and passing.
echo "== manifest images =="
images=$(/opt/microshift/manifest-images.sh \
	/usr/lib/microshift/manifests /usr/lib/microshift/manifests.d/*/ \
	/etc/microshift/manifests /etc/microshift/manifests.d/*/) \
	|| fail "/opt/microshift/manifest-images.sh failed"
while read -r img; do
	fsha=$(echo "$img" | sha256sum | awk '{ print $1 }')
	[[ -f $cache/$fsha/manifest.json ]] || fail "manifest image was not embedded: $img"
	echo "   embedded: $img"
done <<<"$images"

echo "all checks passed"
