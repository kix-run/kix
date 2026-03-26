# DI-Driven Defaults: From Immich Pattern to General Infrastructure

## Working Document — March 2026

**Status:** Design exploration
**Predecessors:** doc 11 (infrastructure DI), doc 22 (secrets), doc 34 (connection graph)
**Reference implementation:** packages/immich (ingress, TLS, ML, storage, monitoring)

---

## 1. The Problem

Immich demonstrates a powerful pattern: optional dependencies gate feature creation.
When `ingressNginx` is injected → ingress auto-created. When `clusterIssuer` is
injected → TLS auto-enabled. When `machineLearning` is injected → ML URL wired.

But this pattern hasn't been applied consistently. The current state:

| Package | Ingress | TLS | Metrics | Storage | Object Storage |
|---|---|---|---|---|---|
| immich | DI ✓ | DI ✓ | config flag | DI (PVC) | — |
| n8n | config flag | hardcoded string | none | none | — |
| harbor | DI ✓ | DI ✓ | none | hardcoded | hardcoded S3 |
| stackgres-cluster | n/a | n/a | none | hardcoded string | S3 backup hardcoded |
| loki | Helm values | Helm values | Helm | — | hardcoded S3 |
| velero | n/a | n/a | none | — | hardcoded S3 |

Three problems:
1. **Inconsistency** — same concern (ingress, TLS) solved differently per package
2. **Hardcoded strings** — invisible to the dependency graph, break when infra changes
3. **Missing capabilities** — S3, DNS, auth, monitoring are all infrastructure that should be DI-driven but aren't modeled as packages at all

---

## 2. The Immich Pattern (Reference)

The established pattern uses three mechanisms:

### 2.1 Feature gating via optional dep

```nix
{ ingressNginx ? null, clusterIssuer ? null }:
# ...
hasIngress = ingressNginx != null && config.ingress.host != null;
hasTls = hasIngress && clusterIssuer != null;
```

The dep's *presence* is the feature flag. No `config.ingress.enabled` needed.

### 2.2 Config derivation via `out`

```nix
className = ingressNginx.out.ingressClassName;  # auto-derived from dep
host = config.ingress.host;                      # user must set this (for now)
```

### 2.3 Resource transformation via `out.withX`

```nix
|> (if hasTls then clusterIssuer.out.withCert else lib.id)
```

The infrastructure package exposes a pipe-friendly transformer that stamps its
config onto the consumer's resource.

---

## 3. Standardizing Across Packages

### 3.1 Ingress + TLS (apply immich pattern everywhere)

**n8n today** (config-driven, hardcoded strings):
```nix
# Bad: config flag + hardcoded strings
ingress.enabled = false;
ingress.className = "public";             # string, no dep tracking
ingress.tls.issuer = "";                  # string, no dep tracking
```

**n8n should be** (DI-driven):
```nix
{ scope, lib, kix, postgres ? null, valkey ? null,
  ingressNginx ? null, clusterIssuer ? null }:
# ...
hasIngress = ingressNginx != null && config.ingress.host != null;
hasTls = hasIngress && clusterIssuer != null;

ingress = if hasIngress then
  self.service
  |> kix.ingress.fromService {
    name = name;
    host = config.ingress.host;
    className = ingressNginx.out.ingressClassName;
    tls = lib.optional hasTls {
      hosts = [ config.ingress.host ];
      secretName = "${name}-tls";
    };
  }
  |> (if hasTls then clusterIssuer.out.withCert else lib.id)
  |> scope.mkResource
else null;
```

Every package with a web UI follows this exact pattern. The cluster config
controls it by whether `ingressNginx` and `clusterIssuer` instances exist.

### 3.2 `cluster.domain` — auto-derive host

**Today**: every package requires `config.ingress.host` to be set explicitly.

**Proposal**: when `clusterConfig.global.domain` is set, derive a default host:

```nix
options = {
  ingress = lib.mkOption {
    type = lib.types.anything;
    default = {
      host = null;  # null = auto-derive from cluster.domain
    };
  };
};

build = { self, config, clusterConfig, ... }:
let
  clusterDomain = clusterConfig.global.domain or null;
  effectiveHost =
    if config.ingress.host != null then config.ingress.host
    else if clusterDomain != null then "${name}.${clusterDomain}"
    else null;
  hasIngress = ingressNginx != null && effectiveHost != null;
in ...
```

**Cluster definition**:
```nix
# modules.nix already has `global` — just use it
global.domain = "northwind.example";

# Result: immich gets "immich.northwind.example", n8n gets "n8n.northwind.example"
# Override per-instance: config.ingress.host = "photos.northwind.example"
```

