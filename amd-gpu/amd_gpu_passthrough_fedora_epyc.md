# AMD GPU Passthrough on Fedora (EPYC/Supermicro H11SSL-i)
## Complete Setup Guide

**Host:** Supermicro H11SSL-i, AMD EPYC 7001 series (Naples), Fedora 37  
**GPU:** AMD Radeon RX 6600 (Navi 23, `1002:73ff`)  
**Goal:** Pass the GPU through to a libvirt KVM VM (SNO) for use with OpenShift AI / ROCm

---

## Prerequisites

- Fedora host with KVM/libvirt installed
- AMD GPU physically installed in a PCIe slot
- IPMI or physical access to the server BIOS
- VM already created with UEFI boot (required for GPU passthrough)

---

## Step 1: Enable IOMMU in the BIOS

Access the server BIOS via IPMI remote console and navigate to:

```
Advanced → North Bridge Configuration
```

Set the following:
- **IOMMU** → `Enabled`
- **ACS Enable** → `Auto`

Also confirm under `Advanced → CPU Configuration`:
- **SVM Mode** → `Enabled`

Save and reboot.

---

## Step 2: Verify IOMMU Hardware Support

After reboot, confirm AMD-Vi is present in the hardware:

```bash
dmesg | grep -i "AMD-Vi\|DMAR\|IVRS"
```

At this stage you may see nothing, or just generic IOMMU messages — that's expected until the kernel parameters are added.

---

## Step 3: Enable IOMMU in the Kernel

Add the required kernel parameters permanently:

```bash
sudo grubby --update-kernel=ALL --args="amd_iommu=on iommu=pt"
sudo reboot
```

After reboot, verify:

```bash
# Confirm parameters are active
cat /proc/cmdline

# Confirm AMD-Vi is initialised
dmesg | grep -i "AMD-Vi\|iommu"

# Confirm IOMMU groups are populated
find /sys/kernel/iommu_groups/ -type l | sort -V | head -30
```

**Expected output** in dmesg:
```
AMD-Vi: Using global IVHD EFR...
iommu: Default domain type: Passthrough
AMD-Vi: Interrupt remapping enabled
AMD-Vi: Virtual APIC enabled
perf/amd_iommu: Detected AMD IOMMU #0 (2 banks, 4 counters/bank).
```

On a 4-die EPYC Naples CPU you should see 4 IOMMU units detected and 70+ IOMMU groups created.

> **Note:** The warning `AMD-Vi: Unknown option - 'on'` is harmless on newer kernels and can be ignored.

---

## Step 4: Identify the GPU and Its IOMMU Groups

Check the GPU is detected and note its PCI addresses:

```bash
lspci -nnk | grep -A3 -i "VGA\|Radeon\|AMD/ATI"
```

Check which IOMMU groups the GPU and its audio device landed in:

```bash
for g in $(find /sys/kernel/iommu_groups/ -maxdepth 1 -mindepth 1 -type d | sort -V); do
  echo "IOMMU Group ${g##*/}:"
  for d in $g/devices/*; do
    echo -e "\t$(lspci -nns ${d##*/})"
  done
done | grep -A5 "VGA\|Radeon\|1002:"
```

**What to look for:** The GPU (`1002:73ff`) and its HDMI audio device (`1002:ab28`) should each be in their own isolated IOMMU group with no other devices sharing the group. This is the ideal passthrough scenario and requires no ACS override patch.

**Determine NUMA node** from the PCI address prefix:
- `00:xx` - `1f:xx` → NUMA node 0
- `20:xx` - `3f:xx` → NUMA node 1
- `40:xx` - `5f:xx` → NUMA node 2
- `60:xx` - `7f:xx` → NUMA node 3

In this setup the RX 6600 landed at `23:00.0` — NUMA node 1.

---

## Step 5: Bind the GPU to vfio-pci

The GPU must be claimed by `vfio-pci` before `amdgpu` can attach to it at boot. This is done via modprobe configuration and initramfs.

### Create the vfio modprobe config

```bash
sudo vi /etc/modprobe.d/vfio.conf
```

Add the following, substituting your GPU and audio PCI IDs:

```
options vfio-pci ids=1002:73ff,1002:ab28
softdep amdgpu pre: vfio-pci
```

