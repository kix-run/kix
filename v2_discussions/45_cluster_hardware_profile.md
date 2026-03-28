# 45 — Cluster Hardware Profile (`hardware.nix` for Kubernetes)

**Status:** Partially implemented
**Implemented:** Module options (`cluster.provider`, `cluster.capabilities.*`, `cluster.network.*`, `cluster.nodes`) in `lib/modules.nix`. Distro-level flavor presets (`lib/flavors/{k3s,kind,kubeadm}.nix`) exposed as `kix.flavors.*`. Clusters `ludo` and `test-kind` use flavors.
**Not yet implemented:** Component-level flavors, flavor-provided imports, package capability assertions.

## Problem

In NixOS, `hardware.nix` captures the physical reality of a machine — what disks exist, what CPU features are available, which kernel modules to load. The rest of the configuration builds on top of that foundation. kix has no equivalent. Today, platform-specific facts are scattered across `platform.nix` files as ad-hoc options and inline packages (storage classes, disk pools, CIDR ranges), and packages have no structured way to ask "what can this cluster actually do?"

This causes several problems:

1. **K8s flavor differences are invisible.** k3s ships Traefik + local-path-provisioner by default; vanilla kubeadm ships nothing; EKS gives you AWS-specific CSI drivers and LoadBalancer controllers. A package that works on nw1 (k3s + Cilium + OpenEBS) silently breaks on a GKE cluster because it assumes a CiliumNetworkPolicy CRD exists.

2. **Node topology is unmodeled.** nw1 has 3 worker nodes with specific disk layouts. ludo is a single node. Packages set `replicaCount: 3` and anti-affinity rules that are meaningless on a single-node cluster, but there's no way to derive or validate this.

3. **Capability detection is manual.** Does the cluster have a LoadBalancer controller? GPU nodes? ReadWriteMany storage? Today each package either hardcodes assumptions or exposes config knobs (`serviceType = "ClusterIP"` vs `"LoadBalancer"`) that the cluster operator must remember to set.

## Design Goals

- **Describe the cluster's physical/provider reality in one place**, analogous to NixOS `hardware.nix`.
- **Let packages query capabilities**, not provider names — "can I get a LoadBalancer?" not "is this EKS?"
- **Support custom flavors** — a user running Talos + Cilium + Longhorn on bare metal should be able to describe that just as easily as someone on GKE.
- **Keep it optional** — clusters that don't set a hardware profile still work; packages that don't query capabilities still work.
- **No new fields in K8s manifests** — this is purely evaluation-time information that influences which resources get generated and how.

## Proposed Module Options

### `cluster.provider` — where this cluster runs

High-level provider/distribution tag. Not used for logic directly — it's documentation + a default-setter for capabilities below.

```nix
cluster.provider = lib.mkOption {
  type = lib.types.nullOr (lib.types.enum [
    "k3s" "rke2" "kubeadm" "eks" "gke" "aks" "kind" "talos" "custom"
  ]);
  default = null;
  description = "Kubernetes distribution. Sets capability defaults but can be overridden.";
};
```

### `cluster.capabilities` — what this cluster can do

A structured set of booleans and enums that packages query. The provider sets defaults; the operator overrides as needed.

