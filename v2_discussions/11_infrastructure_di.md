# Infrastructure Dependency Injection: Storage, Monitoring, and Beyond

## Working Document — March 2026

**Status:** Design exploration
**Predecessors:** doc 02 (DI resolution, `? default` pattern), doc 05 (type providers, CRD handling)

---

## 1. The Problem

The DI system (doc 02) handles service-to-service dependencies: an API server
depends on postgres, which depends on a session store. Resolution is DNS-like,
the `? default` fallback pattern handles optional/role-based deps.

But services also depend on **infrastructure**: storage, monitoring, ingress,
certificate management, secret injection. These are provided by cluster-level
components (operators, controllers, configuration resources) that multiple
services share.

Today, infrastructure references are typically hardcoded strings:

```nix
# Hardcoded storage class name — invisible to the dependency graph
spec.storageClassName = "ceph-fast";

# Hardcoded ingress class — invisible
spec.ingressClassName = "nginx";

# Hardcoded issuer reference — invisible
annotations."cert-manager.io/cluster-issuer" = "letsencrypt-prod";
```

These strings create invisible dependencies. Deploying a PVC without the
StorageClass existing gives a pending PVC. The dependency graph can't help
because it doesn't know the relationship exists.

**The idea**: treat infrastructure providers as packages, use the same DI
system for infrastructure that we use for services, and get automatic
dependency tracking, tiered fallback, and dev/prod swappability.

---

## 2. The Core Pattern: Infrastructure Providers Are Packages

An infrastructure provider is a package that exposes a configuration resource
(StorageClass, IngressClass, ClusterIssuer) as its `main`. Consumer packages
depend on it by capability name via the DI system.

```
┌─────────────────────────────────────────────────────────────┐
│  Operator Package          Configuration Package            │
│  (cert-manager,            (letsencrypt-issuer,             │
│   ceph-csi)                 ceph-fast-storage)              │
│                                                             │
│  Deploys:                  Deploys:                         │
│  - Controller              - StorageClass / ClusterIssuer   │
│  - CRDs                   Depends on: operator              │
│  - RBAC                   Exposes: config resource as main  │
│                                                             │
│                    Consumer Package                         │
│                    (postgres, my-app)                       │
│                                                             │
│                    Depends on: configuration by             │
│                    capability name (storage, certIssuer)    │
│                    Creates: PVC, Certificate, etc.          │
│                    referencing config resource via ${}      │
└─────────────────────────────────────────────────────────────┘
```

The DI resolution, fallback defaults, and closure computation handle
everything without new machinery.

---

## 3. Storage: The Primary Example

### 3.1 K8s Storage Dependency Chain

```
Pod ──vol.claimName──→ PVC ──storageClassName──→ StorageClass ──provisioner──→ CSI Driver
        (string)             (string)                  (string, runtime match)
```

Three string-based references. In kix:
- PVC → StorageClass: **trackable** via `${}` — `spec.storageClassName = "${storageProvider.main}"`
- StorageClass → CSI Driver: **NOT trackable** — `provisioner` is a string K8s matches at runtime
- Pod → PVC: **trackable** via `${}` — `claimName = "${self.dataPvc}"`

So the PVC→StorageClass link works like any resource reference. The
StorageClass→CSI driver link needs `requires`, same as CRDs need `requires`
for the controller.

### 3.2 A Storage Provider Package

```nix
# packages/ceph-storage/default.nix
#
# A StorageClass backed by Ceph RBD. Depends on the Ceph CSI driver
# being deployed (via DI). Parameterized by pool/tier config.

{ scope, config, lib, cephCsi }:

let
  cfg = scope.defaults config {
    pool = "replicapool";
    fsType = "ext4";
    reclaimPolicy = "Delete";
    volumeBindingMode = "Immediate";
  };
in self: {

  storageClass = scope.mkClusterResource {
    apiVersion = "storage.k8s.io/v1";
    kind = "StorageClass";
    name = scope.instanceName;
    # CSI driver must be deployed, but provisioner is a plain string
    # (K8s matches it to the CSI driver at runtime). This is the same
    # kind of invisible dependency that CRDs have — requires handles it.
    requires = [ cephCsi.main ];
    extra = {
      provisioner = "rbd.csi.ceph.com";
      reclaimPolicy = cfg.reclaimPolicy;
      volumeBindingMode = cfg.volumeBindingMode;
      parameters = {
        clusterID = cfg.clusterID or "";
        pool = cfg.pool;
        "csi.storage.k8s.io/fstype" = cfg.fsType;
        "csi.storage.k8s.io/provisioner-secret-name" = cfg.secretName or "csi-rbd-secret";
        "csi.storage.k8s.io/provisioner-secret-namespace" = cfg.secretNamespace or "ceph-system";
      };
    };
  };

  main = self.storageClass;
}
```

