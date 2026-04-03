# 69 — Infrastructure-Aware Compilation: From Hardware to Fleet

**Status:** Exploration
**Related:** `45_cluster_hardware_profile.md` (foundation — capabilities + node model), `59_load_estimation_demand_aggregation.md` (demand side), `63a_storage_as_cluster_concern.md` (storage as cluster concern), `49_topology_aware_monitoring.md` (topology-derived config), `45_multi_team_and_operator_models.md` (multi-team patterns), `47_air_gapped_deploys.md` (air-gapped/edge), `66_milestone_roadmap.md` (fleet management as M2)

---

## The Question

Doc 45 established `cluster.nodes` with roles, CPU, memory, labels, taints. But it stopped at the Kubernetes-visible slice of a single cluster. Two questions remain:

1. **How deep should we go?** Describe actual hardware — OS, kernel version, GPU model, disk types, CPU architecture — and let kix derive scheduling primitives (taints, tolerations, affinities, topology spread constraints) automatically. The dream: "describe your iron, get correct manifests."

2. **How wide should we go?** Enterprises don't have one cluster. They have fleets — prod/staging/dev per region, edge nodes at retail locations, mixed ARM/x86 clusters, air-gapped environments behind firewalls. Can the hardware model scale from "one homelab box" to "200 clusters across 3 continents"?

This document explores both dimensions.

---

# Part 1: Single-Cluster Hardware Depth

## The Layered Answer

Hardware description value follows a clear gradient. Some things are high-leverage; others are wasted effort because K8s already handles them.

### Tier 1: High Value — K8s Doesn't Know This At Compile Time

These are facts about the cluster that K8s only discovers at runtime (kubelet self-reports) but that kix needs at **compile time** to generate correct manifests. This is where the magic is real.

| Hardware fact | What kix derives | Why K8s can't do this |
|---|---|---|
| **Node count + roles** | Replica count defaults, anti-affinity feasibility, PDB min-available | K8s doesn't prevent you deploying 3-replica anti-affinity on a 2-node cluster — it just leaves pods Pending forever |
| **GPU presence + type** | Auto-taint GPU nodes, add tolerations to GPU workloads, set `nvidia.com/gpu` resource limits | K8s has the device plugin, but nothing stops you from *requesting* a GPU that doesn't exist — it just Pendings |
| **Disk inventory per node** | Storage operator pool config (OpenEBS DiskPool, Longhorn disk paths), local PV generation | Storage operators need explicit config telling them which disks to use — they don't auto-discover safely |
| **Zone/rack topology** | Topology spread constraints with correct topology keys, zone-aware replica distribution | K8s has the primitives but you have to write them correctly per cluster — kix can derive them from node labels |
| **Node memory/CPU totals** | Resource budget validation ("your total requests exceed cluster capacity"), right-sizing warnings | K8s scheduler handles bin-packing at runtime, but can't warn you at deploy time that you've overcommitted |

**The key insight:** K8s knows these facts at runtime. But kix operates at **compile time**, before anything touches the cluster. The value is catching mismatches before deploy, not replacing K8s scheduling.

### Tier 2: Medium Value — Useful Defaults, Not Magic

| Hardware fact | What kix could derive | But... |
|---|---|---|
| **Kernel version** | Gate eBPF features (Cilium needs 4.19+, advanced features need 5.10+), warn about missing capabilities | Only matters for a few infrastructure packages, not general workloads. Kernel version can change independently of kix config. |
| **CPU architecture** | Multi-arch image selection (amd64 vs arm64), node affinity for arch-specific workloads | K8s already labels nodes with `kubernetes.io/arch`. But if kix models it, packages can pick the right image tag at compile time — critical for mixed-arch clusters. |
| **NIC capabilities** | SR-IOV support, DPDK availability, Multus network attachment definitions | Niche — telco/HPC only. |
| **OS / distro** | Warn about known incompatibilities (e.g., certain CSI drivers on specific distros) | K8s is supposed to be distro-agnostic. Modeling this is whack-a-mole. |

### Tier 3: Low Value — K8s Already Abstracts This

| Hardware fact | Why it's low value |
|---|---|
| **Specific CPU model** | K8s doesn't expose CPU model to pods. Use node labels + affinity instead. |
| **RAID configuration** | Below the storage abstraction. K8s sees block devices, not RAID levels. |
| **Network interface bonding** | CNI abstracts the network. Pods get a veth pair regardless. |
| **BIOS/firmware** | Irrelevant to manifest generation. |
| **RAM type/speed** | K8s treats memory as fungible bytes. |

## Automatic Scheduling Derivation — Traced Examples

### Example: Mixed GPU/Non-GPU Cluster

The operator describes:

```nix
cluster.nodes = {
  worker1 = {
    roles = [ "worker" ];
    cpu = 32; memory = "128Gi";
    labels."topology.kubernetes.io/zone" = "dc1";
  };
  worker2 = {
    roles = [ "worker" ];
    cpu = 32; memory = "128Gi";
    labels."topology.kubernetes.io/zone" = "dc2";
  };
  gpu1 = {
    roles = [ "worker" "gpu" ];
    cpu = 32; memory = "128Gi";
    gpu = { type = "nvidia-t4"; count = 2; };
    labels."topology.kubernetes.io/zone" = "dc1";
  };
};
```

kix derives (without the operator writing any of this):

**1. Cluster capabilities — auto-inferred:**
```nix
cluster.capabilities.gpu = true;           # at least one GPU node exists
cluster.capabilities.multiNode = true;     # 3 nodes
cluster.capabilities.availabilityZones = [ "dc1" "dc2" ];  # from node labels
```

**2. For a general workload (e.g., immich):**
```yaml
# Derived: 2 workers in 2 zones → spread across zones
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
# Derived: 3 nodes but one is GPU-tainted → 2 schedulable → max 2 replicas with anti-affinity
replicas: 2
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
```

**3. For a GPU workload (e.g., ML inference):**
```yaml
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
nodeSelector:
  nvidia.com/gpu: "true"
resources:
  limits:
    nvidia.com/gpu: "1"
replicas: 1  # only 1 GPU node
```

**4. Resource budget validation (compile-time warning):**
```
⚠ Cluster capacity: 96 vCPU / 384Gi memory (3 nodes)
  Total requests: 78 vCPU / 310Gi memory
  Headroom: 18 vCPU / 74Gi memory (18.8%)
  Warning: headroom below 20% — node failure will cause evictions
```

### Example: Single Node Homelab

```nix
cluster.nodes.ludo = {
  roles = [ "control-plane" "worker" "storage" ];
  cpu = 8; memory = "16Gi";
  disks = [
    { device = "/dev/sda"; type = "ssd"; size = "512Gi"; role = "system"; }
    { device = "/dev/sd[b-e]"; type = "hdd"; size = "4Ti"; role = "storage"; }
  ];
};
```

kix derives:
- `multiNode = false` → all packages get `replicas: 1`, no anti-affinity, no PDB
- No topology spread constraints (pointless with one node)
- Storage pools derived from disk inventory (OpenEBS/Longhorn config)
- Resource budget is tight — aggressive warnings for overcommit

## The Derivation Engine

### Layer 1: Hardware → Capabilities (automatic)

When `cluster.nodes` is populated, kix auto-derives capabilities:

```nix
# In lib/modules.nix or a dedicated hardware-inference module
cluster.capabilities = {
  multiNode = lib.mkDefault (builtins.length (builtins.attrNames config.cluster.nodes) > 1);
  gpu = lib.mkDefault (builtins.any
    (n: n.gpu or null != null)
    (builtins.attrValues config.cluster.nodes));
  availabilityZones = lib.mkDefault (lib.unique (lib.concatMap
    (n: lib.optional (n.labels ? "topology.kubernetes.io/zone")
      n.labels."topology.kubernetes.io/zone")
    (builtins.attrValues config.cluster.nodes)));
};
```

### Layer 2: Capabilities → Scheduling Primitives (in scope helpers)

```nix
scope.scheduling = {
  topologySpreadConstraints =
    if capabilities.multiNode && capabilities.availabilityZones != []
    then [{
      maxSkew = 1;
      topologyKey = "topology.kubernetes.io/zone";
      whenUnsatisfiable = "DoNotSchedule";
      labelSelector.matchLabels = scope.selectorLabels;
    }]
    else [];

  recommendedReplicas = tier:
    let
      workerCount = builtins.length (builtins.filter
        (n: builtins.elem "worker" n.roles)
        (builtins.attrValues clusterConfig.cluster.nodes));
      zoneCount = builtins.length capabilities.availabilityZones;
    in
      if !capabilities.multiNode then 1
      else if tier == "critical" then builtins.min workerCount (builtins.max 3 zoneCount)
      else if tier == "standard" then builtins.min workerCount 2
      else 1;

  podAntiAffinity = replicas:
    let workerCount = /* ... */; in
    if replicas >= workerCount then "preferred"
    else "required";
};
```

### Layer 3: Package Opt-In (not implicit)

Packages use these helpers explicitly — no invisible injection:

```nix
build = { scope, config, ... }: {
  deployment = scope.mkDeployment {
    replicas = config.replicas;
    spec.template.spec = {
      topologySpreadConstraints = scope.scheduling.topologySpreadConstraints;
    } // lib.optionalAttrs (config.replicas > 1) {
      affinity.podAntiAffinity = scope.scheduling.podAntiAffinity config.replicas;
    };
  };
};

_kixOptions.replicas = lib.mkOption {
  type = lib.types.int;
  default = scope.scheduling.recommendedReplicas "critical";
};
```

