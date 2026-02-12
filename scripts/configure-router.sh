#!/bin/bash
# configure-router.sh — Post-boot configuration for the Semantic Router
#
# Creates the Kubernetes ConfigMap(s) and Secret needed by the semantic-router
# deployment. The infrastructure manifests (Deployment, Service, etc.) are
# applied automatically by MicroShift on boot, but pods stay in
# CreateContainerConfigError until this script provides the configuration.
#
# Usage:
#   configure-router.sh [path/to/router.yaml]
#
# The config file defines the models, endpoints, and API keys — everything
# under `providers:` in the router config. The rest (signals, decisions,
# listeners) comes from the baked-in template.
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
# Load config file
# ─────────────────────────────────────────────────────────────────────────────
CONFIG_FILE="${1:-./router.yaml}"

if [[ "${CONFIG_FILE}" == "--help" || "${CONFIG_FILE}" == "-h" ]]; then
    echo "Usage: $0 [path/to/router.yaml]"
    echo ""
    echo "The config file defines the models and endpoints (providers section)."
    echo "Copy the example and edit it:"
    echo ""
    echo "  cp /etc/semantic-router/templates/router.yaml.example router.yaml"
    echo "  vi router.yaml"
    echo "  sudo $0 router.yaml"
    exit 0
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
    err "Config file not found: ${CONFIG_FILE}

Copy the example config and edit it:

  cp /etc/semantic-router/templates/router.yaml.example router.yaml
  vi router.yaml
  sudo $0 router.yaml"
fi

info "Loading config from ${CONFIG_FILE}..."

# ─────────────────────────────────────────────────────────────────────────────
# Extract model names from the config
# ─────────────────────────────────────────────────────────────────────────────
# Model names are the `- name:` entries under `providers.models`
mapfile -t MODEL_NAMES < <(grep -E '^\s+- name:' "${CONFIG_FILE}" | sed 's/.*- name:[[:space:]]*//' | tr -d '"' | tr -d "'")

if [[ ${#MODEL_NAMES[@]} -lt 1 ]]; then
    err "No models found in ${CONFIG_FILE}. Expected providers.models entries."
fi

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
# Render the final config: inject providers into template
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${MODE}" == "full" ]]; then
    TEMPLATE="${TEMPLATE_DIR}/config-full.yaml.tmpl"
else
    TEMPLATE="${TEMPLATE_DIR}/config-slim.yaml.tmpl"
fi

if [[ ! -f "${TEMPLATE}" ]]; then
    err "Template not found: ${TEMPLATE}"
fi

info "Rendering config from ${TEMPLATE}..."

# Read the config file (providers section) and inject into the template
PROVIDERS_CONTENT=$(cat "${CONFIG_FILE}")
RENDERED_CONFIG=$(python3 -c "
import sys
template = open(sys.argv[1]).read()
providers = open(sys.argv[2]).read()
print(template.replace('__PROVIDERS__', providers))
" "${TEMPLATE}" "${CONFIG_FILE}")

# Substitute __MODEL_N__ placeholders with actual model names from the config
for i in "${!MODEL_NAMES[@]}"; do
    RENDERED_CONFIG="${RENDERED_CONFIG//__MODEL_${i}__/${MODEL_NAMES[$i]}}"
done

# ─────────────────────────────────────────────────────────────────────────────
# Ensure namespace exists
# ─────────────────────────────────────────────────────────────────────────────
if ! ${KUBECTL} get namespace "${NAMESPACE}" &>/dev/null; then
    info "Creating namespace ${NAMESPACE}..."
    ${KUBECTL} create namespace "${NAMESPACE}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Create router ConfigMap
# ─────────────────────────────────────────────────────────────────────────────
info "Applying router config..."
${KUBECTL} -n "${NAMESPACE}" create configmap router-config \
    --from-literal=config.yaml="${RENDERED_CONFIG}" \
    --dry-run=client -o yaml | ${KUBECTL} apply -f -
ok "ConfigMap/router-config created"

# ─────────────────────────────────────────────────────────────────────────────
# Envoy config (slim mode only)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${MODE}" == "slim" ]]; then
    ENVOY_TMPL="${TEMPLATE_DIR}/envoy-slim.yaml.tmpl"
    if [[ ! -f "${ENVOY_TMPL}" ]]; then
        err "Envoy template not found: ${ENVOY_TMPL}"
    fi

    # Extract the first endpoint hostname for Envoy upstream
    ENVOY_ENDPOINT=$(grep -m1 'endpoint:' "${CONFIG_FILE}" | sed 's/.*endpoint:[[:space:]]*//' | tr -d '"' | tr -d "'" | sed 's/:[0-9]*$//')

    if [[ -z "${ENVOY_ENDPOINT}" ]]; then
        err "Could not extract endpoint from config for Envoy"
    fi

    info "Rendering Envoy config (upstream: ${ENVOY_ENDPOINT})..."
    RENDERED_ENVOY=$(sed "s|__ENDPOINT_GENERAL__|${ENVOY_ENDPOINT}|g" "${ENVOY_TMPL}")

    ${KUBECTL} -n "${NAMESPACE}" create configmap envoy-config \
        --from-literal=envoy.yaml="${RENDERED_ENVOY}" \
        --dry-run=client -o yaml | ${KUBECTL} apply -f -
    ok "ConfigMap/envoy-config created"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Create Secret from access_keys in the config
# ─────────────────────────────────────────────────────────────────────────────
info "Creating Secret/litellm-credentials..."
SECRET_ARGS=""
INDEX=0
while IFS= read -r key; do
    key=$(echo "${key}" | xargs)
    [[ -z "${key}" ]] && continue
    SECRET_ARGS="${SECRET_ARGS} --from-literal=api-key-${INDEX}=${key}"
    INDEX=$((INDEX + 1))
done < <(grep 'access_key:' "${CONFIG_FILE}" | sed 's/.*access_key:[[:space:]]*//' | tr -d '"' | tr -d "'")

if [[ -n "${SECRET_ARGS}" ]]; then
    ${KUBECTL} -n "${NAMESPACE}" create secret generic litellm-credentials \
        ${SECRET_ARGS} \
        --dry-run=client -o yaml | ${KUBECTL} apply -f -
    ok "Secret/litellm-credentials created (${INDEX} key(s))"
fi

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
DEFAULT_MODEL=$(grep 'default_model:' "${CONFIG_FILE}" | head -1 | sed 's/.*default_model:[[:space:]]*//' | tr -d '"' | tr -d "'")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Configuration Applied (${MODE} mode)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Models:"
for name in "${MODEL_NAMES[@]}"; do
    if [[ "${name}" == "${DEFAULT_MODEL}" ]]; then
        echo "   • ${name}  (default)"
    else
        echo "   • ${name}"
    fi
done
echo ""
if [[ "${MODE}" == "full" ]]; then
    echo " Endpoints (once running):"
    echo "   API:       http://<IP>:30801/v1/chat/completions"
    echo "   Dashboard: http://<IP>:30700"
    echo "   Grafana:   http://<IP>:30300"
else
    echo " Endpoint (once running):"
    echo "   API:       http://<IP>:30801/v1/chat/completions"
fi
echo ""
echo " Monitor:"
echo "   sudo kubectl -n ${NAMESPACE} get pods -w"
echo "   sudo kubectl -n ${NAMESPACE} logs deploy/semantic-router --tail=50 -f"
echo ""
echo " To reconfigure, edit the config file and re-run this script."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