The CSI driver itself is a separate package — it deploys DaemonSets, RBAC, and
possibly CRDs. It's deployed once regardless of how many StorageClasses exist:

```nix
# packages/ceph-csi/default.nix
{ scope, config, lib }:
self: {
  nodePlugin = scope.mkResource {
    kind = "DaemonSet";
    name = "${scope.instanceName}-nodeplugin";
    # ...
  };

  controller = scope.mkResource {
    kind = "Deployment";
    name = "${scope.instanceName}-controller";
    spec.template.spec.serviceAccountName = "${self.serviceAccount}";
    # ...
  };

  serviceAccount = scope.mkResource { ... };
  clusterRole = scope.mkClusterResource { ... };
  clusterRoleBinding = scope.mkClusterResource { ... };

  service = scope.mkResource {
    kind = "Service";
    name = "${scope.instanceName}";
    requires = [ self.nodePlugin self.controller ];
    spec.ports = [{ port = 12345; }];
  };

  main = self.service;
}
```

### 3.3 Consuming Storage

A package that needs storage declares it as a dependency:

```nix
# packages/postgres/default.nix
{ scope, config, lib, storage, fastStorage ? storage }:

let
  cfg = scope.defaults config {
    dataSize = "50Gi";
    walSize = "10Gi";
  };
in self: {

  dataPvc = scope.mkResource {
    apiVersion = "v1";
    kind = "PersistentVolumeClaim";
    name = "${scope.instanceName}-data";
    spec = {
      # This ${} interpolation does two things:
      # 1. Embeds the StorageClass store path → Nix tracks the dependency
      # 2. Post-processing replaces it with the StorageClass name
      storageClassName = "${fastStorage.main}";
      accessModes = [ "ReadWriteOnce" ];
      resources.requests.storage = cfg.dataSize;
    };
  };

  walPvc = scope.mkResource {
    apiVersion = "v1";
    kind = "PersistentVolumeClaim";
    name = "${scope.instanceName}-wal";
    spec = {
      storageClassName = "${storage.main}";
      accessModes = [ "ReadWriteOnce" ];
      resources.requests.storage = cfg.walSize;
    };
  };

  statefulset = scope.mkResource {
    kind = "StatefulSet";
    name = "${scope.instanceName}";
    spec.template.spec = {
      containers = [{
        name = "postgres";
        image = cfg.image;
        volumeMounts = [
          { name = "data"; mountPath = "/var/lib/postgresql/data"; }
          { name = "wal"; mountPath = "/var/lib/postgresql/wal"; }
        ];
      }];
      volumes = [
        { name = "data"; persistentVolumeClaim.claimName = "${self.dataPvc}"; }
        { name = "wal"; persistentVolumeClaim.claimName = "${self.walPvc}"; }
      ];
    };
  };

  service = scope.mkResource {
    kind = "Service";
    name = "${scope.instanceName}";
    outputs = { port = "5432"; };
    requires = [ self.statefulset ];
    spec.ports = [{ port = 5432; }];
  };

  main = self.service;
}
```

### 3.4 The Dependency Graph

```
postgres Service
    │
  requires
    │
StatefulSet
    ├── ${dataPvc} ──→ PVC (data)
    │                    └── ${fastStorage.main} ──→ StorageClass (fast-ssd)
    │                                                  └── requires → ceph-csi Service
    │                                                                    ├── requires → DaemonSet
    │                                                                    └── requires → Controller
    └── ${walPvc} ──→ PVC (wal)
                       └── ${storage.main} ──→ StorageClass (standard)
                                                 └── requires → ceph-csi Service (same instance, deduped)
```

Deploying postgres pulls in both StorageClasses AND the Ceph CSI driver.
Everything is in the closure. Deploy ordering is correct: CSI driver first,
then StorageClasses, then PVCs, then the StatefulSet.

### 3.5 Cluster Configuration

**Production: separate tiers**