```nix
cluster.capabilities = {
  loadBalancer = lib.mkOption {
    type = lib.types.bool;
    default = {
      eks = true; gke = true; aks = true;
      k3s = true; # servicelb
      kind = false; kubeadm = false;
    }.${config.cluster.provider or ""} or false;
    description = "Whether Services of type LoadBalancer get an external IP.";
  };

  ingressController = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = {
      k3s = "traefik";
      gke = "gce";
    }.${config.cluster.provider or ""} or null;
    description = "Built-in ingress controller, if any. null = bring your own.";
  };

  cni = lib.mkOption {
    type = lib.types.nullOr (lib.types.enum [
      "cilium" "calico" "flannel" "weave" "aws-vpc" "gke-native" "custom"
    ]);
    default = null;
    description = "CNI plugin. Drives networkPolicy generation (e.g. CiliumNetworkPolicy vs NetworkPolicy).";
  };

  networkPolicyAPI = lib.mkOption {
    type = lib.types.enum [ "k8s" "cilium" "calico" "none" ];
    default = {
      cilium = "cilium";
      calico = "calico";
    }.${config.cluster.capabilities.cni or ""} or "k8s";
    description = "Which network policy CRD to generate. Derived from CNI.";
  };

  storageProvisioner = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = {
      k3s = "local-path";
      eks = "ebs-csi";
      gke = "pd-csi";
    }.${config.cluster.provider or ""} or null;
    description = "Default storage provisioner name. Informational — the actual StorageClass is still a package.";
  };

  rwxStorage = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Whether ReadWriteMany PVCs are supported (e.g. NFS, EFS, Longhorn).";
  };

  gpu = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Whether GPU scheduling (nvidia.com/gpu) is available.";
  };

  multiNode = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether anti-affinity and topology spread constraints are meaningful.";
  };

  availabilityZones = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = "Known AZs. Empty = single-zone or unknown.";
  };
};
```

### `cluster.nodes` — what the cluster is made of

Node topology for validation and resource planning. This is where it gets interesting — a static cluster (bare metal, manually provisioned VMs) can enumerate nodes directly. A cloud cluster with autoscaling describes node pools instead.

```nix
cluster.nodes = lib.mkOption {
  type = lib.types.attrsOf (lib.types.submodule {
    options = {
      roles = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "control-plane" "worker" "storage" "gpu" ]);
        default = [ "worker" ];
      };
      cpu = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "vCPU count (for resource budget warnings).";
      };
      memory = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Total memory, K8s quantity format (e.g. '16Gi').";
      };
      labels = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Node labels (topology, zone, etc).";
      };
      taints = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [];
      };
      disks = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [];
        description = "Disk layout — used by storage packages (OpenEBS, Longhorn) for pool config.";
      };
    };
  });
  default = {};
  description = "Static node inventory. Leave empty for autoscaled clusters.";
};

cluster.nodePools = lib.mkOption {
  type = lib.types.attrsOf (lib.types.submodule {
    options = {
      minNodes = lib.mkOption { type = lib.types.int; default = 0; };
      maxNodes = lib.mkOption { type = lib.types.int; default = 0; };
      instanceType = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
      roles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "worker" ];
      };
      labels = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
      };
      taints = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [];
      };
      gpu = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "GPU type (e.g. 'nvidia-t4', 'nvidia-a100'). null = no GPU.";
      };
    };
  });
  default = {};
  description = "Autoscaled node pools. For cloud/managed clusters.";
};
```

### `cluster.network` — CIDRs and DNS

Already partially exists (`cluster.podCidr`, `cluster.serviceCidr`, `dns.upstreamResolvers` in nw1). This formalizes and collects it.

```nix
cluster.network = {
  podCidr = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
  };
  serviceCidr = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
  };
  dnsUpstream = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = "Upstream DNS resolvers (for CoreDNS forwarding, cert-manager DNS01, etc).";
  };
};
```

## How Packages Use Capabilities

Packages **never** import `cluster.provider` or check for specific distributions. They query `cluster.capabilities.*` through the existing global config mechanism.

### Option 1: Via `_kixOptions` defaults (preferred)

Packages declare options with defaults that reference capabilities:

```nix
# packages/ingress-nginx/default.nix
{ scope, lib, ... }:
{
  meta.version = "4.12.0";

  _kixOptions = {
    serviceType = lib.mkOption {
      type = lib.types.str;
      # Falls back to ClusterIP if no LoadBalancer support
      default =
        if scope.cluster.capabilities.loadBalancer
        then "LoadBalancer"
        else "ClusterIP";
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = if scope.cluster.capabilities.multiNode then 3 else 1;
    };
  };
  # ...
}
```

### Option 2: In assertions/warnings

