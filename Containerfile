FROM quay.io/centos-bootc/centos-bootc:stream10

# ─────────────────────────────────────────────────────────────────────────────
# Install MicroShift
# ─────────────────────────────────────────────────────────────────────────────
RUN curl -s https://microshift-io.github.io/microshift/quickrpm.sh | bash && \
    dnf clean all

# ─────────────────────────────────────────────────────────────────────────────
# Firewall rules
# ─────────────────────────────────────────────────────────────────────────────
# SSH access
RUN firewall-offline-cmd --add-service=ssh && \
    firewall-offline-cmd --add-service=http && \
    firewall-offline-cmd --add-service=https && \
    # NodePort range for Kubernetes services
    firewall-offline-cmd --add-port=30000-32767/tcp && \
    firewall-offline-cmd --add-port=30000-32767/udp && \
    # Pod and service network CIDRs (trusted for internal cluster traffic)
    firewall-offline-cmd --permanent --zone=trusted \
        --add-source=10.42.0.0/16 && \
    firewall-offline-cmd --permanent --zone=trusted \
        --add-source=169.254.169.1

# ─────────────────────────────────────────────────────────────────────────────
# Systemd services
# ─────────────────────────────────────────────────────────────────────────────
# OVN-Kubernetes requires rshared mount propagation on the root filesystem
COPY scripts/make-rshared.service /etc/systemd/system/
RUN systemctl enable firewalld microshift make-rshared

# ─────────────────────────────────────────────────────────────────────────────
# Kustomize manifests — infrastructure only, no configuration baked in
# ─────────────────────────────────────────────────────────────────────────────
# MicroShift auto-applies manifests from /usr/lib/microshift/manifests/ on boot.
# These define the Deployments, Services, etc. but reference ConfigMaps and
# Secrets that don't exist yet — pods will wait until configure-router.sh
# creates them post-boot.
COPY manifests/semantic-router/ /usr/lib/microshift/manifests/semantic-router/

# ─────────────────────────────────────────────────────────────────────────────
# Configuration templates + helper scripts
# ─────────────────────────────────────────────────────────────────────────────
COPY config/templates/ /etc/semantic-router/templates/
COPY config/llm-router-dashboard.json /etc/semantic-router/
COPY scripts/configure-router.sh /usr/local/bin/
COPY scripts/select-mode.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/configure-router.sh /usr/local/bin/select-mode.sh

# ─────────────────────────────────────────────────────────────────────────────
# Pre-pull container images for air-gapped operation
# ─────────────────────────────────────────────────────────────────────────────
# These images are copied into CRI-O's container storage so MicroShift
# doesn't need to pull them from the internet on first boot.
#
# NOTE: The skopeo containers-storage transport requires the CRI-O storage
# backend to be available at build time. If this fails on your build host,
# alternatives include:
#   - podman pull + copy the image store layer
#   - MicroShift's mirror-images.sh helper
#   - directory-based mirroring with CRI-O additional image stores
RUN skopeo copy --all \
    docker://ghcr.io/vllm-project/semantic-router/vllm-sr:latest \
    containers-storage:ghcr.io/vllm-project/semantic-router/vllm-sr:latest && \
    skopeo copy --all \
    docker://ghcr.io/vllm-project/semantic-router/extproc:latest \
    containers-storage:ghcr.io/vllm-project/semantic-router/extproc:latest && \
    skopeo copy --all \
    docker://docker.io/envoyproxy/envoy:v1.31.7 \
    containers-storage:docker.io/envoyproxy/envoy:v1.31.7 && \
    skopeo copy --all \
    docker://docker.io/prom/prometheus:v2.53.3 \
    containers-storage:docker.io/prom/prometheus:v2.53.3 && \
    skopeo copy --all \
    docker://docker.io/grafana/grafana:11.4.0 \
    containers-storage:docker.io/grafana/grafana:11.4.0