## Static Description vs. Dynamic Reality (Drift)

Hardware descriptions drift. A node gets added, a disk gets replaced, a kernel gets upgraded. Three approaches, not mutually exclusive:

**Option A: Accept it** — the profile describes *intended* state. K8s handles scheduling gaps at runtime. Most kix value comes from the compile-time *shape* (single-node vs multi-node, GPU vs none, which zones), not every runtime change.

**Option B: Reconcile from the live cluster** — `kix health` compares `cluster.nodes` against actual K8s node objects and warns about drift. Use the profile for compilation, validate against reality during health checks.

**Option C: Generate the hardware profile** — `kix import-hardware --context my-cluster` queries the K8s API and produces a `hardware.nix` file. The `nixos-generate-config` equivalent. Generate once, own forever.

All three compose: generate (C) to bootstrap, accept (A) as the steady state, reconcile (B) as a safety net.

## OS/Kernel — Limited but Real Value

**Kernel version** — useful for exactly two things:
1. **eBPF feature gating.** Cilium needs 4.19+ for basic eBPF, 5.10+ for bandwidth manager, 6.1+ for BIG TCP. kix can warn: "You've enabled bandwidthManager but nodes run kernel 5.4."
2. **Seccomp/AppArmor profile availability.** Niche.

**OS/distro** — almost never useful for manifest generation. K8s abstracts the node OS. Talos has no SSH, Bottlerocket is immutable — operational knowledge, not manifest concerns.

**Recommendation:** Add `kernel` as optional field on nodes. Don't model OS/distro.

---

# Part 2: Enterprise Scale — Multi-Cluster, Multi-Region, Edge

Everything above assumes one cluster. Enterprises live in a different world.

## The Fleet Reality

A mid-size enterprise (100-500 engineers) typically has:

| Cluster type | Count | Characteristics |
|---|---|---|
| **Production** per region | 2-5 | Multi-zone, HA, strict compliance, change windows |
| **Staging** per prod | 2-5 | Mirrors prod topology but smaller nodes, relaxed policies |
| **Dev/CI** | 1-3 | Ephemeral or long-lived, minimal nodes, fast iteration |
| **Edge** | 10-200 | Retail stores, factories, branch offices. k3s/k0s on ARM or x86 mini-PCs. Air-gapped or intermittent connectivity. |
| **Specialized** | 1-3 | GPU clusters for ML, high-memory clusters for analytics, bare-metal for low-latency |

That's 15-200+ clusters, with wildly different hardware profiles, network constraints, and compliance requirements — but running overlapping sets of services.

## Multi-Cluster Architecture in kix

### The Nix Answer: One Flake, Many Clusters

kix's natural multi-cluster pattern extends from Nix flakes. Each cluster is a flake output:

```nix
# flake.nix
{
  outputs = { self, kixpkgs, ... }: {
    clusters = {
      prod-eu    = import ./clusters/prod-eu.nix    { inherit kixpkgs; };
      prod-us    = import ./clusters/prod-us.nix    { inherit kixpkgs; };
      staging-eu = import ./clusters/staging-eu.nix { inherit kixpkgs; };
      edge-store-001 = import ./clusters/edge/store-001.nix { inherit kixpkgs; };
      edge-store-002 = import ./clusters/edge/store-002.nix { inherit kixpkgs; };
      gpu-ml     = import ./clusters/gpu-ml.nix     { inherit kixpkgs; };
    };
  };
}
```

Each cluster definition imports its own hardware profile and flavors. **The packages are shared; the infrastructure description differs.** This is the core insight: the same `packages.immich` produces different manifests on each cluster because `scope.cluster` is different.

### Cluster Templates — DRY for Similar Clusters

Edge clusters and staging environments are often nearly identical. Nix functions handle this naturally:

```nix
# lib/cluster-templates/edge-retail.nix
# A template for retail store edge nodes
{ kixpkgs, storeId, region, nodeSpec ? {} }:

kixpkgs.lib.buildCluster {
  name = "edge-${storeId}";
  modules = [
    kixpkgs.flavors.k3s
    kixpkgs.flavors.topology.single-node

    {
      cluster.provider = "k3s";
      cluster.capabilities = {
        loadBalancer = false;
        multiNode = false;
        persistentStorage = true;       # local SSD
        rwxStorage = false;
      };

      cluster.nodes.edge = nodeSpec // {
        roles = [ "control-plane" "worker" ];
        arch = nodeSpec.arch or "amd64";
        cpu = nodeSpec.cpu or 4;
        memory = nodeSpec.memory or "8Gi";
      };

      cluster.metadata = {
        inherit region storeId;
        environment = "production";
        connectivity = "intermittent";  # edge-specific
      };
    }

    ./edge-retail/services.nix   # POS system, inventory sync, local cache
  ];
}
```

