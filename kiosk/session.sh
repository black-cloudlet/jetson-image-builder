#!/bin/bash
# The X session kiosk.sh starts: GNOME Kiosk as the window manager, Firefox as
# the only window. Firefox runs as this script's PID, so whatever ends it ends
# the session, X with it, and jetson-kiosk.service starts over.
set -euo pipefail

# GL from Mesa's software renderer only, never NVIDIA's, should the base image
# carry it: glvnd would otherwise pick a vendor by itself.
export __GLX_VENDOR_LIBRARY_NAME=mesa
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
export LIBGL_ALWAYS_SOFTWARE=1
export XDG_SESSION_TYPE=x11 GDK_BACKEND=x11 MOZ_ENABLE_WAYLAND=0

connected() { grep -qx connected /sys/class/drm/card*-*/status 2>/dev/null; }

# Fullscreens every window and turns a newly plugged monitor on. If it dies,
# Firefox is left an ordinary window, so the session ends with it.
{ gnome-kiosk --x11 || true; kill "$$" 2>/dev/null || true; } &

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

# A fresh profile on every start, in XDG_RUNTIME_DIR (tmpfs): no state carried
# across sessions, nothing for a crash to corrupt, no profile writes on the eMMC.
profile=${XDG_RUNTIME_DIR:?}/firefox-profile
rm -rf "$profile"
mkdir -p "$profile"

exec firefox --kiosk --no-remote --profile "$profile" "$KIOSK_URL"
