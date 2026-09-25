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
rendered=$(oc kustomize /etc/microshift/manifests) \
	|| { echo "does not render: /etc/microshift/manifests"; exit 1; }

# Prints the replica count it reached through the render, so the number in the
# log is the one the plugin will read. Diagnostics go to stderr, out of it.
replicas=$(awk '
	function warn(msg) { print "   " msg > "/dev/stderr"; bad = 1 }
	function flush_doc() {
		if (kind == "ConfigMap" && name != "" && rep != "") cmrep[name] = rep
		kind = ""; name = ""; rep = ""; sect = ""; inner = ""
		flush_mount(); flush_env(); flush_vol()
	}
	function flush_mount() { if (mpath != "") mount[mpath] = mname; mpath = ""; mname = "" }
	function flush_env()   { if (ename == "CONFIG_FILE") cfg = evalue; ename = ""; evalue = "" }
	# Only a volume that is a configMap is recorded, so a volume of another
	# kind at the same path reads as missing rather than as an empty name.
	function flush_vol()   { if (vname != "" && vcm != "") volcm[vname] = vcm
		vname = ""; vcm = "" }

	/^---$/ { flush_doc(); next }
	/^kind: / { kind = $2; next }
	/^metadata:$/ { meta = 1; next }
	meta && /^  name: / { name = $2; meta = 0; next }
	/^[a-z]/ { meta = 0 }
	/^ +replicas: [0-9]+$/ { rep = $2; next }

	/^      containers:$/ { sect = "containers"; inner = ""; next }
	/^      volumes:$/    { flush_vol(); sect = "volumes"; inner = ""; next }
	/^      [a-z]/ { flush_mount(); flush_env(); flush_vol(); sect = ""; inner = "" }
	/^  [a-z]/     { flush_mount(); flush_env(); flush_vol(); sect = ""; inner = "" }

	# A list item carries its first key on the dash line. Re-indent it so the
	# rules below see one shape, whichever key kustomize puts first.
	sect == "containers" && /^      - / { ncon++; flush_mount(); flush_env()
		inner = ""; sub(/^      - /, "        ") }
	sect == "containers" && /^        volumeMounts:/ { flush_env(); inner = "vm"; next }
	sect == "containers" && /^        env:/ { flush_mount(); inner = "env"; next }
	sect == "containers" && /^        [a-z]/ { flush_mount(); flush_env(); inner = "" }

	inner == "vm" && /^        - / { flush_mount() }
	inner == "vm" && /mountPath: / { mpath = $NF; next }
	inner == "vm" && /name: /      { mname = $NF; next }

	inner == "env" && /^        - / { flush_env() }
	inner == "env" && /name: /  { ename = $NF; next }
	inner == "env" && /value: / { evalue = $NF; next }

	sect == "volumes" && /^      - / { flush_vol(); sub(/^      - /, "        ") }
	sect == "volumes" && /^          name: / { vcm = $NF; next }
	sect == "volumes" && /^        name: /   { vname = $NF; next }

	END {
		flush_doc()
		if (ncon != 1)
			warn("the pod has " ncon + 0 " containers, expected 1: a merge key " \
				"that stopped matching appends one instead of patching upstream")
		if (cfg == "")
			warn("no CONFIG_FILE in the render: the patch never reached the container")
		else {
			dir = cfg
			sub(/\/[^\/]*$/, "", dir)
			if (!(dir in mount))
				warn("CONFIG_FILE is " cfg " but no volumeMount covers " dir)
			else if (!(mount[dir] in volcm))
				warn("the volume mounted at " dir " is not a configMap")
			else if (!(volcm[mount[dir]] in cmrep))
				warn("configMap " volcm[mount[dir]] " is not in the render, " \
					"or names no replica count")
			else
				print cmrep[volcm[mount[dir]]]
		}
		# Upstream ships this one, but it is checked because the plugin cannot
		# register with kubelet without it, not to prove a merge merged.
		if (!("/var/lib/kubelet/device-plugins" in mount))
			warn("nothing mounts /var/lib/kubelet/device-plugins: " \
				"the plugin cannot register with kubelet")
		if (bad) exit 1
	}
' <<<"$rendered") || { echo "the device plugin is not wired to the time-slicing config"; exit 1; }
echo "   time-slicing replicas: $replicas"

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
