#!/bin/bash
# Put the images and manifests baked into /usr where k3s looks for them, under
# /var/lib/rancher — machine state, so nothing the image ships is there at first
# boot. Runs once per boot from k3s-stage-assets.service, before k3s.service.
set -euxo pipefail

AGENT_DIR=/var/lib/rancher/k3s/agent
SERVER_DIR=/var/lib/rancher/k3s/server

# A symlink, not a copy: the control plane tarball is close to a gigabyte, and
# copying it onto the eMMC on every boot spends both space and write endurance
# to duplicate something already on disk. k3s only reads this directory.
install -d -m 0700 "$AGENT_DIR"
if [[ ! -L $AGENT_DIR/images ]]; then
	rm -rf "$AGENT_DIR/images"
	ln -s /usr/share/k3s/agent-images "$AGENT_DIR/images"
fi

# k3s writes its own bundled manifests (coredns, traefik, local-storage,
# metrics-server) into this one, so it has to be a real directory.
install -d -m 0700 "$SERVER_DIR/manifests"
install -m 0600 /usr/share/k3s/manifests/*.yaml "$SERVER_DIR/manifests/"