```nix
instances = { ref, ... }: {
  ceph-system = {
    ceph-csi = {
      package = packages.cephCsi;
      packageType = "cephCsi";
    };
  };

  storage = {
    standard = {
      package = packages.cephStorage;
      packageType = "storage";
      config = { pool = "hdd-replicated"; reclaimPolicy = "Retain"; };
    };
    fast-ssd = {
      package = packages.cephStorage;
      packageType = "fastStorage";
      config = { pool = "nvme-replicated"; reclaimPolicy = "Retain"; };
    };
  };

  data = {
    postgres = {
      package = packages.postgres;
      packageType = "postgres";
      config = { dataSize = "500Gi"; walSize = "50Gi"; };
      # DI resolves:
      #   storage     → storage/standard  (cluster-wide unique "storage")
      #   fastStorage → storage/fast-ssd  (cluster-wide unique "fastStorage")
    };
  };
};
```

**Development: one tier for everything**

```nix
instances = { ref, ... }: {
  infra = {
    local-storage = {
      package = packages.localPathStorage;
      packageType = "storage";
      # No "fastStorage" instance exists → postgres's `fastStorage ? storage`
      # falls back to this. Same StorageClass for data and WAL.
    };
  };

  data = {
    postgres = {
      package = packages.postgres;
      packageType = "postgres";
      config = { dataSize = "10Gi"; walSize = "2Gi"; };
    };
  };
};
```

The postgres package is identical in both environments. The only difference is
what storage instances exist in the cluster config. The `fastStorage ? storage`
fallback means dev works with one StorageClass, prod uses two.

---

## 4. The Two-Level Pattern: Operator + Configuration

Many infrastructure concerns have two levels:

| Operator (deploy once) | Configuration (per-tier/per-use) | Consumer creates |
|---|---|---|
| CSI driver (DaemonSet + controller) | StorageClass | PVC |
| cert-manager (controller + CRDs) | ClusterIssuer | Certificate |
| prometheus-operator (controller + CRDs) | — (no config resource) | ServiceMonitor |
| ingress-nginx (controller) | IngressClass | Ingress |
| external-secrets-operator | SecretStore / ClusterSecretStore | ExternalSecret |

The split matters because:
- **One operator, many configurations**: one Ceph CSI driver serves multiple StorageClasses (fast, standard, bulk). One cert-manager serves multiple ClusterIssuers (letsencrypt-prod, letsencrypt-staging, internal-ca).
- **The operator is heavy** (DaemonSets, RBAC, CRDs). You deploy it once.
- **The configuration is light** (a single resource). You deploy one per tier/use case.

In kix, this maps to:
1. Operator = a package. Deployed as one instance.
2. Configuration = a separate package that depends on the operator. Deployed as one instance per tier.
3. Consumer = depends on the configuration by capability name.

The configuration package acts as the **DI entry point** — consumers ask for
`storage` or `fastStorage`, and the resolution gives them a configuration
package whose closure transitively includes the operator.

### 4.1 When to Split vs. Combine

**Split** (separate operator and configuration packages) when:
- Multiple configurations share one operator (multiple StorageClasses, multiple Issuers)
- Different teams manage operator vs. configuration
- The operator is complex and has its own lifecycle

**Combine** (operator and configuration in one package) when:
- There's always exactly one configuration per operator (e.g., a simple local-path provisioner that has one StorageClass)
- The configuration is trivially derived from operator settings

For simple cases, combining is fine:

```nix
# packages/local-path-storage/default.nix
# Combined: provisioner + StorageClass in one package
{ scope, config, lib }:
self: {
  provisioner = scope.mkResource { kind = "Deployment"; ... };
  # ...

  storageClass = scope.mkClusterResource {
    kind = "StorageClass";
    name = scope.instanceName;
    requires = [ self.provisioner ];
    extra.provisioner = "rancher.io/local-path";
  };

  main = self.storageClass;
}
```

Consumers don't care whether it's split or combined — they depend on `storage`
and get a StorageClass either way.

---

## 5. The Tiered Fallback Pattern

The `? default` pattern from doc 02 section 5 generalizes naturally to
infrastructure tiers:

```nix
{ scope, config, lib,
  storage,                    # required: some storage must exist
  fastStorage ? storage,      # prefer fast; fall back to general
  bulkStorage ? storage,      # prefer bulk; fall back to general
  sharedStorage ? storage,    # prefer RWX-capable; fall back to general
}:
```

