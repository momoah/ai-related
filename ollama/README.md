# Ollama + Open WebUI on OpenShift SNO
## Complete Deployment Guide

**Environment:** Single Node OpenShift (SNO) with external Ceph backend (ODF)  
**Goal:** CPU-based local LLM chatbot with persistent chat history, exposed via HTTPS  
**Stack:** Ollama (model server) + Open WebUI (chat interface) + llama3.2:3b

---

## Prerequisites

- OpenShift CLI (`oc`) configured and logged in as cluster-admin
- Podman available on your workstation
- Ollama installed on your workstation (for model download)
- Access to a local container registry (this guide uses Quay)
- External Ceph storage available via ODF (`ocs-external-storagecluster-ceph-rbd`)

---

## Step 1: Mirror Images to Local Registry

Pull both images on your workstation and push them to your local registry. Authentication is required for push even if the repositories are public.

```bash
# Ollama
podman pull docker.io/ollama/ollama:latest
podman tag docker.io/ollama/ollama:latest quay.local.momolab.io/mirror/ollama-chat/ollama:latest
podman push --authfile=/home/momo/auth.json quay.local.momolab.io/mirror/ollama-chat/ollama:latest

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
  storageClassName: ocs-external-storagecluster-ceph-rbd
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
  name: open-webui-data
  namespace: ollama-chat
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ocs-external-storagecluster-ceph-rbd
  resources:
    requests:
      storage: 5Gi
```

Apply both and confirm they bind:

```bash
oc apply -f ollama-pvc.yaml
oc apply -f open-webui-pvc.yaml
oc get pvc
```

Both PVCs should show `STATUS: Bound` within a few seconds.

---

## Step 5: Create Service Accounts and Grant SCC

Both Ollama and Open WebUI need to run as root, which OpenShift blocks by default. We create dedicated ServiceAccounts and grant them the `anyuid` Security Context Constraint.

```bash
# Ollama
oc create serviceaccount ollama
oc adm policy add-scc-to-user anyuid -z ollama

# Open WebUI
oc create serviceaccount open-webui
oc adm policy add-scc-to-user anyuid -z open-webui
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
          image: quay.local.momolab.io/mirror/ollama-chat/ollama:latest
          ports:
            - containerPort: 11434
          env:
            - name: OLLAMA_HOST
              value: "0.0.0.0"
            - name: OLLAMA_NUM_PARALLEL
              value: "2"
            - name: OLLAMA_MAX_LOADED_MODELS
              value: "1"
          resources:
            requests:
              memory: "8Gi"
              cpu: "4"
            limits:
              memory: "16Gi"
              cpu: "16"
          volumeMounts:
            - name: ollama-models
              mountPath: /root/.ollama
      volumes:
        - name: ollama-models
          persistentVolumeClaim:
            claimName: ollama-models
```

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

Ollama stores models in its own blob format, not as plain GGUF files. Copy both the `blobs` and `manifests` directories from your workstation into the running pod. The files are owned by the `ollama` system user so `sudo` is required.

```bash
sudo oc cp /usr/share/ollama/.ollama/models/blobs \
  $(oc get pod -l app=ollama -o name | sed 's/pod\///'):/root/.ollama/models/

sudo oc cp /usr/share/ollama/.ollama/models/manifests \
  $(oc get pod -l app=ollama -o name | sed 's/pod\///'):/root/.ollama/models/
```

Verify the model is registered:

```bash
oc exec -it $(oc get pod -l app=ollama -o name) -- ollama list
```

You should see `llama3.2:3b` and `llama3.2:latest` listed.

Test inference:

```bash
oc exec -it $(oc get pod -l app=ollama -o name) -- ollama run llama3.2:3b "Reply with one short sentence only: what is the capital of France?"
```

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
              value: "http://ollama:11434"
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
            claimName: open-webui-data
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
oc get route open-webui
```

Navigate to the URL in your browser. On first visit you will be prompted to create an admin account.

---

## Final State

After completing all steps, the following resources exist in the `ollama-chat` namespace:

| Resource | Name | Purpose |
|---|---|---|
| Deployment | ollama | Serves the LLM via REST API on port 11434 |
| Deployment | open-webui | Chat interface on port 8080 |
| Service | ollama | Internal cluster DNS for Ollama |
| Service | open-webui | Internal cluster DNS for Open WebUI |
| Route | open-webui | HTTPS ingress via OpenShift router |
| PVC | ollama-models | 50Gi Ceph block storage for model files |
| PVC | open-webui-data | 5Gi Ceph block storage for SQLite chat history |
| ServiceAccount | ollama | Runs Ollama with anyuid SCC |
| ServiceAccount | open-webui | Runs Open WebUI with anyuid SCC |

---

## Post-Installation Hardening

The `WEBUI_SECRET_KEY` is currently stored in plain text in the deployment manifest. Move it to a Secret:

```bash
oc create secret generic open-webui-secret \
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
oc exec -it $(oc get pod -l app=ollama -o name) -- ollama run <model-name>
```

Open WebUI will automatically detect any models registered with Ollama and make them available in the model selector dropdown.
