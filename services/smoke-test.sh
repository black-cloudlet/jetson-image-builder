#!/bin/bash
# Checks run inside the services image before it is pushed. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < services/smoke-test.sh
#
# Three jobs: what this layer added is there, the cluster underneath it still
# is — this layer's only real risk is breaking what it is stacked on — and the
# manifests still say what they were patched to say. The last one matters most:
# MicroShift renders these roots itself at start-up, so a root that does not
# render is a component that is silently never applied, on a node nobody can
# ssh into.
set -euo pipefail

echo "== microshift underneath =="
rpm -q microshift openshift-clients
for unit in microshift microshift-make-rshared copy-embedded-images; do
	test -L "/etc/systemd/system/multi-user.target.wants/${unit}.service" \
		|| { echo "not enabled: ${unit}.service"; exit 1; }
done

echo "== service manifest roots =="
mapfile -t roots < <(find /etc/microshift/manifests.d -maxdepth 1 -mindepth 1 \
	-type d 2>/dev/null | sort)
if [[ ${#roots[@]} -eq 0 ]]; then
	echo "no service manifest roots under /etc/microshift/manifests.d"
	exit 1
fi
printf '   %s\n' "${roots[@]}"

# The two upstream installs are curl'd at build time and are not in git, so
# they are the first thing to go missing when a release moves its assets.
for f in /etc/microshift/manifests.d/010-cert-manager/cert-manager.yaml \
	/etc/microshift/manifests.d/020-external-secrets/external-secrets.yaml; do
	test -s "$f" || {
		echo "missing or empty: ${f}"
		ls -la "$(dirname "$f")" | sed 's/^/   /'
		exit 1
	}
	echo "   curl'd: ${f} ($(wc -c < "$f") bytes)"
done

echo "== renders =="
# oc's kustomize is the closest thing in the image to the one MicroShift links
# into its own binary. It is also older than the standalone tool, which is why
# no patch file here holds more than one document.
render=$(mktemp -d)
for root in "${roots[@]}"; do
	out="${render}/$(basename "$root").yaml"
	oc kustomize "$root" > "$out" || { echo "does not render: ${root}"; exit 1; }
	echo "   $(basename "$root"): $(wc -l < "$out") lines"
done

echo "== workloads =="
# kustomize fails the build on a patch that matches nothing, so a rename
# upstream cannot slip through silently — but a workload upstream *adds* can,
# and it would arrive with no resources and, in 020, with the runAsUser that
# restricted-v2 refuses. Name the set both roots may contain; anything else has
# to be looked at before it ships.
workloads_in() {
	awk '/^kind: (Deployment|DaemonSet|StatefulSet)$/ { k = $2 }
		k && /^  name: / { print k "/" $2; k = "" }' "$1" | sort
}
expect_workloads() {
	label=$1 file=$2 want=$3
	got=$(workloads_in "$file")
	if [[ $got != "$want" ]]; then
		echo "unexpected workloads in the ${label} render:"
		echo "$got" | sed 's/^/   /'
		echo "expected:"
		echo "$want" | sed 's/^/   /'
		exit 1
	fi
	echo "   ${label}: $(wc -l <<< "$got") workloads, as expected"
}
expect_workloads 010-cert-manager "${render}/010-cert-manager.yaml" \
"Deployment/cert-manager
Deployment/cert-manager-cainjector
Deployment/cert-manager-webhook"
expect_workloads 020-external-secrets "${render}/020-external-secrets.yaml" \
"Deployment/external-secrets
Deployment/external-secrets-cert-controller
Deployment/external-secrets-webhook"

echo "== external secrets is out of the default namespace =="
eso="${render}/020-external-secrets.yaml"
# Upstream pins the whole install to `default`: ten namespaced objects, the
# ServiceAccount subjects of two ClusterRoleBindings and a RoleBinding, the
# clientConfig of two ValidatingWebhookConfigurations, and three container
# arguments. The kustomization moves the first groups with a namespace
# transformer and the arguments with two JSON patches. Checked here on the
# render, not on the patch files: the transformer is whichever kustomize is
# linked into the renderer, and a field spec a version does not carry is a
# silent no-op rather than an error.
if ! awk 'BEGIN { RS = "\n---\n" }
	/(^|\n)kind: Namespace(\n|$)/ && /\n  name: external-secrets(\n|$)/ { found = 1 }
	END { exit !found }' "$eso"; then
	echo "the render creates no external-secrets namespace"
	echo "nothing else in the root can be applied without it"
	exit 1
fi
echo "   Namespace/external-secrets is in the render"
# Whole CRD documents are skipped: their schemas are full of `default:` keys
# describing fields, none of which is a namespace. Everything else should have
# stopped saying `default` in any spelling — metadata, a subject, a webhook
# clientConfig, a service DNS name inside an argument. Case-sensitive, so
# seccompProfile: RuntimeDefault is not a false alarm.
stale=$(awk 'BEGIN { RS = "\n---\n" }
	/(^|\n)kind: CustomResourceDefinition(\n|$)/ { next }
	{ n = split($0, line, "\n")
	  for (i = 1; i <= n; i++) if (line[i] ~ /default/) print line[i] }' "$eso")
if [[ -n $stale ]]; then
	echo "the render still points at the default namespace:"
	echo "$stale" | sed 's/^/   /'
	exit 1
fi
echo "   nothing outside the CRDs names the default namespace"

echo "== external secrets runs as an SCC-assigned uid =="
# Upstream pins runAsUser: 1000 on all three. restricted-v2 assigns a UID out
# of the namespace's openshift.io/sa.scc.uid-range instead and rejects a pod
# that names its own, so the Deployments would be admitted and every pod they
# create refused. The patches delete the field with an explicit null, which is
# invisible in the patch file if it stops matching — kustomize would fail the
# build on that, but not on upstream adding the field somewhere new.
if grep -n 'runAsUser:' "$eso"; then
	echo "the render still pins a UID; restricted-v2 will refuse those pods"
	exit 1
fi
echo "   no runAsUser in the render"
# Deleting runAsUser must not have taken runAsNonRoot with it: without it the
# SCC is the only thing between this and a root container.
nonroot=$(grep -c 'runAsNonRoot: true' "$eso" || true)
if [[ $nonroot -lt 3 ]]; then
	echo "runAsNonRoot: true on ${nonroot} containers, expected at least 3"
	exit 1
fi
echo "   runAsNonRoot: true x${nonroot}"

echo "== requests and limits =="
# Upstream ships almost none of these, so every pod would be BestEffort and the
# first thing evicted under pressure. The ratios are the house rule: memory
# request equals limit, CPU limit is four times the request. Checked by
# arithmetic rather than by grepping the numbers, so editing a patch cannot
# quietly break the ratio, and a container upstream adds without resources at
# all is caught as well.
check_resources() {
	label=$1 file=$2
	awk -v label="$label" '
		function indent(s,   n) { match(s, /^ */); return RLENGTH }
		function cpu(v) { return (v ~ /m$/) ? substr(v, 1, length(v) - 1) + 0 : v * 1000 }
		function fail(msg) { print label ": " dname "/" cname ": " msg; bad = 1 }
		function check() {
			if (rq_cpu == "" || lm_cpu == "" || rq_mem == "" || lm_mem == "") {
				fail("resources: is missing a cpu or memory request or limit")
				return
			}
			if (rq_mem != lm_mem)
				fail("memory " rq_mem " -> " lm_mem ", want request == limit")
			if (cpu(lm_cpu) != 4 * cpu(rq_cpu))
				fail("cpu " rq_cpu " -> " lm_cpu ", want limit == 4x request")
		}
		/^---$/ { kind = ""; dname = ""; inlist = 0; next }
		/^kind: / { kind = $2; next }
		kind !~ /^(Deployment|DaemonSet|StatefulSet)$/ { next }
		/^  name: / && dname == "" { dname = $2 }
		# Container list items sit at the same indent as the key itself.
		/^ *(containers|initContainers):$/ { clen = indent($0); inlist = 1; next }
		inlist && indent($0) == clen && substr($0, clen + 1, 2) == "- " { containers++ }
		# A sibling key at the same indent ends the list: volumes: also holds
		# `- name:` items, and counting those as containers is a false alarm.
		inlist && indent($0) <= clen { inlist = 0 }
		# resources: block, read by indentation rather than by depth.
		inres && indent($0) <= rlen { check(); inres = 0 }
		inres {
			if ($1 == "limits:") sect = "lm"
			else if ($1 == "requests:") sect = "rq"
			else if ($1 == "cpu:") { if (sect == "lm") lm_cpu = $2; else rq_cpu = $2 }
			else if ($1 == "memory:") { if (sect == "lm") lm_mem = $2; else rq_mem = $2 }
			next
		}
		# Only a name at the container-key indent: ports and volumeMounts carry
		# names too, and ports sorts before resources, so the last one seen would
		# otherwise be a port name in the failure message. (No apostrophes in
		# here: the whole program is one single-quoted shell word.)
		/^ *name: / && indent($0) == clen + 2 { cname = $2 }
		/^ *resources:$/ {
			rlen = indent($0); inres = 1; blocks++
			rq_cpu = lm_cpu = rq_mem = lm_mem = ""; sect = ""
		}
		END {
			if (inres) check()
			if (containers != blocks) {
				print label ": " containers " containers but " blocks \
					" resources: blocks — one of them is unconstrained"
				bad = 1
			}
			if (bad) exit 1
			print "   " label ": " containers " containers, memory 1:1, cpu 1:4"
		}
	' "$file" || exit 1
}
for root in "${roots[@]}"; do
	check_resources "$(basename "$root")" "${render}/$(basename "$root").yaml"
done

echo "== images the manifests name =="
# A manifest naming an image SERVICE_IMAGES does not means ImagePullBackOff on
# a node with no registry. Check the scanner exists first: process substitution
# that fails leaves the loop reading nothing and this section passing blind.
scan=/opt/microshift/manifest-images.sh
if [[ ! -x $scan ]]; then
	echo "missing: $scan — it comes from the microshift layer below"
	ls -la /opt/microshift 2>&1 | sed 's/^/   /'
	exit 1
fi
images=$("$scan" "${roots[@]}")
if [[ -z $images ]]; then
	echo "the manifest roots name no images at all"
	exit 1
fi

# embed_image.sh keys the cache on `echo "$ref" | sha256sum`, newline included.
while read -r img; do
	# CRI-O resolves a short name against unqualified-search-registries
	# (registry.access.redhat.com first, docker.io last) rather than looking
	# in the local store first, so an unqualified reference is a pull attempt
	# on a node that has no network. Both upstreams qualify their own images
	# today; this is what notices if one stops.
	host=${img%%/*}
	if [[ $host != *.* && $host != *:* ]]; then
		echo "unqualified image reference: ${img}"
		echo "give it a registry host, or the node will try to pull it"
		exit 1
	fi
	fsha="$(echo "$img" | sha256sum | awk '{ print $1 }')"
	if [[ ! -f /usr/lib/containers-image-cache/${fsha}/manifest.json ]]; then
		echo "a manifest names ${img}, which is not embedded"
		echo "the build embeds what this same scan prints; check its log"
		exit 1
	fi
	echo "   embedded: ${img}"
done <<< "$images"

echo "== embedded images =="
# Cumulative: the control plane and device plugin came from the layer below.
mapping=/usr/lib/containers-image-cache/mapping.txt
if [[ ! -s $mapping ]]; then
	echo "no mapping at $mapping; the microshift layer should have written one"
	ls -la /usr/lib/containers-image-cache 2>&1 | sed 's/^/   /'
	exit 1
fi
echo "embedded: $(wc -l < "$mapping") images"
while IFS=, read -r img sha; do
	test -f "/usr/lib/containers-image-cache/${sha}/manifest.json" \
		|| { echo "missing embedded image: ${img}"; exit 1; }
done < "$mapping"
# Printed, not asserted: the cache is copied into containers-storage at first
# boot, so every embedded image is paid for twice on a 40 GiB root. The number
# belongs in the log — it is the first thing to look at when a build stops
# fitting.
du -sh /usr/lib/containers-image-cache

echo "all checks passed"
