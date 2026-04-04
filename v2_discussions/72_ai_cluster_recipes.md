# 72 — AI Cluster Recipes: AICR-Inspired GPU/AI Cluster Configuration

**Status:** Draft
**Related:** `45_cluster_hardware_profile.md` (capability model), `69_hardware_driven_scheduling.md` (hardware depth + fleet), `business_discussions/13_ai_native_infrastructure_positioning.md` (AI positioning)

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

### The Overlay System

The recipe engine's core is an **asymmetric criteria matching** system with specificity scoring. Overlays are layered:

```
base → cloud-provider → cloud+intent → cloud+intent+GPU → cloud+intent+GPU+OS
```

Each overlay can set component versions, Helm values, custom manifests, and constraints. More specific overlays win. The overlay library is embedded in the Go binary via `go:embed`, with an `--data` flag for external overrides.

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
| Skyhook | OS-level GPU node tuning: kernel params, sysctl, hugepages |
| NVSentinel | GPU health monitoring + automated remediation (cordon/drain on GPU errors) |
| DRA Driver | K8s Dynamic Resource Allocation API for GPUs (v1.34+) |
| KAI Scheduler | DRA-aware gang scheduler with hierarchical queues + topology-aware placement |
| Dynamo | Distributed inference with prefix-cache routing, disaggregated prefill/decode |
| Kubeflow Trainer | Distributed training with JobSet |
| kube-prometheus-stack | GPU-specific dashboards, prometheus-adapter for HPA on GPU utilization |
| cert-manager | Foundation dependency (many operators need it) |

---

## Gap Analysis: What Kix Has vs What AICR Provides

### Already in kix (strong foundation)

| AICR concept | kix equivalent | Status |
|-------------|---------------|--------|
| Cloud presets (EKS/GKE/AKS) | `kix.flavors.{eks,gke,aks,...}` (10 flavors) | Implemented |
| Component composition | DI-driven package system with auto-instantiation | Implemented |
| Version locking | Nix flake inputs + package `meta.version` | Implemented |
| Deploy ordering | Content-addressed DAG with `depends-on` + wave-based deploy | Implemented |
| Constraint validation | Scorecard rules (15 built-in) + package assertions | Implemented |
| Deployment tool flexibility | `kix deploy` (direct), operator, or `nix build` → GitOps | Implemented |
| Cluster capability model | `cluster.capabilities.*` (gpu, multiNode, cni, etc.) | Partially implemented |
| Node inventory | `cluster.nodes` with roles, CPU, memory, labels, taints, disks | Designed (doc 45) |
| GPU node modeling | `cluster.nodes.*.gpu = { type, count }` | Designed (doc 69) |
| Scheduling derivation | Auto-derive replicas, anti-affinity, topology spread from hardware | Designed (doc 69) |

### Missing in kix (the gaps)

| AICR capability | Gap in kix | Difficulty |
|----------------|-----------|------------|
| **Hardware snapshot agent** | No auto-discovery. `cluster.nodes` is manual. | Medium — K8s Job + Nix JSON import |
| **GPU component packages** | No gpu-operator, network-operator, NCCL plugins, DRA driver, gang scheduler | Large — each is a new package |
| **Intent-driven composition** | No "I want training" → resolved stack. Packages are composed explicitly. | Medium — new concept: "intents" as module presets |
| **Known-good version matrix** | No tested GPU+driver+CUDA+operator combinations. kix has versions but no qualification data. | Large — requires testing infrastructure or importing AICR's data |
| **Performance validation** | Scorecard checks policy, not performance. No NCCL bandwidth tests. | Medium — extend scorecard or separate tool |
| **GPU health monitoring** | No NVSentinel equivalent (cordon on GPU errors) | Medium — new package |
| **OS-level tuning** | No Skyhook equivalent (kernel params, hugepages for GPU nodes) | Small-Medium — DaemonSet package |

---

## Proposal

### Core Insight: kix Doesn't Need to Clone AICR

AICR is a **single-vendor configuration oracle** — it encodes NVIDIA's internal knowledge about which versions work together. kix is a **general-purpose compiled infrastructure platform**. The right move is not to replicate AICR's overlay engine, but to:

