# Hybrid Inference in a Box — bootc Image

An immutable, self-contained appliance that boots MicroShift with the vLLM
Semantic Router and a local Small Language Model (SLM) pre-deployed. Simpler
queries run on-device via the local GPU; complex queries route to external
LLM endpoints — all through a single OpenAI-compatible API.

## Architecture

```
bootc image (CentOS Stream 10)
├── MicroShift (RPM, auto-starts on boot)
├── manifests.d/semantic-router/    ← semantic router (full or slim mode)
├── manifests.d/vllm-slm/          ← local SLM (Qwen2.5-1.5B on GPU)
├── Pre-pulled container images
├── NVIDIA Container Toolkit + CDI  ← GPU runtime (systemd, on every boot)
├── GPU Operator (Helm, post-boot)  ← device plugin + GPU feature discovery
├── /usr/local/bin/setup-gpu-operator.sh
├── /usr/local/bin/configure-semantic-router.sh
└── /etc/semantic-router/templates/

┌──────────────────────────────┐     ┌──────────────────────────────┐
│  semantic-router namespace   │     │  vllm-slm namespace          │
│  ┌────────────────────────┐  │     │  ┌────────────────────────┐  │
│  │ semantic-router Deploy │  │     │  │ vllm-slm Deployment    │  │
│  │ ├─ extproc (routing)   │  │     │  │ └─ vLLM container      │  │
│  │ └─ envoy (proxy) ──────┼──┼────►│  │    Qwen2.5-1.5B        │  │
│  └────────────────────────┘  │     │  │    port 8000 (OpenAI)  │  │
│  NodePort 30801 (API)        │     │  │    NVIDIA GPU           │  │
└──────────────────────────────┘     │  └────────────────────────┘  │
         │                           │  NodePort 30500 (direct API) │
         │                           └──────────────────────────────┘
         │
         ├───► External LLM (e.g. litellm.example.com, HTTPS)
         └───► Local SLM (vllm-slm.vllm-slm.svc:8000, HTTP)
```

**Three-stage boot flow:**
1. MicroShift starts → applies manifests → pods wait for config
2. User runs `setup-gpu-operator.sh` → GPU becomes available → SLM pod starts
3. User runs `configure-semantic-router.sh` → creates ConfigMap + Secret → router starts

## Components

| Component | Namespace | Description |
|-----------|-----------|-------------|
| **Semantic Router** | `semantic-router` | Routes queries to the right model based on domain classification |
| **vLLM SLM** | `vllm-slm` | Local Qwen2.5-1.5B-Instruct served by vLLM on GPU |
| **GPU Operator** | `gpu-operator` | NVIDIA device plugin + GPU feature discovery (Helm) |

## Deployment Modes

| Mode | Components | Ports |
|------|-----------|-------|
| **full** (default) | vllm-sr all-in-one + Grafana + Prometheus + SLM | API:30801, SLM:30500, Dashboard:30700, Grafana:30300 |
| **slim** | extproc + Envoy sidecar + SLM | API:30801, SLM:30500 |

## Build

```bash
podman build -t hybrid-inference-bootc:latest -f Containerfile .
```

CI builds run automatically on push to `main` and publish multi-arch
(amd64 + arm64) manifest lists to
`ghcr.io/<owner>/hybrid-inference-in-a-box:<tag>`. See
[`.github/workflows/build-bootc.yaml`](.github/workflows/build-bootc.yaml).

## First Boot

> [!NOTE]
> On first boot, infrastructure pods may show `CreateContainerConfigError`
> (waiting for ConfigMap/Secret) and the vLLM SLM pod will show `Pending`
> (waiting for GPU resources). This is expected.

### 1. Boot the image

Deploy via VM (qcow2), bare metal (ISO), or cloud (AMI). MicroShift starts
automatically.

**Quick start with KVM/libvirt:**

```bash
# Full mode (8GB RAM, 4 vCPUs, 100GB disk)
./scripts/start-bootc-vm.sh

# Slim mode (4GB RAM, 2 vCPUs, 40GB disk)
./scripts/start-bootc-vm.sh --mode=slim
```

### 2. Set up GPU support

