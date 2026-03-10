#!/bin/bash
# setup-gpu-operator.sh — Install the NVIDIA GPU Operator on MicroShift
#
# Installs the GPU Operator via Helm with driver and toolkit disabled,
# since DGX Spark (and similar systems) ship with pre-installed NVIDIA
# drivers and the NVIDIA Container Toolkit.
#
# The operator manages the device plugin, CDI specs, and GPU feature
# discovery automatically.
#
# Usage:
#   sudo setup-gpu-operator.sh
#
# Can be re-run safely (helm upgrade --install is idempotent).
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
err()   { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

NAMESPACE="gpu-operator"
OPERATOR_VERSION="v25.10.1"

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisites
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v helm &>/dev/null; then
    err "helm is not installed. Install it first:
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
fi

if ! nvidia-smi &>/dev/null; then
    err "No NVIDIA GPU detected. This script requires pre-installed NVIDIA drivers."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Configure CRI-O for NVIDIA runtime (required before operator install)
# ─────────────────────────────────────────────────────────────────────────────
if command -v nvidia-ctk &>/dev/null; then
    info "Configuring CRI-O with NVIDIA runtime..."
    nvidia-ctk runtime configure --runtime=crio --cdi.enabled
    systemctl restart crio 2>/dev/null || true
    ok "CRI-O configured"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Generate CDI specs
# ─────────────────────────────────────────────────────────────────────────────
if command -v nvidia-ctk &>/dev/null; then
    info "Generating NVIDIA CDI specs..."
    mkdir -p /etc/cdi
    nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
    ok "CDI specs generated at /etc/cdi/nvidia.yaml"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Pre-create namespace and grant OpenShift SCCs
# ─────────────────────────────────────────────────────────────────────────────
# MicroShift enforces OpenShift Security Context Constraints. The GPU Operator
# pods need privileged access (hostPath volumes, device access). We create the
# namespace and grant the privileged SCC to all operator service accounts
# BEFORE helm install so pods can schedule immediately.
info "Setting up namespace and security context constraints..."
kubectl create namespace "${NAMESPACE}" 2>/dev/null || true

GPU_OPERATOR_SERVICE_ACCOUNTS=(
    gpu-operator
    node-feature-discovery
    nvidia-device-plugin
    nvidia-device-plugin-mps-control-daemon
    nvidia-dcgm-exporter
    nvidia-gpu-feature-discovery
    nvidia-mig-manager
    nvidia-operator-validator
)

for sa in "${GPU_OPERATOR_SERVICE_ACCOUNTS[@]}"; do
    oc adm policy add-scc-to-user privileged \
        -n "${NAMESPACE}" -z "${sa}" 2>/dev/null || true
done
ok "Privileged SCC granted to GPU Operator service accounts"

# ─────────────────────────────────────────────────────────────────────────────
# Install GPU Operator
# ─────────────────────────────────────────────────────────────────────────────
info "Adding NVIDIA Helm repo..."
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
helm repo update nvidia

info "Installing NVIDIA GPU Operator ${OPERATOR_VERSION}..."
helm upgrade --install gpu-operator \
    -n "${NAMESPACE}" \
    nvidia/gpu-operator \
    --version="${OPERATOR_VERSION}" \
    --set driver.enabled=false \
    --set toolkit.enabled=false \
    --wait --timeout 10m

ok "GPU Operator installed"

# ─────────────────────────────────────────────────────────────────────────────
# Verify
# ─────────────────────────────────────────────────────────────────────────────
info "Waiting for GPU resources to be advertised..."
for i in $(seq 1 60); do
    GPU_COUNT=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "")
    if [[ -n "${GPU_COUNT}" && "${GPU_COUNT}" != "0" ]]; then
        ok "GPU advertised: nvidia.com/gpu=${GPU_COUNT}"
        echo ""
        echo "GPU Operator is ready. The vllm-slm pod should now be scheduled."
        echo "  kubectl -n vllm-slm get pods -w"
        exit 0
    fi
    sleep 5
done

echo ""
echo "GPU not yet advertised. Check operator status:"
echo "  kubectl -n ${NAMESPACE} get pods"
echo "  kubectl -n ${NAMESPACE} logs -l app=nvidia-device-plugin-daemonset"
