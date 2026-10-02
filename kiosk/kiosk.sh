#!/bin/bash
# Run by jetson-kiosk.service as the kiosk user, on tty1. Waits for a monitor,
# then for the frontend, then starts GNOME Kiosk as the Wayland compositor and
# Firefox as its only window. Firefox runs as this script's PID, so whatever
# ends it ends the service; systemd stops the compositor with it and starts
# this again: back to waiting.
set -euo pipefail

: "${KIOSK_URL:?KIOSK_URL is not set; it comes from /etc/jetson-kiosk.conf}"
: "${XDG_RUNTIME_DIR:?no XDG_RUNTIME_DIR: the PAM session of the unit did not open}"

# Any connector rather than DP by name: the names come from the display driver,
# unverified on this one. The status file is the driver's last hotplug state,
# so reading it every two seconds costs nothing.
connected() { grep -qx connected /sys/class/drm/card*-*/status 2>/dev/null; }

# With no monitor nothing runs at all: no compositor, no Firefox decoding video
# for an empty port.
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
echo "${KIOSK_URL} answered ${code}; starting the compositor"

# --display-server: drive KMS itself through the logind session, not nest in
# another compositor. --no-x11: no Xwayland, since Firefox speaks Wayland. If
# it dies there is nothing to draw on, so the session ends with it.
{ gnome-kiosk --wayland --display-server --no-x11 || true; kill "$$" 2>/dev/null || true; } &

# The first free name is wayland-0: logind gives every session a fresh
# XDG_RUNTIME_DIR, and a lock left by a dead compositor is not held.
export WAYLAND_DISPLAY=wayland-0
for _ in $(seq 30); do
	[[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]] && break
	sleep 1
done
[[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]] || {
	echo "GNOME Kiosk did not open $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY in 30 s; in it:"
	ls -la "$XDG_RUNTIME_DIR" | sed 's/^/   /'
	exit 1
}

# Ten seconds with no monitor ends the session, so nothing decodes video for an
# empty port. Ten rather than one poll: a cable wiggle should not cost a
# Firefox start.
{
	gone=0
	while sleep 2; do
		if connected; then gone=0; else gone=$((gone + 1)); fi
		if ((gone >= 5)); then break; fi
	done
	echo "no monitor for 10 s; ending the session"
	kill "$$" 2>/dev/null || true
} &

# A fresh profile on every start, on tmpfs: no state carried across sessions,
# nothing for a crash to corrupt, no profile writes on the eMMC.
profile=$XDG_RUNTIME_DIR/firefox-profile
rm -rf "$profile"
mkdir -p "$profile"

export XDG_SESSION_TYPE=wayland GDK_BACKEND=wayland MOZ_ENABLE_WAYLAND=1
exec firefox --kiosk --no-remote --profile "$profile" "$KIOSK_URL"