```nix
# clusters/edge/store-001.nix
{ kixpkgs }:
import ../../lib/cluster-templates/edge-retail.nix {
  inherit kixpkgs;
  storeId = "001";
  region = "eu-west";
  nodeSpec = {
    arch = "arm64";          # Raspberry Pi 5 / Rockchip
    cpu = 4;
    memory = "8Gi";
    disks = [{ device = "/dev/mmcblk0"; type = "ssd"; size = "256Gi"; role = "system"; }];
  };
}

# clusters/edge/store-002.nix
{ kixpkgs }:
import ../../lib/cluster-templates/edge-retail.nix {
  inherit kixpkgs;
  storeId = "002";
  region = "eu-central";
  nodeSpec = {
    arch = "amd64";          # Intel NUC
    cpu = 8;
    memory = "16Gi";
    disks = [
      { device = "/dev/nvme0n1"; type = "nvme"; size = "512Gi"; role = "system"; }
      { device = "/dev/sda"; type = "ssd"; size = "1Ti"; role = "storage"; }
    ];
  };
}
```

200 retail stores? 200 files that are each 15 lines calling the same template with different hardware specs. Or generate them programmatically:

```nix
# clusters/edge/all.nix — generate all edge clusters from a data file
{ kixpkgs }:
let
  storeData = builtins.fromJSON (builtins.readFile ./stores.json);
  mkStore = store: import ../../lib/cluster-templates/edge-retail.nix {
    inherit kixpkgs;
    inherit (store) storeId region;
    nodeSpec = store.hardware;
  };
in builtins.mapAttrs (_: mkStore) storeData
```

This is where kix's Nix foundation crushes Helm/Kustomize. Try generating 200 slightly-different Kustomize overlays from a JSON inventory file. It's possible but miserable. In Nix it's a `mapAttrs`.

## Multi-Architecture: ARM, x86, and Mixed Clusters

### The Problem

ARM is no longer niche. AWS Graviton offers 20-40% better price/performance for many workloads. Ampere Altra powers Hetzner's ARM offerings. Raspberry Pis and Rockchip boards run edge clusters. Apple Silicon means developers' machines are ARM.

A real fleet often has:
- **Prod:** x86 (legacy, specific software requirements, GPU)
- **Edge:** ARM (power efficiency, cost, form factor)
- **Dev:** Mixed (developers on Apple Silicon, CI on x86)
- **Cost-optimized:** ARM for stateless services, x86 for databases

