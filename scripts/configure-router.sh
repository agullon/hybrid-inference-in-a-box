#!/bin/bash
# configure-router.sh — Post-boot configuration for the Semantic Router
#
# Creates the Kubernetes ConfigMap(s) and Secret needed by the semantic-router
# deployment. The infrastructure manifests (Deployment, Service, etc.) are
# applied automatically by MicroShift on boot, but pods stay in
# CreateContainerConfigError until this script provides the configuration.
#
# Usage:
#   configure-router.sh --endpoint <url> --api-key <key> \
#                        --model-coding <name> --model-general <name>
#
#   Or run without args for interactive prompts.
#
# Can be re-run at any time to update configuration.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Defaults
# ─────────────────────────────────────────────────────────────────────────────
NAMESPACE="semantic-router"
KUBECTL="sudo kubectl"
TEMPLATE_DIR="/etc/semantic-router/templates"
MANIFEST_DIR="/usr/lib/microshift/manifests/semantic-router"
DASHBOARD_JSON="/etc/semantic-router/llm-router-dashboard.json"

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────────────────────────────────────
LITELLM_ENDPOINT=""
LITELLM_API_KEY=""
MODEL_CODING=""
MODEL_GENERAL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --endpoint)     LITELLM_ENDPOINT="$2";  shift 2 ;;
        --api-key)      LITELLM_API_KEY="$2";   shift 2 ;;
        --model-coding) MODEL_CODING="$2";      shift 2 ;;
        --model-general) MODEL_GENERAL="$2";    shift 2 ;;
        --help|-h)
            echo "Usage: $0 --endpoint <url> --api-key <key> --model-coding <name> --model-general <name>"
            echo ""
            echo "Options:"
            echo "  --endpoint       LiteLLM gateway hostname (e.g., litellm.example.com)"
            echo "  --api-key        LiteLLM API key (e.g., sk-...)"
            echo "  --model-coding   Model name for coding/engineering queries"
            echo "  --model-general  Model name for general queries (also used as default)"
            echo ""
            echo "If options are not provided, interactive prompts will be shown."
            exit 0
            ;;
        *)
            err "Unknown argument: $1. Use --help for usage."
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Interactive prompts for missing values
# ─────────────────────────────────────────────────────────────────────────────
if [[ -z "${LITELLM_ENDPOINT}" ]]; then
    read -rp "LiteLLM endpoint hostname (e.g., litellm.example.com): " LITELLM_ENDPOINT
fi
if [[ -z "${LITELLM_API_KEY}" ]]; then
    read -rsp "LiteLLM API key: " LITELLM_API_KEY
    echo ""
fi
if [[ -z "${MODEL_CODING}" ]]; then
    read -rp "Model for coding queries (e.g., Mistral-Small-24B-W8A8): " MODEL_CODING
fi
if [[ -z "${MODEL_GENERAL}" ]]; then
    read -rp "Model for general queries (e.g., Granite-3.3-8B-Instruct): " MODEL_GENERAL
fi

# Validate required values
[[ -z "${LITELLM_ENDPOINT}" ]] && err "LiteLLM endpoint is required"
[[ -z "${LITELLM_API_KEY}" ]]  && err "LiteLLM API key is required"
[[ -z "${MODEL_CODING}" ]]     && err "Coding model name is required"
[[ -z "${MODEL_GENERAL}" ]]    && err "General model name is required"

# Strip protocol prefix if provided (we only need the hostname)
LITELLM_ENDPOINT="${LITELLM_ENDPOINT#https://}"
LITELLM_ENDPOINT="${LITELLM_ENDPOINT#http://}"
# Strip trailing slash
LITELLM_ENDPOINT="${LITELLM_ENDPOINT%/}"

# ─────────────────────────────────────────────────────────────────────────────
# Detect current mode
# ─────────────────────────────────────────────────────────────────────────────
MODE="full"
if [[ -f "${MANIFEST_DIR}/kustomization.yaml" ]]; then
    if grep -q "overlays/slim" "${MANIFEST_DIR}/kustomization.yaml" 2>/dev/null; then
        MODE="slim"
    fi
fi
info "Detected mode: ${MODE}"

# ─────────────────────────────────────────────────────────────────────────────
# Ensure namespace exists
# ─────────────────────────────────────────────────────────────────────────────
if ! ${KUBECTL} get namespace "${NAMESPACE}" &>/dev/null; then
    info "Creating namespace ${NAMESPACE}..."
    ${KUBECTL} create namespace "${NAMESPACE}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Render templates and create ConfigMaps
