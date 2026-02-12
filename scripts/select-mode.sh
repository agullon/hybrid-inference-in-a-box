#!/bin/bash
# select-mode.sh — Switch between full and slim deployment modes
#
# Updates the Kustomize entry point to select the appropriate overlay.
# Requires a MicroShift restart to take effect.
#
# Usage:
#   select-mode.sh full    # Dashboard + Grafana + Prometheus + API
#   select-mode.sh slim    # API only (lower resource usage)

set -euo pipefail

MANIFEST_DIR="/usr/lib/microshift/manifests/semantic-router"

MODE="${1:-}"

if [[ -z "${MODE}" ]]; then
    echo "Usage: $0 [full|slim]"
    echo ""
    echo "Modes:"
    echo "  full  — vllm-sr all-in-one: API + Dashboard + Grafana + Prometheus"
    echo "          Requires ~25GB disk, ~4GB RAM"
    echo "  slim  — extproc + Envoy sidecar: API only"
    echo "          Requires ~5GB disk, ~2GB RAM"
    echo ""
    # Show current mode
    if [[ -f "${MANIFEST_DIR}/kustomization.yaml" ]]; then
        CURRENT=$(grep -oP 'overlays/\K(full|slim)' "${MANIFEST_DIR}/kustomization.yaml" 2>/dev/null || echo "unknown")
        echo "Current mode: ${CURRENT}"
    fi
    exit 1
fi

if [[ "${MODE}" != "full" && "${MODE}" != "slim" ]]; then
    echo "Error: Mode must be 'full' or 'slim', got '${MODE}'"
    exit 1
fi

if [[ ! -d "${MANIFEST_DIR}" ]]; then
    echo "Error: Manifest directory not found: ${MANIFEST_DIR}"
    exit 1
fi

cat > "${MANIFEST_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - overlays/${MODE}
EOF

echo "Mode set to: ${MODE}"
echo ""
echo "Next steps:"
echo "  1. Restart MicroShift to apply the new manifests:"
echo "     sudo systemctl restart microshift"
echo "  2. Wait for MicroShift to restart (~30s)"
echo "  3. Run configure-router.sh to create the configuration:"
echo "     sudo configure-router.sh --endpoint <url> --api-key <key> \\"
echo "       --model-coding <name> --model-general <name>"
