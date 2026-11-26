# 48 — System Contracts: Compile-Time Verification of Cluster Prerequisites

**Status:** Partially implemented (capability checks in scope), DI system deps not yet built
**Related:** `45_cluster_hardware_profile.md` (capabilities/flavors), `29_compiler-design.md` (compiler passes), `37_di_derived_network_policies.md`

## Final Design Decision

Two mechanisms. The split is: **DI for services** (things packages connect to), **capability checks for runtime constraints** (things the cluster physically can or can't do). The key principle: if a package needs to _reference_ something (a StorageClass name, an ingress class, a DNS resolver), that's DI. If the cluster physically can or can't do something regardless of software (allocate external IPs, schedule DaemonSets, run privileged pods), that's a capability check.

### DI handles system services

Services that packages connect to or consume are resolved via the existing DI system. Flavors MUST provide imports for platform-managed services so DI resolution succeeds.

| System service | DI alias | How packages use it | How flavors provide it |
|---|---|---|---|
| **DNS** | `dns` | Auto-injected dep when package produces FQDN references. Store-path edge creates correct deploy ordering. | Flavors provide `mkImport` with alias `"dns"`. On bare metal with kix-managed CoreDNS, the coredns package has `meta.defaultAliases = ["dns"]`. |
| **Storage** | `storageClasses` | PVC packages take `storageClasses` as a DI dep (already works). Use `storageClasses.out.storageClassName`. | Flavors provide import with `out.storageClassName` (e.g. `"standard"` on kind, `"local-path"` on k3s). |
| **Ingress controller** | `ingressController` | Packages that create Ingress resources take `ingressController` as a DI dep. Use `ingressController.out.ingressClassName`. No need to know nginx vs traefik. | Flavors with a built-in controller provide the import. Clusters without one must either add a controller package or have no Ingress resources. |
| **CRD operators** | per-CRD | `mkCRDRef` / `mkCRD` already create DI edges. | Existing mechanism. |

**Key rule:** flavors MUST place a `dns` import into the DI graph. If nothing provides `dns` (no flavor, no package), DI resolution fails at build time — unresolved dependency error. This is not a special system; it's the normal DI error path.

**Auto-injection of `dns` deps:** Post-evaluation pass (similar to how netpol works). The evaluator inspects what resources a package produced. If any resource contains an FQDN (`.svc.cluster.local`), the evaluator auto-adds a store-path edge to the `dns` provider. Hash changes from this are correct — they reflect real deployment ordering (DNS must be up before apps that resolve FQDNs).

### Capability checks handle runtime constraints

Runtime constraints that no software can change are checked at resource construction time in `scope.nix`. These are `throw` errors — the resource will definitely not work on this cluster.

| Capability | Checked where | Trigger | Error example |
|---|---|---|---|
| **`loadBalancer`** | `scopeMkResource` | `kind: Service` + `spec.type: LoadBalancer` | "Service 'caddy' uses type=LoadBalancer but cluster has no LB controller" |
| **`daemonSets`** | `mkWorkload` | `kind: DaemonSet` | "DaemonSet cannot be deployed — GKE Autopilot does not support DaemonSets" |
| **`privilegedContainers`** | `mkWorkload` | `hostNetwork`, `hostPID`, or `securityContext.privileged` | "Workload uses hostNetwork but cluster restricts privileged workloads" |

**Implemented:** All three checks are live in `lib/eval/scope.nix`. They read `capabilities` passed from `clusterConfig.cluster.capabilities` via `instance.nix → mkScope`. Checks gracefully skip when `capabilities == {}` (tests, standalone scope usage).

**Security team override:** `privilegedContainers` can be set to `false` at high module priority by a security team module. Package authors who need privileged access would need `mkForce` to override, which is auditable.

### What is NOT a capability check

- **`persistentStorage = false`** (kind) — this is a **warning**, not an error. DI resolves, PVCs get created, but data is ephemeral. The flavor flag exists for tooling/warnings, not to block builds. A PVC on kind "works" — it just doesn't survive cluster recreation.
- **Ingress controller missing** — this is a DI resolution failure, not a capability check. The package takes `ingressController` as a dep; if nothing provides it, DI fails.
- **StorageClass missing** — same, DI resolution failure via `storageClasses` dep.
- **DNS missing** — same, DI resolution failure via `dns` dep.

### Post-eval verification for Helm chart imports

Helm chart imports (`fromHelmChart`) produce opaque resource sets that kix didn't construct via the DSL. These bypass DI wiring — a Helm chart might create PVCs or Ingresses that reference StorageClasses or IngressClasses by string, not via DI.

A post-evaluation scan in `buildCluster` catches resources from Helm imports that imply missing prerequisites:
- PVCs exist but no `storageClasses` provider in the cluster
- Ingress resources exist but no `ingressController` provider
- LoadBalancer Services on a cluster with `loadBalancer = false`

This is a safety net for the DI bypass that Helm imports inherently create.

### Implementation status

| Component | Status |
|---|---|
| Capability checks in scope (LB, DaemonSet, privileged) | **Done** — `lib/eval/scope.nix` |
| Capabilities passed to scope from clusterConfig | **Done** — `lib/eval/instance.nix` |
| Flavor-provided DNS import | Not yet built |
| Flavor-provided storageClasses import | Not yet built (ludo/platform.nix does this manually) |
| Auto-injected DNS dep on FQDN references | Not yet built |
| Post-eval verification for Helm imports | Not yet built |
| Deploy target verification (`allowedContexts`) | Roadmap item |

---

## Problem

Every Kubernetes workload silently assumes certain system services exist:

- **DNS** — `service.ns.svc.cluster.local` resolves. Without CoreDNS/kube-dns, every cross-service reference is dead.
- **Pod networking** — CNI is installed and pods can reach each other. Without it, nothing works.
- **Service routing** — kube-proxy or equivalent (Cilium eBPF) translates ClusterIP VIPs to pod endpoints.
- **Storage provisioner** — if a PVC exists, something must fulfill it.
- **Ingress controller** — if an Ingress resource exists, something must route external traffic.
- **Network policy enforcement** — if NetworkPolicy resources exist, something must enforce them.
- **CRD operators** — if a CR exists, something must reconcile it.

Today, kix generates manifests that reference these assumptions but never verifies them. The build succeeds, `kix deploy` applies the YAML, and things break at runtime when DNS doesn't resolve or PVCs hang in `Pending`.

We are a compiler. If CoreDNS doesn't exist, we should error at build time. But this shouldn't be CoreDNS-specific — it should be a general mechanism.

## Design Space

There are several ways to approach this. They're not mutually exclusive — the right answer is probably a combination.

### Approach 1: Explicit System Contracts

The cluster declares which system services are satisfied. The compiler checks that everything needed is present.

```nix
# In lib/modules.nix — new option
cluster.systemServices = {
  dns = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Whether cluster DNS is available (CoreDNS, kube-dns, or managed).";
  };
  podNetworking = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Whether a CNI is installed and pod-to-pod networking works.";
  };
  serviceRouting = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Whether kube-proxy or equivalent provides Service ClusterIP routing.";
  };
};
```

Flavors set these:

```nix
# lib/flavors/gke.nix
cluster.systemServices = {
  dns = lib.mkDefault true;           # managed by GKE
  podNetworking = lib.mkDefault true;  # gke-native CNI
  serviceRouting = lib.mkDefault true; # kube-proxy or eBPF
};

# lib/flavors/kubeadm.nix
cluster.systemServices = {
  dns = lib.mkDefault true;            # kubeadm installs CoreDNS
  podNetworking = lib.mkDefault false;  # you must install a CNI
  serviceRouting = lib.mkDefault true;  # kube-proxy installed by default
};
```

kix packages that provide a system service mark it:

```nix
# packages/coredns
meta.provides = [ "dns" ];

# packages/cilium
meta.provides = [ "podNetworking" "serviceRouting" ];
```

`buildCluster` verifies: for each required system service, either `cluster.systemServices.X = true` (flavor/managed) or some package in the cluster has `meta.provides = [ "X" ]`.

**Pros:** Explicit, predictable, easy to understand error messages. Works for managed clusters where kix doesn't deploy the system service.

**Cons:** Manual declaration. You have to know which system services exist and enumerate them. Doesn't catch the case where a PVC exists but no storage provisioner does — unless you also track "storageProvisioner" as a system service, which gets into an ever-growing list.

**Error example:**
```
error: cluster 'ludo' is missing required system service 'dns'
  No package with meta.provides = ["dns"] found in the cluster,
  and cluster.systemServices.dns is not set.

  CoreDNS is required for cross-service DNS resolution.
  Either add a CoreDNS package or set cluster.systemServices.dns = true
  if DNS is managed externally.
```

### Approach 2: Resource-Implied Dependencies

Instead of declaring system services upfront, let the compiler infer what's needed from the resources that are generated. If you create certain kinds of resources, the compiler knows what system service they require.

The rules:

| If you create... | You need... |
|---|---|
| Any resource with a cross-service FQDN string | DNS |
| A PersistentVolumeClaim | A storage provisioner |
| An Ingress | An ingress controller |
| A NetworkPolicy / CiliumNetworkPolicy | Network policy enforcement |
| A Service of type LoadBalancer | A LoadBalancer controller |
| A Certificate CR (cert-manager) | cert-manager operator |
| Any custom CR | The operator for that CRD |

The compiler already has all this information. It knows every resource kind, every FQDN reference (via string context), every CRD/CR relationship. The check is a post-evaluation pass over the full cluster resource set.

**Implementation sketch:**

```nix
# In buildCluster, after all resources are collected:
systemRequirements = deriveSystemRequirements allResources;
# Returns: { dns = true; storageProvisioner = true; ingressController = true; ... }

# Check against what's satisfied:
satisfied = {
  dns = cluster.systemServices.dns
    || builtins.any (i: builtins.elem "dns" (i._meta.packageMeta.provides or [])) allInstancesList;
  storageProvisioner = cluster.systemServices.storageProvisioner
    || builtins.any (i: builtins.elem "storageProvisioner" ...) allInstancesList;
  # ...
};

# Error on unsatisfied requirements
unsatisfied = filterAttrs (_: v: !v) (intersectAttrs systemRequirements satisfied);
```

**Pros:** No manual annotation needed — the compiler figures it out from the resources. Creates errors only when something is actually needed.

**Cons:** The inference rules are hard-coded in the compiler. Adding a new CRD operator requirement means updating the compiler, not just adding a package. Also, some requirements are hard to infer (DNS — does the cluster need it if no FQDN is used? Yes, because `kubernetes.default.svc` is used internally).

### Approach 3: Auto-Require DNS on Cross-Service References

This is the most granular version. Instead of a cluster-level check, `mkResource` itself detects when a resource references another service and auto-adds a dependency on the DNS system service.

In kix, when you write `postgres.out.fqdn` in an env var, the store-path context tracks the dependency on the postgres package. But the actual runtime resolution of that FQDN requires DNS. The compiler can detect this.

**Where the detection happens:**

`mkResource` already processes string context to track dependencies. If a string contains a `.svc.cluster.local` pattern (or any FQDN constructed by kix), the resource implicitly requires DNS. Similarly:

- If `spec.storageClassName` is set or a PVC kind is created → requires storage provisioner
- If `kind: Ingress` → requires ingress controller
- If `spec.type: LoadBalancer` on a Service → requires LB controller

```nix
# In mkResource or in the post-processing pass:
impliedDeps =
  (if hasFqdnReference manifest then [ "dns" ] else [])
  ++ (if kind == "PersistentVolumeClaim" then [ "storageProvisioner" ] else [])
  ++ (if kind == "Ingress" then [ "ingressController" ] else [])
  ++ (if kind == "Service" && spec.type == "LoadBalancer" then [ "loadBalancer" ] else [])
  ++ (if kind == "NetworkPolicy" then [ "networkPolicyEnforcement" ] else []);
```

**Pros:** Precise — only triggers when actually needed. No false positives. Naturally extends as new patterns are added.

**Cons:** Requires deep inspection of resource content. FQDN detection is heuristic (what if someone constructs a DNS name without using `.out.fqdn`?). Also, this tracks per-resource requirements but the satisfaction check is still cluster-level.

### Approach 4: DI Aliases as System Contracts

Use the existing DI system. System services are just DI aliases. If a package needs DNS, it takes `dns` as a DI dep. If nothing provides it, the existing DI resolution fails.

But that would mean every package that uses an FQDN needs `dns ? null` in its function signature. That's noisy and manual. Unless...

**Auto-injection:** The compiler injects certain DI deps automatically based on resource content. If a package creates resources with FQDN references, the evaluator auto-adds `dns` to its dep list. If DNS isn't available, DI resolution fails with a clear error.

```nix
# Automatically injected — package author doesn't write this
# The evaluator detects FQDN usage and adds the dep

# Flavor provides:
instances.kube-system.coredns = {
  package = packages.coredns;
  aliases = [ "dns" ];
};

# Or for managed clusters:
instances.kube-system.dns = {
  package = kix.mkImport {
    out.provider = "managed";
  };
  aliases = [ "dns" ];
};
```

**Pros:** Reuses existing DI machinery entirely. No new concept needed. Error messages come from the existing DI resolution system. Flavors provide imports, packages provide instances — same pattern everywhere.

**Cons:** Conflates "system-level assumption" with "package dependency." DNS isn't a dependency the way postgres is — you don't consume its `out`. The DI resolution error message would need to distinguish "you need to install DNS" from "you need to add a postgres instance."

### Approach 5: Capability Requirements on Resources (Declarative)

Resources declare what cluster capabilities they require. The compiler checks these against `cluster.capabilities` (from the flavor).

```nix
# mkResource gains a `requires` capability field (separate from store-path requires):
scope.mkResource {
  name = "my-ingress";
  kind = "Ingress";
  # ...
  _requiresCapabilities = [ "ingressController" ];  # auto-set by kind
};

scope.mkResource {
  name = "my-pvc";
  kind = "PersistentVolumeClaim";
  # ...
  _requiresCapabilities = [ "persistentStorage" ];
};
```

The compiler auto-sets these based on resource kind, and the cluster-level pass validates:

```
error: cluster 'ludo' targets 'kind' but contains resources requiring
  capabilities that are not available:

  - 'persistentStorage' required by PersistentVolumeClaim/storage (immich namespace)
    kind clusters use ephemeral storage — PVC data will not survive restarts.
    Set cluster.capabilities.persistentStorage = true to override.

  - 'ingressController' required by Ingress/immich-ingress (immich namespace)
    kind clusters have no built-in ingress controller.
    Install an ingress controller or remove the Ingress resource.
```

**Pros:** Connects directly to the capability system we just built. Error messages reference the flavor and explain what's wrong. Auto-derivable for known kinds.

**Cons:** Only works for capabilities, not for "is CoreDNS running?" which is a service, not a capability. Capabilities are booleans — they say "the cluster can do X" but not "something is deployed that does X."

## Proposed Design: Layered System

Combine approaches. Three layers, each catching different things:

### Layer 1: Resource-Implied Capability Checks (Approach 5)

The compiler auto-derives capability requirements from resource kinds and checks them against `cluster.capabilities`. This is a post-evaluation pass in `buildCluster`.

```nix
# Built-in rules — extend over time
resourceCapabilityRules = {
  PersistentVolumeClaim = [ "persistentStorage" ];
  Ingress = [ "ingressController" ];
  NetworkPolicy = { check = cfg: cfg.networkPolicyAPI != "none"; name = "networkPolicyEnforcement"; };
  CiliumNetworkPolicy = { check = cfg: cfg.networkPolicyAPI == "cilium"; name = "ciliumNetworkPolicy"; };
};

# For Services, inspect spec.type:
serviceRules = svc:
  if svc.spec.type or "ClusterIP" == "LoadBalancer"
  then [ "loadBalancer" ]
  else [];
```

This catches: PVCs on kind (no persistent storage), Ingress without a controller, LoadBalancer on bare metal, NetworkPolicy without enforcement.

This does NOT catch: "is DNS running?" — that's not a capability, it's a service.

### Layer 2: System Service Contracts (Approach 1 + 4 hybrid)

A small set of **universal system services** that every cluster needs. These are not optional — they're always required. The question is only how they're satisfied.

```nix
# New module option
cluster.systemServices = {
  dns = lib.mkOption {
    type = lib.types.enum [ "managed" "kix" "external" ];
    default = "managed"; # safe default — most clusters have DNS
    description = ''
      How cluster DNS is provided.
      "managed" = platform provides it (GKE, EKS, k3s built-in).
      "kix" = a kix package provides it (e.g. packages.coredns).
      "external" = managed outside kix and the platform (rare).
    '';
  };
  podNetworking = lib.mkOption {
    type = lib.types.enum [ "managed" "kix" "external" ];
    default = "managed";
    description = "How pod-to-pod networking (CNI) is provided.";
  };
  serviceRouting = lib.mkOption {
    type = lib.types.enum [ "managed" "kix" "external" ];
    default = "managed";
    description = "How Service ClusterIP routing (kube-proxy or eBPF) is provided.";
  };
};
```

Flavors set these:

```nix
# GKE — everything managed
cluster.systemServices = {
  dns = lib.mkDefault "managed";
  podNetworking = lib.mkDefault "managed";
  serviceRouting = lib.mkDefault "managed";
};

# kubeadm — DNS and routing are installed by kubeadm, CNI is not
cluster.systemServices = {
  dns = lib.mkDefault "managed";         # kubeadm installs CoreDNS
  podNetworking = lib.mkDefault "external"; # you must install a CNI
  serviceRouting = lib.mkDefault "managed"; # kube-proxy
};
```

When `systemServices.X = "kix"`, `buildCluster` verifies that some package provides that service (via `meta.provides`). When `"managed"` or `"external"`, no check needed — it's assumed to exist.

```nix
# packages/coredns
meta.provides = [ "dns" ];

# packages/cilium
meta.provides = [ "podNetworking" "serviceRouting" ];
```

**Error when "kix" but no provider:**
```
error: cluster 'htz1' declares systemServices.podNetworking = "kix"
  but no package with meta.provides containing "podNetworking" was found.

  Install a CNI package (e.g. cilium, calico) or set
  systemServices.podNetworking = "managed" if the CNI is pre-installed.
```

**Error when nothing set and kubeadm flavor:**
The kubeadm flavor sets `podNetworking = "external"` which means "not my problem." If a user hasn't installed a CNI, the build succeeds but deploy fails. To get the build-time check, they'd set `podNetworking = "kix"` and the compiler catches the missing package.

### Layer 3: CRD-Implied Operator Contracts (Auto-Derived)

This already partially exists. When a package creates a CR, it depends on the CRD via `requires`. If the CRD doesn't exist, the build fails (DI resolution for the CRD provider). But the **operator** that reconciles the CR is a separate concern.

Two sub-cases:

**CRD created by kix:** The CRD resource is in the cluster build. The operator package is (or should be) a dependency. Existing DI handles this.

**CRD exists externally:** `mkCRDRef` creates a reference to a CRD that kix doesn't manage. The CR depends on the ref, but nothing guarantees the operator is running. This is similar to the DNS problem — the CRD exists, but will anything act on the CR?

For external CRDs, the system service contract model applies: the cluster declares "cert-manager is managed externally" or "cert-manager is a kix package." The compiler verifies accordingly.

```nix
# Future: packages can declare operator requirements
meta.requiresOperator = "cert-manager";
# or tied to specific CRDRefs used in the package
```

This is lower priority than DNS/CNI but follows the same pattern.

## Where Each Layer Runs

```
Nix eval time (buildCluster):

  1. Module evaluation → merged config with capabilities + systemServices
  2. Auto-instantiation → packages resolved
  3. Instance evaluation → resources generated
  4. POST-EVALUATION PASS:
     a. Collect all resource kinds across the cluster
     b. Layer 1: check resource-implied capabilities
        - PVC exists + !persistentStorage → error
        - Ingress exists + !ingressController → error
        - LoadBalancer Service + !loadBalancer → error
        - NetworkPolicy + networkPolicyAPI == "none" → warning
     c. Layer 2: check system service contracts
        - systemServices.dns == "kix" + no provider → error
        - systemServices.podNetworking == "kix" + no provider → error
     d. Layer 3: CRD operator contracts (future)
```

## DNS Specifically

DNS is special because it's so fundamental. Should we auto-require it on every cross-service reference?

**Option A: Always required, never checked.**
DNS is assumed to exist on every cluster. The `cluster.systemServices.dns` default is `"managed"`. Only if someone explicitly sets it to `"kix"` does the compiler check for a DNS package. This is pragmatic — DNS is the one thing that truly every cluster has.

**Option B: Auto-detect FQDN usage, require DNS.**
If any resource in the cluster contains an FQDN (`.svc.cluster.local`), the compiler requires DNS. Since virtually every cluster has cross-service references, this is effectively "always." The value is in the error message: "your cluster references service FQDNs but DNS is not configured."

**Option C: DNS is a system contract, flavors always set it.**
Every flavor sets `systemServices.dns = "managed"`. If you create a cluster with no flavor and no DNS package, the compiler errors. This catches the "I'm building a cluster from scratch and forgot DNS" case.

**Recommendation:** Option C. DNS is a system contract. Flavors always satisfy it. The kubeadm flavor says `dns = "managed"` because kubeadm installs CoreDNS. If someone uses `cluster.provider = "custom"` and doesn't set any system services, they get errors for everything they haven't explicitly declared. This is the safest default.

## Error Message Design

The error messages should be actionable and reference the flavor:

```
error: cluster 'ludo' (flavor: kind) contains 3 PersistentVolumeClaims
  but cluster.capabilities.persistentStorage = false

  kind clusters use ephemeral storage backed by the Docker container
  filesystem. PVC data will NOT survive 'kind delete cluster'.

  Resources:
    - PersistentVolumeClaim/storage @ immich
    - PersistentVolumeClaim/storage @ nas
    - PersistentVolumeClaim/storage @ vaultwarden

  Options:
    1. Set cluster.capabilities.persistentStorage = true to acknowledge
       and suppress this error (data loss risk on cluster recreation)
    2. Remove the PVC-dependent packages from this cluster definition
```

```
error: cluster 'htz1' contains 2 Ingress resources but
  cluster.capabilities.ingressController = null

  No ingress controller is configured. Ingress resources will be
  accepted by the API server but no traffic will be routed.

  Resources:
    - Ingress/immich-ingress @ immich
    - Ingress/grafana-ingress @ monitoring-system

  Options:
    1. Add an ingress controller package (e.g. ingress-nginx)
    2. Set cluster.capabilities.ingressController = "nginx" if one
       is installed outside of kix
```

## What Capability Requirements Look Like Per Resource Kind

Exhaustive list of auto-derivable rules:

| Resource Kind | Capability Required | Condition |
|---|---|---|
| `PersistentVolumeClaim` | `persistentStorage` | Always |
| `Ingress` | `ingressController != null` | Always |
| `Service` | `loadBalancer` | `spec.type == "LoadBalancer"` |
| `NetworkPolicy` | `networkPolicyAPI != "none"` | Always (warning, not error — accepted but unenforced) |
| `CiliumNetworkPolicy` | `networkPolicyAPI == "cilium"` | Always |
| `CalicoNetworkPolicy` | `networkPolicyAPI == "calico"` | Always |
| `DaemonSet` | `daemonSets` | Always |
| `Pod` with `hostNetwork: true` | `privilegedContainers` | When `hostNetwork` set |
| `Pod` with `securityContext.privileged: true` | `privilegedContainers` | When privileged |
| Any workload | `podSecurityEnforcement` compatible | Check against PSA level |

## Open Questions

1. **Should Layer 1 (capability checks) produce errors or warnings?** PVC on kind is arguably "works but data is ephemeral" — is that an error or a warning? NetworkPolicy without enforcement is clearly a warning (accepted, just ignored). The distinction might be: errors for "will definitely fail at runtime" vs warnings for "will work but not as expected."

2. **Should system service contracts be tri-state ("managed"/"kix"/"external") or just booleans?** The tri-state gives better error messages but is more complex. A boolean `true`/`false` is simpler: true = satisfied somehow, false = not satisfied. The compiler only errors if false and the service is needed.

3. **How do we handle the "CoreDNS is both a system service and a regular package" duality?** If someone deploys CoreDNS via kix on k3s (replacing the built-in), should the flavor's `dns = "managed"` be overridden to `"kix"`? Or does it not matter because either way DNS is satisfied?

4. **Should the capability checks be opt-out per resource?** A package might legitimately create a PVC on an ephemeral cluster for caching that doesn't need persistence. An annotation or meta flag to suppress the warning?

5. **How does this interact with `managedControlPlane`?** On GKE, deploying CoreDNS would conflict with the managed DNS. Should `managedControlPlane = true` generate an error if a kix package has `meta.provides = ["dns"]`? This would prevent accidentally deploying system components that conflict with managed ones.

6. **What about "soft" system services?** Not every cluster needs an ingress controller — only clusters with Ingress resources. DNS is arguably needed everywhere. Storage provisioner only if PVCs exist. The resource-implied approach (Layer 1) handles this naturally, but the system contract approach (Layer 2) is always-on. Should system contracts also be demand-driven?
