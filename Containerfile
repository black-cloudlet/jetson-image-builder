# Derived bootc image for the Jetson AGX Orin (P3737 + P3701).
# The base is Red Hat's JetPack-for-RHEL image: RHEL 9.8, kernel 5.14.0-687.42.1.el9_8,
# JetPack 6.2.2 / L4T r36.5.0, Tegra kmods, CUDA/JetPack userspace, nvidia-ctk CDI unit.
# Nothing NVIDIA-related needs to be added here.
ARG BASE=quay.io/redhat-user-workloads/jetpack-for-rhel-tenant/rhel-98-bootc:6.2.2_5.14.0-687.42.1_090326003719
FROM ${BASE}

# Next layers (k3s or MicroShift, device plugin, bound app images) go here.

RUN bootc container lint
