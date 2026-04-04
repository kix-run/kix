# 72 — AI Cluster Recipes: AICR-Inspired GPU/AI Cluster Configuration

**Status:** Draft
**Related:** `45_cluster_hardware_profile.md` (capability model), `69_hardware_driven_scheduling.md` (hardware depth + fleet), `26_images-vertical-integration.md` (image + NixOS vertical integration), `business_discussions/13_ai_native_infrastructure_positioning.md` (AI positioning)

---

## Problem

NVIDIA released [AICR](https://github.com/NVIDIA/aicr) (AI Cluster Runtime) — a configuration engine that takes a GPU cluster's hardware inventory and produces validated, version-locked deployment artifacts for the full AI infrastructure stack (GPU operator, network operator, NCCL plugins, gang schedulers, monitoring, etc.). Its core value proposition: **"known-good combinations"** — encoding NVIDIA's internal hardware qualification knowledge as machine-readable recipes that prevent the fragile version mismatches that plague GPU clusters.

kix already has many of the architectural primitives that AICR's pipeline requires — flavors, DI-driven composition, hardware capabilities, scorecard validation, and a content-addressed deploy pipeline. But kix lacks three things AICR provides:

1. **GPU/AI-specific domain knowledge** — which component versions work together for a given GPU + cloud + OS + intent combination.
2. **Hardware inventory as input** — AICR's snapshot agent auto-discovers what you have; kix requires manual `cluster.nodes` declarations.
3. **Intent-driven composition** — "I want training on H100s on EKS" resolves to a specific, validated stack. kix composes packages explicitly.

The question: **how much of AICR's value can kix absorb, and what's the right design?**

---

## What AICR Does (and Doesn't Do)

### The Pipeline

AICR is a five-stage data pipeline:

```
snapshot → recipe → validate → bundle → deploy
```

| Stage | What it does | Output |
|-------|-------------|--------|
| **Snapshot** | Privileged K8s Job inventories the cluster: GPUs (nvidia-smi), OS, kernel, drivers, CUDA, K8s version, running images, node topology | Structured `Snapshot` object (ConfigMap or file) |
| **Recipe** | Matches snapshot (or explicit query: `--service eks --accelerator h100 --intent training`) against an overlay library with specificity scoring, resolves multi-level inheritance (up to 10 deep), produces version-locked component set | `Recipe` with `componentRefs`, `constraints`, `deploymentOrder`, `appliedOverlays` |
| **Validate** | Compares recipe constraints against live snapshot — driver versions, K8s version bounds, deployment checks, NCCL bandwidth tests | CTRF (Common Test Report Format) JSON, non-zero exit on failure |
| **Bundle** | Materializes recipe into per-component directories: Helm `values.yaml`, custom manifests, install/undeploy scripts, checksums | Directory tree of deployment artifacts |
| **Deploy** | Transforms bundles into Helm charts or ArgoCD Applications with sync-wave annotations | Ready-to-apply artifacts |

### What AICR is NOT

- Not a K8s distribution (bring your own cluster)
- Not a provisioner (doesn't create nodes)
- Not a general-purpose package manager (only NVIDIA's AI stack)
- Not a runtime (doesn't reconcile or heal)

It's a **configuration oracle**: given your hardware, it tells you the exact versions and settings that work.

### AI/GPU-Specific Components AICR Manages

| Component | Purpose |
|-----------|---------|
| GPU Operator | Driver lifecycle, CUDA, MIG, DCGM exporter |
| Network Operator | RDMA, SR-IOV, host networking for multi-node GPU comms |
| Cloud NCCL plugins | `gke-nccl-tcpxo` (GKE), `aws-efa` (EKS) — GPU-to-GPU network optimization |
| Skyhook | OS-level GPU node tuning: kernel params, sysctl, hugepages, **node reboots** |
| NVSentinel | GPU health monitoring + automated remediation (cordon/drain on GPU errors) |
| DRA Driver | K8s Dynamic Resource Allocation API for GPUs (v1.34+) |
| KAI Scheduler | DRA-aware gang scheduler with hierarchical queues + topology-aware placement |
| Dynamo | Distributed inference with prefix-cache routing, disaggregated prefill/decode |
| Kubeflow Trainer | Distributed training with JobSet |
| kube-prometheus-stack | GPU-specific dashboards, prometheus-adapter for HPA on GPU utilization |
| cert-manager | Foundation dependency (many operators need it) |

---

## Deep Dive: What AICR's Snapshot Actually Discovers and Why

### The snapshot serves two purposes

**1. Recipe matching — "which overlay do I use?"**

Only **3 fields** from the entire snapshot actually drive recipe selection:

| Criteria | Extracted from | How |
|----------|---------------|-----|
| **Service** (eks/gke/aks) | K8s server version string (`-eks-`, `-gke` substring) + node providerID (`aws://` → eks) | Auto-detected |
| **Accelerator** (h100/gb200/a100) | `nvidia-smi` GPU model name, case-insensitive substring match | Auto-detected |
| **OS** (ubuntu/rhel/cos) | `/etc/os-release` `ID` field | Auto-detected |

**Intent** (training/inference) and **Platform** (kubeflow/dynamo) are NOT extracted from the snapshot — the user must specify them explicitly. So the snapshot really only auto-detects 3 things: cloud, GPU, and OS.

In kix, these map directly to: `cluster.provider` (flavor), `cluster.nodes.*.gpu.type`, and OS (unmodeled today, but a single field).

**2. Constraint validation — "is this cluster compatible?"**

The snapshot collects much more than the recipe needs, specifically for pre-deploy validation:

| What | Source | Why / constraint example |
|------|--------|------------------------|
| K8s version | API `/version` | H100+EKS+Ubuntu requires `>= 1.32.4`, base requires `>= 1.25` |
| Kernel version | `/proc/sys/kernel/osrelease` | `>= 6.8` for GPU drivers on EKS |
| OS version | `/etc/os-release VERSION_ID` | Exact match: `= "24.04"` for Ubuntu |
| GPU driver version | `nvidia-smi` | Compatibility with operator version |
| CUDA version | `nvidia-smi` | Compatibility with workloads |
| Running container images | K8s API (all pods) | Detect existing GPU operator — avoid conflicts |
| ClusterPolicy CRD | K8s API | Detect existing GPU operator config |
| Loaded kernel modules | `/proc/modules` | Validate `nvidia`, `ib_core`, `mlx5_core` presence |
| Sysctl values | `/proc/sys/**` | Validate hugepages, vm settings after tuning |
| SystemD service configs | D-Bus (`containerd`, `kubelet`) | Validate containerd has nvidia runtime hook |
| GRUB/boot params | `/proc/cmdline` | Validate `hugepagesz=1G`, `nokaslr` |
| Node taints/labels | K8s API | Topology, GPU node identification |
| Node count | K8s API | Passed to Skyhook's `estimatedNodeCount` |

### What AICR sets up that modifies the HOST OS

This is the critical part that goes beyond K8s manifests. AICR deploys K8s resources that reach through to the host:

**Skyhook** — an operator + CR that runs 3 sequential packages on GPU nodes:

| Package | What it does | Interrupt |
|---------|-------------|-----------|
| `nvidia-setup-kernel` | Installs/pins kernel `>= 6.14.0-1018`, pins exact version | — |
| `nvidia-tuned` | Sets GRUB params (hugepages, nokaslr), kernel sysctl, containerd service limits | **Reboots the node** |
| `nvidia-setup-full` | Full driver/toolkit setup post-kernel | **Reboots the node** |

Skyhook also:
- Auto-taints new GPU nodes until setup completes (`spec.autoTaintNewNodes: true`)
- Protects labeled workloads from eviction during setup
- Varies by cloud: EKS/Ubuntu gets full kernel install + reboot; GKE/COS only gets sysctl tuning (COS is immutable)

**GPU Operator** host-level configuration varies by cloud:

| Cloud | `driver.enabled` | `toolkit.enabled` | `hostPaths.driverInstallDir` | Why |
|-------|---|---|---|---|
| Base (any) | `true`, version `580.105.08`, open kernel modules | `true` | default | Full driver management |
| EKS | inherits base | inherits | `/run/nvidia/driver` | EKS-specific driver path |
| GKE (COS) | **`false`** | `true`, installDir `/home/kubernetes/bin/nvidia` | `/home/kubernetes/bin/nvidia` | GKE pre-installs drivers on COS |
| AKS | inherits base | **`false`** | default | AKS pre-installs container toolkit |

Other base GPU operator settings: `driver.rdma.enabled: true`, `gdrcopy.enabled: true` (false on GKE), `dcgm.enabled: true`, `migManager.enabled: true`, `devicePlugin.env: DEVICE_LIST_STRATEGY=cdi-cri,cdi-annotations,volume-mounts`.

**GB200-specific**: Kernel module parameter `options nvidia NVreg_GrdmaPciTopoCheckOverride=1` for RDMA/PCIe topology.

### Overlay specificity algorithm

Overlays declare criteria (service, accelerator, os, intent, platform). Matching is asymmetric:
- Recipe field = empty → wildcard, matches anything
- Query field = empty → only matches empty recipe fields
- Both specific → must match exactly

**Specificity = count of non-empty fields** (0–6). Applied in ascending order (least specific first, most specific wins). Inheritance chain example for H100+EKS+Ubuntu training:

```
base.yaml → eks → eks-training → h100-eks-training → h100-eks-ubuntu-training
```

### Validation constraints (concrete examples)

| Overlay | Constraint | Meaning |
|---------|-----------|---------|
| `base` | `K8s.server.version >= 1.25` | Minimum K8s for any AICR deployment |
| `eks` | `K8s.server.version >= 1.28` | EKS minimum |
| `eks-training` | `K8s.server.version >= 1.30` | Training on EKS |
| `h100-eks-ubuntu-training` | `K8s.server.version >= 1.32.4` | Specific tested version |
| `h100-eks-ubuntu-training` | `OS.release.ID = ubuntu` | Exact match |
| `h100-eks-ubuntu-training` | `OS.release.VERSION_ID = "24.04"` | Exact match |
| `h100-eks-ubuntu-training` | `OS.sysctl./proc/sys/kernel/osrelease >= 6.8` | Kernel version |

Post-deployment: NCCL bandwidth tests (H100: `>= 300 GB/s`, GB200: `>= 720 GB/s`).

### Network topology — what granularity matters?

For **manifest generation**, the relevant network topology is coarse:

| Level | Relevant for manifests? | Why |
|-------|------------------------|-----|
| **Zone / rack** | Yes | Topology spread constraints, anti-affinity. Already in doc 45 via node labels. |
| **RDMA / InfiniBand availability** | Yes | Determines whether network-operator is needed, which NCCL transport to use. A boolean capability. |
| **NVLink / NVSwitch topology** | No | NCCL discovers this at runtime via `nvidia-smi topo -m` and routes traffic automatically. No different manifests needed. |
| **Switch-level / spine-leaf** | No | Below the K8s abstraction. CNI handles it. |
| **NIC model / speed** | Mostly no | Only if configuring SR-IOV or Multus — then it's a package option, not cluster topology. |

**Zone + RDMA boolean is sufficient.** Both already fit in the existing `cluster.capabilities` + `cluster.nodes.*.labels` model from doc 45.

---

## Gap Analysis: What Kix Has vs What AICR Provides

### Already in kix (strong foundation)

| AICR concept | kix equivalent | Status |
|-------------|---------------|--------|
| Cloud presets (EKS/GKE/AKS) | `kix.flavors.{eks,gke,aks,...}` (10 flavors) | Implemented |
| Component composition | DI-driven package system with auto-instantiation | Implemented |
| Version locking | Nix flake inputs + package `meta.version` | Implemented |
| Deploy ordering | Content-addressed DAG with `depends-on` + wave-based deploy | Implemented |
| Constraint validation | Scorecard rules (15 built-in) + `meta.compatibleWith` + package assertions | Implemented |
| Deployment tool flexibility | `kix deploy` (direct), operator, or `nix build` → GitOps | Implemented |
| Overlay inheritance | Nix module `mkDefault` priorities — identical semantics | Implemented |
| Cluster capability model | `cluster.capabilities.*` (gpu, multiNode, cni, etc.) | Partially implemented |
| Node inventory | `cluster.nodes` with roles, CPU, memory, labels, taints, disks | Designed (doc 45) |
| GPU node modeling | `cluster.nodes.*.gpu = { type, count }` | Designed (doc 69) |
| Scheduling derivation | Auto-derive replicas, anti-affinity, topology spread from hardware | Designed (doc 69) |

### Missing in kix (the gaps)

| AICR capability | Gap in kix | Difficulty |
|----------------|-----------|------------|
| **GPU component packages** | No gpu-operator, network-operator, NCCL plugins, DRA driver, gang scheduler | Medium — each is a Helm chart wrapper |
| **Per-cloud GPU operator config** | Flavors don't set GPU operator defaults (driver.enabled, toolkit paths) | Small — extend existing flavors |
| **Hardware snapshot** | No auto-discovery. `cluster.nodes` is manual. | Small — K8s API read + JSON import |
| **Known-good version matrix** | No tested GPU+driver+CUDA+operator combinations | Small mechanism (existing `meta.compatibleWith`), large data (NVIDIA domain knowledge) |
| **OS-level tuning** | No Skyhook equivalent (kernel params, hugepages for GPU nodes) | Medium — DaemonSet package OR NixOS module (see below) |
| **Performance validation** | Scorecard checks policy, not performance. No NCCL bandwidth tests. | Medium — extend scorecard or separate CLI command |
| **NixOS node image generation** | kix only outputs K8s manifests, not node OS config | New capability (see Part 3) |

---

## Proposal: Minimal Footprint, Maximum Leverage

### Core Insight: kix Already Has the Architecture

AICR built a custom overlay engine, a custom bundler, a custom deployer, and a custom validator — all to replicate what kix already does with the Nix module system, packages, `nix build`, and scorecard. The only genuinely new things AICR brings are:

1. **GPU domain packages** (gpu-operator, network-operator, etc.)
2. **Hardware auto-discovery** (snapshot agent)
3. **Version compatibility data** (the "known-good combinations")

Everything else — composition, overrides, validation, deploy ordering — maps directly onto existing kix primitives with **zero new core concepts**.

### What Maps Where

| AICR concept | kix equivalent | New code needed? |
|-------------|---------------|-----------------|
| Overlay inheritance | Nix module `mkDefault` priorities | No |
| Recipe (component selection) | Module that declares `instances.*` | No — it's just a module file |
| Constraints | `meta.compatibleWith` + package assertions | No — already exists in `meta.nix` |
| Snapshot | `kix snapshot` → `hardware.json` → `builtins.fromJSON` | Yes — CLI command + import function |
| Bundle | `nix build` | No |
| Deploy | `kix deploy` | No |
| "Intent" (training/inference) | Just another module in the `modules = [...]` list | No new concept — it's a module |
| Known-good version matrix | `meta.compatibleWith` constraints between packages | No new mechanism |

**The punchline: there are no "intents" as a concept. There are no "recipes." There are modules.** A "gpu-training module" is exactly the same thing as `kix.flavors.eks` — a module that sets instances, config, and capabilities via `mkDefault`. Multiple modules compose via the standard Nix module merge.

---

## Part 1: Snapshot — The `hardware-configuration.nix` for Kubernetes

### Actual state vs desired state

NixOS has `nixos-generate-config` which produces `hardware-configuration.nix` — a one-shot snapshot of the machine's hardware that becomes part of the declarative config. For clusters, the answer depends on who controls the nodes:

| Scenario | Hardware is... | Right approach |
|----------|---------------|---------------|
| Bare metal / static VMs | Fixed reality you can't change from kix | **Snapshot** (discover what exists) |
| Cloud managed (EKS, GKE) | Desired state — you chose `g5.48xlarge` | **Declare** (you control what exists) |
| Hybrid | Mix of both | Both — snapshot static nodes, declare pools |

This is already the split in doc 45: `cluster.nodes` (static inventory) vs `cluster.nodePools` (autoscaled, desired).

The snapshot's value isn't really discovery — most operators *know* what they have. It's **structured import**: turning "I have 4 H100 nodes" into the right Nix module options without hand-writing them.

### What can you discover from the K8s API (no privileged access)?

| Fact | Source | Reliability |
|------|--------|-------------|
| Node names, count | `.items[].metadata.name` | Always available |
| CPU/memory capacity | `.items[].status.capacity` | Always available |
| Availability zone | `topology.kubernetes.io/zone` label | Cloud providers set automatically |
| Architecture (amd64/arm64) | `kubernetes.io/arch` label | Always available |
| OS image | `.status.nodeInfo.osImage` | Always available |
| Kernel version | `.status.nodeInfo.kernelVersion` | Always available |
| K8s version | `/version` API | Always available |
| Container runtime | `.status.nodeInfo.containerRuntimeVersion` | Always available |
| Instance type (cloud) | `node.kubernetes.io/instance-type` label | Cloud only |
| Node taints | `.spec.taints` | Always available |
| GPU product name | `nvidia.com/gpu.product` label | If GPU device plugin running |
| GPU count | `nvidia.com/gpu.count` label | If GPU device plugin running |
| GPU memory | `nvidia.com/gpu.memory` label | If GPU device plugin running |
| GPU driver version | `nvidia.com/driver.major` + `.minor` + `.revision` | If GPU device plugin running |
| CUDA version | `nvidia.com/cuda.driver.major` + `.minor` | If GPU device plugin running |
| MIG capable | `nvidia.com/mig.capable` label | If GPU device plugin running |
| GPU family | `nvidia.com/gpu.family` label (e.g. "hopper") | If GPU device plugin running |

**Key insight:** In any real GPU cluster, the GPU device plugin is already running (it's the first thing you install). So GPU info is available as node labels — no `nvidia-smi` Job needed.

### `kix snapshot` design

```bash
kix snapshot --context my-gpu-cluster -o cluster-hardware.json
```

Reads `kubectl get nodes -o json`, extracts the Kubernetes-visible facts (capacity, labels, taints, zones), and writes structured JSON. ~100-200 lines of Rust. No privileged access. Works on any cluster.

The JSON maps to module options via a trivial Nix function:

```nix
# clusters/ai-prod.nix
kix.buildCluster {
  name = "ai-prod";
  modules = [
    kix.flavors.eks
    (kix.fromHardwareSnapshot ./cluster-hardware.json)  # sets cluster.nodes, cluster.capabilities
    ./gpu-stack.nix     # "intent" — just a module
    ./apps.nix
  ];
}
```

`kix.fromHardwareSnapshot` is a ~30-line function: read JSON, map to `cluster.nodes.*` and `cluster.capabilities.*`. Same pattern as NixOS `hardware-configuration.nix` — a generated module you commit to your repo.

### Deeper discovery (privileged Job) — when needed

Only for the **bootstrapping case**: no GPU device plugin yet, need to know what GPUs exist to decide whether to install it. AICR runs a privileged Job for this. We could too, but it's a chicken-and-egg problem that's rarely encountered — in practice people know they have GPUs before configuring their cluster.

---

## Part 2: Compatibility, Modules, and Validation

### Compatibility via existing `meta` — no new mechanism

`meta.nix` already has `compatibleWith` for version constraints and `checkMetaStatic` validates at build time. GPU packages just use this:

```nix
# packages/gpu-operator/default.nix
{ meta.compatibleWith = {
    cert-manager = { minVersion = "1.14"; };
    k8s = { minVersion = "1.28"; maxVersion = "1.32"; };
}; }

# packages/network-operator/default.nix
{ meta.compatibleWith = {
    gpu-operator = { minVersion = "25.3"; maxVersion = "25.4"; reason = "NVIDIA tested combination"; };
}; }
```

The "known-good combination" isn't a separate database — it's **the version constraints each package declares on its dependencies**. Decentralized rather than centralized, which scales better.

AICR's tested combinations could be auto-imported: a script parses AICR's `recipes/` directory and generates `meta.compatibleWith` values for kix packages. The mechanism is the same — package-level meta constraints.

### "Intents" are just modules

No new `kix.intents.*` namespace needed. A "GPU training stack" is a `.nix` file:

```nix
# modules/gpu-training.nix
{ lib, packages, ... }:
{
  cluster.capabilities.gpu = lib.mkDefault true;

  instances.gpu-operator = {
    gpu-operator = { package = packages.gpu-operator; };
    network-operator = { package = packages.network-operator; };
    gpu-node-tuning = { package = packages.gpu-node-tuning; };
  };
  instances.kube-system.kai-scheduler = { package = packages.kai-scheduler; };
  instances.training.kubeflow-trainer = { package = packages.kubeflow-trainer; };
}
```

**Multiple modules compose** via standard Nix merge — `mkDefault` loses to explicit, collisions error:

```nix
modules = [
  kix.flavors.eks
  ./gpu-training.nix     # adds kubeflow, kai-scheduler, gpu-operator with training defaults
  ./gpu-inference.nix    # adds dynamo, MIG defaults
  ./monitoring.nix       # adds prometheus, grafana with GPU dashboards
];
```

**How do they differ from flavors?** They don't, structurally. Both are modules. The distinction is naming convention:
- `kix.flavors.*` = "what platform am I on" (provider, CNI, storage)
- User/shipped modules = "what do I want to run" (GPU stack, monitoring, apps)

### Per-cloud GPU config belongs in flavors

The per-cloud differences (driver enabled/disabled, toolkit paths) are exactly what flavors already do. Extending them:

```nix
# lib/flavors/gke.nix (extended with GPU defaults)
{
  # ... existing capabilities ...
  instances.gpu-operator.gpu-operator.config = lib.mkDefault {
    driver.managed = false;      # GKE pre-installs drivers on COS
    toolkit.installDir = "/home/kubernetes/bin/nvidia";
    gdrcopy.enable = false;      # Not available on COS
  };
}
```

Zero new mechanism — just more config in existing flavors. Users override with `mkForce` or explicit values.

### "Validation first" = kix's existing model

AICR's "validate" is a separate step because Helm has no compile step. In kix, **every build validates**:

- `meta.compatibleWith` → version mismatches
- `meta.k8s.minVersion` → K8s version bounds
- Package assertions → capability requirements
- Scorecard rules → policy violations
- DI resolution → missing dependencies
- Type system → malformed config

The compiler IS the validator. Nothing to add.

---

## Part 3: Beyond Skyhook — NixOS as the Node OS

### The problem Skyhook solves (and its limitations)

Skyhook exists because **K8s nodes are opaque to the K8s control plane.** When you need specific kernel versions, sysctl settings, hugepages, or driver installations, your only option is to run privileged DaemonSets that reach through the container abstraction to modify the host OS. This is:

- **Fragile** — privileged pods modifying `/proc/sys`, GRUB, systemd, then rebooting nodes
- **Slow** — sequential: install kernel → reboot → tune sysctls → reboot → install drivers → reboot
- **Opaque** — the desired host state isn't declarative; it's imperative scripts inside containers
- **Duplicative** — Skyhook reimplements OS configuration management (poorly) inside K8s

AICR accepts this limitation because it targets arbitrary clusters with arbitrary OS choices. But kix doesn't have to.

### The kix + NixOS vertical integration

If nodes run NixOS, the entire Skyhook problem dissolves. The node OS configuration becomes a Nix expression — the same language as kix, evaluated together, from the same source of truth. Instead of deploying privileged pods that hack the host, you **build the correct node image upfront**.

The vision: a single `buildCluster` produces BOTH K8s manifests AND NixOS configurations for the nodes, with the cluster declaration driving both.

#### How it could look

```nix
# clusters/ai-training.nix
kix.buildCluster {
  name = "ai-training";
  modules = [
    kix.flavors.eks
    ./gpu-training.nix

    {
      cluster.nodes = {
        gpu-0 = {
          roles = [ "worker" "gpu" ];
          cpu = 96; memory = "2Ti";
          gpu = { type = "h100"; count = 8; memory = "80Gi"; };
          os = "nixos";  # ← this node runs NixOS
        };
        gpu-1 = { /* ... */ os = "nixos"; };
        gpu-2 = { /* ... */ os = "nixos"; };
        gpu-3 = { /* ... */ os = "nixos"; };
        system-0 = { roles = [ "worker" ]; cpu = 16; memory = "64Gi"; os = "nixos"; };
      };
    }
  ];
}
```

`nix build .#cluster-ai-training` produces the usual K8s manifests. But `nix build .#cluster-ai-training.nodeConfigs.gpu-0` (or similar) produces a NixOS system configuration for that node, informed by the cluster declaration.

#### What the cluster declaration could drive in NixOS config

| Cluster fact | NixOS output | Replaces |
|-------------|-------------|----------|
| `gpu.type = "h100"` | `hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.production` | GPU operator driver install |
| `gpu.type = "h100"` | `boot.kernelParams = [ "hugepagesz=1G" "hugepages=32" "nokaslr" ]` | Skyhook `nvidia-tuned` kernel params |
| `gpu.count = 8` | `boot.kernel.sysctl."vm.nr_hugepages" = 32768` | Skyhook sysctl tuning |
| `cluster.capabilities.cni = "cilium"` | `boot.kernelParams = [ "net.core.bpf_jit_enable=1" ]` | Manual eBPF setup |
| `roles = [ "gpu" ]` | `services.nvidia-container-runtime.enable = true` | Skyhook `nvidia-setup-full` |
| `roles = [ "gpu" ]` | `virtualisation.containerd.settings.plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia = { ... }` | GPU operator toolkit config |
| `cluster.gpu.networking.rdma = true` | `boot.kernelModules = [ "ib_core" "rdma_ucm" "mlx5_core" ]` | Network operator kernel modules |
| `gpu = { type = "gb200"; }` | `boot.extraModprobeConfig = "options nvidia NVreg_GrdmaPciTopoCheckOverride=1"` | GB200-specific kernel module param |
| `cluster.provider = "eks"` | Nothing (EKS controls the OS) | N/A |

#### Three tiers of integration

**Tier 0: No NixOS — Skyhook-style packages (works today)**

For non-NixOS nodes (Ubuntu, COS, RHEL, cloud-managed), kix packages generate the same kind of privileged DaemonSets that Skyhook uses. A `gpu-node-tuning` package wraps this. This is what AICR does and what works on arbitrary clusters.

```nix
# packages/gpu-node-tuning/default.nix — DaemonSet that tunes the host
{ scope, lib, kix }:
{
  meta.scope = "cluster";
  build = { scope, config, ... }: [
    (scope.mkDaemonSet {
      spec.template.spec = {
        hostPID = true;
        containers = [{
          name = "tuner";
          securityContext.privileged = true;
          # Sets sysctls, hugepages, etc. on the host
        }];
        tolerations = [{ key = "nvidia.com/gpu"; operator = "Exists"; }];
        nodeSelector."nvidia.com/gpu" = "true";
      };
    })
  ];
}
```

**Tier 1: NixOS node config generation (the interesting one)**

kix gains a `nodeConfig` output — a NixOS module per node that sets kernel, drivers, sysctls, and container runtime config based on the cluster declaration. The node OS is now driven by the same source of truth as the K8s manifests.

```nix
# lib/nixos/gpu-node.nix — derives NixOS config from cluster.nodes entry
{ nodeConfig, clusterConfig }:
{ config, pkgs, lib, ... }:
let
  gpu = nodeConfig.gpu;
  hasGpu = gpu != null;
  isTraining = clusterConfig.gpu.networking.rdma or false;  # heuristic or explicit flag
in
{
  # Kernel
  boot.kernelPackages = lib.mkIf hasGpu pkgs.linuxPackages_6_14;  # pinned for GPU compat
  boot.kernelParams = lib.mkIf hasGpu [
    "hugepagesz=1G"
    "hugepages=${toString (gpu.count * 4)}"  # 4 hugepages per GPU, derived
    "nokaslr"
  ];
  boot.kernel.sysctl = lib.mkIf hasGpu {
    "vm.nr_hugepages" = gpu.count * 4096;   # derived from GPU count
    "vm.max_map_count" = 1048576;
    "kernel.numa_balancing" = 0;             # disable for GPU workloads
  };

  # NVIDIA driver
  hardware.nvidia = lib.mkIf hasGpu {
    open = true;  # open kernel modules (required for recent drivers)
    package = config.boot.kernelPackages.nvidiaPackages.production;
    # MIG
    mig = lib.mkIf (clusterConfig.gpu.mig.enabled or false) {
      enable = true;
      strategy = clusterConfig.gpu.mig.strategy or "single";
    };
  };

  # Container runtime
  virtualisation.containerd = {
    enable = true;
    settings.plugins."io.containerd.grpc.v1.cri" = {
      containerd.default_runtime_name = if hasGpu then "nvidia" else "runc";
      containerd.runtimes.nvidia = lib.mkIf hasGpu {
        runtime_type = "io.containerd.runc.v2";
        options.BinaryName = "${pkgs.nvidia-container-toolkit}/bin/nvidia-container-runtime";
      };
    };
  };

  # RDMA / InfiniBand
  boot.kernelModules = lib.optionals isTraining [
    "ib_core" "rdma_ucm" "mlx5_core" "mlx5_ib"
  ];
  boot.extraModprobeConfig = lib.optionalString (gpu.type or "" == "gb200")
    "options nvidia NVreg_GrdmaPciTopoCheckOverride=1";

  # Kubernetes node labels (kubelet config)
  services.kubernetes.kubelet.extraConfig = {
    registerNode = true;
    nodeLabels = lib.filterAttrs (_: v: v != null) {
      "node.kubernetes.io/role" = if hasGpu then "gpu" else "worker";
      "nvidia.com/gpu.type" = if hasGpu then gpu.type else null;
    };
  };
}
```

The cluster definition drives this automatically. Change `gpu.count = 8` to `gpu.count = 4`, and the hugepages, sysctl values, and containerd config all update — without touching the node module directly.

**Tier 2: Full NixOS node image builds**

The NixOS config above produces a full system configuration that can be built into a disk image:

```bash
# Build NixOS image for gpu-0
nix build .#cluster-ai-training.nodeImages.gpu-0
# → result/nixos.qcow2 (or .raw, .iso, etc.)
```

This integrates with doc 26 (image vertical integration). The entire stack from node kernel → container runtime → K8s manifests → application config is one Nix expression. Change a GPU driver version in the cluster definition, and both the NixOS image and the K8s manifests update in lockstep.

For cloud (EKS/GKE), NixOS node images aren't applicable — the cloud controls the OS. But for bare metal and self-managed VMs, this is the end-state: **no Skyhook, no privileged DaemonSets, no node reboots via K8s. The node boots correctly from the start.**

#### What this eliminates

| AICR/Skyhook step | NixOS equivalent | Eliminated? |
|-------------------|-----------------|------------|
| `nvidia-setup-kernel` (install kernel, reboot) | `boot.kernelPackages = pkgs.linuxPackages_6_14` | Yes — correct kernel from first boot |
| `nvidia-tuned` (GRUB params, sysctl, reboot) | `boot.kernelParams`, `boot.kernel.sysctl` | Yes — set at image build time |
| `nvidia-setup-full` (driver install, reboot) | `hardware.nvidia.package` | Yes — driver in the image |
| GPU operator driver management | NixOS handles drivers | Partially — can disable `driver.managed` in gpu-operator |
| GPU operator container toolkit | `virtualisation.containerd` NixOS config | Partially — can disable `toolkit.enabled` |
| Network operator kernel module loading | `boot.kernelModules` | Yes — modules in initrd |
| Skyhook auto-taint new nodes | Not needed — nodes boot ready | Yes |

**Three reboots become zero.** The node image IS the desired state.

#### Architecture options

**Option A: `kix.buildCluster` outputs both**

```nix
let cluster = kix.buildCluster { ... };
in {
  # K8s manifests (existing)
  packages.cluster-ai-training = cluster;

  # NixOS configs (new)
  nixosConfigurations = builtins.mapAttrs (name: nodeSpec:
    nixpkgs.lib.nixosSystem {
      modules = [
        (kix.nixos.fromNodeSpec { inherit nodeSpec; clusterConfig = cluster.config; })
        ./nodes/${name}/hardware-configuration.nix  # actual disk/NIC hw
      ];
    }
  ) (lib.filterAttrs (_: n: n.os or null == "nixos") cluster.config.cluster.nodes);
}
```

**Option B: Separate node flake, cluster config as input**

```nix
# flake.nix for nodes (separate repo or same repo)
{
  inputs.kixpkgs.url = "...";
  outputs = { kixpkgs, nixpkgs, ... }:
  let
    clusterConfig = (import ./clusters/ai-training.nix { inherit kixpkgs; }).config;
  in {
    nixosConfigurations.gpu-0 = nixpkgs.lib.nixosSystem {
      modules = [
        (kixpkgs.lib.nixos.fromNodeSpec {
          nodeSpec = clusterConfig.cluster.nodes.gpu-0;
          inherit clusterConfig;
        })
        ./nodes/gpu-0/hardware-configuration.nix
      ];
    };
  };
}
```

**Option C: NixOS modules shipped alongside kix packages**

GPU packages ship both a K8s build function AND a NixOS module. The NixOS module sets kernel/driver/sysctl, the K8s build produces the operator resources. Both are derived from the same package options.

```nix
# packages/gpu-operator/default.nix
{
  meta.version = "25.3.3";
  options = { driver.version = ...; driver.managed = ...; };

  # K8s resources (existing pattern)
  build = { scope, config, ... }: [ (kix.fromHelmChart { ... }) ];

  # NixOS module (new — optional, only used if nodes run NixOS)
  nixosModule = { config, pkgs, ... }: {
    hardware.nvidia.package = pkgs.linuxPackages.nvidiaPackages."${config.driver.version}";
    boot.kernelParams = [ "nokaslr" ];
    # ...
  };
}
```

This is the most modular option — each package owns its own NixOS requirements, and `kix.nixos.fromNodeSpec` collects them from all instantiated packages. It parallels how packages already own their K8s resources, RBAC, network policies, and monitoring config.

#### What this means for the cluster declaration

The cluster declaration becomes the **single source of truth** for both planes:

```
cluster.nix
  ├── K8s manifests (via nix build .#cluster-ai-training)
  │   ├── gpu-operator ClusterPolicy
  │   ├── network-operator config
  │   ├── kai-scheduler
  │   ├── training jobs
  │   └── monitoring stack
  │
  └── NixOS node configs (via nix build .#cluster-ai-training.nodeConfigs.gpu-0)
      ├── kernel 6.14 + hugepages + nokaslr
      ├── nvidia driver 580.105.08
      ├── containerd + nvidia runtime
      ├── RDMA kernel modules
      └── kubelet with correct labels
```

Change `gpu.type` from `h100` to `gb200` in the cluster definition, and:
- K8s manifests update (GPU operator config, NCCL transport, scheduler settings)
- NixOS configs update (different kernel module params, different driver version)
- `meta.compatibleWith` validates the entire stack at build time
- Content hashes change, `kix diff` shows the blast radius

#### Open questions for NixOS integration

1. **Who owns the NixOS hardware-configuration.nix per node?** This is actual-hardware (disks, NICs, boot loader) — analogous to kix's `cluster.nodes` being the Kubernetes-visible slice. The NixOS hardware config would be separate from the kix-generated config, composed as a module.

2. **How does NixOS node image deployment work?** Building the image is Nix. Deploying it to bare metal (PXE, USB) or VMs (qcow2, AMI) is outside kix's scope. But `kix deploy` could grow a `--nodes` flag that triggers `nixos-rebuild switch` via SSH or `colmena`. Or this could be a separate tool entirely (colmena, deploy-rs, nixos-anywhere).

3. **Mixed fleets — some nodes NixOS, some not.** The GPU operator still needs to exist for non-NixOS nodes. On NixOS nodes, some operator features are redundant (driver install, toolkit config). The gpu-operator package should detect `node.os == "nixos"` and disable those features for NixOS nodes.

4. **How tightly should kix packages couple to NixOS modules?** Option C (packages ship nixosModule alongside build) is the most modular but means every package author thinks about NixOS. Option A (centralized mapping) keeps it simpler but less composable. Recommendation: start with a centralized `kix.nixos.fromNodeSpec` that handles the common cases (kernel, driver, sysctl, containerd), and allow packages to contribute via optional `nixosModule` for package-specific host requirements.

5. **NixOS module granularity — per-node or per-role?** GPU nodes need different config than system nodes. Per-node is most flexible but verbose. Per-role (`kix.nixos.gpuWorker`, `kix.nixos.worker`, `kix.nixos.controlPlane`) with per-node overrides might be the right balance.

---

## GPU Packages (the actual work)

The real effort is building the packages. Sketches for the core ones:

### `packages/gpu-operator/default.nix`

```nix
{ scope, lib, kix }:
{
  meta = {
    version = "25.3.3";
    scope = "cluster";
    lifecycle = "stateful";
    owner = "platform";
    defaultAliases = [ "gpu" "nvidia-gpu" ];
    compatibleWith = {
      cert-manager = { minVersion = "1.14"; };
      k8s = { minVersion = "1.28"; maxVersion = "1.32"; };
    };
  };

  options = {
    driver.version = lib.mkOption { type = lib.types.str; default = "580.105.08"; };
    driver.managed = lib.mkOption { type = lib.types.bool; default = true; };
    driver.rdma = lib.mkOption { type = lib.types.bool; default = true; };
    cuda.version = lib.mkOption { type = lib.types.str; default = "12.8"; };
    mig.strategy = lib.mkOption { type = lib.types.enum [ "single" "mixed" ]; default = "single"; };
    dcgmExporter.enable = lib.mkOption { type = lib.types.bool; default = true; };
    gds.enable = lib.mkOption { type = lib.types.bool; default = false; };
    gdrcopy.enable = lib.mkOption { type = lib.types.bool; default = true; };
    toolkit.enable = lib.mkOption { type = lib.types.bool; default = true; };
    toolkit.installDir = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
  };

  deps = {
    certManager = { package = "cert-manager"; };
    prometheus = { package = "prometheus"; optional = true; };
  };

  build = { scope, config, certManager, prometheus ? null }:
    let
      chart = kix.fetchHelmChart {
        repo = "https://helm.ngc.nvidia.com/nvidia";
        chart = "gpu-operator";
        version = "v${config.meta.version}";
      };
    in
    [
      (kix.fromHelmChart {
        inherit scope chart;
        values = {
          driver = {
            enabled = config.driver.managed;
            version = config.driver.version;
            rdma.enabled = config.driver.rdma;
          };
          toolkit = {
            enabled = config.toolkit.enable;
          } // lib.optionalAttrs (config.toolkit.installDir != null) {
            installDir = config.toolkit.installDir;
          };
          dcgmExporter.enabled = config.dcgmExporter.enable;
          mig.strategy = config.mig.strategy;
          gds.enabled = config.gds.enable;
          gdrcopy.enabled = config.gdrcopy.enable;
          devicePlugin.env = [{
            name = "DEVICE_LIST_STRATEGY";
            value = "cdi-cri,cdi-annotations,volume-mounts";
          }];
        };
      })
    ]
    ++ lib.optional (prometheus != null) (kix.monitor {
      service = "gpu-operator";
      port = "gpu-operator-metrics";
    });
}
```

### Other packages (same pattern)

| Package | Wraps | Key options | DI deps |
|---------|-------|-------------|---------|
| `network-operator` | NVIDIA Network Operator Helm chart | `rdma.enable`, `srIov.enable` | cert-manager, gpu-operator (optional) |
| `gpu-node-tuning` | DaemonSet with sysctl/hugepages (Tier 0 — non-NixOS) | `hugepages2Mi`, `hugepages1Gi`, `sysctls` | — |
| `gpu-health-monitor` | DaemonSet watching GPU errors | `action` (cordon/drain/alert) | prometheus (optional) |
| `kai-scheduler` | KAI Scheduler Helm chart | `gangScheduling.enable`, `topologyAware` | gpu-operator |
| `kubeflow-trainer` | Kubeflow Training Operator | `enabledFrameworks` (pytorch, jax) | — |
| `nccl-plugin` | Cloud-specific NCCL transport | `transport` (efa/tcpxo/ib/tcp) | — |

---

## What Makes This Different From Cloning AICR

| Aspect | AICR | kix |
|--------|------|-----|
| **Scope** | NVIDIA AI stack only | Full cluster in one graph |
| **Composition** | Custom overlay engine (Go) | Nix module system |
| **Validation** | Separate `validate` step | Every `nix build` validates |
| **Compatibility** | Centralized matrix embedded in binary | Decentralized `meta.compatibleWith` on each package |
| **Host OS tuning** | Skyhook: privileged pods, 3 reboots | NixOS: correct from first boot, zero reboots (Tier 1+) |
| **Multi-vendor** | NVIDIA only | Extensible — ROCm, Gaudi use the same API |
| **Deployment** | Helm charts or ArgoCD apps | Wave-based SSA, operator, or GitOps |
| **Customization** | `--set` flags | Full language |
| **Node OS** | Opaque — Skyhook hacks it via privileged pods | Declarative — NixOS config from same source of truth |
| **Lock-in** | Vendor tool with embedded data | Open packages, visible constraints, overridable |

### The strategic angle

AICR is a **vendor lock-in tool disguised as a helper**. The overlay library and "known-good combinations" are NVIDIA's internal data, embedded in the binary. Extending it to non-NVIDIA components requires forking.

kix inverts this: packages, constraints, and modules are all user-visible Nix. The NixOS integration adds a dimension AICR can't touch — **the node OS itself becomes part of the compiled, validated, reproducible cluster definition.**

AICR needs Skyhook because it can't control the OS. kix + NixOS doesn't need Skyhook because it IS the OS.

---

## Implementation: Minimal Footprint

### Core kix changes (tiny)

| Change | Effort |
|--------|--------|
| `kix.fromHardwareSnapshot` — Nix function, reads JSON → module options | ~30 lines |
| `kix snapshot` — CLI reads K8s API nodes, writes JSON | ~200 lines Rust |
| GPU fields on `cluster.nodes.*.gpu` (from doc 69) | ~10 lines in `lib/modules.nix` |
| `kix.nixos.fromNodeSpec` — derives NixOS module from cluster node spec | ~100 lines (Tier 1) |

### Packages (the real work)

| Phase | What | Effort |
|-------|------|--------|
| 1 | `gpu-operator` package (Helm wrapper with typed options) | 1-2 weeks |
| 2 | `network-operator`, `gpu-node-tuning`, `nccl-plugin` | 1-2 weeks |
| 3 | `kai-scheduler`, `gpu-health-monitor` | 1 week |
| 4 | `kubeflow-trainer`, `nvidia-dra-driver` | 1 week |

### NixOS integration (can happen in parallel)

| Phase | What | Effort |
|-------|------|--------|
| A | `kix.nixos.fromNodeSpec` — GPU node NixOS module derivation | 1 week |
| B | Per-package `nixosModule` support in eval pipeline | 1 week |
| C | Node image builds (qcow2/ISO/AMI) | 1-2 weeks |

### What we can import from AICR

AICR's `recipes/` directory contains the version matrix and Helm values overrides as data files. A script can parse these and generate:
- Default option values for GPU packages (driver versions, component versions)
- `meta.compatibleWith` constraints
- Per-cloud flavor overrides (the GKE/EKS/AKS differences table above)

This gives us NVIDIA's qualification data without maintaining it ourselves.

---

## Open Questions

1. **Import AICR's version data or maintain our own?** Auto-import is low-maintenance but couples us to NVIDIA's release cadence. Recommendation: auto-import as defaults, let users override via `mkForce`.

2. **How much GPU-specific surface in `cluster.*`?** Doc 45 has `cluster.capabilities.gpu = bool`. Doc 69 has `cluster.nodes.*.gpu = { type, count }`. That seems sufficient — MIG profiles, NVLink topology are package options, not cluster options.

3. **NixOS integration: Option A, B, or C?** (from architecture options above). Recommendation: start with Option A (centralized `fromNodeSpec`) for simplicity, evolve toward Option C (per-package `nixosModule`) as we learn what packages need from the host.

4. **Should NixOS node deployment be part of kix?** Building NixOS images is natural. Deploying them (SSH, PXE, colmena) may be out of scope. Recommendation: build images yes, deploy them no — use existing tools (colmena, deploy-rs, nixos-anywhere).

5. **Skyhook as a maintained module by NVIDIA on top of kix?** NVIDIA could ship a kix module (or NixOS module) with their qualified tuning values, similar to how `nixos-hardware` ships vendor-specific profiles. This is more open than embedding data in a Go binary.

---

## References

- [NVIDIA AICR GitHub](https://github.com/NVIDIA/aicr) — Source code and documentation
- kix doc 45 — Cluster hardware profile (capability model, node inventory)
- kix doc 69 — Infrastructure-aware compilation (hardware depth, scheduling derivation, fleet)
- kix doc 26 — Image vertical integration (Nix-built images, nix-snapshotter)
- kix doc 13 (business) — AI-native infrastructure positioning
- kix ROADMAP — Vertical integration section, hardware.nix, importable decision sets
- [NVIDIA GPU Operator docs](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/)
- [KAI Scheduler](https://github.com/NVIDIA/KAI-Scheduler) — Gang scheduling for GPU workloads
- [Skyhook](https://github.com/NVIDIA/skyhook) — Node lifecycle management for GPU clusters
- [nixos-hardware](https://github.com/NixOS/nixos-hardware) — Vendor-specific NixOS profiles (model for GPU tuning profiles)