### Create the dracut config

```bash
sudo vi /etc/dracut.conf.d/vfio.conf
```

Add:

```
add_drivers+=" vfio vfio_iommu_type1 vfio_pci "
```

> **Note:** `vfio_virqfd` was merged into the `vfio` module in kernel 6.2+ and should **not** be included on Fedora 37 with kernel 6.5. Including it will cause dracut to fail.

### Rebuild the initramfs

```bash
sudo dracut -f --kver $(uname -r)
sudo reboot
```

> **Note on kernel updates:** You do not need to manually rebuild the initramfs after kernel updates. When `dnf` installs a new kernel, dracut automatically rebuilds the initramfs for it using your config files in `/etc/dracut.conf.d/`. The manual `dracut -f` command is only needed when you change the config on an already-installed kernel.

---

## Step 6: Verify vfio-pci Binding

After reboot, confirm both devices are now bound to `vfio-pci`:

```bash
lspci -nnk | grep -A3 "23:00"
```

Expected output:

```
23:00.0 VGA compatible controller: AMD/ATI Navi 23 [Radeon RX 6600] [1002:73ff]
    Kernel driver in use: vfio-pci
    Kernel modules: amdgpu
23:00.1 Audio device: AMD/ATI Navi 21/23 HDMI/DP Audio Controller [1002:ab28]
    Kernel driver in use: vfio-pci
    Kernel modules: snd_hda_intel
```

The key indicator is `Kernel driver in use: vfio-pci`. The `Kernel modules:` line still shows `amdgpu` — this is correct and expected. It means the kernel knows about amdgpu but vfio-pci claimed the device first.

The host Fedora system will have no discrete GPU at this point and falls back to the ASPEED AST2500 BMC graphics for any host display needs.

---

## Step 7: Verify GPU Inside the VM

After starting the VM, SSH in and confirm the GPU is visible and initialised:

```bash
lspci | grep -i "AMD\|Radeon\|VGA"
dmesg | grep -i "amdgpu\|radeon"
```

**Expected lspci output:**
```
08:00.0 VGA compatible controller: AMD/ATI Navi 23 [Radeon RX 6600/6600 XT/6600M]
09:00.0 Audio device: AMD/ATI Navi 21/23 HDMI/DP Audio Controller
```

**Key dmesg lines confirming success:**
```
amdgpu 0000:08:00.0: amdgpu: VRAM: 8176M ... (8176M used)
kfd kfd: amdgpu: added device 1002:73ff
amdgpu 0000:08:00.0: amdgpu: SE 2, SH per SE 2, CU per SH 8, active_cu_number 28
[drm] Initialized amdgpu 3.59.0 for 0000:08:00.0
```

The KFD (Kernel Fusion Driver) line `added device 1002:73ff` is particularly important — this is the compute interface used by ROCm for GPU acceleration.

---

## Hardware Reference

### Host System

| Component | Detail |
|---|---|
| Motherboard | Supermicro H11SSL-i |
| CPU | AMD EPYC 7001 series (Naples, single socket) |
| NUMA topology | 4 nodes, 12 CPUs each, ~64GB RAM each |
| PCIe slots | 3x PCIe 3.0 x16, 3x PCIe 3.0 x8 |
| BMC | ASPEED AST2500 |

### GPU

| Component | Detail |
|---|---|
| Card | AMD Radeon RX 6600 (Gigabyte) |
| GPU PCI ID | `1002:73ff` |
| Audio PCI ID | `1002:ab28` |
| VRAM | 8GB GDDR6 |
| Host PCI address | `23:00.0` / `23:00.1` |
| NUMA node | 1 (die 1, `20:` domain) |
| IOMMU groups | 41 (GPU), 42 (audio) — isolated, no sharing |
| VM PCI address | `08:00.0` / `09:00.0` |

---

## Next Steps

With the GPU passing through cleanly into the SNO VM, the next steps toward OpenShift AI are:

1. Mirror the AMD GPU Operator images to the local Quay registry
2. Install the AMD GPU Operator in OpenShift
3. Install OpenShift AI operator and its dependencies
4. Deploy a vLLM serving runtime backed by the RX 6600
5. Migrate from Ollama to OpenShift AI model serving
