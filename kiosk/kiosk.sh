#!/bin/bash
# Run by jetson-kiosk.service as the kiosk user, on tty1. Waits for a monitor,
# then for the frontend, then starts X with session.sh as its only client. X
# ends when the session does, and systemd starts this again: back to waiting.
set -euo pipefail

: "${KIOSK_URL:?KIOSK_URL is not set; it comes from /etc/jetson-kiosk.conf}"

# Any connector rather than DP by name: the names come from the display driver,
# unverified on this one. The status file is the driver's last hotplug state,
# so reading it every two seconds costs nothing.
connected() { grep -qx connected /sys/class/drm/card*-*/status 2>/dev/null; }

# With no monitor nothing runs at all: no X, no Firefox decoding video for an
# empty port.
echo "waiting for a monitor on any of: $(cd /sys/class/drm && echo card*-*)"
until connected; do sleep 2; done

# MicroShift takes minutes after boot to apply its manifests, and Firefox would
# sit on an error page with nobody to reload it. Any answer that is not a 5xx
# will do: a 5xx is the router with no ready backend. -k because this only asks
# whether something answers; whether to trust it is Firefox's call.
echo "monitor connected; waiting for ${KIOSK_URL}"
until code=$(curl -ks -o /dev/null -w '%{http_code}' --max-time 5 "$KIOSK_URL") \
		&& [[ $code != 5* ]]; do
	sleep 5
done
echo "${KIOSK_URL} answered ${code}; starting X"

# -keeptty: the VT is this service's, not one for X to open. -s 0 -dpms: X's
# own screen saver and power-off, the only blanking left with no GNOME
# settings daemon running.
exec xinit /opt/jetson-kiosk/session.sh -- /usr/bin/Xorg :0 "vt${XDG_VTNR:-1}" \
	-keeptty -nolisten tcp -s 0 -dpms