This is a natural extension. The `global` option already exists in `modules.nix`.

### 3.3 Monitoring — auto-create ServiceMonitor when prometheus is injected

**Today** (immich): `config.metrics.enabled` flag + manual CRDRef:
```nix
# Package creates its own CRDRef and ServiceMonitor
serviceMonitorCRDRef = scope.mkCRDRef { group = "monitoring.coreos.com"; ... };
mkServiceMonitor = serviceMonitorCRDRef.out.mkCR scope;
serviceMonitor = if config.metrics.enabled then mkServiceMonitor { ... } else null;
```

**Proposal**: prometheus as a DI dep that exposes a ServiceMonitor builder:

```nix
{ prometheus ? null }:
# ...
serviceMonitor = if prometheus != null then
  prometheus.out.mkServiceMonitor scope {
    name = name;
    selector = self.service.out.selector;
    endpoints = [{ port = "metrics"; }];
  }
else null;
```

The kube-prometheus-stack package would expose:
```nix
root.out = {
  mkServiceMonitor = consumerScope: args:
    serviceMonitorCRD.out.mkCR consumerScope args;

  mkPodMonitor = consumerScope: args:
    podMonitorCRD.out.mkCR consumerScope args;

  # Transformer: adds prometheus.io/* annotations
  withScrape = port: args: args // {
    annotations = (args.annotations or {}) // {
      "prometheus.io/scrape" = "true";
      "prometheus.io/port" = toString port;
    };
  };
};
```

**The key insight**: the monitoring package exposes *builders*, not just config.
Consumers don't need to know about CRDRefs or ServiceMonitor spec — they pass
their service selector and port names, the builder handles the rest.

**Two approaches to auto-enable:**

A. **Consumer-side** (explicit): package declares `prometheus ? null`, creates
   ServiceMonitor if present. Package controls what metrics are exposed.

B. **Provider-side** (global overlay): prometheus uses `globalPartsOverlays` to
   scan all instances for ports named "metrics" and auto-creates ServiceMonitors.
   Packages don't need to know about monitoring at all.

Recommendation: **A for now, B as future enhancement.** Consumer-side is explicit,
debuggable, and follows the established pattern. Provider-side is more magical
but requires the connection graph (doc 34) to know which ports are metrics ports.

---

## 4. New Infrastructure Capabilities

### 4.1 Object Storage (S3) — the big one

Multiple packages need S3-compatible storage: Loki (log chunks), Harbor (image
layers), Velero (backups), StackGres (WAL archiving), potentially any app with
file uploads.

**Today**: every package hardcodes S3 config:
```nix
# loki defaultValues
storage.s3.endpoint = "https://s3.eu-central-1.amazonaws.com";
storage.s3.bucketnames = "loki-chunks";
storage.s3.region = "eu-central-1";

# harbor config
storage.s3.region = "eu-central-1";
storage.s3.bucket = "harbor-registry";

# stackgres backup
objectStorage.s3.endpoint = "...";
```

Same pattern as hardcoded StorageClass names — invisible, duplicated, fragile.

**Implemented approach**: S3 endpoints as `mkImport` with explicit `out`.
No package needed — the bucket exists externally, kix just names it for DI:

```nix
# In cluster definition (e.g. clusters/nw1/platform.nix)
instances.storage = {
  hetzner-s3 = {
    package = kix.mkImport {
      out = {
        endpoint = "https://hel1.your-objectstorage.com";
        provider = "s3";
        s3ForcePathStyle = "true";
      };
    };
    aliases = [ "objectStorage" ];
  };

  ovh-s3 = {
    package = kix.mkImport {
      out = {
        endpoint = "https://s3.gra.io.cloud.ovh.net/";
        region = "gra";
        provider = "s3";
      };
    };
    aliases = [ "backupStorage" ];
  };
};
```

This creates PackageInstance markers in the graph. No fake K8s resources.
Consumers reference via `ref.storage.hetzner-s3.out.endpoint`.

Future: when S3 provisioning is needed (Crossplane, non-manifest side effects),
the import can evolve into a full package without changing consumers.

**Consumer usage (loki)**:
```nix
{ scope, lib, objectStorage ? null }:
# ...
build = { self, config, clusterConfig, ... }:
let
  # S3 config: DI-driven when objectStorage injected, else from config
  s3 =
    if objectStorage != null then {
      endpoint = objectStorage.out.endpoint;
      bucketnames = objectStorage.out.bucket;
      region = objectStorage.out.region;
    }
    else config.s3;
in { ... };
```

