# Hybrid Inference in a Box — bootc Image

An immutable, self-contained appliance that boots MicroShift with the vLLM
Semantic Router pre-deployed. No SSH-and-apply workflow — just boot, configure
your LLM backend, and start routing.

## Architecture

```
bootc image (CentOS Stream 10)
├── MicroShift (RPM, auto-starts on boot)
├── /usr/lib/microshift/manifests/semantic-router/
│   ├── kustomization.yaml          ← selects full or slim overlay
│   ├── base/                       ← namespace
│   ├── overlays/full/              ← vllm-sr + grafana + prometheus
│   └── overlays/slim/              ← extproc + envoy sidecar
├── Pre-pulled container images
├── /usr/local/bin/configure-router.sh
├── /usr/local/bin/select-mode.sh
└── /etc/semantic-router/templates/ ← config templates with placeholders
```

**Two-stage boot flow:**
1. MicroShift starts → applies infrastructure manifests → pods wait for config
2. User runs `configure-router.sh` → creates ConfigMap + Secret → pods start

## Deployment Modes

| Mode | Components | Disk | RAM | Ports |
|------|-----------|------|-----|-------|
| **full** (default) | vllm-sr all-in-one + Grafana + Prometheus | ~100GB | ~8GB | API:30801, Dashboard:30700, Grafana:30300 |
| **slim** | extproc + Envoy sidecar | ~20GB | ~4GB | API:30801 |

## Build

```bash
podman build -t hybrid-inference-bootc:latest -f Containerfile .
```

CI builds run automatically on push to `main` and publish multi-arch
(amd64 + arm64) manifest lists to
`ghcr.io/<owner>/hybrid-inference-in-a-box:<tag>`. Each architecture is
built in parallel on its native runner, then combined into a single manifest
list. See
[`.github/workflows/build-bootc.yaml`](.github/workflows/build-bootc.yaml).

## First Boot

### 1. Boot the image

Deploy via VM (qcow2), bare metal (ISO), or cloud (AMI). The image boots
with MicroShift enabled. Infrastructure pods will be in
`CreateContainerConfigError` state — this is expected.

**Quick start with KVM/libvirt** — the included helper script converts the
container image to a qcow2 disk and creates a VM:

```bash
# Full mode (8GB RAM, 4 vCPUs, 100GB disk)
./scripts/start_vm_bootc.sh

# Slim mode (4GB RAM, 2 vCPUs, 40GB disk)
./scripts/start_vm_bootc.sh --mode=slim

# Specify a custom image and VM name
./scripts/start_vm_bootc.sh --image=ghcr.io/org/hybrid-inference-in-a-box:main my-vm

# Delete a VM
./scripts/start_vm_bootc.sh --delete my-vm
```

The script auto-detects the image from the git remote or the GHCR API, uses
`bootc-image-builder` to produce the qcow2, sets the deployment mode, and
waits for the VM to get an IP address.

### 2. Configure the router

```bash
sudo configure-router.sh \
  --endpoint litellm.example.com \
  --api-key sk-your-key-here \
  --model-coding Mistral-Small-24B-W8A8 \
  --model-general Granite-3.3-8B-Instruct
```

Or run without arguments for interactive prompts:
```bash
sudo configure-router.sh
```

### 3. Wait for pods to start

```bash
sudo kubectl -n semantic-router get pods -w
```

Full mode downloads ~18GB of classifier models on first boot. Slim mode
downloads ~500MB.

### 4. Access

**Full mode:**
- API: `http://<IP>:30801/v1/chat/completions`
- Dashboard: `http://<IP>:30700`
- Grafana: `http://<IP>:30300`

**Slim mode:**
- API: `http://<IP>:30801/v1/chat/completions`

### 5. Test

```bash
# Coding query → routes to coding model
curl -s http://<IP>:30801/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"Write a Python quicksort"}]}' | jq .

# General query → routes to general model
curl -s http://<IP>:30801/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"What is photosynthesis?"}]}' | jq .
```

## Switching Modes

```bash
sudo select-mode.sh slim
sudo systemctl restart microshift
# Wait ~30s for MicroShift to restart
sudo configure-router.sh --endpoint ... --api-key ... \
  --model-coding ... --model-general ...
```

## Reconfiguring

Re-run `configure-router.sh` at any time with new values. It will update
the ConfigMap/Secret and restart the deployment.

```bash
sudo configure-router.sh \
  --endpoint new-litellm.example.com \
  --api-key sk-new-key \
  --model-coding NewCodingModel \
  --model-general NewGeneralModel
```

## What's Baked vs Runtime

| Baked in image (immutable) | Configured post-boot |
|---|---|
| Namespace, Deployments, Services | LiteLLM endpoint URL |
| Prometheus + Grafana (full mode) | LiteLLM API key |
| Container images (pre-pulled) | Model names |
| Firewall rules, systemd units | Routing decisions |
| Config templates | Envoy upstream (slim mode) |

## File Layout

```
hybrid-inference-in-a-box/
├── Containerfile
├── .github/workflows/
│   └── build-bootc.yaml              ← CI/CD: build & push to GHCR
├── manifests/semantic-router/
│   ├── kustomization.yaml
│   ├── base/
│   │   ├── kustomization.yaml
│   │   └── namespace.yaml
│   └── overlays/
│       ├── full/
│       │   ├── kustomization.yaml
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   ├── prometheus.yaml
│       │   └── grafana.yaml
│       └── slim/
│           ├── kustomization.yaml
│           ├── deployment.yaml
│           └── service.yaml
├── config/
│   ├── llm-router-dashboard.json
│   └── templates/
│       ├── config-full.yaml.tmpl
│       ├── config-slim.yaml.tmpl
│       └── envoy-slim.yaml.tmpl
├── scripts/
│   ├── configure-router.sh            ← post-boot configuration
│   ├── select-mode.sh                 ← switch full ↔ slim
│   ├── start_vm_bootc.sh              ← create VM from bootc image
│   └── make-rshared.service
└── README.md
```

## Troubleshooting

**Pods stuck in CreateContainerConfigError:**
Run `configure-router.sh` — the pods are waiting for ConfigMap/Secret.

**Pods stuck in ImagePullBackOff:**
Pre-pulled images may not have been copied correctly. Check CRI-O storage:
```bash
sudo crictl images
```

**MicroShift not starting:**
```bash
sudo systemctl status microshift
sudo journalctl -u microshift --no-pager -l
```

**Router not connecting to LiteLLM:**
Test connectivity from the node:
```bash
curl -s https://<endpoint>/models -H 'Authorization: Bearer <key>'
```

## Risks & Notes

- CentOS Stream 10 bootc base image is relatively new — fall back to RHEL 9
  bootc if you encounter build issues
- The `skopeo copy` pre-pull mechanism needs validation on CS10 bootc;
  alternatives include directory-based mirroring or MicroShift's
  `mirror-images.sh`
- The Grafana init container uses `python:3.12-alpine` to pre-seed the
  dashboard short URL — this image should also be pre-pulled for air-gapped
  operation