The GPU Operator installs the NVIDIA device plugin and GPU feature discovery.
This is required for the SLM pod to access the GPU.

```bash
sudo setup-gpu-operator.sh
```

This script:
- Configures CRI-O with the NVIDIA container runtime
- Generates CDI specs for GPU device injection
- Grants OpenShift SCCs to GPU Operator service accounts
- Installs the GPU Operator via Helm (driver + toolkit disabled, uses host drivers)
- Waits for `nvidia.com/gpu` to be advertised

### 3. Wait for the SLM to start

Once the GPU is available, the vLLM SLM pod downloads the model from
HuggingFace and starts serving. First boot takes a few minutes for the
download.

```bash
sudo kubectl -n vllm-slm get pods -w
# Wait for READY 1/1

# Verify the model is serving
curl http://<IP>:30500/v1/models
```

### 4. Configure the semantic router

Copy the example config and edit it:

```bash
cp config/router.yaml.example router.yaml
vi router.yaml   # edit endpoints, API keys, models
sudo configure-semantic-router.sh router.yaml
```

**Local SLM only** (simplest setup — no external endpoints needed):

```yaml
providers:
  models:
    - name: "Qwen2.5-1.5B-Instruct"
      endpoints:
        - name: "local-vllm"
          weight: 1
          endpoint: "vllm-slm.vllm-slm.svc:8000"
          protocol: "http"
      access_key: "none"

  default_model: "Qwen2.5-1.5B-Instruct"
```

**Hybrid** (local SLM + external LLMs — edit endpoints and keys):

```yaml
providers:
  models:
    - name: "Mistral-Small-24B-W8A8"
      endpoints:
        - name: "litellm"
          weight: 1
          endpoint: "litellm.example.com:443"
          protocol: "https"
      access_key: "sk-your-key-here"

    - name: "Qwen2.5-1.5B-Instruct"
      endpoints:
        - name: "local-vllm"
          weight: 1
          endpoint: "vllm-slm.vllm-slm.svc:8000"
          protocol: "http"
      access_key: "none"

  default_model: "Qwen2.5-1.5B-Instruct"
```

### 5. Wait for router pods

```bash
sudo kubectl -n semantic-router get pods -w
```

Full mode downloads ~18GB of classifier models on first boot. Slim mode
downloads ~500MB.

### 6. Access

| Endpoint | URL |
|----------|-----|
| Router API | `http://<IP>:30801/v1/chat/completions` |
| SLM direct | `http://<IP>:30500/v1/chat/completions` |
| Dashboard (full) | `http://<IP>:30700` |
| Grafana (full) | `http://<IP>:30300` |

### 7. Test

```bash
# Simple query → routed to local SLM
curl -s http://<IP>:30801/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"What is photosynthesis?"}]}' | jq .

# Coding query → routed to external model
curl -s http://<IP>:30801/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"Write a Python quicksort"}]}' | jq .

# Direct SLM access (bypass router)
curl -s http://<IP>:30500/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-1.5B-Instruct","messages":[{"role":"user","content":"What is 2+2?"}]}' | jq .
```

## GPU Support

### Prerequisites

The host must have:
- NVIDIA GPU with drivers pre-installed
- `nvidia-container-toolkit` package (baked into the bootc image)

### DGX Spark / GB10

The NVIDIA GB10 (Blackwell, CUDA capability 12.1) has unified memory shared
with the CPU. The vLLM deployment accounts for this:

- `--gpu-memory-utilization 0.5` — only uses 50% of reported GPU memory
  (the rest is shared with the system)
