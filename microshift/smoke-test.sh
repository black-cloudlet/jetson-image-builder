#!/bin/bash
# Checks that run inside the built image, before it is pushed. Fed to the
# container on stdin by the build workflow:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < microshift/smoke-test.sh
#
# This proves the image was assembled correctly. It proves nothing about the
# GPU or the cluster — only a boot on real hardware does that.
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

echo "== base image =="
bootc --version
cat /etc/nv_tegra_release
rpm -q nvidia-jetpack-for-rhel-9.8-kmod nvidia-container-toolkit-base
ls /usr/lib/modules/*/extra/drivers/gpu/nvgpu/nvgpu.ko

echo "== microshift =="
rpm -q microshift microshift-release-info openshift-clients microshift-gitops
oc version --client

# The GitOps RPM is only manifests; if it stopped shipping them, Argo CD would
# silently never be deployed. Name what was found either way.
# || true: a missing directory must reach the message below, not abort under
# set -e with nothing said.
gitops_roots=$(find /usr/lib/microshift/manifests.d -maxdepth 1 -mindepth 1 -type d \
	-name '*gitops*' 2>/dev/null || true)
if [[ -z $gitops_roots ]]; then
	echo "microshift-gitops shipped no manifest root under /usr/lib/microshift/manifests.d"
	ls -la /usr/lib/microshift/manifests.d 2>&1 | sed 's/^/   /'
	exit 1
fi
echo "gitops manifest roots:"
echo "$gitops_roots" | sed 's/^/   /'
for unit in microshift microshift-make-rshared copy-embedded-images; do
	test -L "/etc/systemd/system/multi-user.target.wants/${unit}.service" \
		|| { echo "not enabled: ${unit}.service"; exit 1; }
done
have -f /usr/lib/systemd/system/microshift.service.d/microshift-copy-images.conf \
	/usr/lib/systemd/system/microshift.service.d

echo "== firewall =="
ports="$(firewall-offline-cmd --zone=public --list-ports)"
for p in 22/tcp 443/tcp 6443/tcp; do
	[[ " $ports " == *" $p "* ]] || { echo "missing public port: $p"; exit 1; }
done
sources="$(firewall-offline-cmd --zone=trusted --list-sources)"
for src in 10.42.0.0/16 10.43.0.0/16 169.254.169.1; do
	[[ " $sources " == *" $src "* ]] || { echo "missing trusted source: $src"; exit 1; }
done

echo "== nvidia device plugin =="
# .toml is the name nvidia-ctk actually writes for a drop-in; on a miss, list the
# directory so a future rename says so instead of failing blind.
have -s /etc/crio/crio.conf.d/99-nvidia.toml /etc/crio/crio.conf.d
have -s /etc/microshift/manifests/nvidia-device-plugin.yml /etc/microshift/manifests
have -s /etc/microshift/manifests/kustomization.yaml /etc/microshift/manifests

echo "== embedded images =="
mapping=/usr/lib/containers-image-cache/mapping.txt
have -s "$mapping" /usr/lib/containers-image-cache
echo "embedded: $(wc -l < "$mapping") images"
while IFS=, read -r img sha; do
	test -f "/usr/lib/containers-image-cache/${sha}/manifest.json" \
		|| { echo "missing embedded image: ${img}"; exit 1; }
done < "$mapping"

# The real question is not how many images were embedded but whether the ones
# the manifests will ask for are among them — the device plugin's, Argo CD's,
# and anything a later layer added. embed_image.sh keys the cache directory on
# the sha256 of the reference it was handed, newline and all, so recompute it
# the same way rather than matching on the mapping's rewritten name.
echo "== manifest images =="
while read -r img; do
	fsha="$(echo "$img" | sha256sum | awk '{ print $1 }')"
	if [[ ! -f /usr/lib/containers-image-cache/${fsha}/manifest.json ]]; then
		echo "manifest image was not embedded: ${img}"
		exit 1
	fi
	echo "   embedded: ${img}"
done < <(/opt/microshift/manifest-images.sh \
	/usr/lib/microshift/manifests /usr/lib/microshift/manifests.d/*/ \
	/etc/microshift/manifests /etc/microshift/manifests.d/*/)

echo "all checks passed"
