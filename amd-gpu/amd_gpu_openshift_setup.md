# AMD GPU Passthrough to OpenShift SNO
## End-to-End Setup Guide: vfio-pci Host Binding through ROCm GPU Compute

| | |
|---|---|
| **Host** | Fedora 38, libvirt 9.0, AMD EPYC 7401 |
| **GPU** | AMD Radeon RX 6600 (Navi 23, `1002:73ff`) |
| **Guest** | OpenShift SNO 4.20 (RHEL CoreOS 9.6) |
| **Goal** | ROCm GPU compute via AMD GPU Operator |

---

## Overview

This guide covers the complete setup from a GPU that is already physically installed and visible in the host OS, through to a working ROCm compute environment inside OpenShift Single Node OpenShift (SNO). It assumes the GPU passthrough to the libvirt VM has already been configured (IOMMU, vfio-pci binding, VM XML). For that prior work, see the companion document *AMD GPU Passthrough on Fedora (EPYC/Supermicro H11SSL-i)*.

The guide is split into four phases:

- **Phase 1:** Verify the GPU is healthy on the host and visible inside the VM
- **Phase 2:** Install the three required OpenShift operators via OperatorHub GUI
- **Phase 3:** Configure the operators and verify ROCm GPU compute works
- **Phase 4:** Deploy Ollama with GPU inference and Open WebUI chat frontend

### Architecture Overview

Three operators work in sequence to expose the GPU to OpenShift workloads:

| Operator | Role |
|---|---|
| Node Feature Discovery (NFD) | Scans PCI bus, labels node with `feature.node.kubernetes.io/pci-1002.present=true` (for reference `feature.node.kubernetes.io/pci-10de.present=true` (10de is NVIDIA's vendor ID).) |
| Kernel Module Management (KMM) | Builds and loads the `amdgpu` kernel module into the immutable CoreOS node |
| AMD GPU Operator | Deploys device plugin so pods can request `amd.com/gpu: 1` as a resource |

> **Note:** OpenShift nodes are immutable — you cannot SSH in and run `dnf install`. KMM solves this by building the kernel module in a container and loading it via a privileged DaemonSet, making it persistent and automatic across reboots.

---

## Phase 1: Verify GPU Visibility

### Step 1 — Verify GPU is Bound to vfio-pci on the Host

Before starting the VM, confirm the GPU endpoints are bound to the `vfio-pci` driver and not to `amdgpu`:

```bash
lspci -ks 23:00.0 | grep driver
lspci -ks 23:00.1 | grep driver
```

Expected output:

```
Kernel driver in use: vfio-pci
Kernel driver in use: vfio-pci
```

> ⚠️ **Warning:** If the driver shows `amdgpu` instead of `vfio-pci`, the binding has not persisted. Check `/etc/modprobe.d/vfio-pci.conf` and rebuild the initramfs: `sudo dracut --force`

Also verify the VFIO device nodes exist:

```bash
ls -la /dev/vfio/

# Expected:
# crw-------. 1 root root 239, 41  /dev/vfio/41  <- RX 6600 VGA (IOMMU group 41)
# crw-------. 1 root root 239, 42  /dev/vfio/42  <- HDMI Audio (IOMMU group 42)
```

### Step 2 — Start the VM and Verify GPU Inside SNO

Start the VM and SSH into the SNO node:

```bash
sudo virsh start sno1
ssh core@sno1.local.momolab.io
```

Confirm the GPU is visible on the guest PCI bus:

```bash
sudo lspci | grep -i 'AMD\|ATI'

# Expected output:
# 08:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI]
#         Navi 23 [Radeon RX 6600/6600 XT/6600M] (rev c7)
# 09:00.0 Audio device: Advanced Micro Devices, Inc. [AMD/ATI]
#         Navi 21/23 HDMI/DP Audio Controller
```

> **Note:** The guest PCI addresses (`08:00.0`, `09:00.0`) differ from the host addresses (`23:00.0`, `23:00.1`). QEMU assigns new addresses inside the VM.

Confirm the `amdgpu` module is NOT yet loaded (KMM will load it later):

```bash
lsmod | grep amdgpu
# Expected: no output
```

---

## Phase 2: Install OpenShift Operators

All three operators are installed via the OpenShift web console OperatorHub. Navigate to **Operators > OperatorHub** in the left menu for each installation.

> ⚠️ **Disconnected clusters:** Ensure operator images are mirrored to your local registry and an `ImageContentSourcePolicy` or `ImageDigestMirrorSet` is configured before proceeding.

### Step 3 — Install Node Feature Discovery (NFD) Operator

In the OpenShift web console:

1. Navigate to **Operators > OperatorHub**
2. Search for: `Node Feature Discovery`
3. Select: **Node Feature Discovery** (provided by Red Hat)
4. Click **Install**
5. Installation Mode: `A specific namespace on the cluster`
6. Installed Namespace: `openshift-nfd` (create if it does not exist)
7. Click **Install** and wait for status: `Succeeded`

After the operator installs, create the NodeFeatureDiscovery instance. Navigate to **Operators > Installed Operators > Node Feature Discovery > NodeFeatureDiscovery > Create NodeFeatureDiscovery** and apply:

```yaml
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  workerConfig:
    configData: |
      sources:
        pci:
          deviceClassWhitelist:
            - "0300"
            - "0302"
          deviceLabelFields:
            - "vendor"
  operand:
    imagePullPolicy: IfNotPresent
    servicePort: 12000
```

> **Note:** `deviceClassWhitelist` values `0300` and `0302` are PCI class codes for VGA controllers. They match by class, not by PCI bus address — the `08:00.0` guest address is irrelevant here. For disconnected clusters, add `spec.operand.image` pointing to your local registry if no `ImageContentSourcePolicy` is configured.

Verify NFD is running and has labeled the node:

```bash
oc get pods -n openshift-nfd
# Expected: nfd-controller-manager, nfd-master, nfd-worker, nfd-gc all Running

oc get node -o json | jq '.items[].metadata.labels | with_entries(
  select(.key | contains("pci-1002")))'

# Expected output:
# {
#   "feature.node.kubernetes.io/pci-1002.present": "true"
# }
```

### Step 4 — Install Kernel Module Management (KMM) Operator

In the OpenShift web console:

1. Navigate to **Operators > OperatorHub**
2. Search for: `Kernel Module Management`
3. Select: **Kernel Module Management** (provided by Red Hat)
4. Click **Install**
5. Installation Mode: `All namespaces on the cluster`
6. Click **Install** and wait for status: `Succeeded`

KMM does not require a custom CR at this stage. Verify it is running:

```bash
oc get pods -n openshift-kmm
# Expected:
# kmm-operator-controller-xxxxx   1/1   Running
# kmm-operator-webhook-xxxxx      1/1   Running
```

### Step 5 — Install AMD GPU Operator

In the OpenShift web console:

1. Navigate to **Operators > OperatorHub**
2. Search for: `AMD GPU`
3. Select: **AMD GPU Operator** (provided by AMD)
4. Click **Install**
5. Installation Mode: `A specific namespace on the cluster`
6. Installed Namespace: `openshift-amd-gpu` (create if it does not exist)
7. Click **Install** and wait for status: `Succeeded`

Verify the controller is running:

```bash
oc get pods -n openshift-amd-gpu
# Expected:
# amd-gpu-operator-controller-manager-xxxxx   1/1   Running
```

---

## Phase 3: Configure and Verify

### Step 6 — Enable the Internal Image Registry

KMM builds the `amdgpu` kernel module inside the cluster and stores the resulting image in the OpenShift internal image registry. On SNO this registry is disabled by default and must be enabled.

```bash
# Preferred: Enable with PVC (persistent) — requires a default StorageClass (e.g. lvms-vg1)
oc patch configs.imageregistry.operator.openshift.io cluster --type=merge \
  -p '{"spec":{"managementState":"Managed","storage":{"pvc":{"claim":""}},"replicas":1}}'

# Alternative: Enable with emptyDir (ephemeral) — lost on registry pod restart
oc patch configs.imageregistry.operator.openshift.io cluster --type=merge \
  -p '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}},"replicas":1}}'

# Wait for the registry pod to be ready
oc get pods -n openshift-image-registry -w
# Expected: image-registry-xxxxx   1/1   Running
```

Allow the internal registry to be accessed without TLS verification (required for KMM build pods):

```bash
oc patch image.config.openshift.io/cluster --type=merge -p \
  '{"spec":{"registrySources":{"insecureRegistries":["image-registry.openshift-image-registry.svc:5000"]}}}'
```

### Step 7 — Apply AMD GPU Module Parameters via MachineConfig

The `amdgpu` kernel module requires specific parameters when passed through via VFIO. Without these, the SMU (System Management Unit) firmware version mismatch between the driver and the GPU firmware causes initialization to fail with error `-95 (EOPNOTSUPP)`.

```bash
oc apply -f - << 'EOF'
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-amdgpu-modprobe
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - path: /etc/modprobe.d/amdgpu.conf
        mode: 0644
        contents:
          source: data:text/plain;charset=utf-8;base64,b3B0aW9ucyBhbWRncHUgbm9yZXRyeT0xIHBwZmVhdHVyZW1hc2s9MCBncHVfcmVjb3Zlcnk9MQ==
EOF

# The base64 decodes to: options amdgpu noretry=1 ppfeaturemask=0 gpu_recovery=1

# Wait for MachineConfigPool to apply and node to reboot
oc get mcp master -w
# Wait until: UPDATED=True  UPDATING=False  DEGRADED=False
```

| Parameter | Purpose |
|---|---|
| `noretry=1` | Disables retry on failed GPU memory operations — prevents hang in VM |
| `ppfeaturemask=0` | Disables all power/performance features — works around SMU firmware version mismatch |
| `gpu_recovery=1` | Enables automatic GPU recovery on errors |

### Step 8 — Create the DeviceConfig CR

The DeviceConfig CR triggers the AMD GPU Operator to build the kernel module via KMM, deploy the device plugin, and run the node labeller.

First, verify the driver version exists for your RHEL version:

```bash
# Check the node OS version
oc get node -o json | jq '.items[].metadata.labels["feature.node.kubernetes.io/system-os_release.VERSION_ID"]'
# Example output: "9.6"

# Verify the driver version exists for your OS
curl -s https://repo.radeon.com/amdgpu/6.4.4/el/9.6/main/x86_64/repodata/repomd.xml \
  -o /dev/null -w "%{http_code}"
# Expected: 200
```

Apply the DeviceConfig:

```bash
oc apply -f - << 'EOF'
apiVersion: amd.com/v1alpha1
kind: DeviceConfig
metadata:
  name: amd-gpu-config
  namespace: openshift-amd-gpu
spec:
  selector:
    feature.node.kubernetes.io/pci-1002.present: "true"
  driver:
    enable: true
    version: "6.4.4"
  devicePlugin:
    enable: true
    enableNodeLabeller: true
EOF
```

> **Note:** The driver version (`6.4.4`) must exist in the AMD repository for your OS version. Check available versions at `https://repo.radeon.com/amdgpu/` — look for directories matching your RHEL version under the `el/` subdirectory.

### Step 9 — Monitor the Build Process

After creating the DeviceConfig, KMM triggers a container build to compile `amdgpu-dkms`. This takes **10–30 minutes** depending on available CPU resources.

```bash
# Watch pods appear
oc get pods -n openshift-amd-gpu -w

# Follow the build log (replace pod name with actual)
oc logs -f amd-gpu-config-build-xxxxx-build -n openshift-amd-gpu

# The build succeeds when you see:
# Successfully pushed image-registry.openshift-image-registry.svc:5000/
#   openshift-amd-gpu/amdgpu_kmod:coreos-9.6-<kernel>-6.4.4
# Push successful
```

After a successful build, KMM deploys a worker pod to load the module onto the node:

```bash
# Verify the module is loaded on the node
oc debug node/sno1.local.momolab.io -- chroot /host lsmod | grep amdgpu

# Verify KFD (compute interface) initialized
oc debug node/sno1.local.momolab.io -- chroot /host dmesg | grep kfd
# Expected: kfd kfd: amdgpu: added device 1002:73ff
```

### Step 10 — Verify GPU Resource Availability

```bash
oc get node -o json | jq '.items[].status.capacity | with_entries(
  select(.key | contains("amd")))'

# Expected output:
# {
#   "amd.com/gpu": "1"
# }
```

### Step 11 — Run the ROCm Smoke Test

```bash
oc run gpu-test --image=docker.io/rocm/rocm-terminal:6.4 --restart=Never \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "gpu-test",
        "image": "docker.io/rocm/rocm-terminal:6.4",
        "command": ["rocminfo"],
        "resources": {"limits": {"amd.com/gpu": "1"}},
        "securityContext": {
          "privileged": true,
          "runAsUser": 0,
          "supplementalGroups": [797, 44]
        },
        "volumeMounts": [
          {"mountPath": "/dev/dri", "name": "dri"},
          {"mountPath": "/dev/kfd", "name": "kfd"}
        ]
      }],
      "volumes": [
        {"name": "dri", "hostPath": {"path": "/dev/dri"}},
        {"name": "kfd", "hostPath": {"path": "/dev/kfd"}}
      ]
    }
  }' \
  --command -- rocminfo

# Wait for completion then check logs
oc logs gpu-test

# Clean up
oc delete pod gpu-test
```

Expected output confirming success:

```
ROCk module is loaded
=====================
HSA System Attributes
=====================
Runtime Version:         1.15
...
*******
Agent 2
*******
  Name:                    gfx1032
  Marketing Name:          AMD Radeon RX 6600
  Device Type:             GPU
  Compute Unit:            28
  Pool Info:
    Pool 1
      Size:                    8372224(0x7fc000) KB    <- 8GB VRAM
*** Done ***
```

✅ **AMD Radeon RX 6600 fully operational.** 28 compute units, 8GB VRAM, ISA `gfx1032` (Navi 23). GPU is schedulable via `amd.com/gpu: 1` in pod resource requests.

---

## Phase 4: Ollama GPU Inference + Open WebUI

This phase deploys Ollama (LLM inference server) using the AMD GPU for acceleration, with Open WebUI as the chat frontend. Prerequisites: Phase 3 complete, GPU schedulable as `amd.com/gpu: 1`, LVMS storage available.

### Step 12 — Prevent GPU Runtime PM Suspend (Critical)

The RX 6600 SMU firmware mismatch causes the GPU to enter an unrecoverable error state if the kernel's runtime power management suspends it. The GPU resumes with `gfx_v10_0 failed -110`, making `/dev/dri/renderD129` return `EINVAL` on every open call until the node is rebooted.

Apply this MachineConfig **before** deploying any GPU workloads:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-amdgpu-norunpm
  labels:
    machineconfiguration.openshift.io/role: master
spec:
  kernelArguments:
    - amdgpu.runpm=0
EOF
```

Wait for the node to reboot and MCP to settle:

```bash
watch -n5 "oc get mcp master"
# Wait until: UPDATED=True  UPDATING=False  DEGRADED=False
```

Verify after reboot:

```bash
oc debug node/sno1.local.momolab.io -- nsenter -a -t 1 -- sh -c "
  cat /proc/cmdline | grep -o 'amdgpu.runpm=0' && echo 'kernel arg OK'
  cat /sys/bus/pci/devices/0000:08:00.0/power/runtime_status
  dd if=/dev/dri/renderD129 bs=1 count=0 2>&1 && echo 'renderD129 OK'
"
# Expected: amdgpu.runpm=0 kernel arg OK / active / renderD129 OK
```

### Step 13 — Mirror the Ollama ROCm Image

The `ollama:rocm` image bundles the ROCm runtime. Mirror it to your local registry:

```bash
podman pull docker.io/ollama/ollama:rocm
podman tag docker.io/ollama/ollama:rocm quay.local.momolab.io/mirror/ollama-chat/ollama:rocm
podman push --authfile=/home/momo/auth.json quay.local.momolab.io/mirror/ollama-chat/ollama:rocm
```

Also mirror Open WebUI:

```bash
podman pull ghcr.io/open-webui/open-webui:main
podman tag ghcr.io/open-webui/open-webui:main quay.local.momolab.io/mirror/ollama-chat/open-webui:main
podman push --authfile=/home/momo/auth.json quay.local.momolab.io/mirror/ollama-chat/open-webui:main
```

### Step 14 — Create Namespace, PVCs, and Service Accounts

```bash
oc new-project ollama-chat

# PVCs
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-models
  namespace: ollama-chat
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: lvms-vg1
  resources:
    requests:
      storage: 50Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-webui-data
  namespace: ollama-chat
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: lvms-vg1
  resources:
    requests:
      storage: 5Gi
EOF

# Service accounts with anyuid SCC
oc create serviceaccount ollama -n ollama-chat
oc create serviceaccount open-webui -n ollama-chat
oc adm policy add-scc-to-user anyuid -z ollama -n ollama-chat
oc adm policy add-scc-to-user anyuid -z open-webui -n ollama-chat
```

> **Note:** PVCs will remain `Pending` (WaitForFirstConsumer) until a pod is scheduled — this is normal for LVMS.

### Step 15 — Deploy Ollama with GPU

```bash
cat <<'EOF' | oc apply -f -
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
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: ollama-chat
spec:
  selector:
    app: ollama
  ports:
    - port: 11434
      targetPort: 11434
EOF
```

> **Important:** `strategy.type: Recreate` is required. `amd.com/gpu: 1` is an exclusive resource — RollingUpdate will deadlock because the new pod cannot claim the GPU until the old pod releases it.

> **`HSA_OVERRIDE_GFX_VERSION=10.3.0`** tells the ROCm HSA runtime to treat the RX 6600 (gfx1032) as gfx1030-family, which has full ROCm support. Required for Navi 23.

> **`LD_LIBRARY_PATH`** ensures Ollama's subprocess runner can find `libggml-base.so.0` alongside the ROCm libraries. Without this, Ollama skips the ROCm backend entirely.

> **Do not set `OLLAMA_LLM_LIBRARY=hip`** — this causes Ollama to skip the hip library rather than use it.

### Step 16 — Load a Model

Copy a model from your workstation to the pod (model must already be pulled with `ollama pull` on the workstation):

```bash
OLLAMA_POD=$(oc get pod -l app=ollama -n ollama-chat --field-selector=status.phase=Running -o name | sed 's|pod/||')

oc cp /usr/share/ollama/.ollama/models/blobs/. ${OLLAMA_POD}:/root/.ollama/models/blobs/ -n ollama-chat
oc cp /usr/share/ollama/.ollama/models/manifests/. ${OLLAMA_POD}:/root/.ollama/models/manifests/ -n ollama-chat

# Verify the model is registered
oc exec -it ${OLLAMA_POD} -n ollama-chat -- ollama list
```

### Step 17 — Verify GPU Inference

Check Ollama startup logs for GPU detection:

```bash
oc logs ${OLLAMA_POD} -n ollama-chat | grep -i "inference compute"
# Expected:
# inference compute id=0 library=ROCm compute=gfx1030 name=ROCm0 total="8.0 GiB"
```

Run a test inference and verify VRAM usage:

```bash
# VRAM before (should be ~16MB idle)
oc exec -it ${OLLAMA_POD} -n ollama-chat -- sh -c "cat /sys/class/drm/card1/device/mem_info_vram_used"

# Run inference
oc exec -it ${OLLAMA_POD} -n ollama-chat -- ollama run llama3.2:3b "what is 2+2? answer in one word"

# VRAM after (should be ~3.3GB with llama3.2:3b loaded)
oc exec -it ${OLLAMA_POD} -n ollama-chat -- sh -c "cat /sys/class/drm/card1/device/mem_info_vram_used"
```

Check Ollama logs confirm all layers on GPU:

```bash
oc logs ${OLLAMA_POD} -n ollama-chat | grep -i "offload\|layers\|ROCm"
# Expected:
# load_tensors: offloaded 29/29 layers to GPU
# load_tensors: ROCm0 model buffer size = 1918.35 MiB
```

### Step 18 — Deploy Open WebUI

```bash
cat <<'EOF' | oc apply -f -
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
            - name: WEBUI_SECRET_KEY
              value: "replace-with-a-random-string"
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "1Gi"
              cpu: "1"
          volumeMounts:
            - name: webui-data
              mountPath: /app/backend/data
      volumes:
        - name: webui-data
          persistentVolumeClaim:
            claimName: ollama-webui-data
---
apiVersion: v1
kind: Service
metadata:
  name: open-webui
  namespace: ollama-chat
spec:
  selector:
    app: open-webui
  ports:
    - port: 8080
      targetPort: 8080
---
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
EOF
```

Get the URL:

```bash
oc get route open-webui -n ollama-chat
# Access at: https://open-webui-ollama-chat.apps.sno1.local.momolab.io
```

### Performance Reference

Measured on RX 6600 (8GB VRAM) with VFIO passthrough, RHEL CoreOS 9.6, amdgpu stock kernel driver:

| Model | VRAM | Tokens/sec | Notes |
|---|---|---|---|
| llama3.2:1b | ~1GB | ~35-40 tok/s | Fast, limited quality |
| llama3.2:3b | ~2GB | ~15-20 tok/s | Good balance for simple tasks |
| llama3.1:8b | ~4.7GB | ~5-8 tok/s | Best quality that fits in 8GB VRAM |

> **Note:** Models larger than ~8B parameters at Q4 quantization will not fit in 8GB VRAM. Ollama will split them across GPU+CPU which degrades performance to near-CPU speeds.

> **Clock reporting:** `pp_dpm_sclk` reports 0MHz due to the SMU firmware version mismatch — this is a telemetry failure, not actual clock throttling. The GPU computes at full speed as confirmed by the tokens/second measurements above.

---

## Troubleshooting Reference

### Build Failures

| Error | Fix |
|---|---|
| `404 for repo.radeon.com/amdgpu/X.X.X/el/9.X` | Driver version does not exist for your OS. The AMD GPU Operator uses the `DRIVERS_VERSION` field directly as a path component (e.g. `6.4.4` → `amdgpu/6.4.4/el/9.6/`). Verify the path exists: `curl -s https://repo.radeon.com/amdgpu/6.4.4/el/9.6/main/x86_64/repodata/repomd.xml -o /dev/null -w "%{http_code}"`. Use `latest` or check `https://repo.radeon.com/amdgpu/` for valid versions. |
| Build uses wrong OS version (e.g. `el/9.4` instead of `el/9.6`) | The Dockerfile uses `${VERSION_ID}` from `/etc/os-release`. If the build is picking up the wrong version, patch the KMM build ConfigMap directly (scale down the operator first to prevent it overwriting the ConfigMap). |
| `x509: certificate signed by unknown authority` | CA not trusted by build pod. Ensure your CA is in the cluster additional trusted CA ConfigMap: `oc get image.config.openshift.io/cluster` |
| `pinging container registry image-registry: no such host` | Internal image registry not enabled. Apply the patch from Step 6. |
| `expected 0 or 1 BuildImage resources, got 2` | Stale Build objects from a version change. Run: `oc delete build --all -n openshift-amd-gpu` then `oc delete mbsc amd-gpu-config -n openshift-amd-gpu` |

### Module Load Failures

| Error | Fix |
|---|---|
| `amdgpu: probe of 0000:08:00.0 failed with error -95` | SMU firmware mismatch. Apply the MachineConfig from Step 7 with `ppfeaturemask=0` |
| `Key was rejected by service` | Secure Boot is rejecting an unsigned KMM-built module. The stock RHEL kernel amdgpu is already signed by Red Hat and loads correctly without KMM building a new module. Do not attempt to upgrade the amdgpu driver via KMM unless you have a MOK enrolled for signing. |
| `SMU driver if version not matched` | Warning only — non-fatal if followed by `SMU is resumed successfully` with `ppfeaturemask=0` applied |
| `rlc autoload: gc ucode autoload timeout` followed by `resume of IP block <gfx_v10_0> failed -110` | GPU failed to resume from runtime PM suspend due to SMU mismatch. Apply `amdgpu.runpm=0` kernel argument (Phase 4, Step 12) and reboot. |
| `feature.node.kubernetes.io/pci-1002.present` missing after reboot | NFD did not rescan. Re-apply manually: `oc label node <node> feature.node.kubernetes.io/pci-1002.present=true` |

### ROCm Failures

| Error | Fix |
|---|---|
| `HSA_STATUS_ERROR_OUT_OF_RESOURCES` | `/dev/kfd` not accessible. Ensure it is mounted in the container and `supplementalGroups` includes `797` (render group GID) |
| `amd.com/gpu: 0` (device plugin running) | `amdgpu` module failed to initialize. Check `dmesg` for probe errors. `dmesg \| grep kfd` should show `added device 1002:73ff` |
| `rocm-terminal` image pull fails | Check available tags: `curl -s "https://registry.hub.docker.com/v2/repositories/rocm/rocm-terminal/tags/?page_size=20" \| python3 -m json.tool \| grep name` |

### VM / Host Issues

| Error | Fix |
|---|---|
| `Unknown PCI header type '127'` | GPU in zombie state from unclean VM shutdown. **Requires full host reboot** to power cycle the GPU. |
| libvirt 8.6.0: `Unknown PCI header type '127'` | libvirt bug fixed in 9.0. Upgrade libvirt and add `<driver name='vfio'/>` inside each `<hostdev>` in the VM XML. |
| Config space returns all `0xFF` | GPU not responding on PCI bus. Full host reboot required. |

> ⚠️ **Never suspend the host or VM while GPU passthrough is active.** The GPU enters a state where PCI config reads return `0xFF` and libvirt cannot start the domain until the host is fully power cycled. Always cleanly shut down the VM first: `sudo virsh shutdown sno1`

---

## Known Issues and Limitations

| Issue | Notes |
|---|---|
| SMU firmware version mismatch warning | The stock RHEL 9.6 amdgpu driver (5.14 kernel) reports version mismatch against GPU SMU firmware `59.49.0`. Non-fatal — GPU initialises successfully and compute works. DPM clock reporting via `pp_dpm_sclk` shows 0MHz but GPU is actively computing. |
| Runtime PM suspend/resume failure | With SMU version mismatch, runtime PM suspend triggers a broken resume path (`rlc autoload timeout`, `gfx_v10_0 resume failed -110`). `/dev/dri/renderD129` returns `EINVAL` after this occurs. **Fix:** Apply `amdgpu.runpm=0` kernel argument via MachineConfig (see Phase 4). Requires reboot. |
| NFD label lost on reboot | In some cases `pci-1002.present` is not re-applied by NFD after a MachineConfig-triggered reboot. Monitor after reboots and re-apply if needed. |
| `amd-gpu: true` label not from NFD | The `feature.node.kubernetes.io/amd-gpu` label is applied by the AMD GPU Operator node-labeller, not NFD. It requires `amdgpu` to be loaded and `/dev/dri/card1` accessible. |
| emptyDir registry loses images on pod restart | A registry pod restart loses the built kernel module image. KMM triggers a rebuild automatically. Use PVC storage to avoid this. |
| KMM-built module rejected by Secure Boot | DKMS-built modules from AMD's repo are unsigned. Secure Boot (enabled by default on OpenShift) rejects them with `Key was rejected by service`. The stock RHEL kernel amdgpu is Red Hat-signed and loads correctly — KMM module upgrade is not required for basic GPU compute. |
| `pp_dpm_sclk` reports 0MHz | SMU version mismatch prevents DPM telemetry from initialising. GPU is still computing at full speed — this is a reporting failure, not clock throttling. Confirmed by VRAM usage and tokens/second measurements. |

---

## Ansible Automation

Add the following tasks to your OpenShift post-install playbook (after LVMS is configured):

```yaml
- name: Enable internal image registry with PVC storage
  ansible.builtin.shell: |
    set -e -o pipefail
    export KUBECONFIG="{{ myworkdir }}/{{ item }}/ocp/auth/kubeconfig"
    "{{ myworkdir }}"/oc patch configs.imageregistry.operator.openshift.io cluster \
      --type=merge -p '{"spec":{"managementState":"Managed",
      "storage":{"pvc":{"claim":""}},"replicas":1}}'
  with_items: "{{ snos }}"

- name: Wait for image registry pod to be ready
  ansible.builtin.shell: |
    set -e -o pipefail
    export KUBECONFIG="{{ myworkdir }}/{{ item }}/ocp/auth/kubeconfig"
    "{{ myworkdir }}"/oc get pods -n openshift-image-registry \
      | grep -E '^image-registry-' | grep '1/1.*Running'
  with_items: "{{ snos }}"
  register: registry_ready
  until: registry_ready is not failed
  retries: 60
  delay: 10

- name: Allow insecure access to internal image registry
  ansible.builtin.shell: |
    set -e -o pipefail
    export KUBECONFIG="{{ myworkdir }}/{{ item }}/ocp/auth/kubeconfig"
    "{{ myworkdir }}"/oc patch image.config.openshift.io/cluster --type=merge \
      -p '{"spec":{"registrySources":{"insecureRegistries":
      ["image-registry.openshift-image-registry.svc:5000"]}}}'
  with_items: "{{ snos }}"

- name: Apply amdgpu modprobe parameters via MachineConfig
  ansible.builtin.shell: |
    set -e -o pipefail
    export KUBECONFIG="{{ myworkdir }}/{{ item }}/ocp/auth/kubeconfig"
    "{{ myworkdir }}"/oc apply -f - << 'EOF'
    apiVersion: machineconfiguration.openshift.io/v1
    kind: MachineConfig
    metadata:
      labels:
        machineconfiguration.openshift.io/role: master
      name: 99-amdgpu-modprobe
    spec:
      config:
        ignition:
          version: 3.2.0
        storage:
          files:
          - path: /etc/modprobe.d/amdgpu.conf
            mode: 0644
            contents:
              source: data:text/plain;charset=utf-8;base64,b3B0aW9ucyBhbWRncHUgbm9yZXRyeT0xIHBwZmVhdHVyZW1hc2s9MCBncHVfcmVjb3Zlcnk9MQ==
    EOF
  with_items: "{{ snos }}"

- name: Wait for MachineConfigPool to finish applying
  ansible.builtin.shell: |
    set -e -o pipefail
    export KUBECONFIG="{{ myworkdir }}/{{ item }}/ocp/auth/kubeconfig"
    "{{ myworkdir }}"/oc get mcp master \
      -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' | grep -w True
  with_items: "{{ snos }}"
  register: mcp_ready
  until: mcp_ready is not failed
  retries: 60
  delay: 30
```

---

## Quick Reference

### Verification Commands

| What to Check | Command |
|---|---|
| GPU bound to vfio-pci on host | `lspci -ks 23:00.0 \| grep driver` |
| GPU visible in guest | `ssh core@sno1 'sudo lspci \| grep AMD'` |
| NFD label on node | `oc get node -o json \| jq '.items[].metadata.labels["feature.node.kubernetes.io/pci-1002.present"]'` |
| amdgpu module loaded | `oc debug node/sno1... -- chroot /host lsmod \| grep amdgpu` |
| KFD initialized | `oc debug node/sno1... -- chroot /host dmesg \| grep kfd` |
| GPU resource capacity | `oc get node -o json \| jq '.items[].status.capacity \| with_entries(select(.key \| contains("amd")))'` |
| All AMD GPU operator pods | `oc get pods -n openshift-amd-gpu` |
| KMM pods | `oc get pods -n openshift-kmm` |
| NFD pods | `oc get pods -n openshift-nfd` |
| Build status | `oc get builds -n openshift-amd-gpu` |
| Module images config | `oc describe mic amd-gpu-config -n openshift-amd-gpu \| grep -A3 Status` |
| GPU runtime PM disabled | `cat /proc/cmdline \| grep amdgpu.runpm` |
| renderD129 accessible | `dd if=/dev/dri/renderD129 bs=1 count=0 2>&1 && echo OK` |
| GPU runtime status | `cat /sys/bus/pci/devices/0000:08:00.0/power/runtime_status` (expect: `active`) |
| Ollama GPU detection | `oc logs <ollama-pod> -n ollama-chat \| grep "inference compute"` |
| VRAM usage | `oc exec <ollama-pod> -n ollama-chat -- sh -c "cat /sys/class/drm/card1/device/mem_info_vram_used"` |
| Ollama models loaded | `oc exec <ollama-pod> -n ollama-chat -- ollama list` |

### Key Resource Names

| Resource | Name / Namespace |
|---|---|
| NFD Namespace | `openshift-nfd` |
| KMM Namespace | `openshift-kmm` |
| AMD GPU Operator Namespace | `openshift-amd-gpu` |
| NodeFeatureDiscovery CR | `nfd-instance` / `openshift-nfd` |
| DeviceConfig CR | `amd-gpu-config` / `openshift-amd-gpu` |
| Module (created by operator) | `amd-gpu-config` / `openshift-amd-gpu` |
| ModuleBuildSignConfig | `amd-gpu-config` / `openshift-amd-gpu` |
| ModuleImagesConfig | `amd-gpu-config` / `openshift-amd-gpu` |
| MachineConfig (modprobe) | `99-amdgpu-modprobe` / cluster-scoped |
| MachineConfig (runpm) | `99-amdgpu-norunpm` / cluster-scoped |
| Internal registry config | `cluster` / `configs.imageregistry.operator.openshift.io` |
| Ollama Namespace | `ollama-chat` |
| Ollama Deployment | `ollama` / `ollama-chat` |
| Ollama Service | `ollama` / `ollama-chat` (port 11434) |
| Ollama Models PVC | `ollama-models` / `ollama-chat` (50Gi) |
| Open WebUI Deployment | `open-webui` / `ollama-chat` |
| Open WebUI Service | `open-webui` / `ollama-chat` (port 8080) |
| Open WebUI Data PVC | `ollama-webui-data` / `ollama-chat` (5Gi) |
| Open WebUI Route | `open-webui` / `ollama-chat` |
