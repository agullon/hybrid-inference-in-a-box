#!/bin/bash
# configure-semantic-router.sh — Post-boot configuration for the Semantic Router
#
# Creates the Kubernetes ConfigMap(s) and Secret needed by the semantic-router
# deployment. The infrastructure manifests (Deployment, Service, etc.) are
# applied automatically by MicroShift on boot, but pods stay in
# CreateContainerConfigError until this script provides the configuration.
#
# Usage:
#   configure-semantic-router.sh [path/to/router.yaml]
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
MANIFEST_DIR="/usr/lib/microshift/manifests.d/semantic-router"
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
# Model names are the top-level `- name:` entries under `providers.models`,
# not the nested endpoint names. We use python to parse the YAML properly.
mapfile -t MODEL_NAMES < <(python3 -c "
import yaml, sys
cfg = yaml.safe_load(open(sys.argv[1]))
for m in cfg.get('providers', {}).get('models', []):
    print(m['name'])
" "${CONFIG_FILE}")

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
# The deployment mounts the secret key "api-key" as the LITELLM_API_KEY env var.
# We use the first access_key found in the config file.
info "Creating Secret/litellm-credentials..."
API_KEY=$(python3 -c "
import yaml, sys
cfg = yaml.safe_load(open(sys.argv[1]))
for m in cfg.get('providers', {}).get('models', []):
    if 'access_key' in m:
        print(m['access_key'])
        break
" "${CONFIG_FILE}")

if [[ -n "${API_KEY}" ]]; then
    ${KUBECTL} -n "${NAMESPACE}" create secret generic litellm-credentials \
        --from-literal=api-key="${API_KEY}" \
        --dry-run=client -o yaml | ${KUBECTL} apply -f -
    ok "Secret/litellm-credentials created"
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
DEFAULT_MODEL=$(python3 -c "
import yaml, sys
cfg = yaml.safe_load(open(sys.argv[1]))
print(cfg.get('providers', {}).get('default_model', ''))
" "${CONFIG_FILE}")

# Detect the node IP address for endpoint URLs
NODE_IP=$(${KUBECTL} get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null) || true
if [[ -z "${NODE_IP}" ]]; then
    NODE_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || NODE_IP="<IP>"
fi

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
    echo "   API:       http://${NODE_IP}:30801/v1/chat/completions"
    echo "   Dashboard: http://${NODE_IP}:30700"
    echo "   Grafana:   http://${NODE_IP}:30300"
else
    echo " Endpoint (once running):"
    echo "   API:       http://${NODE_IP}:30801/v1/chat/completions"
fi
echo ""
echo " Monitor:"
echo "   sudo kubectl -n ${NAMESPACE} get pods -w"
echo "   sudo kubectl -n ${NAMESPACE} logs deploy/semantic-router --tail=50 -f"
echo ""
echo " To reconfigure, edit the config file and re-run this script."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
