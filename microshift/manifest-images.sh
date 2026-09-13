#!/bin/bash
# Print, one per line, every container image referenced by the MicroShift
# manifest roots given as arguments. Build time: it says what has to be embedded
# for a node that will never reach a registry. Smoke test: it says whether that
# actually happened.
#
# Rendering with kustomize rather than grepping the files is the point. A root
# whose kustomization.yaml carries an `images:` transformer names the image it
# will really pull nowhere in its resources, and an optional MicroShift RPM ships
# whatever layout its own team chose. MicroShift renders these same roots at
# start-up, so this sees exactly what the cluster will ask for.
set -euo pipefail

for root in "$@"; do
	# Unmatched globs arrive as literals; a root the caller guessed at may not
	# exist. Neither is an error — the caller passes every path MicroShift reads.
	[ -d "$root" ] || continue

	if [ -f "$root/kustomization.yaml" ] || [ -f "$root/kustomization.yml" ] ||
		[ -f "$root/Kustomization" ]; then
		oc kustomize "$root"
	else
		# MicroShift also accepts a directory of plain manifests.
		cat "$root"/*.yaml "$root"/*.yml 2>/dev/null || true
	fi
done | awk '{
	# "image: foo" and "- image: foo" alike; \047 is the single quote, which
	# cannot be written literally inside this single-quoted program.
	for (i = 1; i < NF; i++)
		if ($i == "image:") {
			gsub(/["\047]/, "", $(i + 1))
			if ($(i + 1) != "" && $(i + 1) != "null")
				print $(i + 1)
		}
}' | sort -u
