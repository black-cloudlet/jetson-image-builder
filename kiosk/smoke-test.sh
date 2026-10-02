#!/bin/bash
# Checks run inside the kiosk layer before it is pushed. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < kiosk/smoke-test.sh
#
# This proves the layer is wired together. Whether a picture leaves the DP port,
# whether hotplug is seen and whether the GPU stays idle are hardware questions:
# no display driver is loaded in a container.
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
	|| fail "jetson-kiosk.service runs as '$unit_user', which /usr/lib/sysusers.d/jetson-kiosk.conf does not create"
echo "   $unit_user"

echo "== what the scripts run =="
# Package names are checked by dnf; the commands the scripts call by name are
# not, and a missing one fails only once a monitor is plugged in.
for cmd in xinit gnome-kiosk firefox curl; do
	command -v "$cmd" || fail "not on PATH: $cmd ($PATH)"
done
[[ -x /usr/bin/Xorg ]] || missing /usr/bin/Xorg /usr/bin
for s in /opt/jetson-kiosk/kiosk.sh /opt/jetson-kiosk/session.sh; do
	bash -n "$s" || fail "syntax error in $s"
done

echo "== software rendering only =="
# session.sh pins glvnd to Mesa by name and by file. A name or path that does
# not exist leaves the session with no GL at all, and GNOME Kiosk does not start.
egl=$(sed -n 's/^export __EGL_VENDOR_LIBRARY_FILENAMES=//p' /opt/jetson-kiosk/session.sh)
[[ -f $egl ]] || missing "$egl (the EGL vendor session.sh names)" "${egl%/*}"
[[ -e /usr/lib64/libGLX_mesa.so.0 ]] \
	|| missing "/usr/lib64/libGLX_mesa.so.0 (__GLX_VENDOR_LIBRARY_NAME=mesa)" /usr/lib64
[[ -e /usr/lib64/dri/swrast_dri.so ]] \
	|| missing "/usr/lib64/dri/swrast_dri.so (the software renderer)" /usr/lib64/dri

# An xorg.conf from below takes part in the same configuration as our snippet,
# and a second Device section naming NVIDIA's driver would put X on the GPU.
[[ ! -e /etc/X11/xorg.conf ]] \
	|| fail "/etc/X11/xorg.conf exists and would be merged with 90-jetson-kiosk.conf:" \
		"$(sed 's/^/   /' /etc/X11/xorg.conf)"

# A policies.json that does not parse is ignored whole: Firefox then runs with
# hardware acceleration and nothing locked down, and says so only in about:policies.
python3 - /etc/firefox/policies/policies.json <<'EOF'
import json, sys
p = json.load(open(sys.argv[1]))["policies"]
if p.get("HardwareAcceleration") is not False:
    sys.exit("HardwareAcceleration is not false in " + sys.argv[1])
wr = p.get("Preferences", {}).get("gfx.webrender.software", {})
if wr.get("Value") is not True or wr.get("Status") != "locked":
    sys.exit("gfx.webrender.software is not locked to true in " + sys.argv[1])
EOF
echo "   no GPU in X, GL or Firefox"

echo "all checks passed"