```nix
{
  meta.k8s.minVersion = "1.28";

  assertions = { config, deps, ... }: [
    {
      assertion = config.serviceType != "LoadBalancer"
        || scope.cluster.capabilities.loadBalancer;
      message = "serviceType=LoadBalancer but cluster has no LoadBalancer controller";
    }
  ];
}
```

### Option 3: Conditional resource generation

```nix
build = { scope, config, ... }: {
  root = scope.mkDeployment { ... };
  service = scope.mkService { ... };
} // lib.optionalAttrs scope.cluster.capabilities.multiNode {
  pdb = scope.mkResource {
    apiVersion = "policy/v1";
    kind = "PodDisruptionBudget";
    # ...
  };
};
```

## How `scope.cluster` Gets Populated

The `buildCluster` evaluator already passes `clusterConfig` to each instance's scope. We extend this to include the hardware profile:

```nix
# Accessible as scope.cluster in packages
scope.cluster = {
  inherit (evaluatedConfig)
    provider
    capabilities
    nodes
    nodePools
    network
    ;
  # Existing fields
  inherit (evaluatedConfig) domain k8sVersion;
};
```

This is a read-only view — packages cannot modify capabilities.

## Flavor Presets

To avoid boilerplate, we provide preset modules that set sensible defaults for common distributions. These are **modules**, not special API — users import them and override whatever doesn't match.

```nix
# lib/flavors/k3s.nix
{ lib, ... }:
{
  cluster.provider = lib.mkDefault "k3s";
  cluster.capabilities = {
    loadBalancer = lib.mkDefault true;     # servicelb
    ingressController = lib.mkDefault "traefik";
    cni = lib.mkDefault "flannel";
    storageProvisioner = lib.mkDefault "local-path";
    multiNode = lib.mkDefault true;
  };
}

# lib/flavors/kind.nix
{ lib, ... }:
{
  cluster.provider = lib.mkDefault "kind";
  cluster.capabilities = {
    loadBalancer = lib.mkDefault false;
    ingressController = lib.mkDefault null;
    cni = lib.mkDefault "flannel";  # kindnet
    multiNode = lib.mkDefault false;
    rwxStorage = lib.mkDefault false;
  };
}

# lib/flavors/eks.nix
{ lib, ... }:
{
  cluster.provider = lib.mkDefault "eks";
  cluster.capabilities = {
    loadBalancer = lib.mkDefault true;
    ingressController = lib.mkDefault null;  # bring your own
    cni = lib.mkDefault "aws-vpc";
    storageProvisioner = lib.mkDefault "ebs-csi";
    multiNode = lib.mkDefault true;
  };
}
```

Usage:

```nix
# clusters/ludo.nix
kix.buildCluster {
  name = "ludo";
  modules = [
    kix.flavors.k3s
    {
      cluster.capabilities.multiNode = false;  # single node
      cluster.capabilities.cni = "cilium";     # replaced flannel
      cluster.network.dnsUpstream = [ "1.1.1.1" ];

      cluster.nodes.ludo = {
        roles = [ "control-plane" "worker" "storage" ];
        cpu = 8;
        memory = "16Gi";
        disks = [
          { device = "/dev/sda"; type = "ssd"; size = "512Gi"; role = "system"; }
          { device = "/dev/sd[b-e]"; type = "hdd"; size = "4Ti"; role = "storage"; note = "raidz2"; }
        ];
      };
    }
    ./ludo/platform.nix
    # ...
  ];
}
```

