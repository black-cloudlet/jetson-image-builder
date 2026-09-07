# Derived bootc image for the Jetson AGX Orin (P3737 + P3701).
# The base is Red Hat's JetPack-for-RHEL image: RHEL 9.8, kernel 5.14.0-687.42.1.el9_8,
# JetPack 6.2.2 / L4T r36.5.0, Tegra kmods, CUDA/JetPack userspace, nvidia-ctk CDI unit.
# Nothing NVIDIA-related needs to be added here.
ARG BASE=quay.io/redhat-user-workloads/jetpack-for-rhel-tenant/rhel-98-bootc:6.2.2_5.14.0-687.42.1_090326003719
FROM ${BASE}

# ---------------------------------------------------------------------------
# MicroShift
#
# The RPMs live in entitlement-gated repos. The build therefore has to run on a
# subscribed host: the workflow runs it inside a UBI container that has done
# `subscription-manager register`, which writes the entitlement certificates and
# the /etc/yum.repos.d/redhat.repo that defines the rhocp and fast-datapath
# repos. Without that registration --enablerepo has nothing to enable.
# For a local build on a registered RHEL host, podman injects the entitlement by
# itself and this just works.
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
# NVIDIA device plugin
#
# CRI-O has to know about the NVIDIA runtime before a pod can ask for a GPU.
# The plugin itself is dropped into /etc/microshift/manifests, which MicroShift
# applies through kustomize on first start.
# ---------------------------------------------------------------------------
ARG NVIDIA_DEVICE_PLUGIN_VER=v0.17.1

RUN nvidia-ctk runtime configure --runtime=crio --set-as-default \
        --config=/etc/crio/crio.conf.d/99-nvidia.conf

RUN mkdir -p /etc/microshift/manifests && \
    curl -fsSL -o /etc/microshift/manifests/nvidia-device-plugin.yml \
      "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VER}/deployments/static/nvidia-device-plugin.yml"

RUN printf 'apiVersion: kustomize.config.k8s.io/v1beta1\n\
kind: Kustomization\n\
resources:\n\
  - nvidia-device-plugin.yml\n' > /etc/microshift/manifests/kustomization.yaml

# ---------------------------------------------------------------------------
# Physically bound images
#
# The nodes have no network at first boot, so every image the cluster needs has
# to already be on disk: MicroShift's own control plane (etcd, kube-apiserver,
# OVN, CoreDNS, service-ca, CSI) plus the device plugin referenced by the
# manifest above.
#
# The cache lives in /usr/lib/containers-image-cache and is replayed into
# containers-storage once per boot by copy-embedded-images.service. Red Hat's
# own image-mode recipe instead uses ExecStartPre= on microshift.service; a
# standalone oneshot is used here so the copy happens once per boot rather than
# on every MicroShift restart, and so later app images share one mechanism.
# Approach and scripts from redhat-et/edge-ai-image-pipelines (Apache-2.0).
# ---------------------------------------------------------------------------
COPY --chmod=0555 physically-bound-images/embed_image.sh \
      /opt/physically-bound-images/embed_image.sh
COPY --chmod=0555 physically-bound-images/copy_embedded_images.sh \
      /opt/physically-bound-images/copy_embedded_images.sh

# No network-online dependency: the copy reads local disk only, and waiting for
# a carrier that is never coming would add NetworkManager-wait-online's timeout
# to every boot of a disconnected node.
RUN printf '[Unit]\n\
Description=Copy embedded container images into containers-storage\n\
Wants=basic.target\n\
After=basic.target local-fs.target\n\
[Service]\n\
Type=oneshot\n\
ExecStart=/opt/physically-bound-images/copy_embedded_images.sh\n\
RemainAfterExit=yes\n\
[Install]\n\
WantedBy=multi-user.target\n' > /usr/lib/systemd/system/copy-embedded-images.service && \
    systemctl enable copy-embedded-images.service

RUN mkdir -p /usr/lib/systemd/system/microshift.service.d && \
    printf '[Unit]\n\
Requires=copy-embedded-images.service\n\
After=copy-embedded-images.service\n' \
      > /usr/lib/systemd/system/microshift.service.d/microshift-copy-images.conf

RUN --mount=type=secret,id=pullsecret,dst=/run/secrets/pull-secret.json \
    images="$(jq -r '.images[]' /usr/share/microshift/release/release-"$(uname -m)".json)" ; \
    images="${images} $(awk '{for(i=1;i<NF;i++) if($i=="image:"){gsub(/"/,"",$(i+1)); print $(i+1)}}' \
        /etc/microshift/manifests/nvidia-device-plugin.yml | sort -u)" ; \
    for img in ${images} ; do \
        /opt/physically-bound-images/embed_image.sh "${img}" \
            --authfile /run/secrets/pull-secret.json ; \
    done

# Next layers (bound app images: PostgreSQL, RabbitMQ, KServe, the model
# server) go here — same embed_image.sh, same cache, same boot-time replay.

RUN bootc container lint