1. **Build the GPU infrastructure packages** that AICR bundles (gpu-operator, network-operator, etc.) as first-class kix packages with typed options and DI.
2. **Introduce "intents"** — high-level module presets that compose the right packages for a goal (training, inference, hybrid).
3. **Extend the hardware profile** to capture GPU-specific facts (doc 45 + 69, mostly designed already).
4. **Optionally import AICR's version matrix** as a data source for known-good combinations.

The result: kix users get AICR's value (correct GPU stack for their hardware) with kix's advantages (compile-time validation, dependency tracking, customizability, non-NVIDIA components in the same graph).

### Design: Three Layers

```
Layer 3: Intents          "I want GPU training on EKS with H100s"
                          ↓ resolves to
Layer 2: GPU Packages     gpu-operator + network-operator + nccl-plugin + scheduler + monitoring
                          ↓ composed via
Layer 1: Hardware Profile  cluster.gpu.* capabilities, node inventory, driver versions
```

#### Layer 1: Extended Hardware Profile for GPUs

Extend `cluster.capabilities` and `cluster.nodes` (docs 45/69) with GPU-specific fields:

```nix
# In cluster definition
cluster.gpu = {
  # High-level: what GPU hardware exists
  accelerator = lib.mkOption {
    type = lib.types.nullOr (lib.types.enum [
      "t4" "a10" "l4" "a100" "h100" "h200" "gb200" "b200"
    ]);
    default = null;
    description = "Primary GPU accelerator type. Auto-derived from cluster.nodes if set.";
  };

  # Driver/CUDA versions (auto-discovered or manually set)
  driver = {
    version = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;  # e.g. "580.82.07"
      description = "NVIDIA driver version. Used for compatibility validation.";
    };
    cuda = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;  # e.g. "12.8"
    };
  };

  # Networking capabilities for multi-node GPU communication
  networking = {
    rdma = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "RDMA/RoCE/InfiniBand available for GPU-to-GPU comms.";
    };
    srIov = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    nccl = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "tcp" "efa" "tcpxo" "ib" ]);
      default = null;
      description = "NCCL transport. Auto-derived from provider if null.";
    };
  };

  # MIG (Multi-Instance GPU) configuration
  mig = {
    enabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    strategy = lib.mkOption {
      type = lib.types.enum [ "single" "mixed" ];
      default = "single";
    };
  };
};

# Extend cluster.nodes with GPU info
cluster.nodes.<name>.gpu = lib.mkOption {
  type = lib.types.nullOr (lib.types.submodule {
    options = {
      type = lib.mkOption { type = lib.types.str; };       # "h100", "a100", etc.
      count = lib.mkOption { type = lib.types.int; };      # GPUs per node
      memory = lib.mkOption {                                # GPU memory
        type = lib.types.nullOr lib.types.str;
        default = null;  # "80Gi" for A100-80GB
      };
    };
  });
  default = null;
};
```