```nix
# clusters/nw1.nix
kix.buildCluster {
  name = "nw1";
  modules = [
    kix.flavors.k3s
    {
      cluster.capabilities.cni = "cilium";
      cluster.capabilities.rwxStorage = true;  # OpenEBS Mayastor
      cluster.network = {
        podCidr = "10.69.0.0/16";
        serviceCidr = "10.70.0.0/16";
        dnsUpstream = [ "185.12.64.1" "185.12.64.2" ];
      };
      cluster.capabilities.availabilityZones = [ "az1" "az2" "az3" ];

      cluster.nodes = {
        nw1-worker1 = {
          roles = [ "worker" "storage" ];
          labels."topology.lithus.eu/az" = "az1";
          disks = [{ device = "/dev/vg0/mayastor0"; role = "storage"; }];
        };
        nw1-worker2 = {
          roles = [ "worker" "storage" ];
          labels."topology.lithus.eu/az" = "az2";
          disks = [{ device = "/dev/vg0/mayastor0"; role = "storage"; }];
        };
        nw1-worker3 = {
          roles = [ "worker" "storage" ];
          labels."topology.lithus.eu/az" = "az3";
          disks = [{ device = "/dev/vg0/mayastor0"; role = "storage"; }];
        };
      };
    }
    ./nw1/platform.nix
    # ...
  ];
}
```

## Derived Values and Assertions

The hardware profile enables cluster-level assertions that run before any package evaluation:

```nix
# Automatic, inside buildCluster
assertions = [
  {
    assertion = config.cluster.capabilities.multiNode
      || (builtins.length (builtins.attrNames config.cluster.nodes)) <= 1;
    message = "multiNode=false but multiple nodes declared";
  }
  {
    assertion = config.networkPolicy.enable
      -> config.cluster.capabilities.networkPolicyAPI != "none";
    message = "networkPolicy enabled but cluster has no network policy API";
  }
];

# Derived convenience values
cluster.workerCount = builtins.length (
  builtins.filter (n: builtins.elem "worker" n.roles)
    (builtins.attrValues config.cluster.nodes)
);
```

Packages like OpenEBS could pull disk pool config directly from the node inventory instead of duplicating it:

```nix
# packages/openebs: derive diskPools from cluster.nodes
_kixOptions.diskPools = lib.mkOption {
  default = lib.concatMap (name: node:
    map (disk: {
      name = "${name}-pool";
      node = name;
      disks = [ disk.device ];
    }) (builtins.filter (d: d.role == "storage") node.disks)
  ) (lib.attrsToList scope.cluster.nodes);
};
```

## What This Intentionally Does NOT Cover

- **Provisioning.** This doesn't create nodes or cloud resources. It describes what exists. Provisioning is Terraform/Pulumi/NixOps territory.
- **Runtime state.** Node health, current pod placement, autoscaler decisions — these are runtime concerns, not config-time concerns.
- **Provider-specific APIs.** No `eks.vpcId` or `gke.projectId`. If a package needs those, they go into `cluster.global` or custom module options as they do today.

## Hand-Rolled Clusters: Composable Component Flavors

The distro-level presets (`flavors.k3s`, `flavors.eks`) cover managed and common setups. But the most interesting case is a hand-rolled cluster — e.g. bare metal Hetzner racks with kubeadm + Cilium + Longhorn + MetalLB. There's no single preset that matches. You're composing every layer yourself.

### The Problem with Distro Presets

A distro preset bundles assumptions that may not hold:

- `flavors.k3s` assumes flannel, but you replaced it with Cilium on day one.
- `flavors.kubeadm` says `loadBalancer = false`, but you installed MetalLB.
- There's no `flavors.talos-cilium-longhorn-metallb` and there shouldn't be.

You can override individual capabilities after importing a distro preset, but at that point the preset is more misleading than helpful — it suggests a "standard k3s" setup when you're running something quite different.

### Component-Level Flavors

Instead of (or in addition to) distro presets, we provide **component-level modules** — one per infrastructure choice. Each sets 1-3 capabilities. They compose via `mkDefault` so any explicit setting wins.