### 5.1 How It Resolves

Given cluster config:

```nix
instances = { ref, ... }: {
  storage = {
    standard   = { package = packages.cephStorage; packageType = "storage";     config.pool = "hdd"; };
    fast       = { package = packages.cephStorage; packageType = "fastStorage"; config.pool = "nvme"; };
    # No bulkStorage or sharedStorage instances
  };
  data = {
    postgres = { package = packages.postgres; packageType = "postgres"; };
  };
};
```

Resolution for postgres:

```
  Arg "storage":
    Index: "storage" → [ storage/standard ]
    Cluster-wide unique → storage/standard
    ✓ resolved

  Arg "fastStorage" (default: ? storage):
    Index: "fastStorage" → [ storage/fast ]
    Cluster-wide unique → storage/fast
    ✓ resolved (override beats default)

  Arg "bulkStorage" (default: ? storage):
    Index: "bulkStorage" → []
    No candidates. Has Nix default.
    → Nix evaluates: bulkStorage = storage = storage/standard
    ✓ falls back to general storage

  Arg "sharedStorage" (default: ? storage):
    Index: "sharedStorage" → []
    No candidates. Has Nix default.
    → Nix evaluates: sharedStorage = storage = storage/standard
    ✓ falls back to general storage
```

**The property**: start with one StorageClass for everything. Add dedicated
tiers as needed. Packages don't change — the fallback handles it.

### 5.2 Progressive Tier Expansion

Start minimal, add tiers as the cluster grows:

```
Day 1:  storage (local-path)
        → everything uses local-path

Day 30: storage (ceph-standard), fastStorage (ceph-nvme)
        → databases use nvme for data, standard for WAL
        → everything else uses standard

Day 90: storage, fastStorage, bulkStorage (ceph-hdd-ec),
        sharedStorage (cephfs-rwx)
        → databases: nvme data, standard WAL
        → log aggregation: bulk erasure-coded storage
        → ML pipelines: shared filesystem
        → everything else: standard
```

Each step only adds cluster config. No package changes.

### 5.3 Cross-Tier Fallback Chains

You can express more complex fallback hierarchies:

```nix
{ scope, config, lib,
  storage,                          # general purpose
  fastStorage ? storage,            # prefer fast
  databaseStorage ? fastStorage,    # prefer database-optimized, then fast, then general
}:
```

Resolution tries `databaseStorage` first. If not found, Nix evaluates
`databaseStorage = fastStorage`. If `fastStorage` was resolved to a real
instance, that's used. If `fastStorage` also fell back, then
`databaseStorage = fastStorage = storage`.

Three-level fallback chain, no special machinery — just Nix `? default`
semantics.

---

## 6. Other Infrastructure Concerns

### 6.1 Certificates (Operator + Configuration Pattern)

```nix
# packages/letsencrypt-issuer/default.nix
# Configuration package: a ClusterIssuer backed by Let's Encrypt
{ scope, config, lib, certManager }:

let
  cfg = scope.defaults config {
    email = null;  # required
    server = "https://acme-v02.api.letsencrypt.org/directory";
    solverType = "http01";
  };
in self: {

  clusterIssuer = certManager.types.clusterIssuer.mk {
    name = scope.instanceName;
    spec.acme = {
      server = cfg.server;
      email = cfg.email;
      privateKeySecretRef.name = "${scope.instanceName}-acme-key";
      solvers = [
        (if cfg.solverType == "http01"
         then { http01.ingress.ingressClassName = "nginx"; }
         else { dns01.cloudDNS = cfg.dns01Config; })
      ];
    };
  };

  main = self.clusterIssuer;

  # Convenience: wrap cert-manager's certificate type provider
  # with this issuer pre-configured. Consumers can use
  # certIssuer.types.certificate.mk { ... } without knowing about
  # cert-manager directly.
  types.certificate = {
    mk = { spec ? {}, ... }@args:
      certManager.types.certificate.mk (args // {
        spec = spec // {
          issuerRef = {
            name = "${self.clusterIssuer}";
            kind = "ClusterIssuer";
          };
        };
      });
  };
}
```

Consumer:

```nix
# packages/my-app/default.nix
{ scope, config, lib, certIssuer ? null }:

self: {
  certificate = if certIssuer != null then certIssuer.types.certificate.mk {
    name = "${scope.instanceName}-tls";
    namespace = scope.namespace;
    spec = {
      secretName = "${scope.instanceName}-tls";
      dnsNames = config.domains or [ "${scope.instanceName}.example.com" ];
    };
  } else null;

  deployment = scope.mkResource {
    kind = "Deployment";
    # ... mount the TLS secret if certificate exists
    spec.template.spec.volumes = lib.optional (self.certificate != null) {
      name = "tls";
      secret.secretName = "${scope.instanceName}-tls";
    };
  };

  # ...
}
```

The consumer doesn't mention cert-manager at all. It depends on `certIssuer`
(a capability), which wraps cert-manager's type provider. Deploying the
consumer's closure pulls in the ClusterIssuer → cert-manager controller → CRDs.

Cluster config:

```nix
instances = { ref, ... }: {
  cert-manager = {
    cert-manager = { package = packages.certManager; packageType = "certManager"; };
    letsencrypt  = {
      package = packages.letsencryptIssuer;
      packageType = "certIssuer";
      config.email = "ops@example.com";
    };
  };
  # ...
};
```

### 6.2 Monitoring (Operator + Consumer-Created Resources)

Monitoring is different from storage and certificates: there's no separate
"configuration package." The consumer creates ServiceMonitors directly via the
operator's type provider.

```nix
# packages/my-app/default.nix
{ scope, config, lib, monitoring ? null }:

self: {
  serviceMonitor = if monitoring != null then monitoring.types.serviceMonitor.mk {
    name = "${scope.instanceName}";
    namespace = scope.namespace;
    spec = {
      selector.matchLabels = selectorLabels;
      endpoints = [{ port = "metrics"; interval = "30s"; }];
    };
  } else null;

  # The ServiceMonitor references the Service via label selector (not ${}),
  # so it needs requires if we want ordering.
  service = scope.mkResource {
    kind = "Service";
    requires = lib.optional (self.serviceMonitor != null) self.serviceMonitor;
    # ...
  };

  # ...
}
```

