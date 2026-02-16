# Ollama + Open WebUI on OpenShift SNO
## Complete Deployment Guide (AMD GPU)

**Environment:** Single Node OpenShift (SNO) with LVMS storage, AMD Radeon RX 6600 via VFIO passthrough  
**Goal:** GPU-accelerated local LLM chatbot with persistent chat history, exposed via HTTPS  
**Stack:** Ollama ROCm (model server) + Open WebUI (chat interface) + llama3.2:3b  
**Prerequisites:** AMD GPU Operator stack installed and `amd.com/gpu: 1` schedulable (see `08_setup_amd_gpu.yaml`)

---

## Prerequisites

- OpenShift CLI (`oc`) configured and logged in as cluster-admin
- Podman available on your workstation
- Ollama installed on your workstation (for model download)
- Access to a local container registry (this guide uses Quay)
- LVMS storage available (`lvms-vg1`)
- AMD GPU Operator installed, node labeled `amd.com/gpu: 1` schedulable

---

## Step 1: Mirror Images to Local Registry

Pull both images on your workstation and push them to your local registry. Use the `ollama:rocm` tag — this bundles the ROCm runtime required for AMD GPU inference.

```bash
# Ollama with ROCm
podman pull docker.io/ollama/ollama:rocm
podman tag docker.io/ollama/ollama:rocm quay.local.momolab.io/mirror/ollama-chat/ollama:rocm
podman push --authfile=/home/momo/auth.json quay.local.momolab.io/mirror/ollama-chat/ollama:rocm

# Open WebUI
podman pull ghcr.io/open-webui/open-webui:main
podman tag ghcr.io/open-webui/open-webui:main quay.local.momolab.io/mirror/ollama-chat/open-webui:main
podman push --authfile=/home/momo/auth.json quay.local.momolab.io/mirror/ollama-chat/open-webui:main
```

---

## Step 2: Download the LLM Model

Pull the model on your workstation using Ollama. This stores it locally for later transfer to the cluster.

```bash
ollama pull llama3.2:3b
```

Verify the model path (Ollama on Linux stores models under `/usr/share/ollama`):

```bash
sudo ls /usr/share/ollama/.ollama/models/
sudo ls /usr/share/ollama/.ollama/models/manifests/registry.ollama.ai/library/llama3.2/
```

You should see `blobs/` and `manifests/` directories, and `3b` and `latest` tags under the manifests path.

---

## Step 3: Create the Namespace

```bash
oc new-project ollama-chat
```

This creates the project and switches your active context into it.

---

## Step 4: Create Persistent Volume Claims

### Ollama model storage (50Gi)

Create `ollama-pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-models
  namespace: ollama-chat
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: lvms-vg1
  resources:
    requests:
      storage: 50Gi
```

### Open WebUI data storage (5Gi)

Create `open-webui-pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-webui-data
  namespace: ollama-chat
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: lvms-vg1
  resources:
    requests:
      storage: 5Gi
```

Apply both:

```bash
oc apply -f ollama-pvc.yaml
oc apply -f open-webui-pvc.yaml
oc get pvc
```

> **Note:** LVMS PVCs use `WaitForFirstConsumer` binding — they will show `Pending` until a pod is scheduled. This is expected.

---

## Step 5: Create Service Accounts and Grant SCC

Both Ollama and Open WebUI need to run as root, which OpenShift blocks by default. We create dedicated ServiceAccounts and grant them the `anyuid` Security Context Constraint.

```bash
# Ollama
oc create serviceaccount ollama -n ollama-chat
oc adm policy add-scc-to-user anyuid -z ollama -n ollama-chat

# Open WebUI
oc create serviceaccount open-webui -n ollama-chat
oc adm policy add-scc-to-user anyuid -z open-webui -n ollama-chat
```

---

## Step 6: Deploy Ollama

Create `ollama-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: ollama-chat
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      serviceAccountName: ollama
      containers:
        - name: ollama
          image: quay.local.momolab.io/mirror/ollama-chat/ollama:rocm
          ports:
            - containerPort: 11434
          env:
            - name: OLLAMA_HOST
              value: "0.0.0.0"
            - name: OLLAMA_NUM_PARALLEL
              value: "2"
            - name: OLLAMA_MAX_LOADED_MODELS
              value: "1"
            - name: HSA_OVERRIDE_GFX_VERSION
              value: "10.3.0"
            - name: LD_LIBRARY_PATH
              value: "/usr/lib/ollama:/usr/lib/ollama/rocm"
          resources:
            requests:
              memory: "8Gi"
              cpu: "4"
              amd.com/gpu: "1"
            limits:
              memory: "16Gi"
              cpu: "8"
              amd.com/gpu: "1"
          volumeMounts:
            - name: ollama-models
              mountPath: /root/.ollama
      volumes:
        - name: ollama-models
          persistentVolumeClaim:
            claimName: ollama-models
```

> **`strategy: Recreate`** is required. `amd.com/gpu: 1` is an exclusive resource — RollingUpdate will deadlock because the new pod cannot claim the GPU until the old pod releases it.

> **`HSA_OVERRIDE_GFX_VERSION=10.3.0`** tells ROCm to treat the RX 6600 (gfx1032) as gfx1030-family, which has full ROCm support. Required for Navi 23.

> **`LD_LIBRARY_PATH`** ensures Ollama's subprocess runner finds `libggml-base.so.0` alongside the ROCm libraries. Without this Ollama silently falls back to CPU.

> **Do not set `OLLAMA_LLM_LIBRARY=hip`** — this causes Ollama to skip the ROCm backend rather than select it.

Apply and wait for the pod to be ready:

```bash
oc apply -f ollama-deployment.yaml
oc get pods -w
```

---

## Step 7: Create the Ollama Service