```nix
# lib/flavors/cni/cilium.nix
{ lib, ... }:
{
  cluster.capabilities.cni = lib.mkDefault "cilium";
  cluster.capabilities.networkPolicyAPI = lib.mkDefault "cilium";
}

# lib/flavors/cni/calico.nix
{ lib, ... }:
{
  cluster.capabilities.cni = lib.mkDefault "calico";
  cluster.capabilities.networkPolicyAPI = lib.mkDefault "calico";
}

# lib/flavors/cni/flannel.nix
{ lib, ... }:
{
  cluster.capabilities.cni = lib.mkDefault "flannel";
  cluster.capabilities.networkPolicyAPI = lib.mkDefault "k8s";
}

# lib/flavors/storage/longhorn.nix
{ lib, ... }:
{
  cluster.capabilities.storageProvisioner = lib.mkDefault "longhorn";
  cluster.capabilities.rwxStorage = lib.mkDefault true;
}

# lib/flavors/storage/openebs.nix
{ lib, ... }:
{
  cluster.capabilities.storageProvisioner = lib.mkDefault "openebs";
  cluster.capabilities.rwxStorage = lib.mkDefault true;  # mayastor
}

# lib/flavors/storage/local-path.nix
{ lib, ... }:
{
  cluster.capabilities.storageProvisioner = lib.mkDefault "local-path";
  cluster.capabilities.rwxStorage = lib.mkDefault false;
}

# lib/flavors/lb/metallb.nix
{ lib, ... }:
{
  cluster.capabilities.loadBalancer = lib.mkDefault true;
}

# lib/flavors/lb/kube-vip.nix
{ lib, ... }:
{
  cluster.capabilities.loadBalancer = lib.mkDefault true;
}

# lib/flavors/lb/none.nix
{ lib, ... }:
{
  cluster.capabilities.loadBalancer = lib.mkDefault false;
}

# lib/flavors/topology/single-node.nix
{ lib, ... }:
{
  cluster.capabilities.multiNode = lib.mkDefault false;
  cluster.capabilities.availabilityZones = lib.mkDefault [];
}

# lib/flavors/topology/bare-metal.nix — no cloud-provider assumptions
{ lib, ... }:
{
  cluster.capabilities.multiNode = lib.mkDefault true;
}
```

A distro preset is then just a convenience that imports the right component flavors:

```nix
# lib/flavors/k3s.nix — now a composition, not a monolith
{ lib, ... }:
{
  imports = [
    ./cni/flannel.nix
    ./storage/local-path.nix
    ./lb/servicelb.nix
  ];
  cluster.provider = lib.mkDefault "k3s";
  cluster.capabilities.ingressController = lib.mkDefault "traefik";
}
```

### The Hetzner Rack Example

Here's what a fully hand-rolled cluster looks like — kubeadm on Hetzner bare metal with Cilium, Longhorn, and MetalLB:

