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
rpm -q microshift microshift-release-info openshift-clients
oc version --client

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

echo "== node ip on lo =="
nmconn=/usr/lib/NetworkManager/system-connections/stable-microshift.nmconnection
have -s "$nmconn" /usr/lib/NetworkManager/system-connections
[[ $(stat -c %a "$nmconn") == 600 ]] \
	|| { echo "mode $(stat -c %a "$nmconn") on $nmconn, NetworkManager needs 600"; exit 1; }
grep -qx 'address1=10.44.0.1/32' "$nmconn" \
	|| { echo "no 10.44.0.1/32 in $nmconn"; exit 1; }
have -s /etc/microshift/config.d/10-node-ip.yaml /etc/microshift/config.d
grep -q '^ *nodeIP: 10.44.0.1$' /etc/microshift/config.d/10-node-ip.yaml \
	|| { echo "nodeIP is not the lo address"; exit 1; }

echo "== nvidia device plugin =="
# .toml is the name nvidia-ctk actually writes for a drop-in; on a miss, list the
# directory so a future rename says so instead of failing blind.
have -s /etc/crio/crio.conf.d/99-nvidia.toml /etc/crio/crio.conf.d
have -s /etc/microshift/manifests/nvidia-device-plugin.yml /etc/microshift/manifests
have -s /etc/microshift/manifests/kustomization.yaml /etc/microshift/manifests
have -s /etc/microshift/manifests/nvidia-device-plugin-config.yaml /etc/microshift/manifests
have -s /etc/microshift/manifests/nvidia-device-plugin-time-slicing.yaml \
	/etc/microshift/manifests

echo "== gpu time slicing =="
# A patch that stops matching is a no-op in kustomize, not an error.
rendered=$(oc kustomize /etc/microshift/manifests)

# From the ConfigMap: a Deployment added later would own the render's first one.
replicas=$(sed -n 's/^ *replicas: \([0-9]*\) *$/\1/p' \
	/etc/microshift/manifests/nvidia-device-plugin-config.yaml)
[[ -n $replicas ]] || { echo "no replica count in the device plugin config"; exit 1; }
echo "time-slicing replicas: $replicas"

for want in \
	'name: CONFIG_FILE' \
	'value: /etc/nvidia-device-plugin/config.yaml' \
	'mountPath: /etc/nvidia-device-plugin' \
	'name: nvidia-device-plugin-config' \
	; do
	grep -qF -- "$want" <<<"$rendered" \
		|| { echo "patch did not apply, missing from rendered output: $want"; exit 1; }
done

# Gone means the merge replaced the lists instead of merging them.
for want in \
	'name: FAIL_ON_INIT_ERROR' \
	'mountPath: /var/lib/kubelet/device-plugins' \
	; do
	grep -qF -- "$want" <<<"$rendered" \
		|| { echo "strategic merge clobbered upstream field: $want"; exit 1; }
done

echo "== embedded images =="
mapping=/usr/lib/containers-image-cache/mapping.txt
have -s "$mapping" /usr/lib/containers-image-cache
echo "embedded: $(wc -l < "$mapping") images"
while IFS=, read -r img sha; do
	test -f "/usr/lib/containers-image-cache/${sha}/manifest.json" \
		|| { echo "missing embedded image: ${img}"; exit 1; }
done < "$mapping"

# Whether the images the manifests will ask for are actually in the cache.
# embed_image.sh names the directory after `echo "$ref" | sha256sum`, newline
# and all, so recompute it rather than match the mapping's rewritten name.
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