The manifest impact is **primarily container images**. Most modern images are multi-arch (Docker manifest lists), but:
- Some are not (legacy, niche, or internally-built images)
- Tag conventions sometimes differ (`image:tag` vs `image:tag-arm64`)
- Init containers and sidecars may have different arch support
- Base images matter for custom builds (you can't run an x86 binary on ARM)

### How kix Handles This

**Per-node `arch` field** (already proposed in Part 1):

```nix
cluster.nodes = {
  arm-worker1.arch = "arm64";
  arm-worker2.arch = "arm64";
  x86-worker1.arch = "amd64";
};
```

**Cluster-level arch derivation:**

```nix
# Auto-derived
cluster.capabilities.architectures = lib.unique (
  map (n: n.arch) (builtins.attrValues config.cluster.nodes)
);
cluster.capabilities.multiArch =
  builtins.length config.cluster.capabilities.architectures > 1;
```

**Package-level image selection:**

Packages already declare images as structured attributes. On a multi-arch cluster, the package can expose arch-specific variants:

```nix
# packages/my-app/default.nix
{ scope, lib, ... }:
{
  _kixOptions.image = lib.mkOption {
    type = lib.types.attrs;
    default = {
      repository = "ghcr.io/myorg/myapp";
      tag =
        if scope.cluster.capabilities.multiArch
        then "v2.0.0"  # must be a multi-arch manifest
        else "v2.0.0-${builtins.head scope.cluster.capabilities.architectures}";
    };
  };

  # Compile-time assertion
  assertions = [
    {
      assertion = !scope.cluster.capabilities.multiArch
        || config.image.multiArchVerified or true;
      message = "Multi-arch cluster but image ${config.image.repository}:${config.image.tag} "
        + "is not verified as multi-arch. Set image.multiArchVerified = true to suppress.";
    }
  ];
}
```

**For mixed clusters where specific workloads need specific architectures:**

```nix
build = { scope, config, ... }: {
  deployment = scope.mkDeployment {
    spec.template.spec = {
      nodeSelector = lib.optionalAttrs (config.requiredArch != null) {
        "kubernetes.io/arch" = config.requiredArch;
      };
    };
  };
};

_kixOptions.requiredArch = lib.mkOption {
  type = lib.types.nullOr (lib.types.enum [ "amd64" "arm64" ]);
  default = null;
  description = "Pin this workload to a specific architecture. null = any (multi-arch image required).";
};
```

**The scorecard can validate image arch compatibility:**

```nix
# A scorecard rule
multiArchImageCheck = {
  description = "Container images must support all cluster architectures";
  level = "resource";
  severity = "warning";
  check = resource:
    if resource.kind != "Deployment" then null
    else
      let images = extractImages resource; in
      # This would need a registry query or a local cache of image manifests
      # Practical: just flag images that don't use multi-arch tag conventions
      null;  # placeholder
};
```

### The Practical Image Problem

The hardest part isn't generating manifests — it's **knowing at compile time which images support which architectures**. Options:

1. **Trust convention** — if the image tag doesn't have an arch suffix, assume it's multi-arch. Works for 90% of public images.
2. **Image metadata cache** — `kix images --inspect` queries registries for manifest lists and caches the result. Compile-time check becomes: "this image supports amd64 and arm64."
3. **Explicit declaration** — packages declare `meta.architectures = [ "amd64" "arm64" ];`. Manual but reliable.

Option 3 is the kix way — explicit, deterministic, no runtime queries during eval. Option 2 is a nice CLI complement for validation.

## Multi-Region and Data Sovereignty

### The Concern

GDPR, HIPAA, data residency laws: certain data must stay in certain jurisdictions. A European fintech might need:
- User data processed exclusively in EU clusters
- Backups stored in EU
- Analytics may run on US clusters but only with anonymized data
- Audit logs must be retained in the jurisdiction of origin

### How This Maps to kix

This is primarily a **multi-cluster concern**, not a per-node concern. The unit of data sovereignty is the cluster (or namespace within a cluster), not individual nodes.

```nix
# Cluster-level metadata
cluster.metadata = {
  region = "eu-central";
  jurisdiction = "EU";
  dataClassification = "confidential";  # determines which services may run here
  compliance = [ "gdpr" "soc2" ];
};
```

Packages can query this:

```nix
# A package that processes PII
assertions = [
  {
    assertion = builtins.elem scope.cluster.metadata.jurisdiction [ "EU" "EEA" ];
    message = "user-data-service processes PII and must run in EU/EEA jurisdiction. "
      + "This cluster is in ${scope.cluster.metadata.jurisdiction}.";
  }
];
```

But the real value isn't per-package assertions — it's **fleet-level validation:**

```bash
$ kix fleet validate --policy data-residency
✓ prod-eu:      user-data-service in EU           — OK
✓ prod-us:      user-data-service not deployed     — OK (correct: PII stays in EU)
✗ staging-us:   user-data-service deployed in US   — VIOLATION (staging mirrors prod-us but includes PII service)
```

This requires a fleet-level view that today's single-cluster `buildCluster` doesn't provide. See "Fleet Management" below.

### Cross-Cluster Dependencies

Multi-region setups often have cross-cluster service dependencies:
- EU users authenticate against an EU cluster; API calls to US services carry auth tokens
- Database replication flows EU → US (read replicas) but not US → EU (writes)
- Shared infrastructure (DNS, certificate authorities) spans all clusters

kix doesn't model cross-cluster dependencies today. This is a significant gap for enterprise. The question is whether it should:

**Option A: Out of scope** — kix manages what's inside a cluster. Cross-cluster wiring (VPNs, DNS, service mesh federation) is Terraform/Istio territory. kix just needs to know about it (e.g., `cluster.externalServices` for services that live in other clusters).

**Option B: Fleet-level dependency graph** — extend the DI model to cross-cluster deps. A package in `prod-eu` can declare a dependency on a package in `prod-us`. The fleet evaluator validates that both clusters expose the expected interface.

Option A is pragmatic and correct for now. Option B is interesting for M5+ (IDP level) but premature.

## Edge Clusters

### What Makes Edge Different

Edge isn't just "small clusters." It has unique constraints that change what manifests look like:

| Constraint | Impact on manifests |
|---|---|
| **Single node** | No anti-affinity, no PDB, replicas=1, no topology spread |
| **Limited resources** | Aggressive resource limits, no monitoring stack (or minimal), stripped-down services |
| **Intermittent connectivity** | Image pull policy `IfNotPresent` or `Never`, pre-pulled images, no dependency on external APIs during runtime |
| **ARM hardware** | Arch-specific images, lower memory defaults |
| **Air-gapped or restricted** | No public registry access, local mirror, no external-secrets-operator (use sealed-secrets or local) |
| **Physical access risk** | Encrypted storage, minimal secrets on-device, short-lived tokens |
| **Fleet scale** | 10-200+ identical clusters with minor variations |

### Edge Flavor Module

```nix
# lib/flavors/topology/edge.nix
{ lib, config, ... }:
{
  cluster.capabilities = {
    multiNode = lib.mkDefault false;
    loadBalancer = lib.mkDefault false;
    persistentStorage = lib.mkDefault true;
    rwxStorage = lib.mkDefault false;
    nodeAutoscaling = lib.mkDefault false;
    managedControlPlane = lib.mkDefault false;
    privilegedContainers = lib.mkDefault true;
  };

  cluster.metadata.tier = lib.mkDefault "edge";

  # Edge-specific: image pull policy should avoid depending on registry availability
  cluster.edge = {
    offlineCapable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this cluster must operate without internet access.
        When true, packages should use imagePullPolicy: IfNotPresent
        and avoid runtime dependencies on external APIs.
      '';
    };

    uptimeRequirement = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "best-effort" "business-hours" "24x7" ]);
      default = "best-effort";
    };
  };
}
```

Packages adapt:

```nix
# packages/inventory-sync/default.nix
# An edge service that syncs local inventory to the central system
{ scope, lib, ... }:
{
  _kixOptions = {
    syncMode = lib.mkOption {
      type = lib.types.enum [ "realtime" "batch" "store-and-forward" ];
      default =
        if scope.cluster.edge.offlineCapable or false
        then "store-and-forward"    # buffer locally, sync when connectivity returns
        else "realtime";
    };
    localCacheSize = lib.mkOption {
      type = lib.types.str;
      default =
        if scope.cluster.edge.offlineCapable or false
        then "10Gi"                 # need to buffer during outages
        else "1Gi";                 # just a small cache
    };
  };

  build = { config, ... }: {
    deployment = scope.mkDeployment {
      replicas = 1;  # always 1 on edge
      spec.template.spec.containers = [{
        image = config.image;
        imagePullPolicy =
          if scope.cluster.edge.offlineCapable or false
          then "IfNotPresent"
          else "Always";
      }];
    };
  };
}
```

### Edge + Air-Gapped: Image Pre-Loading

Doc 47 (air-gapped deploys) designed `kix images` to list all container images. For edge, this becomes critical — you need to pre-load images onto devices before deployment:

```bash
# Build the manifest bundle for all 200 stores
$ for store in $(kix fleet list --tier edge); do
    kix images $store --format skopeo > /tmp/$store-images.yaml
    skopeo sync --src yaml --dest dir /tmp/$store-images.yaml /tmp/$store-images/
    # Ship the images to the store's local registry (USB, satellite uplink, etc.)
  done
```

The hardware profile tells kix which arch to pull: a store with `arch = "arm64"` only needs ARM images.

## Specialized Hardware: GPU Clusters, High-Memory, FPGA

### GPU Clusters for ML/AI

ML workloads have specific scheduling needs that go beyond "has GPU":

```nix
# clusters/gpu-ml.nix
cluster.nodes = {
  gpu-a100-1 = {
    roles = [ "worker" "gpu" ];
    cpu = 64; memory = "512Gi";
    gpu = { type = "nvidia-a100"; count = 8; };  # 8x A100, typical DGX-like
    labels = {
      "nvidia.com/gpu.product" = "A100-SXM4-80GB";
      "nvidia.com/gpu.memory" = "80Gi";
    };
    # NVLink topology matters for multi-GPU training
    interconnect = "nvlink";  # optional: nvlink, pcie, none
  };
  gpu-a100-2 = { /* identical */ };
  cpu-worker-1 = {
    roles = [ "worker" ];
    cpu = 32; memory = "128Gi";
    # No GPU — for preprocessing, model serving, monitoring
  };
};
```

Packages for ML infra can derive config:

```nix
# packages/gpu-operator/default.nix — simplified
_kixOptions.nodeDiscovery = lib.mkOption {
  default = let
    gpuNodes = lib.filterAttrs (_: n: n.gpu or null != null)
      scope.cluster.nodes;
  in {
    enable = gpuNodes != {};
    gpuTypes = lib.unique (map (n: n.gpu.type) (builtins.attrValues gpuNodes));
    totalGPUs = lib.foldl' (acc: n: acc + n.gpu.count) 0 (builtins.attrValues gpuNodes);
  };
};

# packages/training-job/default.nix
_kixOptions.gpuRequest = lib.mkOption {
  type = lib.types.int;
  default = 1;
};

assertions = [
  {
    assertion = config.gpuRequest <= scope.cluster.capabilities.maxGPUPerNode or 8;
    message = "Requested ${toString config.gpuRequest} GPUs but largest node has "
      + "${toString (scope.cluster.capabilities.maxGPUPerNode or 0)}";
  }
];
```

### High-Memory Nodes (Analytics, In-Memory Databases)

Some workloads need terabytes of memory (SAP HANA, ClickHouse, Redis clusters). The hardware profile enables:

```nix
cluster.nodes.highmem1 = {
  roles = [ "worker" ];
  cpu = 96; memory = "1.5Ti";
  labels."node.kubernetes.io/instance-type" = "r6i.metal";
  taints = [{ key = "dedicated"; value = "highmem"; effect = "NoSchedule"; }];
};
```

A ClickHouse package:

```nix
_kixOptions.nodePool = lib.mkOption {
  type = lib.types.nullOr lib.types.str;
  default =
    let
      highmemNodes = lib.filterAttrs (_: n:
        let mem = parseK8sQuantity (n.memory or "0"); in
        mem >= parseK8sQuantity "256Gi"
      ) scope.cluster.nodes;
    in if highmemNodes != {} then "highmem" else null;
};
```

## Fleet Management

### What a Fleet View Enables

Today, kix builds one cluster at a time. A fleet view builds all clusters and enables cross-cluster analysis:

```bash
$ kix fleet build
Building 47 clusters...
  prod-eu:       ████████████████████ OK (2847 resources)
  prod-us:       ████████████████████ OK (2651 resources)
  staging-eu:    ████████████████████ OK (1893 resources)
  edge-store-*:  ████████████████████ OK (42 clusters, 126-134 resources each)
  gpu-ml:        ████████████████████ OK (847 resources)

Fleet summary:
  Total resources: 13,241
  Unique images: 87 (23 arch-specific)
  Clusters with warnings: 3
    staging-eu: resource budget at 91% (add nodes or reduce requests)
    edge-store-047: kernel 5.4 but Cilium configured (needs 5.10+)
    gpu-ml: GPU utilization estimate 34% (consider consolidating)
```

### Fleet-Level Validations

Things you can only check across clusters:

| Validation | What it catches |
|---|---|
| **Image consistency** | staging uses nginx:1.27 but prod uses nginx:1.25 — version drift between environments |
| **Capability consistency** | prod-eu has `rwxStorage = true` but prod-us doesn't — asymmetric HA |
| **Policy consistency** | all prod clusters enforce `podSecurityEnforcement = "restricted"` except prod-us |
| **Package coverage** | monitoring-stack deployed to all prod/staging but missing from 12 edge clusters |
| **Arch coverage** | new package added to edge template but image doesn't support arm64 |
| **Data residency** | PII-processing service accidentally included in US staging cluster |

### Fleet as Nix Evaluation

A fleet is just an attrset of clusters. Fleet-level operations are functions over that attrset:

```nix
# lib/fleet.nix
{
  # Evaluate all clusters and collect cross-cluster metadata
  buildFleet = clusters:
    let
      evaluated = builtins.mapAttrs (_: c: c.evaluated) clusters;
      allImages = lib.unique (lib.concatMap
        (c: c.images)
        (builtins.attrValues evaluated));
      warnings = lib.concatMap
        (name: c:
          map (w: { cluster = name; warning = w; }) c.warnings
        ) (lib.attrsToList evaluated);
    in {
      inherit evaluated allImages warnings;
      # Cross-cluster consistency checks
      assertions = [
        {
          assertion = allProdClustersHaveMonitoring evaluated;
          message = "Not all production clusters have monitoring-stack deployed";
        }
      ];
    };
}
```

### Fleet Topology — Cluster Metadata

The hardware profile describes what's inside a cluster. Fleet topology describes relationships *between* clusters:

```nix
# cluster-level metadata (in each cluster definition)
cluster.metadata = {
  environment = "production";       # production | staging | development | edge
  region = "eu-central";            # geographic region
  jurisdiction = "EU";              # legal jurisdiction for data residency
  tier = "tier-1";                  # SLA tier (affects replica counts, monitoring)
  connectivity = "always-on";       # always-on | intermittent | air-gapped
  owner = "platform-team";          # team responsible
  costCenter = "infra-eu";          # for cost allocation
};
```

This metadata drives fleet-level policy without being Kubernetes-specific. It's organizational topology, not hardware topology.

## Revised Node Model (Extended for Enterprise)

Building on Part 1's proposal, adding the enterprise fields:

```nix
cluster.nodes = lib.mkOption {
  type = lib.types.attrsOf (lib.types.submodule {
    options = {
      # --- Core (from Part 1) ---
      roles = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [
          "control-plane" "worker" "storage" "gpu"
        ]);
        default = [ "worker" ];
      };
      cpu = lib.mkOption { type = lib.types.nullOr lib.types.int; default = null; };
      memory = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
      labels = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = {}; };
      taints = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            key = lib.mkOption { type = lib.types.str; };
            value = lib.mkOption { type = lib.types.str; default = ""; };
            effect = lib.mkOption {
              type = lib.types.enum [ "NoSchedule" "PreferNoSchedule" "NoExecute" ];
            };
          };
        });
        default = [];
      };

      # --- Hardware (Tier 1) ---
      gpu = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            type = lib.mkOption { type = lib.types.str; };
            count = lib.mkOption { type = lib.types.int; default = 1; };
            memory = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Per-GPU memory (e.g. '80Gi'). Enables GPU memory-aware scheduling.";
            };
          };
        });
        default = null;
      };

      disks = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            device = lib.mkOption { type = lib.types.str; };
            type = lib.mkOption {
              type = lib.types.enum [ "ssd" "nvme" "hdd" "virtual" ];
              default = "ssd";
            };
            size = lib.mkOption { type = lib.types.str; };
            role = lib.mkOption {
              type = lib.types.enum [ "system" "storage" "scratch" ];
              default = "storage";
            };
          };
        });
        default = [];
      };

      # --- Architecture ---
      arch = lib.mkOption {
        type = lib.types.enum [ "amd64" "arm64" ];
        default = "amd64";
        description = "CPU architecture. Drives image selection and node affinity.";
      };

      # --- Optional (Tier 2) ---
      kernel = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Kernel version (e.g. '6.1'). Enables eBPF feature validation.";
      };
    };
  });
  default = {};
};

# --- Fleet/Enterprise metadata ---
cluster.metadata = lib.mkOption {
  type = lib.types.submodule {
    options = {
      environment = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [
          "production" "staging" "development" "edge" "ci"
        ]);
        default = null;
      };
      region = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Geographic region (e.g. 'eu-central', 'us-east', 'ap-southeast').";
      };
      jurisdiction = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Legal jurisdiction for data residency (e.g. 'EU', 'US', 'APAC').";
      };
      tier = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "tier-1" "tier-2" "tier-3" "edge" ]);
        default = null;
        description = "SLA tier. Affects replica counts, monitoring depth, backup frequency.";
      };
      connectivity = lib.mkOption {
        type = lib.types.enum [ "always-on" "intermittent" "air-gapped" ];
        default = "always-on";
      };
      owner = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
    };
  };
  default = {};
};

# --- Edge capabilities ---
cluster.edge = lib.mkOption {
  type = lib.types.submodule {
    options = {
      offlineCapable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Must operate without internet. Affects imagePullPolicy, sync modes.";
      };
      uptimeRequirement = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "best-effort" "business-hours" "24x7" ]);
        default = null;
      };
    };
  };
  default = {};
};
```

## What's "Magical" at Enterprise Scale

Returning to the original question — "describe your hardware and everything will be magical."

**Single cluster magic (from Part 1):**
- Topology → scheduling primitives
- GPU → taints/tolerations
- Disk inventory → storage pools
- Resource totals → budget warnings

**Enterprise/fleet magic (new):**
- Architecture → correct image selection across ARM/x86
- Cluster templates → 200 edge clusters from one function + data file
- Fleet validation → catch cross-cluster inconsistencies before deploy
- Data residency → compile-time enforcement of jurisdiction constraints
- Edge capabilities → packages auto-adapt to offline/constrained environments
- `kix fleet build` → one command evaluates everything, catches everything

**Where it breaks down:**
- Cross-cluster runtime dependencies (service mesh federation, DB replication) — these are fundamentally runtime concerns
- Autoscaler behavior — can't model dynamic node counts at compile time
- Network path latency between clusters — runtime measurement, not config
- Cost optimization across the fleet — needs cloud API integration, not just hardware description

## Conclusions and Investment Priority

### For the current stage (M1-M2):

1. **Auto-derive capabilities from nodes** — pure upside, low effort
2. **`kix import-hardware`** — bootstrap from live cluster, solve drift
3. **`scope.scheduling` helpers** — recommendedReplicas, topologySpread
4. **`arch` field on nodes** — needed once any customer has ARM

### For enterprise readiness (M3-M4):

5. **`cluster.metadata`** — environment, region, jurisdiction, tier
6. **Cluster templates** — functions that stamp out similar clusters
7. **Fleet build + fleet validation** — cross-cluster consistency checks
8. **Edge flavor module** — offlineCapable, imagePullPolicy derivation

### For full fleet management (M5+):

9. **Fleet-level dependency graph** — cross-cluster service dependencies
10. **Fleet policy engine** — "all prod clusters must have X" as code
11. **Fleet drift detection** — compare all clusters against their profiles simultaneously
12. **Image arch validation** — registry queries to verify multi-arch support

The vision scales. A homelab user describes one node and gets correct replica counts. An enterprise describes 200 clusters across 3 continents with mixed ARM/x86 and gets compile-time validation of data residency, architecture compatibility, and scheduling feasibility — from the same system, the same primitives, the same packages.

The magic is real where Kubernetes isn't opinionated (topology, architecture, storage). It's pointless where Kubernetes already handles it (CPU model, RAM speed, NIC bonding). And at fleet scale, the magic shifts from hardware-to-manifest derivation to cross-cluster consistency — which is an entirely new category of value that no existing tool provides at compile time.