```nix
# clusters/htz1.nix
{ kix, packages }:

kix.buildCluster {
  name = "htz1";
  specialArgs = { inherit packages kix; };
  modules = [
    # Stack your infrastructure choices
    kix.flavors.cni.cilium
    kix.flavors.storage.longhorn
    kix.flavors.lb.metallb
    kix.flavors.topology.bare-metal

    # Cluster-specific facts
    {
      cluster.provider = "kubeadm";
      k8sVersion = "1.31";

      cluster.network = {
        podCidr = "10.244.0.0/16";
        serviceCidr = "10.96.0.0/16";
        dnsUpstream = [ "185.12.64.1" "185.12.64.2" ];
      };

      cluster.capabilities.availabilityZones = [ "fsn1-dc14" "fsn1-dc15" ];

      # You know exactly what you have — enumerate it
      cluster.nodes = {
        htz-cp1 = {
          roles = [ "control-plane" ];
          cpu = 8;
          memory = "32Gi";
          labels."topology.kubernetes.io/zone" = "fsn1-dc14";
        };
        htz-cp2 = {
          roles = [ "control-plane" ];
          cpu = 8;
          memory = "32Gi";
          labels."topology.kubernetes.io/zone" = "fsn1-dc15";
        };
        htz-cp3 = {
          roles = [ "control-plane" ];
          cpu = 8;
          memory = "32Gi";
          labels."topology.kubernetes.io/zone" = "fsn1-dc14";
        };
        htz-w1 = {
          roles = [ "worker" "storage" ];
          cpu = 32;
          memory = "128Gi";
          labels."topology.kubernetes.io/zone" = "fsn1-dc14";
          disks = [
            { device = "/dev/nvme0n1"; type = "nvme"; size = "1Ti"; role = "system"; }
            { device = "/dev/nvme1n1"; type = "nvme"; size = "2Ti"; role = "storage"; }
          ];
        };
        htz-w2 = {
          roles = [ "worker" "storage" ];
          cpu = 32;
          memory = "128Gi";
          labels."topology.kubernetes.io/zone" = "fsn1-dc15";
          disks = [
            { device = "/dev/nvme0n1"; type = "nvme"; size = "1Ti"; role = "system"; }
            { device = "/dev/nvme1n1"; type = "nvme"; size = "2Ti"; role = "storage"; }
          ];
        };
        htz-w3 = {
          roles = [ "worker" "storage" ];
          cpu = 32;
          memory = "128Gi";
          labels."topology.kubernetes.io/zone" = "fsn1-dc14";
          disks = [
            { device = "/dev/nvme0n1"; type = "nvme"; size = "1Ti"; role = "system"; }
            { device = "/dev/nvme1n1"; type = "nvme"; size = "2Ti"; role = "storage"; }
          ];
        };
      };
    }

    ./htz1/platform.nix
    ./htz1/services.nix
  ];
}
```

Every package in this cluster now knows: Cilium is the CNI, LoadBalancers work (MetalLB), RWX is available (Longhorn), there are 3 workers across 2 zones, and GPU is not available. No package checks for "kubeadm" — they check capabilities.

### What the Node Model Should and Shouldn't Capture

On bare metal you know _everything_ about the machine — RAID layout, NIC bonding, IPMI addresses, BIOS settings, kernel modules. The kix hardware profile should only capture the **Kubernetes-visible slice** of this:

**In scope** (affects K8s manifest generation):
- **Worker count** — replica count defaults, anti-affinity feasibility
- **Disk inventory** — storage operator pool config (Longhorn volumes, OpenEBS pools)
- **Node labels** — for topology spread, zone-aware scheduling
- **Node taints** — for toleration generation (GPU nodes, dedicated tenant nodes)
- **CPU/memory totals** — resource budget warnings ("total requests exceed cluster capacity")
- **Roles** — which nodes accept workloads, which are control-plane-only

**Out of scope** (provisioning-time concerns, belong in NixOS/Terraform):
- RAID configuration (mdadm, ZFS pool layout)
- Network interface bonding
- IPMI/BMC addresses
- Kernel module loading
- Firmware/BIOS settings
- OS-level package installation

The line is: if a kix package needs to reference it when generating K8s manifests, it belongs in the hardware profile. If it only matters when provisioning the machine itself, it belongs elsewhere.

### Swapping Components

The power of component flavors shows when you change infrastructure decisions. Migrating from Flannel to Cilium? Replace one module:

```nix
# Before
modules = [
  kix.flavors.cni.flannel
  kix.flavors.storage.longhorn
  # ...
];

# After
modules = [
  kix.flavors.cni.cilium
  kix.flavors.storage.longhorn
  # ...
];
```

Every package that checked `capabilities.networkPolicyAPI` now gets `"cilium"` instead of `"k8s"`. NetworkPolicy resources become CiliumNetworkPolicy resources. No package code changes. The cluster definition is the single source of truth for "what infrastructure am I running on."

### Defining Your Own Flavor

A "custom flavor" is just a module. If you're running something unusual — say Talos with Cilium, Rook-Ceph for storage, and a custom admission controller — you write a module:

```nix
# lib/flavors/talos-lithus.nix — our internal bare-metal standard
{ lib, ... }:
{
  imports = [
    ./cni/cilium.nix
    ./topology/bare-metal.nix
  ];

  cluster.provider = lib.mkDefault "talos";
  cluster.capabilities = {
    storageProvisioner = lib.mkDefault "rook-ceph";
    rwxStorage = lib.mkDefault true;
    loadBalancer = lib.mkDefault true;  # we run kube-vip
  };
}
```

