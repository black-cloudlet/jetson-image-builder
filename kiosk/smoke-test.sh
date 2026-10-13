#!/bin/bash
# Checks run inside the kiosk layer before it is pushed. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < kiosk/smoke-test.sh
#
# Proves the pieces agree with each other. Whether a picture leaves the DP port
# is a hardware question, and so is whether the GPU draws it: no display
# driver is loaded in a container.
set -euo pipefail

fail() { echo "$*"; exit 1; }

echo "== boots to GDM =="
# `systemctl enable` only warns on a bad [Install], so the build does not notice.
[[ $(readlink /etc/systemd/system/default.target) == */graphical.target ]] \
	|| fail "default.target is $(readlink /etc/systemd/system/default.target), not graphical.target"
[[ $(readlink /etc/systemd/system/display-manager.service) == */gdm.service ]] \
	|| fail "display-manager.service is not gdm.service"

echo "== kiosk user and session =="
# What the node does at boot, done here in a throwaway container: an escape
# tmpfiles does not expand, or an owner sysusers did not create, shows now.
systemd-sysusers
systemd-tmpfiles --create /usr/lib/tmpfiles.d/jetson-kiosk.conf
user=$(sed -n 's/^AutomaticLogin=//p' /etc/gdm/custom.conf)
id "$user" || fail "GDM logs in '$user', which sysusers did not create"

session=$(sed -n 's/^Session=//p' "/var/lib/AccountsService/users/$user")
[[ -f /usr/share/wayland-sessions/$session.desktop ]] || {
	echo "the AccountsService file names session '$session', which is not installed:"
	ls -la /usr/share/wayland-sessions
	exit 1
}

script=/var/home/$user/.local/bin/gnome-kiosk-script
[[ -x $script ]] || fail "$script is not executable"
bash -n "$script"
grep -q '.local/bin/gnome-kiosk-script' "$(command -v gnome-kiosk-script)" \
	|| fail "gnome-kiosk-script no longer runs ~/.local/bin/gnome-kiosk-script"
for cmd in firefox curl; do
	command -v "$cmd" || fail "not on PATH: $cmd"
done

echo "== GPU path =="
groups=$(id -nG "$user")
[[ " $groups " == *" video "* ]] \
	|| fail "$user is not in video ($groups): it cannot open NVIDIA's GPU nodes"

# A gdm update can add or rename a rule that turns Wayland off on NVIDIA; every
# rule file that can do it must be masked.
for rule in $(grep -l 'WaylandEnable false' /usr/lib/udev/rules.d/*.rules); do
	[[ $(readlink "/etc/udev/rules.d/${rule##*/}") == /dev/null ]] || {
		echo "$rule can turn Wayland off on NVIDIA, and /etc/udev/rules.d does not mask it:"
		ls -la /etc/udev/rules.d
		exit 1
	}
done

# What GNOME Kiosk and Firefox draw through, all from the vendor image and
# checked nowhere else: a base bump that drops one leaves no GPU path. -e
# follows links, so a dangling one fails.
for f in /usr/share/glvnd/egl_vendor.d/10_nvidia.json \
	/usr/lib64/gbm/nvidia-drm_gbm.so \
	/usr/share/egl/egl_external_platform.d/nvidia_gbm.json \
	/usr/share/egl/egl_external_platform.d/nvidia_wayland.json \
	/etc/systemd/system/graphical.target.wants/load-nvidia-drm.service; do
	[[ -e $f ]] || { echo "missing: $f"; ls -la "${f%/*}"; exit 1; }
done
grep -rqsx 'options nvidia-drm .*modeset=1.*' /etc/modprobe.d /usr/lib/modprobe.d \
	|| fail "no modprobe.d file sets nvidia-drm modeset=1: no KMS for the compositor"

echo "== firefox policies =="
# A policies.json that does not parse is ignored whole, silently.
python3 -m json.tool /etc/firefox/policies/policies.json >/dev/null \
	|| fail "/etc/firefox/policies/policies.json does not parse"

echo "all checks passed"