Here `monitoring` is the prometheus-operator package instance. Its
`.types.serviceMonitor.mk` injects `requires` for the ServiceMonitor CRD and
the operator controller (same as doc 05's type provider pattern). If no
monitoring instance exists in the cluster, `monitoring` is null and no
ServiceMonitor is created.

### 6.3 Ingress (Two-Level: Controller + IngressClass)

```nix
# packages/nginx-ingress/default.nix — combined controller + IngressClass
{ scope, config, lib }:
self: {
  controller = scope.mkResource { kind = "Deployment"; ... };
  # ...

  ingressClass = scope.mkClusterResource {
    apiVersion = "networking.k8s.io/v1";
    kind = "IngressClass";
    name = scope.instanceName;
    requires = [ self.controller ];
    extra.spec.controller = "k8s.io/ingress-nginx";
  };

  service = scope.mkResource {
    kind = "Service";
    name = scope.instanceName;
    outputs = { class = scope.instanceName; };
    requires = [ self.controller ];
    spec.type = "LoadBalancer";
    # ...
  };

  main = {
    resource = self.service;
    requires = [ self.ingressClass ];
  };
}
```

Consumer:

```nix
{ scope, config, lib, ingress ? null }:
self: {
  ingress = if ingress != null then scope.mkResource {
    apiVersion = "networking.k8s.io/v1";
    kind = "Ingress";
    name = scope.instanceName;
    spec.ingressClassName = "${ingress.ingressClass}";
    # ...
  } else null;

  service = scope.mkResource {
    kind = "Service";
    requires = lib.optional (self.ingress != null) self.ingress;
    # ...
  };

  # ...
}
```

Alternatively, the consumer could access `ingress.main` if the IngressClass is
part of the main closure, or use a dedicated output. But accessing the
IngressClass resource directly is cleaner because it's a `${}` reference that
tracks the dependency.

### 6.4 External Secrets (Operator + Configuration + Consumer)

Full three-level pattern:

```nix
# Operator: external-secrets-operator (packageType = "externalSecrets")
# Config:   aws-secret-store (packageType = "secretStore", depends on externalSecrets)
# Consumer: my-app (depends on secretStore)

# packages/aws-secret-store/default.nix
{ scope, config, lib, externalSecrets }:
self: {
  clusterSecretStore = externalSecrets.types.clusterSecretStore.mk {
    name = scope.instanceName;
    spec.provider.aws.service = "SecretsManager";
    spec.provider.aws.region = config.region or "us-east-1";
  };

  main = self.clusterSecretStore;

  # Convenience type provider: create ExternalSecrets pre-wired to this store
  types.externalSecret = {
    mk = { spec ? {}, ... }@args:
      externalSecrets.types.externalSecret.mk (args // {
        spec = { secretStoreRef = {
          name = "${self.clusterSecretStore}";
          kind = "ClusterSecretStore";
        }; } // spec;
      });
  };
}

# Consumer
{ scope, config, lib, secretStore ? null }:
self: {
  dbCredentials = if secretStore != null then secretStore.types.externalSecret.mk {
    name = "${scope.instanceName}-db-creds";
    spec.data = [{
      secretKey = "password";
      remoteRef = { key = "prod/postgres/password"; };
    }];
  } else null;

  # ...
}
```

---

## 7. Design Properties

### 7.1 Infrastructure Is Just Packages

No new system concepts. Storage providers, cert issuers, monitoring operators —
they're all packages with resources, resolved through the same DI system.
A StorageClass is `main` the same way a Service is `main`.

### 7.2 The `${}` Boundary

Some infrastructure references are trackable via `${}`:
- PVC → StorageClass (`storageClassName = "${storage.main}"`)
- Ingress → IngressClass (`ingressClassName = "${ingress.ingressClass}"`)
- Certificate → ClusterIssuer (through type provider wrapping)

Others are invisible:
- StorageClass → CSI Driver (`provisioner` is a runtime string)
- Ingress controller → IngressClass (the controller watches for its class)

For invisible references, `requires` fills the gap — same mechanism as
CRDs (doc 05). No new patterns needed.

### 7.3 Swappability Without Package Changes

The same postgres package works with:
- Local-path provisioner (dev)
- Ceph RBD (staging)
- AWS EBS CSI (production)

Because it depends on `storage` (a capability), not on `ceph-storage` (an
implementation). The cluster config decides which implementation fills the
capability.

### 7.4 Tiered Resources Compose via Nix Defaults

The `fastStorage ? storage` pattern means:
- Adding a tier is additive (add an instance to cluster config)
- Removing a tier falls back gracefully
- The package never needs to change
- The chain can be arbitrarily deep (`databaseStorage ? fastStorage ? storage`)

### 7.5 Closures Include Infrastructure

Deploying `postgres` from a `deployGroup` automatically includes:
- The PVCs
- The StorageClass(es)
- The CSI driver (via `requires` chain)
- All RBAC, DaemonSets, etc. the CSI driver needs

No manual tracking of infrastructure prerequisites.

---

## 8. Interaction with Type Providers (Doc 05)

Infrastructure DI and type providers are complementary:

- **Type providers** handle the CRD gap: consumer creates a CR, type provider
  auto-injects `requires` for CRD + controller.
- **Infrastructure DI** handles the configuration gap: consumer needs a
  StorageClass/Issuer/SecretStore, DI resolves it by capability name.

For operators that have CRDs (cert-manager, prometheus-operator,
external-secrets), the configuration package uses type providers to create its
configuration resources (ClusterIssuer, ClusterSecretStore). The consumer then
depends on the configuration package, which transitively pulls in the operator.

The configuration package can also **wrap** the operator's type providers,
pre-configuring them for the consumer:

```nix
# Configuration package wraps operator's type provider
types.certificate = {
  mk = args: certManager.types.certificate.mk (args // {
    spec.issuerRef = { name = "${self.clusterIssuer}"; kind = "ClusterIssuer"; };
  });
};
```

This gives consumers a single dependency (`certIssuer`) instead of two
(`certManager` + `certIssuer`). The wrapping is optional — consumers that need
more control can depend on the operator directly.

---

## 9. Storage Class vs. Volume Claim Template

### 9.1 PVC in the Package vs. VolumeClaimTemplate

StatefulSets have `volumeClaimTemplates` — K8s creates PVCs automatically from
the template. Should the package create explicit PVC resources or use
volumeClaimTemplates?

**With explicit PVCs** (recommended for kix):

```nix
dataPvc = scope.mkResource {
  kind = "PersistentVolumeClaim";
  spec.storageClassName = "${fastStorage.main}";
  # ...
};

statefulset = scope.mkResource {
  kind = "StatefulSet";
  spec.template.spec.volumes = [{
    persistentVolumeClaim.claimName = "${self.dataPvc}";
  }];
};
```

Advantages:
- The PVC is a first-class resource in the dependency graph
- `${}` tracks the StorageClass dependency on the PVC
- The PVC → StorageClass → CSI driver chain is visible in the closure
- `nix-diff` shows PVC changes

**With volumeClaimTemplates**:

```nix
statefulset = scope.mkResource {
  kind = "StatefulSet";
  extra.spec.volumeClaimTemplates = [{
    metadata.name = "data";
    spec = {
      storageClassName = "${fastStorage.main}";
      accessModes = [ "ReadWriteOnce" ];
      resources.requests.storage = cfg.dataSize;
    };
  }];
};
```

This also works — the `${}` interpolation in `storageClassName` still tracks
the dependency, even though it's nested inside `extra`. Both approaches are
valid. The explicit PVC approach makes the resource visible as its own node in
the graph; the template approach is more concise.

### 9.2 Recommendation

Use volumeClaimTemplates when K8s manages PVC lifecycle (StatefulSets with
auto-created PVCs). Use explicit PVCs when you need the PVC to exist
independently (Deployments with pre-provisioned storage, shared volumes).

Either way, `${}` interpolation of the StorageClass tracks the dependency.

---

## 10. Open Questions

### 10.1 Should Infrastructure Providers Validate Consumer Requests?

A StorageClass backed by Ceph RBD only supports `ReadWriteOnce`. If a consumer
requests `ReadWriteMany`, it will fail at provisioning time. Should kix catch
this at eval time?

Options:
- **No validation**: keep it simple, let K8s report the error
- **Advisory outputs**: storage provider exposes `.out.accessModes = "ReadWriteOnce"`, consumer can check
- **Eval-time check**: add a cross-resource validation (like the existing service-selector check) that warns on incompatible access modes

The advisory outputs approach is cheapest and fits the existing model. A
consumer that wants to be careful can check:

```nix
assert builtins.elem "ReadWriteMany" (storage.out.accessModes or [ "ReadWriteOnce" ]);
```

### 10.2 StorageClass "default" Annotation

K8s supports a default StorageClass via annotation
`storageclass.kubernetes.io/is-default-class: "true"`. If a PVC omits
`storageClassName`, K8s uses the default.

Should kix packages rely on the default? Probably not — it's an implicit
dependency that the graph can't track. Always specifying
`storageClassName = "${storage.main}"` is more explicit and produces better
graphs.

But for helm-bridged packages (where PVCs are generated by `helm template`),
the default annotation may be the only way to inject storage without
modifying the chart. The helm bridge could strip `storageClassName: ""` from
PVCs and inject the resolved storage provider's class name as a
post-processing step. This is a future enhancement, not needed for v2 launch.

### 10.3 Per-PVC StorageClass Override

Sometimes a package wants most PVCs on standard storage but one specific PVC
on fast storage. With the current model:

```nix
{ storage, fastStorage ? storage }:
# dataPvc uses fastStorage, walPvc uses storage
```

This works for two tiers. For more granular control, consumers can use config:

```nix
{ storage, fastStorage ? storage }:
let
  cfg = scope.defaults config {
    dataStorageOverride = null;
    walStorageOverride = null;
  };
  dataStorage = if cfg.dataStorageOverride != null then cfg.dataStorageOverride else fastStorage;
  walStorage = if cfg.walStorageOverride != null then cfg.walStorageOverride else storage;
in self: {
  dataPvc = scope.mkResource { spec.storageClassName = "${dataStorage.main}"; ... };
  walPvc = scope.mkResource { spec.storageClassName = "${walStorage.main}"; ... };
}
```

This lets the cluster config override per-PVC:

```nix
postgres = {
  package = packages.postgres;
  config.dataStorageOverride = ref.storage.ultra-fast;
};
```

Whether this level of configurability is needed depends on the use case.

### 10.4 Infrastructure Capabilities as Interfaces?

Doc 02 section 5.4 mentions a future direction where packages declare
`implements = [ "kv-store" "session-store" ]` for interface-based matching.

The same idea applies to infrastructure: a storage provider could declare
`implements = [ "block-storage" "read-write-once" ]` and a consumer could
request `blockStorage` as a capability.

For now, capability names (`storage`, `fastStorage`, `certIssuer`) are plain
strings matched by packageType/alias. This covers the real-world cases. The
interface system would add type safety but also complexity.