- `--enforce-eager` — disables Triton/torch.compile (the bundled ptxas
  doesn't support `sm_121a` yet)

### Boot-time automation

The `generate-nvidia-cdi.sh` systemd service runs on every boot before
MicroShift and:
1. Configures CRI-O with the NVIDIA container runtime (`nvidia-ctk runtime configure`)
2. Generates CDI specs at `/etc/cdi/nvidia.yaml`

## Switching Modes

```bash
sudo select-mode.sh slim
sudo systemctl restart microshift
# Wait ~30s for MicroShift to restart
sudo configure-semantic-router.sh router.yaml
```

## Reconfiguring

Edit `router.yaml` and re-run `configure-semantic-router.sh`:

```bash
sudo configure-semantic-router.sh router.yaml
```

## What's Baked vs Runtime

| Baked in image (immutable) | Configured post-boot |
|---|---|
| Namespace, Deployments, Services | Model names (`router.yaml`) |
| Prometheus + Grafana (full mode) | LLM endpoint(s) and API key(s) |
| vLLM SLM deployment + container image | Default model |
| NVIDIA Container Toolkit + CDI service | GPU Operator (Helm, `setup-gpu-operator.sh`) |
| Helm binary | |
| Container images (pre-pulled) | |
| Firewall rules, systemd units | |
| Config templates | |

## File Layout

```
hybrid-inference-in-a-box/
├── Containerfile
├── .github/workflows/
│   └── build-bootc.yaml              ← CI/CD: build & push to GHCR
├── manifests/
│   ├── semantic-router/
│   │   ├── kustomization.yaml
│   │   ├── base/
│   │   │   ├── kustomization.yaml
│   │   │   └── namespace.yaml
│   │   └── overlays/
│   │       ├── full/                  ← vllm-sr + grafana + prometheus
│   │       └── slim/                  ← extproc + envoy sidecar
│   └── vllm-slm/
│       ├── kustomization.yaml
│       └── base/
│           ├── kustomization.yaml
│           ├── namespace.yaml
│           ├── deployment.yaml        ← vLLM + Qwen2.5-1.5B on GPU
│           └── service.yaml           ← NodePort 30500
├── config/
│   ├── router.yaml.example           ← sample config (external + local models)
│   ├── llm-router-dashboard.json
│   └── templates/
│       ├── config-full.yaml.tmpl
│       ├── config-slim.yaml.tmpl
│       └── envoy-slim.yaml.tmpl
├── scripts/
│   ├── configure-semantic-router.sh   ← post-boot router configuration
│   ├── setup-gpu-operator.sh          ← install NVIDIA GPU Operator (Helm)
│   ├── generate-nvidia-cdi.sh         ← CRI-O runtime + CDI specs (systemd)
│   ├── select-mode.sh                 ← switch full / slim
│   ├── start-bootc-vm.sh             ← create VM from bootc image
│   ├── create-vg.sh                   ← loopback LVM VG for TopoLVM
│   └── make-rshared.service
└── README.md
```

## Troubleshooting

**Pods stuck in CreateContainerConfigError:**
Run `configure-semantic-router.sh` — the pods are waiting for ConfigMap/Secret.

**vLLM SLM pod stuck in Pending:**
The GPU Operator hasn't advertised `nvidia.com/gpu` yet. Run
`setup-gpu-operator.sh` and check:
```bash
sudo kubectl get nodes -o jsonpath='{.items[0].status.allocatable}' | python3 -m json.tool | grep nvidia
```

**vLLM SLM crashes with "Free memory ... less than desired":**
The default `--gpu-memory-utilization` is too high for unified memory GPUs.
Edit the deployment:
```bash
sudo kubectl -n vllm-slm edit deployment vllm-slm
# Lower --gpu-memory-utilization (default: 0.5, try 0.3)
```

**vLLM crashes with "ptxas fatal: Value 'sm_121a' is not defined":**
The GPU architecture is too new for the bundled Triton. The deployment
includes `--enforce-eager` to work around this. If you removed it, add it
back.

**GPU Operator pods stuck (SCC errors):**
The `setup-gpu-operator.sh` script grants SCCs automatically. If you
installed manually, grant them:
```bash
oc adm policy add-scc-to-user privileged -n gpu-operator -z node-feature-discovery
oc adm policy add-scc-to-user privileged -n gpu-operator -z nvidia-device-plugin
# ... (see setup-gpu-operator.sh for the full list)
```

**TopoLVM pods in CrashLoopBackOff:**
```bash
sudo systemctl status create-vg
sudo vgs myvg1
```

**MicroShift not starting:**
```bash
sudo systemctl status microshift
sudo journalctl -u microshift --no-pager -l
```

**Router not connecting to LLM endpoint:**
```bash
curl -s https://<endpoint>/models -H 'Authorization: Bearer <key>'
```