**Consumer usage (stackgres WAL archiving)**:
```nix
{ scope, lib, backupStorage ? null }:
# backupStorage is resolved to an s3-bucket instance
# ...
objectStorage = if backupStorage != null then {
  type = "s3";
  s3 = {
    bucket = backupStorage.out.bucket;
    region = backupStorage.out.region;
    endpoint = backupStorage.out.endpoint;
  };
} else config.objectStorage;
```

**Cluster config (tiered like block storage)**:
```nix
instances = {
  storage = {
    # Block storage (existing)
    fast = { package = packages.storage-classes; config.name = "fast-nvme"; };

    # Object storage (new)
    loki-s3 = {
      package = packages.s3-bucket;
      aliases = [ "objectStorage" ];
      config = {
        endpoint = "https://s3.eu-central-1.amazonaws.com";
        region = "eu-central-1";
        bucket = "company-loki-chunks";
        credentials.secretName = "aws-s3-credentials";
      };
    };
    backup-s3 = {
      package = packages.s3-bucket;
      aliases = [ "backupStorage" ];
      config = {
        endpoint = "https://s3.eu-central-1.amazonaws.com";
        region = "eu-central-1";
        bucket = "company-backups";
        credentials.secretName = "aws-s3-credentials";
      };
    };
  };

  monitoring.loki = {
    package = packages.loki;
    # DI resolves objectStorage → storage/loki-s3
  };

  backup.velero = {
    package = packages.velero;
    # DI resolves backupStorage → storage/backup-s3
  };
};
```

**The tiered fallback works here too:**
```nix
{ objectStorage, backupStorage ? objectStorage }:
# One S3 config for everything → backupStorage falls back to objectStorage
# Dedicated backup bucket added later → no package changes
```

### 4.2 The S3 Bucket Provisioning Question

The s3-bucket package above is a **configuration node** — it describes where a
bucket is, not how to create it. This is intentional:

- **Import mode**: the bucket already exists (created by Terraform, AWS console,
  manual `aws s3 mb`). The package just names it for DI. This is `mkImport` for
  S3. Most clusters will start here.

- **Future: Crossplane**: the package creates a Crossplane `Bucket` CR. The
  Crossplane provider actually provisions it. The s3-bucket package would depend
  on a crossplane-aws-provider DI dep and use its CRD builders.

- **Future: non-manifest side effect**: a kix-deploy task that runs
  `aws s3 mb s3://${config.bucket}` as a pre-deploy step. This is the
  non-manifest side effects item on the roadmap.

The config-node approach means we can start using S3 DI today without waiting
for provisioning. Same as how `mkImport` works for existing cluster resources.

### 4.3 DNS Zones

External-dns and ingress both need to know about DNS zones.

```nix
# packages/dns-zone/default.nix — configuration node
{ scope, lib }:
{
  meta.defaultAliases = [ "dnsZone" ];

  options = {
    zone = lib.mkOption { type = lib.types.str; };
    provider = lib.mkOption {
      type = lib.types.enum [ "cloudflare" "route53" "azure-dns" ];
      default = "cloudflare";
    };
  };

  build = { self, config, ... }: {
    root = {
      resource = scope.mkResource {
        apiVersion = "v1"; kind = "ConfigMap";
        name = "${scope.instanceName}-dns-zone";
        data = { zone = config.zone; provider = config.provider; };
      };
      out = {
        inherit (config) zone provider;

        # Derive a host from this zone
        hostFor = subdomain: "${subdomain}.${config.zone}";
      };
    };
  };
}
```

**Usage**: cluster-issuers can take `dnsZone` and auto-configure solvers:
```nix
{ scope, lib, certManager, dnsZone ? null }:
# If dnsZone injected → auto-configure DNS01 solver for that zone
# If not → require explicit solver config
```

**Combined with cluster.domain**: `global.domain` could be backed by a dnsZone
instance, making `hostFor` available cluster-wide:
```nix
global.domain = ref.infra.primary-zone.out.zone;
```

### 4.4 Backup Annotations

Velero uses annotations to control backup behavior:

```nix
# velero exposes:
root.out = {
  # Transformer: mark a resource for backup
  withBackup = args: args // {
    annotations = (args.annotations or {}) // {
      "velero.io/exclude-from-backup" = "false";
    };
  };

  # Transformer: exclude from backup
  withoutBackup = args: args // {
    annotations = (args.annotations or {}) // {
      "velero.io/exclude-from-backup" = "true";
    };
  };
};
```

---

## 5. The General Pattern

All of the above follow the same shape:

```
Infrastructure package:
  1. Deploys its own resources (operator, controller, config)
  2. Exposes via out:
     a. Values:       out.X          (className, endpoint, bucket)
     b. Builders:     out.mkX scope  (mkServiceMonitor, mkCertificate)
     c. Transformers: out.withX      (withCert, withAuth, withBackup)

Consumer package:
  1. Declares optional dep:  infraPkg ? null
  2. Gates features:         hasFeature = infraPkg != null && ...
  3. Derives config:         value = infraPkg.out.X
  4. Pipes transformers:     |> infraPkg.out.withX
  5. Creates resources:      infraPkg.out.mkX scope { ... }
```

### 5.1 The Three `out` Shapes

| Shape | Signature | When to use | Example |
|---|---|---|---|
| **Value** | `out.X = "string"` | Consumer reads a config value | `ingressClassName`, `endpoint`, `bucket` |
| **Builder** | `out.mkX = scope -> args -> resource` | Consumer creates infra's CRs | `mkServiceMonitor`, `mkCertificate` |
| **Transformer** | `out.withX = args -> args` | Consumer stamps infra's config onto own resource | `withCert`, `withAuth`, `withScrape` |

Builders and transformers carry dependency tracking automatically:
- Builder: the CRD/operator is in `requires` of the created CR
- Transformer: the infrastructure resource's `out.name` carries Nix string context

### 5.2 Composition Order

For an ingress with TLS, auth, and monitoring:

```nix
ingress = self.service
  |> kix.ingress.fromService { name; host = effectiveHost; className = ingressNginx.out.ingressClassName; ... }
  |> (if hasTls then clusterIssuer.out.withCert else lib.id)
  |> (if auth != null then auth.out.withAuth else lib.id)
  |> scope.mkResource;

serviceMonitor = if prometheus != null then
  prometheus.out.mkServiceMonitor scope {
    name; selector = self.service.out.selector;
    endpoints = [{ port = "http"; }];
  }
else null;
```

Each `withX` is independent — they compose in any order. The pipe makes the
composition chain readable and auditable.

---

## 6. Configuration-Only Packages (Config Nodes)

S3 buckets, DNS zones, and other external resources don't deploy K8s workloads.
They're **configuration nodes** — they exist in the dependency graph to carry
metadata and enable DI, but their "resource" is minimal (a ConfigMap or marker).

Properties:
- No operator dependency (unless provisioned via Crossplane)
- `out` carries connection info (endpoint, credentials, zone)
- Can be `mkImport`-ed when the resource pre-exists
- Future: provisioning via non-manifest side effects

This is a natural extension of `mkImport` — instead of importing a K8s resource
that exists in the cluster, we're importing an external resource (S3 bucket, DNS
zone) that exists outside K8s entirely.

### 6.1 mkExternalResource? (Future)

Today: `mkImport` for K8s resources, config-node packages for external resources.

Future possibility:
```nix
kix.mkExternal {
  type = "s3-bucket";
  provider = "aws";
  config = { bucket = "my-bucket"; region = "eu-central-1"; };
  # Creates a graph node + marker CR, no manifest
  # kix-deploy provisions it via provider plugin
};
```

This is the non-manifest side effects story. Not needed now — config-node
packages work today.

---

## 7. Global Defaults via `clusterConfig`

### 7.1 cluster.domain

Already supported via `global`:
```nix
# Cluster definition
global.domain = "example.com";

# Package reads it
effectiveHost = config.ingress.host or "${name}.${clusterConfig.global.domain or ""}";
```

### 7.2 Possible future globals

```nix
global = {
  domain = "example.com";

  # Default container registry (for air-gapped environments)
  imageRegistry = "registry.internal.example.com";

  # Default resource limits profile
  resourceProfile = "production";  # or "development", "staging"

  # Default security context
  securityDefaults = {
    runAsNonRoot = true;
    readOnlyRootFilesystem = true;
  };
};
```

These would be consumed via `clusterConfig.global.X` in packages, with
`mkDefault` priority so packages can override.

---

## 8. Implementation Plan

### Phase 1: Standardize ingress/TLS across all packages
- Convert n8n to DI-driven ingress (drop config.ingress.enabled)
- Verify harbor pattern matches immich
- Add `cluster.domain` auto-derive for host defaults
- Packages: n8n, harbor, posthog-proxy, metabase, any with ingress

### Phase 2: Monitoring DI
- Convert kube-prometheus-stack to a native kix package (not just Helm values)
- Expose `out.mkServiceMonitor` and `out.mkPodMonitor` builders
- Add `prometheus ? null` dep to immich, n8n, harbor, coredns, etc.
- Auto-create ServiceMonitors when prometheus is injected

