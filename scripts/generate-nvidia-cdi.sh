#!/bin/bash
# generate-nvidia-cdi.sh — Configure NVIDIA runtime and generate CDI specs
#
# Sets up the full NVIDIA GPU stack for CRI-O:
#   1. Configures CRI-O to use the NVIDIA container runtime hook
#   2. Generates CDI specs at /etc/cdi/nvidia.yaml
#
# Required for GPUs like the GB10 (DGX Spark) where NVML cannot enumerate
# device memory, so CDI-based device injection is used instead.
#
# Runs on every boot before MicroShift to ensure config is up to date.
set -euo pipefail

CDI_OUTPUT="/etc/cdi/nvidia.yaml"

# Skip if nvidia-ctk is not available (non-GPU node)
if ! command -v nvidia-ctk &>/dev/null; then
    echo "nvidia-ctk not found, skipping NVIDIA runtime setup"
    exit 0
fi

# Skip if no NVIDIA GPU is detected
if ! nvidia-smi &>/dev/null; then
    echo "No NVIDIA GPU detected, skipping NVIDIA runtime setup"
    exit 0
fi

# Configure CRI-O to use the NVIDIA container runtime with CDI enabled
nvidia-ctk runtime configure --runtime=crio --cdi.enabled
echo "CRI-O configured with NVIDIA runtime"

# Generate CDI specs so CRI-O can inject GPU devices into containers
mkdir -p /etc/cdi
nvidia-ctk cdi generate --output="${CDI_OUTPUT}"
echo "NVIDIA CDI specs generated at ${CDI_OUTPUT}"