# ─────────────────────────────────────────────────────────────────────────────
render_template() {
    local template="$1"
    sed \
        -e "s|__LITELLM_ENDPOINT__|${LITELLM_ENDPOINT}|g" \
        -e "s|__LITELLM_API_KEY__|${LITELLM_API_KEY}|g" \
        -e "s|__MODEL_CODING__|${MODEL_CODING}|g" \
        -e "s|__MODEL_GENERAL__|${MODEL_GENERAL}|g" \
        "${template}"
}

# Router config
if [[ "${MODE}" == "full" ]]; then
    TEMPLATE="${TEMPLATE_DIR}/config-full.yaml.tmpl"
else
    TEMPLATE="${TEMPLATE_DIR}/config-slim.yaml.tmpl"
fi

if [[ ! -f "${TEMPLATE}" ]]; then
    err "Template not found: ${TEMPLATE}"
fi

info "Rendering router config from ${TEMPLATE}..."
RENDERED_CONFIG=$(render_template "${TEMPLATE}")

${KUBECTL} -n "${NAMESPACE}" create configmap router-config \
    --from-literal=config.yaml="${RENDERED_CONFIG}" \
    --dry-run=client -o yaml | ${KUBECTL} apply -f -
ok "ConfigMap/router-config created"

# Envoy config (slim mode only)
if [[ "${MODE}" == "slim" ]]; then
    ENVOY_TEMPLATE="${TEMPLATE_DIR}/envoy-slim.yaml.tmpl"
    if [[ ! -f "${ENVOY_TEMPLATE}" ]]; then
        err "Envoy template not found: ${ENVOY_TEMPLATE}"
    fi

    info "Rendering Envoy config from ${ENVOY_TEMPLATE}..."
    RENDERED_ENVOY=$(render_template "${ENVOY_TEMPLATE}")

    ${KUBECTL} -n "${NAMESPACE}" create configmap envoy-config \
        --from-literal=envoy.yaml="${RENDERED_ENVOY}" \
        --dry-run=client -o yaml | ${KUBECTL} apply -f -
    ok "ConfigMap/envoy-config created"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Create Secret
# ─────────────────────────────────────────────────────────────────────────────
info "Creating Secret/litellm-credentials..."
${KUBECTL} -n "${NAMESPACE}" create secret generic litellm-credentials \
    --from-literal=api-key="${LITELLM_API_KEY}" \
    --dry-run=client -o yaml | ${KUBECTL} apply -f -
ok "Secret/litellm-credentials created"

# ─────────────────────────────────────────────────────────────────────────────
# Create Grafana dashboard ConfigMap (full mode only)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${MODE}" == "full" && -f "${DASHBOARD_JSON}" ]]; then
    info "Creating Grafana dashboard ConfigMap..."
    ${KUBECTL} -n "${NAMESPACE}" create configmap grafana-dashboard \
        --from-file=llm-router-dashboard.json="${DASHBOARD_JSON}" \
        --dry-run=client -o yaml | ${KUBECTL} apply -f -
    ok "ConfigMap/grafana-dashboard created"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Restart deployment to pick up new config
# ─────────────────────────────────────────────────────────────────────────────
info "Restarting semantic-router deployment..."
${KUBECTL} -n "${NAMESPACE}" rollout restart deployment/semantic-router 2>/dev/null || true

if [[ "${MODE}" == "full" ]]; then
    ${KUBECTL} -n "${NAMESPACE}" rollout restart deployment/grafana 2>/dev/null || true
fi

# ─────────────────────────────────────────────────────────────────────────────
# Print status
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Configuration Applied (${MODE} mode)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Endpoint:       ${LITELLM_ENDPOINT}"
echo " Coding model:   ${MODEL_CODING}"
echo " General model:  ${MODEL_GENERAL}"
echo ""
echo " Routing rules:"
echo "   CS/engineering queries → ${MODEL_CODING}"
echo "   all other queries      → ${MODEL_GENERAL}"
echo ""
if [[ "${MODE}" == "full" ]]; then
    echo " Waiting for pods to start (model downloads may take a while)..."
    echo ""
    echo " Endpoints (once running):"
    echo "   API:       http://<IP>:30801/v1/chat/completions"
    echo "   Dashboard: http://<IP>:30700"
    echo "   Grafana:   http://<IP>:30300"
else
    echo " Waiting for pods to start (~500MB model download on first run)..."
    echo ""
    echo " Endpoint (once running):"
    echo "   API:       http://<IP>:30801/v1/chat/completions"
fi
echo ""
echo " Monitor:"
echo "   sudo kubectl -n ${NAMESPACE} get pods -w"
echo "   sudo kubectl -n ${NAMESPACE} logs deploy/semantic-router --tail=50 -f"
echo ""
echo " To reconfigure, re-run this script with new values."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