### Phase 3: Object storage DI
- Create `s3-bucket` config-node package
- Add `objectStorage ? null` dep to loki, harbor, stackgres-cluster, velero
- Add tiered fallback: `backupStorage ? objectStorage`
- Update cluster definitions

### Phase 4: Storage DI for stackgres
- stackgres-cluster takes `storage ? null` DI dep for storageClass
- Falls back to config.storage.storageClass when no DI dep

### Phase 5: Auth, DNS, and remaining capabilities
- OAuth2-proxy / Authelia `out.withAuth` transformer
- DNS zone config-node package
- Velero backup annotations transformer

---

## 9. Open Questions

### 9.1 Config-node packages: ConfigMap or pure metadata?

S3 bucket doesn't need a K8s ConfigMap to function. Options:
- **ConfigMap**: visible in cluster, `kubectl get cm` shows S3 config. But it's
  redundant — the real config is in the bucket itself.
- **PackageInstance-only**: just a PI marker, no other resources. Lighter, but
  less visible.
- **Annotation on PI**: put connection info in PI annotations for discoverability.

Recommendation: ConfigMap for now. It's visible, debuggable, and the overhead is
one small resource per config node.

### 9.2 Helm chart packages and DI

kube-prometheus-stack is a Helm chart wrapped via `fromHelmChart`. It can't
easily expose `out.mkServiceMonitor` because `fromHelmChart` returns a generic
wrapper, not a hand-crafted package.

Options:
- **Rewrite as native package**: most control, but massive effort for kube-prometheus-stack
- **Hybrid**: `fromHelmChart` for deployment, separate hand-crafted `out` extensions on the root
- **partsOverlay**: cluster config adds `out.mkServiceMonitor` via overlay

The hybrid approach seems right — the Helm chart deploys the stack, but the
package definition adds DI-friendly `out` extensions on top.

### 9.3 Auto-enable vs. opt-in for monitoring

Two philosophies:
- **Opt-in (immich today)**: `config.metrics.enabled = true` + `prometheus ? null`
- **Auto-enable**: if `prometheus` dep resolves, metrics are enabled automatically

The immich pattern already hints at auto-enable: ports are conditionally added
when `config.metrics.enabled` is true. If we make `prometheus ? null` the gate
instead of a config flag, the package auto-exposes metrics when prometheus exists.

But some packages have a performance cost to enabling metrics. The config flag
lets operators disable metrics on resource-constrained instances even when
prometheus is available.

**Compromise**: `prometheus ? null` gates ServiceMonitor creation. A separate
`config.metrics.enabled` (default: true) gates metrics *ports*. When prometheus
is injected AND metrics are enabled → ServiceMonitor created. When prometheus is
not injected → no ServiceMonitor regardless of config.

### 9.4 Multiple S3 providers vs. one with tiered fallback

Do we need `minio` as a separate package type from `s3-bucket`? Or is it just
an s3-bucket with `provider = "minio"` and a different endpoint?

From the consumer's perspective, S3 is S3. The `provider` hint in the config
node handles any provider-specific quirks (path-style URLs for MinIO, etc.).
A single `s3-bucket` package with a `provider` option is sufficient.

MinIO itself (the server) is a separate package that deploys the actual
MinIO workload. The s3-bucket config node *points at* a MinIO endpoint — it
doesn't deploy MinIO.

### 9.5 How many `out` shapes is too many?

Every infrastructure package could expose values, builders, AND transformers.
Is there a risk of bloat? When should a package expose `out.withX` vs.
just `out.x` and let the consumer wire it?

Rule of thumb:
- **Transformer** when the consumer would need to copy annotations/labels/spec
  fields from the infrastructure into their own resource (cert-manager, auth, backup)
- **Builder** when the consumer creates instances of the infrastructure's CRDs
  (ServiceMonitor, Certificate, ExternalSecret)
- **Value** when the consumer just needs a name/endpoint/port string

If a concern only needs a value, don't over-engineer a transformer for it.
`ingressClassName` is a value, not a transformer, because it's a single field
the consumer puts in `spec`.

### 9.6 Credential threading

S3 buckets and database connections both involve credentials. Currently:
- Postgres: consumer uses `postgres.out.fqdn` for host, credentials are
  out-of-band (existingSecret, Infisical, manual)
- S3: same — endpoint via DI, credentials via separate secret

The secrets DI design (doc 22) proposes first-class credential packages. When
that lands, s3-bucket could depend on a `credentials` DI dep:

```nix
{ scope, lib, credentials ? null }:
# credentials.out.secretName, credentials.out.keyRef "access-key"
```

For now: `config.credentials.secretName` is sufficient. The DI layer for
secrets can be added later without changing the consumer interface.
