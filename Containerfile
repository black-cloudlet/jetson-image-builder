# Derived bootc image for the Jetson AGX Orin (P3737 + P3701).
# The base is Red Hat's JetPack-for-RHEL image: RHEL 9.8, kernel 5.14.0-687.42.1.el9_8,
# JetPack 6.2.2 / L4T r36.5.0, Tegra kmods, CUDA/JetPack userspace, nvidia-ctk CDI unit.
# Nothing NVIDIA-related needs to be added here.
ARG BASE=quay.io/redhat-user-workloads/jetpack-for-rhel-tenant/rhel-98-bootc:6.2.2_5.14.0-687.42.1_090326003719
FROM ${BASE}

# ---------------------------------------------------------------------------
# MicroShift
#
# The RPMs live in entitlement-gated repos, so this build needs a subscribed
# host's entitlement bind-mounted in (the workflow restores it from the
# RHSM_ENTITLEMENT_TGZ_B64 secret):
#   -v /etc/pki/entitlement:/etc/pki/entitlement:ro
#   -v /etc/rhsm:/etc/rhsm:ro
#   -v /etc/yum.repos.d/redhat.repo:/etc/yum.repos.d/redhat.repo:ro
# redhat.repo is what defines the rhocp and fast-datapath repos; without it
# --enablerepo has nothing to enable.
#
# Deliberately NO `dnf upgrade`. Red Hat's own Containerfile.rhocp runs one,
# but here it could pull a kernel newer than 5.14.0-687.42.1 and the Tegra
# kmod is built against that exact build — the GPU would stop working. The
# base image pins the kernel on purpose; leave it pinned.
#
# --enablerepo rather than `dnf config-manager --set-enabled` so the build does
# not depend on dnf-plugins-core being present in the base image.
# ---------------------------------------------------------------------------
ARG USHIFT_VER=4.20
RUN dnf install -y \
        --enablerepo="rhocp-${USHIFT_VER}-for-rhel-9-$(uname -m)-rpms" \
        --enablerepo="fast-datapath-for-rhel-9-$(uname -m)-rpms" \
        firewalld jq microshift microshift-release-info && \
    systemctl enable microshift && \
    dnf clean all

# Mandatory firewall rules (Red Hat's required set: ssh, pod CIDR, the OVN
# link-local gateway). Nothing else is opened — kubectl runs on the node
# against /var/lib/microshift/resources/kubeadmin/kubeconfig, so 6443 stays
# shut until something actually needs to reach the API from off-box.
RUN firewall-offline-cmd --zone=public --add-port=22/tcp && \
    firewall-offline-cmd --zone=trusted --add-source=10.42.0.0/16 && \
    firewall-offline-cmd --zone=trusted --add-source=169.254.169.1

# OVN images require the root filesystem subtree to be shared.
RUN printf '[Unit]\n\
Description=Make root filesystem shared\n\
Before=microshift.service\n\
ConditionVirtualization=container\n\
[Service]\n\
Type=oneshot\n\
ExecStart=/usr/bin/mount --make-rshared /\n\
[Install]\n\
WantedBy=multi-user.target\n' > /usr/lib/systemd/system/microshift-make-rshared.service && \
    systemctl enable microshift-make-rshared.service

# ---------------------------------------------------------------------------
# Embed MicroShift's container images.
#
# The nodes have no network at first boot, so etcd, kube-apiserver, OVN,
# CoreDNS, service-ca and the CSI driver have to already be on disk. Each
# image goes into its own directory under /usr/lib/containers/storage named
# for the SHA of its reference, and image-list.txt maps reference -> SHA.
#
# Verbatim from Red Hat's packaging/imagemode/Containerfile-embedded.repobase.
# ---------------------------------------------------------------------------
ENV IMAGE_STORAGE_DIR=/usr/lib/containers/storage
ENV IMAGE_LIST_FILE=${IMAGE_STORAGE_DIR}/image-list.txt

# hadolint ignore=DL4006
RUN --mount=type=secret,id=pullsecret,dst=/run/secrets/pull-secret.json \
    images="$(jq -r ".images[]" /usr/share/microshift/release/release-"$(uname -m)".json)" ; \
    mkdir -p "${IMAGE_STORAGE_DIR}" ; \
    for img in ${images} ; do \
        sha="$(echo "${img}" | sha256sum | awk '{print $1}')" ; \
        skopeo copy --all --preserve-digests \
            --authfile /run/secrets/pull-secret.json \
            "docker://${img}" "dir:$IMAGE_STORAGE_DIR/${sha}" ; \
        echo "${img},${sha}" >> "${IMAGE_LIST_FILE}" ; \
    done

# Copy the pre-loaded images into the main container storage before MicroShift
# starts. This is done rather than pointing storage.conf at an additional
# store because an image upgrade overwrites an additional store's contents.
# See https://issues.redhat.com/browse/RHEL-75827
RUN cat > /usr/bin/microshift-copy-images <<EOF
#!/bin/bash
set -eux -o pipefail
while IFS="," read -r img sha ; do
    skopeo copy --preserve-digests \
        "dir:${IMAGE_STORAGE_DIR}/\${sha}" \
        "containers-storage:\${img}"
done < "${IMAGE_LIST_FILE}"
EOF

RUN chmod 755 /usr/bin/microshift-copy-images && \
    mkdir -p /usr/lib/systemd/system/microshift.service.d

RUN cat > /usr/lib/systemd/system/microshift.service.d/microshift-copy-images.conf <<EOF
[Service]
ExecStartPre=/usr/bin/microshift-copy-images
EOF

# Next layers (device plugin, bound app images) go here.

RUN bootc container lint