This is "defining your own flavor." There's no special registration, no enum to extend — it's a NixOS module like any other, and it composes with everything else.

### Component Flavors Can Contribute More Than Capabilities

A component flavor module could also set up related instances via `availablePackages` or `instances`, making it a self-contained "this is what Cilium means for this cluster":

```nix
# lib/flavors/cni/cilium.nix — extended version
{ lib, config, packages, ... }:
{
  cluster.capabilities.cni = lib.mkDefault "cilium";
  cluster.capabilities.networkPolicyAPI = lib.mkDefault "cilium";

  # Auto-enable Cilium network policy generation when Cilium is the CNI
  networkPolicy.enable = lib.mkDefault true;
}
```

This is a heavier pattern — it couples the flavor to the package system. Whether this is desirable is an open question. The minimal version (capabilities only) is safer; the extended version (capabilities + wiring) is more convenient but creates implicit behavior.

## Comparison: Existing Platform Files vs Hardware Profile

Today, `clusters/nw1/platform.nix` mixes three concerns:

1. **Hardware facts**: podCidr, serviceCidr, DNS resolvers, worker disk paths
2. **Infrastructure packages**: CoreDNS, cert-manager, nginx, OpenEBS instances
3. **Cluster options**: domain, ingress class names, TLS issuer

With the hardware profile, this separates cleanly:

| Concern | Where it goes |
|---|---|
| CIDRs, DNS resolvers, node inventory | `cluster.network`, `cluster.nodes` (hardware profile) |
| CNI, storage, LB capabilities | Component flavor modules |
| Ingress class names, TLS issuer, domain | Cluster module options (as today) |
| Package instances (CoreDNS, nginx, etc.) | Platform module (as today, but simpler) |

The platform module shrinks because it no longer needs ad-hoc options for things the hardware profile covers, and packages can derive better defaults from capabilities instead of requiring explicit config.

## Open Questions

1. **How detailed should `cluster.nodes.*.disks` be?** Currently OpenEBS config duplicates device paths from the node inventory. Making the node model rich enough to derive storage config automatically is appealing but could overfit to one storage solution's config shape.

2. **Should `cluster.capabilities` be flat or grouped?** Flat (`capabilities.loadBalancer`) is simpler. Grouped (`capabilities.network.loadBalancer`, `capabilities.storage.rwx`) scales better. The current proposal is flat — we can restructure when the list grows.

3. **Node pools vs static nodes — is one enough?** The proposal has both `cluster.nodes` and `cluster.nodePools`. In practice most clusters are one or the other. Maybe a single `cluster.topology` that can express both? Or keep them separate and just validate they don't conflict.

4. **How should custom capabilities work?** A user running a niche storage driver or a custom admission controller might want `capabilities.myCustomThing = true` that their internal packages can query. Do we allow arbitrary keys in capabilities, or require a module option declaration? (The component-flavor-as-module approach answers this naturally: declare a new option in your flavor module.)

5. **Should component flavors contribute instances/wiring or only capabilities?** The minimal version (capabilities only) keeps flavors simple and predictable. The extended version (capabilities + auto-instantiation + config) is more convenient but creates implicit behavior. Both patterns work with the module system — it's a question of how much magic is appropriate.

6. **Flavor directory structure.** Proposed: `lib/flavors/{cni,storage,lb,topology}/`. Should distro presets live at `lib/flavors/` (top-level) or `lib/flavors/distro/`? Does the grouping hold up as more components are added (ingress, service mesh, admission controllers)?

7. **Resource budget validation.** With CPU/memory declared per node, we could compute total cluster capacity and warn if total resource requests exceed it. How precise should this be? Rough "you're requesting 200Gi of memory but your workers have 128Gi total" vs detailed bin-packing simulation?
