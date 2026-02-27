#!/bin/bash
# generate-nvidia-cdi.sh — Generate NVIDIA CDI specs for the container runtime
#
# The NVIDIA device plugin in CDI mode requires CDI specs at /etc/cdi/nvidia.yaml
# so that CRI-O can expose GPUs to containers. This is necessary for integrated
# GPUs (e.g. NVIDIA GB10 / DGX Spark) where NVML cannot enumerate device memory.
#
# Runs on every boot before MicroShift to ensure specs are up to date.
set -euo pipefail

CDI_OUTPUT="/etc/cdi/nvidia.yaml"

# Skip if nvidia-ctk is not available (non-GPU node)
if ! command -v nvidia-ctk &>/dev/null; then
    echo "nvidia-ctk not found, skipping CDI generation"
    exit 0
fi

# Skip if no NVIDIA GPU is detected
if ! nvidia-smi &>/dev/null; then
    echo "No NVIDIA GPU detected, skipping CDI generation"
    exit 0
fi

mkdir -p /etc/cdi
nvidia-ctk cdi generate --output="${CDI_OUTPUT}"
echo "NVIDIA CDI specs generated at ${CDI_OUTPUT}"
