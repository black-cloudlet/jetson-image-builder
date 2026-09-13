#!/bin/bash
# Print every container image referenced by the MicroShift manifest roots given
# as arguments: what has to be embedded for a node with no registry.
#
# Rendered with kustomize, not grepped — an `images:` transformer names the real
# image nowhere in a root's resources, and MicroShift renders these same roots
# at start-up.
set -euo pipefail

for root in "$@"; do
	# Unmatched globs arrive as literals, and not every root exists.
	[ -d "$root" ] || continue

	if [ -f "$root/kustomization.yaml" ] || [ -f "$root/kustomization.yml" ] ||
		[ -f "$root/Kustomization" ]; then
		oc kustomize "$root"
	else
		# MicroShift also accepts a directory of plain manifests.
		cat "$root"/*.yaml "$root"/*.yml 2>/dev/null || true
	fi
done | awk '{
	# "image: foo" and "- image: foo" alike. \047 is the single quote, which
	# cannot appear literally inside this single-quoted program.
	for (i = 1; i < NF; i++)
		if ($i == "image:") {
			gsub(/["\047]/, "", $(i + 1))
			if ($(i + 1) != "" && $(i + 1) != "null")
				print $(i + 1)
		}
}' | sort -u