Auto-derivation (extending doc 69's engine):
```nix
# Auto-derive cluster.gpu.accelerator from node inventory
cluster.gpu.accelerator = lib.mkDefault (
  let gpuNodes = lib.filter (n: n.gpu != null) (lib.attrValues config.cluster.nodes);
  in if gpuNodes == [] then null
     else (lib.head gpuNodes).gpu.type
);

# Auto-derive capabilities.gpu
cluster.capabilities.gpu = lib.mkDefault (config.cluster.gpu.accelerator != null);

# Auto-derive NCCL transport from provider
cluster.gpu.networking.nccl = lib.mkDefault ({
  eks = "efa";
  gke = "tcpxo";
}.${config.cluster.provider or ""} or "tcp");
```

#### Layer 2: GPU Infrastructure Packages

Each AICR component becomes a kix package with typed options and DI:

##### `packages/gpu-operator/default.nix`

```nix
{ scope, lib, kix }:
{
  meta = {
    version = "25.3.3";
    scope = "cluster";
    lifecycle = "stateful";
    owner = "platform";
    provides = [ "gpu-scheduling" ];
    defaultAliases = [ "gpu" "nvidia-gpu" ];
    compatibleWith.capabilities.gpu = true;
  };

  options = {
    driver = {
      version = lib.mkOption {
        type = lib.types.str;
        default = "580.82.07";
        description = "NVIDIA driver version to install/manage.";
      };
      managed = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether the GPU Operator manages driver installation.";
      };
    };
    cuda.version = lib.mkOption {
      type = lib.types.str;
      default = "12.8";
    };
    dcgmExporter.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    mig = {
      strategy = lib.mkOption {
        type = lib.types.enum [ "single" "mixed" ];
        default = scope.cluster.gpu.mig.strategy or "single";
      };
    };
    devicePlugin = {
      version = lib.mkOption { type = lib.types.str; default = "0.17.1"; };
    };
    gds.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "GPUDirect Storage for direct GPU-to-storage I/O.";
    };
  };

  deps = {
    certManager = { package = "cert-manager"; };
    prometheus = { package = "prometheus"; optional = true; };
    nodeFeatureDiscovery = { package = "node-feature-discovery"; optional = true; };
  };

  build = { scope, config, certManager, prometheus ? null, nodeFeatureDiscovery ? null }:
    let
      helmChart = kix.fetchHelmChart {
        repo = "https://helm.ngc.nvidia.com/nvidia";
        chart = "gpu-operator";
        version = "v${config.meta.version}";
      };
    in
    [
      (kix.fromHelmChart {
        inherit scope helmChart;
        values = {
          driver = {
            enabled = config.driver.managed;
            version = config.driver.version;
          };
          toolkit.version = "v1.17.5";
          devicePlugin.version = "v${config.devicePlugin.version}";
          dcgmExporter.enabled = config.dcgmExporter.enable;
          mig.strategy = config.mig.strategy;
          gds.enabled = config.gds.enable;
          # DI: cert-manager is available
          validator.plugin.env = [
            { name = "WITH_WORKLOAD"; value = "true"; }
          ];
        };
      })
    ]
    ++ lib.optional (prometheus != null) (kix.monitor {
      service = "gpu-operator";
      port = "gpu-operator-metrics";
    });
}
```

##### `packages/network-operator/default.nix` (sketch)

```nix
{ scope, lib, kix }:
{
  meta = {
    version = "25.4.0";
    scope = "cluster";
    owner = "platform";
    provides = [ "gpu-networking" "rdma" ];
    defaultAliases = [ "nvidia-network" ];
  };

  options = {
    rdma.enable = lib.mkOption {
      type = lib.types.bool;
      default = scope.cluster.gpu.networking.rdma or false;
    };
    srIov.enable = lib.mkOption {
      type = lib.types.bool;
      default = scope.cluster.gpu.networking.srIov or false;
    };
  };

  deps = {
    certManager = { package = "cert-manager"; };
    gpuOperator = { package = "gpu-operator"; optional = true; };
  };

  build = { scope, config, certManager, gpuOperator ? null }: [ /* Helm chart wrapping */ ];
}
```

##### Other packages (stubs — each follows the same pattern)

- `packages/nccl-plugin/` — Cloud-specific NCCL transport (EFA for EKS, TCPxO for GKE, IB for bare metal)
- `packages/gpu-node-tuning/` — DaemonSet for kernel params, sysctl, hugepages (Skyhook equivalent)
- `packages/gpu-health-monitor/` — GPU error detection + node cordon/drain (NVSentinel equivalent)
- `packages/kai-scheduler/` — DRA-aware gang scheduler with topology-aware placement
- `packages/gpu-feature-discovery/` — Node labeling for GPU type, driver, CUDA version
- `packages/kubeflow-trainer/` — Distributed training job orchestration
- `packages/nvidia-dra-driver/` — Dynamic Resource Allocation for GPUs (K8s 1.34+)

#### Layer 3: Intents — Goal-Driven Composition

Intents are **module presets** — Nix modules that compose the right packages and settings for a high-level goal. This is kix's answer to AICR's recipe engine, using the existing module system instead of a custom overlay inheritance chain.

```nix
# lib/intents/gpu-training.nix
{ lib, config, packages, ... }:
{
  # Declare what this intent needs
  instances.gpu-operator.gpu-operator = {
    package = packages.gpu-operator;
    config = {
      dcgmExporter.enable = true;
      gds.enable = lib.mkDefault (
        config.cluster.gpu.accelerator or "" == "h100"
        || config.cluster.gpu.accelerator or "" == "gb200"
      );
    };
  };

  instances.gpu-operator.network-operator = {
    package = packages.network-operator;
    config.rdma.enable = lib.mkDefault (
      config.cluster.gpu.networking.rdma
    );
  };

  instances.gpu-operator.nccl-plugin = {
    package = packages.nccl-plugin;
    config.transport = lib.mkDefault (
      config.cluster.gpu.networking.nccl or "tcp"
    );
  };

  instances.gpu-operator.gpu-node-tuning = {
    package = packages.gpu-node-tuning;
  };

  instances.gpu-operator.gpu-health-monitor = {
    package = packages.gpu-health-monitor;
  };

  instances.kube-system.kai-scheduler = {
    package = packages.kai-scheduler;
    config.gangScheduling.enable = true;
  };

  instances.training.kubeflow-trainer = {
    package = packages.kubeflow-trainer;
  };

  # Monitoring integration
  instances.monitoring.gpu-dashboards = {
    package = packages.grafana-dashboard;
    config.dashboards = [ "gpu-cluster" "gpu-node" "dcgm-exporter" ];
  };
}

# lib/intents/gpu-inference.nix
{ lib, config, packages, ... }:
{
  instances.gpu-operator.gpu-operator = {
    package = packages.gpu-operator;
    config = {
      dcgmExporter.enable = true;
      # Inference may use MIG for multi-tenant GPU sharing
      mig.strategy = lib.mkDefault (
        if config.cluster.gpu.mig.enabled then "mixed" else "single"
      );
    };
  };

  # Lighter networking — inference typically doesn't need RDMA
  instances.gpu-operator.network-operator = {
    package = packages.network-operator;
    config.rdma.enable = lib.mkDefault false;
  };

  instances.gpu-operator.gpu-node-tuning = {
    package = packages.gpu-node-tuning;
  };

  instances.gpu-operator.gpu-health-monitor = {
    package = packages.gpu-health-monitor;
  };

  # No gang scheduler needed for inference
  # No kubeflow trainer
}
```

Usage in a cluster definition:

```nix
# clusters/ai-training.nix
{ kix, packages }:

kix.buildCluster {
  name = "ai-training-prod";
  modules = [
    kix.flavors.eks                         # Cloud provider
    kix.intents.gpu-training                # "I want GPU training"

    {
      # Describe hardware (or import from snapshot)
      cluster.gpu.accelerator = "h100";
      cluster.gpu.networking.rdma = true;

      cluster.nodes = {
        gpu-0 = { roles = [ "worker" "gpu" ]; cpu = 96; memory = "2Ti"; gpu = { type = "h100"; count = 8; }; };
        gpu-1 = { roles = [ "worker" "gpu" ]; cpu = 96; memory = "2Ti"; gpu = { type = "h100"; count = 8; }; };
        gpu-2 = { roles = [ "worker" "gpu" ]; cpu = 96; memory = "2Ti"; gpu = { type = "h100"; count = 8; }; };
        gpu-3 = { roles = [ "worker" "gpu" ]; cpu = 96; memory = "2Ti"; gpu = { type = "h100"; count = 8; }; };
        system-0 = { roles = [ "worker" ]; cpu = 16; memory = "64Gi"; };
        system-1 = { roles = [ "worker" ]; cpu = 16; memory = "64Gi"; };
      };

      cluster.network.podCidr = "10.244.0.0/16";
    }

    # Your application packages on top
    ./training-jobs.nix
    ./monitoring.nix
  ];
}
```

### Optional: Hardware Snapshot Import

Instead of manually declaring `cluster.nodes`, a snapshot tool can auto-discover and generate the Nix:

```bash
# Run snapshot agent on the cluster (similar to AICR snapshot)
kix snapshot --context my-gpu-cluster --output cluster-hardware.json

# The JSON is importable in the cluster definition
```

```nix
# clusters/ai-training.nix
{ kix, packages }:
let
  hardware = builtins.fromJSON (builtins.readFile ./cluster-hardware.json);
in
kix.buildCluster {
  name = "ai-training-prod";
  modules = [
    kix.flavors.eks
    kix.intents.gpu-training
    (kix.fromHardwareSnapshot hardware)  # Auto-populates cluster.nodes, cluster.gpu.*
    ./training-jobs.nix
  ];
}
```

`kix.fromHardwareSnapshot` is a function that maps the JSON inventory to module options — it's a one-way import, not a live connection. The cluster definition remains declarative and reproducible.

The snapshot agent itself is a K8s Job (similar to AICR's) that collects:
- GPU info via `nvidia-smi --query-gpu=...`
- Node labels and taints from the K8s API
- OS and kernel version from `/etc/os-release`
- K8s server version

This is a **CLI feature** (`kix snapshot`), not a runtime component. It generates a file that the user commits to their repo.

### Validation: Known-Good Combinations

AICR's deepest value is its **qualification database** — tested combinations of GPU + driver + CUDA + operator versions. kix can encode this as scorecard rules:

```nix
# lib/rules/gpu-compatibility.nix
{ lib }:
{
  name = "gpu-version-compatibility";
  level = "cluster";
  severity = "error";
  description = "Validates GPU component versions are a known-good combination.";

  check = { clusterConfig, instances, ... }:
    let
      gpuOp = instances.gpu-operator.gpu-operator or null;
      accelerator = clusterConfig.cluster.gpu.accelerator or null;
      provider = clusterConfig.cluster.provider or null;

      # Known-good combinations (could be imported from AICR's data or maintained separately)
      compatMatrix = {
        h100.eks = {
          gpu-operator = "25.3.3";
          driver = "580.82.07";
          cuda = "12.8";
          network-operator = "25.4.0";
        };
        h100.gke = {
          gpu-operator = "25.3.3";
          driver = "580.82.07";
          cuda = "12.8";
          network-operator = "25.4.0";
        };
        a100.eks = {
          gpu-operator = "25.3.3";
          driver = "570.86.15";
          cuda = "12.6";
          network-operator = "25.4.0";
        };
        # ...
      };

      expected = compatMatrix.${accelerator}.${provider} or null;
    in
    if gpuOp == null || expected == null then []
    else
      lib.optional (gpuOp.config.driver.version != expected.driver) {
        message = "GPU driver ${gpuOp.config.driver.version} is not in the known-good matrix for ${accelerator} on ${provider}. Expected: ${expected.driver}";
      }
      ++ lib.optional (gpuOp.config.meta.version != expected.gpu-operator) {
        message = "GPU Operator ${gpuOp.config.meta.version} is not in the known-good matrix. Expected: ${expected.gpu-operator}";
      };
}
```

Crucially, this is a **scorecard rule** — it warns or errors at compile time, like all kix validation. Users can override severity or disable it if they're testing newer versions.

---

## What Makes This Different From Just Cloning AICR

| Aspect | AICR | kix + this proposal |
|--------|------|-------------------|
| **Scope** | NVIDIA AI stack only | Full cluster: AI stack + your apps + monitoring + networking + storage — one graph |
| **Composition model** | Overlay inheritance (Go, embedded data) | Nix module system (compose, override, extend with `mkDefault`/`mkForce`) |
| **Customization** | `--set` flags on Helm values | Full language: conditionals, loops, DI, typed options |
| **Validation** | Runtime constraint checking (post-recipe) | Compile-time: type errors, dependency mismatches, scorecard rules — before anything touches the cluster |
| **Dependency tracking** | `deploymentOrder` field in recipe | Automatic from Nix string context — if you reference it, you depend on it |
| **Non-GPU components** | Not covered (cert-manager is a dependency, not a managed component) | cert-manager, ingress, storage, monitoring, your apps — all in the same DI graph |
| **Multi-vendor** | NVIDIA GPUs only | Extensible to AMD (ROCm), Intel (Gaudi), or any accelerator — intents and packages are not vendor-locked |
| **Deployment** | Helm charts or ArgoCD apps | Wave-based SSA with health checks, rollback, operator mode, or GitOps export |
| **Reproducibility** | Version-locked via recipe | Content-addressed via Nix — bit-for-bit reproducible, not just version-locked |

### The Strategic Angle

AICR is a **vendor lock-in tool disguised as a helper**. It makes it easy to set up NVIDIA's stack correctly — but only NVIDIA's stack. The overlay library is embedded in the binary; the "known-good combinations" are NVIDIA's internal data. Extending it to non-NVIDIA components or non-NVIDIA GPUs requires forking.

kix's approach inverts this: the intent modules, packages, and compatibility rules are all user-visible Nix. You can:
- Write a `kix.intents.gpu-inference-amd` that uses ROCm instead of CUDA.
- Override any version in the compatibility matrix.
- Add your own application packages to the same cluster definition.
- Validate the entire stack — not just the GPU components — at compile time.

---

## Implementation Phases

### Phase 0: Foundation (already designed, needs implementation)

Implement the hardware profile from docs 45/69:
- `cluster.gpu.*` module options
- GPU field on `cluster.nodes.*.gpu`
- Auto-derivation of `cluster.capabilities.gpu` from node inventory
- Scheduling derivation (replicas, anti-affinity, topology spread) from hardware

**Effort:** ~1 week. Most of this is translating the designs in docs 45/69 into `lib/modules.nix`.

### Phase 1: GPU Operator Package

Start with the single highest-value package: `packages/gpu-operator/`. This is the foundation everything else builds on.

- Wrap the NVIDIA GPU Operator Helm chart
- Typed options for driver version, CUDA, MIG, DCGM, GDS
- DI on cert-manager, optional prometheus
- Scorecard rules for version compatibility
- Test on Kind + NVIDIA Container Toolkit (local dev) and EKS (cloud)

**Effort:** ~1-2 weeks for a solid v1.

### Phase 2: Networking + Tuning

- `packages/network-operator/` — RDMA, SR-IOV, host networking
- `packages/nccl-plugin/` — Cloud-specific NCCL transport
- `packages/gpu-node-tuning/` — Kernel params, hugepages DaemonSet
- `packages/gpu-feature-discovery/` — Node labeling

**Effort:** ~2 weeks.

### Phase 3: Intent Modules

- `lib/intents/gpu-training.nix` — Composes operator + networking + scheduler + monitoring for training
- `lib/intents/gpu-inference.nix` — Lighter stack for inference workloads
- Known-good compatibility matrix (start with H100+EKS, H100+GKE, A100+EKS)
- Scorecard rules for version validation

**Effort:** ~1 week (leverages packages from phases 1-2).

### Phase 4: Snapshot Agent (optional, nice-to-have)

- `kix snapshot` CLI command
- K8s Job manifest that collects GPU + node + OS inventory
- `kix.fromHardwareSnapshot` Nix function to import results
- Validation: compare snapshot against cluster definition (drift detection)

**Effort:** ~1-2 weeks (Rust CLI + K8s Job + Nix import function).

### Phase 5: Advanced Components (future)

- `packages/kai-scheduler/` — Gang scheduling
- `packages/nvidia-dra-driver/` — DRA for K8s 1.34+
- `packages/kubeflow-trainer/` — Distributed training
- `packages/gpu-health-monitor/` — NVSentinel equivalent
- Performance validation scorecard rules (NCCL bandwidth tests)

---

## Open Questions

1. **Should AICR's compatibility matrix be imported directly?** AICR embeds its overlay data in the Go binary. We could parse the `recipes/` directory from AICR's repo and generate Nix compatibility data automatically. Risk: coupling to NVIDIA's release cadence. Alternative: maintain our own smaller matrix, tested.

2. **Intent vs flavor — is the distinction clear?** Flavors describe "what infrastructure I'm running on" (EKS, k3s). Intents describe "what I want to do" (training, inference). They compose: `kix.flavors.eks + kix.intents.gpu-training`. But intents also set infrastructure packages. Is the boundary clean enough, or will users be confused about which layer to customize?

3. **Multi-GPU-type clusters.** AICR assumes one accelerator type per recipe. Real clusters may mix A100s and H100s (training + inference partitions). The `cluster.gpu.accelerator` single-value field doesn't capture this. Node-level `gpu.type` does, but intents need to handle the heterogeneity.

4. **How much NVIDIA-specific knowledge is worth encoding?** The deeper we go (MIG profiles, NVLink topology, specific driver quirks), the more value we provide — but also the more maintenance burden and the more we couple to NVIDIA's roadmap. Start shallow, deepen based on demand?

5. **Should `kix snapshot` be a CLI feature or a separate tool?** It needs cluster access (kubeconfig), which the Nix evaluator doesn't have. The CLI is the natural home. But it produces a file consumed by Nix, creating a two-step workflow. Is there a way to make this smoother?

6. **AMD/Intel GPU support from day one?** Designing the `cluster.gpu.*` schema to be vendor-neutral from the start avoids breaking changes later. But we have zero domain knowledge about ROCm or Gaudi stacks. Design for extensibility, implement only NVIDIA?

---

## References

- [NVIDIA AICR GitHub](https://github.com/NVIDIA/aicr) — Source code and documentation
- kix doc 45 — Cluster hardware profile (capability model, node inventory)
- kix doc 69 — Infrastructure-aware compilation (hardware depth, scheduling derivation, fleet)
- kix doc 13 (business) — AI-native infrastructure positioning
- [NVIDIA GPU Operator docs](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/)
- [KAI Scheduler](https://github.com/NVIDIA/KAI-Scheduler) — Gang scheduling for GPU workloads
