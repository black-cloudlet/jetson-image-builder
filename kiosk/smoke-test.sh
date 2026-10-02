#!/bin/bash
# Checks run inside the kiosk layer before it is pushed. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < kiosk/smoke-test.sh
#
# This proves the layer is wired together. Whether a picture leaves the DP port,
# whether hotplug is seen and whether the compositor really runs on the GPU are
# hardware questions: no display driver is loaded in a container.
set -euo pipefail

fail() { echo "$*"; exit 1; }
missing() {
	echo "missing: $1"
	shift
	for p in "$@"; do
		echo "-- $p"
		ls -la "$p" 2>&1 | sed 's/^/   /'
	done
	exit 1
}

echo "== unit enabled =="
# `systemctl enable` on a unit whose [Install] section is missing or misspelt
# only warns and exits 0, so the build does not notice.
wants=/etc/systemd/system/multi-user.target.wants
[[ -L $wants/jetson-kiosk.service ]] || missing "$wants/jetson-kiosk.service" "$wants"

echo "== kiosk user =="
# Two files that must name the same account, and nothing in the build compares
# them: a mismatch fails only at boot, as a unit that cannot resolve its User=.
unit_user=$(sed -n 's/^User=//p' /usr/lib/systemd/system/jetson-kiosk.service)
awk -v u="$unit_user" '$1 == "u" && $2 == u { found = 1 } END { exit !found }' \
	/usr/lib/sysusers.d/jetson-kiosk.conf \
	|| fail "jetson-kiosk.service runs as '$unit_user'," \
		"which /usr/lib/sysusers.d/jetson-kiosk.conf does not create"
echo "   $unit_user"

echo "== what the script runs =="
# Package names are checked by dnf; the commands the script calls by name are
# not, and a missing one fails only once a monitor is plugged in.
for cmd in gnome-kiosk firefox curl; do
	command -v "$cmd" || fail "not on PATH: $cmd ($PATH)"
done
bash -n /opt/jetson-kiosk/kiosk.sh || fail "syntax error in /opt/jetson-kiosk/kiosk.sh"

echo "== NVIDIA EGL and GBM =="
# The compositor reaches the GPU through glvnd's EGL vendor list and a GBM
# backend named after the DRM driver. The vendor image is what would carry
# them; without them there is no GPU path at all, and mutter either fails or
# falls back to whatever Mesa offers.
vendors=/usr/share/glvnd/egl_vendor.d
grep -l 'libEGL_nvidia' "$vendors"/*.json \
	|| missing "an EGL vendor file naming libEGL_nvidia (NVIDIA's EGL)" "$vendors"
gbm=$(find /usr/lib64 -name '*nvidia*gbm*.so*' 2>/dev/null || true)
[[ -n $gbm ]] || missing "an NVIDIA GBM library or backend under /usr/lib64" /usr/lib64/gbm
echo "$gbm" | sed 's/^/   /'

echo "== no VT switching =="
# An override naming a key the schema does not have is skipped with a warning
# at compile time, not an error.
got=$(GSETTINGS_BACKEND=memory gsettings get \
	org.gnome.mutter.wayland.keybindings switch-to-session-2 2>&1) \
	|| fail "no org.gnome.mutter.wayland.keybindings in the compiled schemas: $got"
[[ $got == "@as []" ]] \
	|| fail "switch-to-session-2 is $got, not empty: 90-jetson-kiosk.gschema.override did not apply"

echo "== firefox policies =="
# A policies.json that does not parse is ignored whole: Firefox then runs with
# nothing locked down, and says so only in about:policies.
python3 -m json.tool /etc/firefox/policies/policies.json >/dev/null \
	|| fail "/etc/firefox/policies/policies.json does not parse"

echo "all checks passed"
