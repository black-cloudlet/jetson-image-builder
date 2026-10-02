#!/bin/bash
# Checks run inside the kiosk layer before it is pushed. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < kiosk/smoke-test.sh
#
# Proves the pieces agree with each other. Whether a picture leaves the DP port
# is a hardware question.
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

echo "== firefox policies =="
# A policies.json that does not parse is ignored whole, silently.
python3 -m json.tool /etc/firefox/policies/policies.json >/dev/null \
	|| fail "/etc/firefox/policies/policies.json does not parse"

echo "all checks passed"
