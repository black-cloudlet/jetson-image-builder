#!/bin/bash
# Checks run inside the services image before it is pushed. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < services/smoke-test.sh
#
# Three jobs: what this layer added is there, the cluster underneath it still
# is — this layer's only real risk is breaking what it is stacked on — and the
# manifests still say what they were patched to say. The last one matters most:
# MicroShift renders these roots itself at start-up, so a root that does not
# render, or a patch that quietly stopped matching, is a component that is
# simply absent on a node nobody can ssh into.
set -euo pipefail

echo "== microshift underneath =="
rpm -q microshift openshift-clients
for unit in microshift microshift-make-rshared copy-embedded-images; do
	test -L "/etc/systemd/system/multi-user.target.wants/${unit}.service" \
		|| { echo "not enabled: ${unit}.service"; exit 1; }
done

echo "== service manifest roots =="
mapfile -t roots < <(find /etc/microshift/manifests.d -maxdepth 1 -mindepth 1 \
	-type d 2>/dev/null | sort)
if [[ ${#roots[@]} -eq 0 ]]; then
	echo "no service manifest roots under /etc/microshift/manifests.d"
	exit 1
fi
printf '   %s\n' "${roots[@]}"

# The two upstream installs are curl'd at build time and are not in git, so
# they are the first thing to go missing when a release moves its assets.
for f in /etc/microshift/manifests.d/010-cert-manager/cert-manager.yaml \
	/etc/microshift/manifests.d/020-kserve/kserve.yaml; do
	test -s "$f" || {
		echo "missing or empty: ${f}"
		ls -la "$(dirname "$f")" | sed 's/^/   /'
		exit 1
	}
	echo "   curl'd: ${f} ($(wc -c < "$f") bytes)"
done

echo "== renders =="
# oc's kustomize is the closest thing in the image to the one MicroShift links
# into its own binary. It is also older than the standalone tool, which is why
# no patch file here holds more than one document.
render=$(mktemp -d)
for root in "${roots[@]}"; do
	out="${render}/$(basename "$root").yaml"
	oc kustomize "$root" > "$out" || { echo "does not render: ${root}"; exit 1; }
	echo "   $(basename "$root"): $(wc -l < "$out") lines"
done

echo "== kserve configuration =="
ksv="${render}/020-kserve.yaml"
# Standard is what 0.20 calls raw deployment. If the ConfigMap patch stops
# matching, upstream's Serverless stays and every InferenceService waits
# forever on a Knative that is not installed.
for want in '"defaultDeploymentMode": "Standard"' \
	'"disableIngressCreation": true' \
	'"image" : "docker.io/kserve/storage-initializer'; do
	grep -qF -- "$want" "$ksv" || { echo "not in the render: ${want}"; exit 1; }
	echo "   set: ${want}"
done
# Each ConfigMap key is one JSON string and has to be patched whole, so a field
# dropped while editing one is invisible until the controller refuses to start
# — NewIngressConfig rejects an empty ingressGateway even in Standard mode.
for want in '"ingressGateway"' '"domainTemplate"' '"enableModelcar"'; do
	grep -qF -- "$want" "$ksv" \
		|| { echo "the config patch dropped an upstream field: ${want}"; exit 1; }
done
# One workload survives the three delete patches. Anything else is either a
# delete that no longer matches — kustomize would have failed the build — or a
# workload upstream added, which has to be looked at before it ships: the ones
# deleted here were rejected by restricted-v2, not merely unused.
workloads=$(awk '/^kind: (Deployment|DaemonSet|StatefulSet)$/ { k = $2 }
	k && /^  name: / { print k "/" $2; k = "" }' "$ksv")
if [[ $workloads != "Deployment/kserve-controller-manager" ]]; then
	echo "unexpected workloads in the kserve render:"
	echo "$workloads" | sed 's/^/   /'
	echo "expected exactly Deployment/kserve-controller-manager"
	exit 1
fi
echo "   workloads: ${workloads}"

echo "== triton runtime =="
tri="${render}/030-triton-runtime.yaml"
for want in 'kind: ClusterServingRuntime' 'nvidia.com/gpu:' '-py3-igpu'; do
	grep -qF -- "$want" "$tri" || { echo "not in the render: ${want}"; exit 1; }
	echo "   set: ${want}"
done

echo "== images the manifests name =="
# A manifest naming an image SERVICE_IMAGES does not means ImagePullBackOff on
# a node with no registry. Check the scanner exists first: process substitution
# that fails leaves the loop reading nothing and this section passing blind.
scan=/opt/microshift/manifest-images.sh
if [[ ! -x $scan ]]; then
	echo "missing: $scan — it comes from the microshift layer below"
	ls -la /opt/microshift 2>&1 | sed 's/^/   /'
	exit 1
fi
images=$("$scan" "${roots[@]}")
if [[ -z $images ]]; then
	echo "the manifest roots name no images at all"
	exit 1
fi

# embed_image.sh keys the cache on `echo "$ref" | sha256sum`, newline included.
while read -r img; do
	# CRI-O resolves a short name against unqualified-search-registries
	# (registry.access.redhat.com first, docker.io last) rather than looking
	# in the local store first, so an unqualified reference is a pull attempt
	# on a node that has no network. An images: transformer that stops
	# matching leaves one behind silently; this is what notices.
	host=${img%%/*}
	if [[ $host != *.* && $host != *:* ]]; then
		echo "unqualified image reference: ${img}"
		echo "give it a registry host, or the node will try to pull it"
		exit 1
	fi
	fsha="$(echo "$img" | sha256sum | awk '{ print $1 }')"
	if [[ ! -f /usr/lib/containers-image-cache/${fsha}/manifest.json ]]; then
		echo "a manifest names ${img}, which is not embedded"
		echo "the build embeds what this same scan prints; check its log"
		exit 1
	fi
	echo "   embedded: ${img}"
done <<< "$images"

# The controller, the storage initializer and the ConfigMap's copy of it are
# pinned in three places — one ARG and two patch files — and a stale patch is a
# version skew that nothing else would catch.
kserve_tags=$(sed -n 's|^docker\.io/kserve/[^:]*:\(.*\)$|\1|p' <<< "$images" |
	sort -u)
if [[ -n $kserve_tags && $(wc -l <<< "$kserve_tags") -ne 1 ]]; then
	echo "docker.io/kserve images do not share one tag:"
	echo "$kserve_tags" | sed 's/^/   /'
	echo "bump KSERVE_VER and both patch files together"
	exit 1
fi

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
# Printed, not asserted: the cache is copied into containers-storage at first
# boot, so it is paid for twice on a 40 GiB root. Triton's igpu image is the
# one that can make that arithmetic fail, and the number belongs in the log.
du -sh /usr/lib/containers-image-cache

echo "all checks passed"
