#!/bin/bash
# Checks run inside the k3s image before it is pushed. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < k3s/smoke-test.sh
#
# Only what this layer adds; the vendor image underneath was checked by
# base/smoke-test.sh. This proves the image was assembled correctly and nothing
# about the GPU or the cluster — only a boot on real hardware does that.
set -euo pipefail

echo "== k3s binary =="
k3s --version
for cmd in kubectl crictl ctr; do
	[[ "$(readlink "/usr/bin/${cmd}")" == k3s ]] || { echo "/usr/bin/${cmd} is not the k3s symlink"; exit 1; }
done

echo "== selinux policy =="
rpm -q k3s-selinux container-selinux
test -f /usr/share/selinux/packages/k3s.pp
# The build adds the Rancher repo to install the policy and must take it away
# again: the deployed node is air-gapped and would stall on it.
test ! -e /etc/yum.repos.d/rancher-k3s-common.repo

echo "== units =="
for unit in k3s k3s-stage-assets; do
	test -L "/etc/systemd/system/multi-user.target.wants/${unit}.service" \
		|| { echo "not enabled: ${unit}.service"; exit 1; }
done
test -x /usr/libexec/k3s-stage-assets

echo "== firewall =="
ports="$(firewall-offline-cmd --zone=public --list-ports)"
for p in 22/tcp 443/tcp 6443/tcp; do
	[[ " $ports " == *" $p "* ]] || { echo "missing public port: $p"; exit 1; }
done
sources="$(firewall-offline-cmd --zone=trusted --list-sources)"
for src in 10.42.0.0/16 10.43.0.0/16; do
	[[ " $sources " == *" $src "* ]] || { echo "missing trusted source: $src"; exit 1; }
done

echo "== nvidia =="
# Without this the containerd runtime k3s generates is never selected and pods
# get no GPU, with nothing in the logs to say so.
grep -qx 'default-runtime: nvidia' /etc/rancher/k3s/config.yaml
command -v nvidia-container-runtime
test -s /usr/share/k3s/manifests/nvidia-device-plugin.yaml

echo "== staged images =="
# The control plane and the device plugin both have to be on disk: the node has
# no registry to fall back on.
test -s /usr/share/k3s/agent-images/k3s-airgap-images.tar.zst
test -s /usr/share/k3s/agent-images/nvidia-device-plugin.tar
tar -tf /usr/share/k3s/agent-images/nvidia-device-plugin.tar | grep -q '^manifest.json$' \
	|| { echo "device plugin tarball is not a docker archive"; exit 1; }

echo "all checks passed"
