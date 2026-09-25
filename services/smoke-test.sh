#!/bin/bash
# Checks run inside the services image before it is pushed. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < services/smoke-test.sh
#
# What matters here is that the manifests still say what they were patched to
# say. MicroShift renders these roots itself at start-up, so a root that does
# not render is a component that is silently never applied, on a node nobody
# can ssh into. The layers below were checked by their own tests, and a curl or
# COPY that failed would have failed the build.
set -euo pipefail

fail() { echo "$*"; exit 1; }

echo "== renders =="
# oc's kustomize is the closest thing in the image to the one MicroShift links
# into its own binary. It is also older than the standalone tool, which is why
# no patch file here holds more than one document. `oc patch --local` with an
# empty patch never contacts a server; it parses the render and prints it back
# as JSON, which jq can then query.
render=$(mktemp -d)
roots=(/etc/microshift/manifests.d/*/)
for root in "${roots[@]}"; do
	name=$(basename "$root")
	oc kustomize "$root" | oc patch --local -f - --type=merge -p '{}' -o json |
		jq -s . > "$render/$name.json" || fail "does not render: $root"
	echo "   $name: $(jq length "$render/$name.json") objects"
done

# Prefixed to the jq programs below: every workload object in a render.
W='def workloads: .[] | select(.kind | test("^(Deployment|DaemonSet|StatefulSet)$"));'

echo "== workloads =="
# kustomize fails the build on a patch that matches nothing, so a rename
# upstream cannot slip through silently — but a workload upstream *adds* can,
# and it would arrive with no resources and, in 020, with the runAsUser that
# restricted-v2 refuses. Name the set both roots may contain; anything else has
# to be looked at before it ships.
expect_workloads() {
	name=$1 want=$2
	got=$(jq -r "$W"' workloads | "\(.kind)/\(.metadata.name)"' "$render/$name.json" | sort)
	if [[ $got != "$want" ]]; then
		echo "unexpected workloads in the $name render:"
		echo "$got" | sed 's/^/   /'
		echo "expected:"
		echo "$want" | sed 's/^/   /'
		exit 1
	fi
	echo "   $name: $(wc -l <<< "$got") workloads, as expected"
}
expect_workloads 010-cert-manager \
"Deployment/cert-manager
Deployment/cert-manager-cainjector
Deployment/cert-manager-webhook"
expect_workloads 020-external-secrets \
"Deployment/external-secrets
Deployment/external-secrets-cert-controller
Deployment/external-secrets-webhook"

eso=$render/020-external-secrets.json

echo "== external secrets is out of the default namespace =="
# Checked on the render, not the patches: which fields the namespace
# transformer reaches depends on the kustomize version, and one it misses is a
# silent no-op.
jq -e 'any(.[]; .kind == "Namespace" and .metadata.name == "external-secrets")' \
	"$eso" >/dev/null \
	|| fail "the render creates no external-secrets namespace;" \
		"nothing else in the root can be applied without it"
echo "   Namespace/external-secrets is in the render"
# Every string value outside the CRDs, whose schemas are full of the word:
# metadata, a subject, a webhook clientConfig, a service DNS name inside an
# argument. Case-sensitive, so RuntimeDefault is not a false alarm.
stale=$(jq -r '.[] | select(.kind != "CustomResourceDefinition")
	| "\(.kind)/\(.metadata.name)" as $obj
	| paths(strings) as $p | getpath($p) | select(test("default"))
	| "\($obj) \($p | map(tostring) | join(".")): \(.)"' "$eso")
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
pinned=$(jq -r "$W"' workloads | select([.. | objects | has("runAsUser")] | any)
	| "\(.kind)/\(.metadata.name)"' "$eso")
[[ -z $pinned ]] || fail "still pins a UID, which restricted-v2 will refuse:" $pinned
echo "   no runAsUser in the render"
# Deleting runAsUser must not have taken runAsNonRoot with it: without it the
# SCC is the only thing between this and a root container. Per container,
# falling back to the pod, the way the kubelet reads it.
rootable=$(jq -r "$W"' workloads | .metadata.name as $w | .spec.template.spec
	| .securityContext.runAsNonRoot as $pod
	| (.containers + (.initContainers // []))[]
	| select((.securityContext.runAsNonRoot // $pod) != true) | "\($w)/\(.name)"' "$eso")
[[ -z $rootable ]] || fail "runAsNonRoot is not true on:" $rootable
echo "   runAsNonRoot: true on every container"

echo "== requests and limits =="
# Upstream ships almost none of these, so every pod would be BestEffort and the
# first thing evicted under pressure. The ratios are the house rule: memory
# request equals limit, CPU limit is four times the request. Checked by
# arithmetic rather than by grepping the numbers, so editing a patch cannot
# quietly break the ratio, and a container upstream adds without resources at
# all is caught as well.
for root in "${roots[@]}"; do
	name=$(basename "$root")
	out=$(jq -r "$W"'
		def cpu: tostring | if endswith("m") then .[:-1] | tonumber else tonumber * 1000 end;
		workloads | .metadata.name as $w
		| (.spec.template.spec | .containers + (.initContainers // []))[]
		| .resources as $r | "\($w)/\(.name): " +
		if [$r.requests.cpu, $r.limits.cpu, $r.requests.memory, $r.limits.memory]
			| any(. == null) then
			"is missing a cpu or memory request or limit"
		elif ($r.requests.memory | tostring) != ($r.limits.memory | tostring) then
			"memory \($r.requests.memory) -> \($r.limits.memory), want request == limit"
		elif ($r.limits.cpu | cpu) != 4 * ($r.requests.cpu | cpu) then
			"cpu \($r.requests.cpu) -> \($r.limits.cpu), want limit == 4x request"
		else "ok" end' "$render/$name.json")
	if grep -v ': ok$' <<<"$out" | sed "s|^|$name: |" | grep .; then
		exit 1
	fi
	echo "   $name: $(wc -l <<<"$out") containers, memory 1:1, cpu 1:4"
done

echo "== images the manifests name =="
# A manifest naming an image that was not embedded means ImagePullBackOff on a
# node with no registry. Captured first: a scan that fails inside `< <(...)`
# leaves the loop reading nothing and passing.
images=$(/opt/microshift/manifest-images.sh "${roots[@]}") \
	|| fail "/opt/microshift/manifest-images.sh failed"
[[ -n $images ]] || fail "the manifest roots name no images at all"

cache=/usr/lib/containers-image-cache
# embed_image.sh keys the cache on `echo "$ref" | sha256sum`, newline included.
while read -r img; do
	# CRI-O resolves a short name against unqualified-search-registries
	# (registry.access.redhat.com first, docker.io last) rather than looking
	# in the local store first, so an unqualified reference is a pull attempt
	# on a node that has no network. Both upstreams qualify their own images
	# today; this is what notices if one stops. With no slash at all there is
	# no host, only a name and its tag.
	host=${img%%/*}
	[[ $img == */* && ( $host == *.* || $host == *:* ) ]] \
		|| fail "unqualified image reference: $img;" \
			"give it a registry host, or the node will try to pull it"
	fsha=$(echo "$img" | sha256sum | awk '{ print $1 }')
	[[ -f $cache/$fsha/manifest.json ]] \
		|| fail "a manifest names $img, which is not embedded;" \
			"the build embeds what this same scan prints, check its log"
	echo "   embedded: $img"
done <<< "$images"

# Printed, not asserted: the cache is copied into containers-storage at first
# boot, so every embedded image is paid for twice on a 40 GiB root. The number
# belongs in the log — it is the first thing to look at when a build stops
# fitting.
echo "embedded: $(wc -l < "$cache/mapping.txt") images"
du -sh "$cache"

echo "all checks passed"