Create `ollama-service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: ollama-chat
spec:
  selector:
    app: ollama
  ports:
    - protocol: TCP
      port: 11434
      targetPort: 11434
```

```bash
oc apply -f ollama-service.yaml
```

---

## Step 8: Copy the Model into the Pod

Ollama stores models in its own blob format, not as plain GGUF files. Copy both the `blobs` and `manifests` directories from your workstation into the running pod.

```bash
OLLAMA_POD=$(oc get pod -l app=ollama -n ollama-chat \
  --field-selector=status.phase=Running -o name | sed 's|pod/||')

oc cp /usr/share/ollama/.ollama/models/blobs/. \
  ${OLLAMA_POD}:/root/.ollama/models/blobs/ -n ollama-chat

oc cp /usr/share/ollama/.ollama/models/manifests/. \
  ${OLLAMA_POD}:/root/.ollama/models/manifests/ -n ollama-chat
```

Verify the model is registered:

```bash
oc exec -it ${OLLAMA_POD} -n ollama-chat -- ollama list
```

Verify GPU is being used — all layers should be offloaded:

```bash
oc logs ${OLLAMA_POD} -n ollama-chat | grep -i "inference compute"
# Expected: library=ROCm compute=gfx1030 name=ROCm0 total="8.0 GiB"

oc logs ${OLLAMA_POD} -n ollama-chat | grep "offloaded"
# Expected: load_tensors: offloaded 29/29 layers to GPU
```

Test inference:

```bash
time oc exec -it ${OLLAMA_POD} -n ollama-chat -- \
  ollama run llama3.2:3b "Reply with one short sentence only: what is the capital of France?"
```

A response in under 5 seconds confirms GPU inference is working (~15-20 tok/s on RX 6600).

---

## Step 9: Deploy Open WebUI

Generate a secret key for Open WebUI session management:

```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
```

Create `open-webui-deployment.yaml`, substituting your generated key:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: open-webui
  namespace: ollama-chat
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: open-webui
  template:
    metadata:
      labels:
        app: open-webui
    spec:
      serviceAccountName: open-webui
      containers:
        - name: open-webui
          image: quay.local.momolab.io/mirror/ollama-chat/open-webui:main
          ports:
            - containerPort: 8080
          env:
            - name: OLLAMA_BASE_URL
              value: "http://ollama.ollama-chat.svc.cluster.local:11434"
            - name: WEBUI_AUTH
              value: "true"
            - name: WEBUI_SECRET_KEY
              value: "<your-generated-secret-key>"
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "1Gi"
              cpu: "1"
          volumeMounts:
            - name: open-webui-data
              mountPath: /app/backend/data
      volumes:
        - name: open-webui-data
          persistentVolumeClaim:
            claimName: ollama-webui-data
```

```bash
oc apply -f open-webui-deployment.yaml
oc get pods -w
```

---

## Step 10: Create the Open WebUI Service and Route

Create `open-webui-service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: open-webui
  namespace: ollama-chat
spec:
  selector:
    app: open-webui
  ports:
    - protocol: TCP
      port: 8080
      targetPort: 8080
```

Create `open-webui-route.yaml`:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: open-webui
  namespace: ollama-chat
spec:
  to:
    kind: Service
    name: open-webui
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

```bash
oc apply -f open-webui-service.yaml
oc apply -f open-webui-route.yaml
```

Get the URL:

```bash
oc get route open-webui -n ollama-chat
```

Navigate to the URL in your browser. On first visit you will be prompted to create an admin account.

---

## Final State

After completing all steps, the following resources exist in the `ollama-chat` namespace:

| Resource | Name | Purpose |
|---|---|---|
| Deployment | ollama | Serves the LLM via REST API on port 11434, GPU-accelerated |
| Deployment | open-webui | Chat interface on port 8080 |
| Service | ollama | Internal cluster DNS for Ollama |
| Service | open-webui | Internal cluster DNS for Open WebUI |
| Route | open-webui | HTTPS ingress via OpenShift router |
| PVC | ollama-models | 50Gi LVMS block storage for model files |
| PVC | ollama-webui-data | 5Gi LVMS block storage for SQLite chat history |
| ServiceAccount | ollama | Runs Ollama with anyuid SCC |
| ServiceAccount | open-webui | Runs Open WebUI with anyuid SCC |

---

## Performance Reference

Measured on RX 6600 (8GB VRAM) with VFIO passthrough, RHEL CoreOS 9.6:

| Model | VRAM | Tokens/sec | Notes |
|---|---|---|---|
| llama3.2:1b | ~1GB | ~35-40 tok/s | Fast, limited quality |
| llama3.2:3b | ~2GB | ~15-20 tok/s | Good balance for simple tasks |
| llama3.1:8b | ~4.7GB | ~5-8 tok/s | Best quality that fits in 8GB VRAM |

> Models larger than ~8B parameters at Q4 quantization will not fit in 8GB VRAM. Ollama will split them across GPU+CPU, degrading performance to near-CPU speeds.

---

## Post-Installation Hardening

The `WEBUI_SECRET_KEY` is currently stored in plain text in the deployment manifest. Move it to a Secret:

```bash
oc create secret generic open-webui-secret -n ollama-chat \
  --from-literal=WEBUI_SECRET_KEY=<your-generated-secret-key>
```

Then replace the `env` block in the Open WebUI deployment with:

```yaml
envFrom:
  - secretRef:
      name: open-webui-secret
```

---

## Swapping Models

To use a different model, pull it on your workstation, then copy it to the pod using the same `oc cp` method from Step 8. Then run it from within the pod:

```bash
oc exec -it ${OLLAMA_POD} -n ollama-chat -- ollama run <model-name>
```

Open WebUI will automatically detect any models registered with Ollama and make them available in the model selector dropdown.
