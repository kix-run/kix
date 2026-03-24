# 22: First-Class Secrets — Definition, DI, and Consumption

## Working Document — March 2026

**Status:** Design exploration
**Predecessors:** doc 11 (infrastructure DI, storage pattern), doc 21 (CRD builders), doc 07 (instance design)

---

## 1. The Problem

Secrets are the most common infrastructure dependency in Kubernetes, yet kix has
no model for them. Today, packages that need secrets either:

- Hardcode secret names as strings — invisible to the dependency graph
- Create Secret resources inline with placeholder values — no lifecycle separation
- Rely on external tooling (sealed-secrets, ESO) without kix awareness

This creates three gaps:

1. **No dependency tracking.** A Deployment referencing a Secret by string name
   has no graph edge. kix can't order deployment, detect missing secrets, or
   include them in closures.

2. **No shape validation.** A Deployment expects keys `password` and `username`
   in a Secret. Nothing catches a mismatch at build time.

3. **No lifecycle model.** Secrets have different lifecycles than the apps that
   consume them. A database password may outlive ten redeployments of the app,
   or rotate independently. Bundling secret creation inside the consumer
   conflates these lifecycles.

---

## 2. Design Principles

### 2.1 Secrets Are Resources, Not Special

A K8s Secret is a namespaced resource like any other. It should be creatable via
the existing resource system (`scope.mkResource`) and participate in the
dependency graph the same way PVCs and ConfigMaps do. No parallel universe.

### 2.2 Producer Model with Override

Following the storage DI pattern (doc 11), the **producer** of a secret is the
natural owner. Postgres creates its own credential secret. An ingress controller
creates its own TLS secret. The consumer (immich, my-app) accesses the secret
through the producer's `out`.

But sometimes the operator wants to bring their own secret — a pre-existing
credential, a secret from a different source, or a manually managed value. The
producer must accept an **optional DI override** that replaces the default.

This is the `fastStorage ? storage` pattern applied to secrets: the package
provides a sensible default, the cluster definition can override it.

### 2.3 Shape Is the Contract

What makes secrets different from PVCs is **shape** — a secret has named keys,
and consumers depend on specific keys existing. The shape (set of key names) is
the contract between producer and consumer. kix should know this shape at build
time for validation.

### 2.4 Values Are Opaque at Build Time

Secret values are a deploy-time concern. The Nix evaluation produces a Secret
resource with declared keys and deploy-time metadata (generation rules, source
references), but never contains plaintext secret values. This keeps the nix
store clean and the functional model pure.

---

## 3. The `scope.mkSecret` Helper

A new helper that creates a K8s Secret resource with a rich `out` API.
Implemented in `lib/k8s.nix`, analogous to `mkResource`.

```nix
scope.mkSecret {
  name = "db-credentials";

  # Declared shape — which keys this secret contains
  keys = [ "username" "password" "host" "port" ];

  # Optional: deploy-time metadata for kix-deploy
  generate = {
    password = { type = "random"; length = 32; };
    username = { type = "fixed"; value = "immich"; };
    # keys without generate entries must be provided externally
  };

  # Optional: K8s secret type (default: Opaque)
  type = "Opaque";

  # Standard resource options
  requires = [ ];
}
```

### 3.1 What `mkSecret` Returns

A resource object (same `_type = "k8s-resource"`) with an enriched `out`:

```nix
secret.out.name           # → the Secret's metadata.name (string with context)
secret.out.keys           # → [ "username" "password" "host" "port" ]
secret.out.type           # → "Opaque"

# Reference builders — produce K8s-native structures
secret.out.keyRef "password"
# → { valueFrom.secretKeyRef = { name = "db-credentials"; key = "password"; }; }

secret.out.envFrom
# → { secretRef = { name = "db-credentials"; }; }

secret.out.volume "db-creds-vol"
# → { name = "db-creds-vol"; secret = { secretName = "db-credentials"; }; }

secret.out.volumeItem "db-creds-vol" { "password" = "db-password.txt"; }
# → { name = "db-creds-vol"; secret = {
#      secretName = "db-credentials";
#      items = [{ key = "password"; path = "db-password.txt"; }];
#    }; }
```

All string references carry Nix string context, so dependency tracking works
automatically. `secret.out.keyRef "password"` produces a structure where the
`name` field has context pointing to the Secret's store path.

### 3.2 Build-Time Key Validation

`keyRef` validates that the requested key exists in the declared `keys` list:

```nix
secret.out.keyRef "nonexistent"
# → error: secret "db-credentials" does not declare key "nonexistent"
#   declared keys: username, password, host, port
```

This catches typos and contract mismatches at `nix build` time, not at pod
startup.

### 3.3 The Manifest

`mkSecret` produces a standard K8s Secret manifest, but with **placeholder
values** and deploy-time annotations:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: data
  annotations:
    kix.dev/secret-keys: "username,password,host,port"
    kix.dev/generate-password: '{"type":"random","length":32}'
    kix.dev/generate-username: '{"type":"fixed","value":"immich"}'
type: Opaque
# Note: no `data` or `stringData` field — values are injected by kix-deploy
```

The manifest declares the shape and generation rules. `kix-deploy` reads the
annotations, generates or retrieves values, and applies the complete Secret
before deploying dependents.

---

## 4. Producer Pattern — Packages That Create Secrets

### 4.1 A Package That Owns Its Secret

Postgres creates its own credential secret and exposes it for consumers:

```nix
# packages/postgres/default.nix
{ scope, config, storage, credentials ? null }:

let
  creds = if credentials != null
    then credentials
    else scope.mkSecret {
      name = "${scope.instanceName}-credentials";
      keys = [ "username" "password" "host" "port" ];
      generate = {
        password = { type = "random"; length = 32; };
        username = { type = "fixed"; value = "postgres"; };
        host = { type = "derived"; from = "self.service.out.fqdn"; };
        port = { type = "fixed"; value = "5432"; };
      };
    };
in self: {

  credentialSecret = creds;

  statefulset = scope.mkResource {
    kind = "StatefulSet";
    name = scope.instanceName;
    spec.template.spec = {
      containers = [{
        name = "postgres";
        image = config.image;
        env = [
          (creds.out.keyRef "password" // { name = "POSTGRES_PASSWORD"; })
          (creds.out.keyRef "username" // { name = "POSTGRES_USER"; })
        ];
        # ...
      }];
    };
  };

  service = scope.mkResource {
    kind = "Service";
    name = scope.instanceName;
    requires = [ self.statefulset ];
    spec.ports = [{ port = 5432; }];
  };

  main = self.service;

  # Expose credentials for downstream consumers
  out.credentials = creds;
}
```

### 4.2 Consumer Accesses Through the Producer

Immich depends on postgres and accesses its credentials through `out`:

```nix
# packages/immich/default.nix
{ scope, config, postgres }:

self: {

  deployment = scope.mkResource {
    kind = "Deployment";
    name = scope.instanceName;
    spec.template.spec = {
      containers = [{
        name = "immich";
        image = config.image;
        env = [
          (postgres.out.credentials.out.keyRef "password" // { name = "DB_PASSWORD"; })
          (postgres.out.credentials.out.keyRef "username" // { name = "DB_USER"; })
          (postgres.out.credentials.out.keyRef "host" // { name = "DB_HOST"; })
          (postgres.out.credentials.out.keyRef "port" // { name = "DB_PORT"; })
        ];
      }];
    };
  };

  main = scope.mkResource {
    kind = "Service";
    name = scope.instanceName;
    requires = [ self.deployment ];
    spec.ports = [{ port = 3001; }];
  };
}
```

The dependency graph automatically includes the Secret:

```
immich Deployment
    └── env.DB_PASSWORD → secretKeyRef → postgres-credentials (Secret)
    └── env.DB_HOST     → secretKeyRef → postgres-credentials (Secret)
    ...
postgres-credentials (Secret)
    └── (created by postgres package, or injected via DI)
postgres StatefulSet
    └── env.POSTGRES_PASSWORD → secretKeyRef → postgres-credentials (Secret)
```

### 4.3 Overriding the Default Secret

The cluster operator brings their own credentials instead of auto-generated ones:

```nix
# Cluster definition
{
  customDbCreds = {
    package = packages.secret;
    config = {
      keys = [ "username" "password" "host" "port" ];
      # No generate — operator provides values out of band
    };
  };

  postgres = {
    package = packages.postgres;
    deps.credentials = instances.customDbCreds;
  };

  immich = { package = packages.immich; };
  # immich still accesses postgres.out.credentials — unchanged
}
```

Immich's code is identical in both cases. It doesn't know whether postgres
auto-generated credentials or received them externally.

---

## 5. Standalone Secrets — `packages/secret`

For secrets that aren't produced by any package — API keys, external service
credentials, shared tokens — a thin `packages/secret` package acts as the
producer:

```nix
# packages/secret/default.nix
{ scope, config }:

let
  secret = scope.mkSecret {
    name = config.name or scope.instanceName;
    keys = config.keys;
    type = config.type or "Opaque";
    generate = config.generate or {};
  };
in self: {
  main = secret;
  out = secret.out;
}
```

Usage in cluster definition:

```nix
{
  grafanaApiKey = {
    package = packages.secret;
    config.keys = [ "token" ];
  };

  grafana = {
    package = packages.grafana;
    deps.apiSecret = instances.grafanaApiKey;
  };
}
```

This is the equivalent of `packages/persistent-volume-claim` — a thin wrapper
that makes a raw infrastructure resource into a DI-compatible instance.

---

## 6. Shared Secrets Across Packages

Because secrets flow through DI, sharing is natural:

```nix
# Cluster definition — two apps share the same database credentials
{
  postgres = { package = packages.postgres; };

  immich = { package = packages.immich; };
  # Gets postgres.out.credentials via DI

  migrationJob = { package = packages.immich-migration; };
  # Also gets postgres.out.credentials via DI
}
```

Both `immich` and `migrationJob` depend on `postgres` and access
`postgres.out.credentials`. They get the same Secret resource. The dependency
graph correctly shows both depending on the credential Secret.

### 6.1 Cross-Namespace Secrets

K8s Secrets are namespace-scoped. If two consumers are in different namespaces,
they need separate Secret resources with the same content. Two options:

**Option A: Duplicate at build time.** The Nix evaluation stamps the same
`mkSecret` call into each namespace. Both produce separate K8s Secret resources
with identical shape and generation rules. `kix-deploy` populates both with the
same values.

```nix
# The producing package creates a namespace-local copy
{ scope, config, sharedCredentials }:
let
  localCreds = scope.mkSecret {
    name = "${scope.instanceName}-db-creds";
    keys = sharedCredentials.out.keys;
    mirrorOf = sharedCredentials;  # deploy-time hint: same values
  };
in self: {
  # use localCreds in this namespace
}
```

**Option B: Let the consumer reference cross-namespace.** The Secret lives in
the producer's namespace. The consumer uses the FQDN-style reference. This
doesn't work for env vars / volume mounts (K8s enforces same-namespace), so
this is only viable for some CRD patterns.

**Recommendation:** Option A — explicit duplication with a `mirrorOf` hint.
Keeps the model simple (secrets are always namespace-local), and `kix-deploy`
can use the hint to populate duplicates from the same source.

---

## 7. Interaction with Existing Infrastructure DI

Secrets follow the same patterns established in doc 11:

### 7.1 Two-Level Pattern

Some secrets come from an operator + configuration split:

```
external-secrets-operator → ClusterSecretStore → ExternalSecret → Secret
cert-manager              → ClusterIssuer      → Certificate    → Secret (TLS)
```

For these, the configuration package (ClusterSecretStore, ClusterIssuer) is the
DI entry point, and it exposes builders that produce Secrets. The `mkSecret`
helper is for **kix-native secrets** — those that kix creates and manages
directly, without an external operator.

### 7.2 Tiered Fallback

Secrets don't naturally tier like storage (`fastStorage ? storage`). A package
either needs specific credentials or it doesn't. However, the pattern applies
to **secret providers**:

```nix
{ scope, config,
  secretProvider ? null,  # e.g., external-secrets ClusterSecretStore
}:
let
  creds = if secretProvider != null
    then secretProvider.out.mkExternalSecret { ... }  # fetch from vault/aws
    else scope.mkSecret { ... };                       # kix-managed fallback
in self: { ... }
```

In production, a `secretProvider` exists in the cluster → secrets come from
Vault. In dev, no provider → kix auto-generates them.

---

## 8. The `env` Helper — Ergonomic Secret Wiring

The most common consumption pattern is mounting secret keys as environment
variables. The `keyRef` API is correct but verbose:

```nix
# Verbose — every env var is 1 line but deeply nested
env = [
  (creds.out.keyRef "password" // { name = "DB_PASSWORD"; })
  (creds.out.keyRef "username" // { name = "DB_USER"; })
  (creds.out.keyRef "host" // { name = "DB_HOST"; })
];
```

A potential `mkEnv` helper on secrets:

```nix
# Concise — map secret keys to env var names
creds.out.mkEnv {
  DB_PASSWORD = "password";
  DB_USER = "username";
  DB_HOST = "host";
}
# → [
#   { name = "DB_PASSWORD"; valueFrom.secretKeyRef = { name = "..."; key = "password"; }; }
#   { name = "DB_USER"; valueFrom.secretKeyRef = { name = "..."; key = "username"; }; }
#   { name = "DB_HOST"; valueFrom.secretKeyRef = { name = "..."; key = "host"; }; }
# ]
```

This is a convenience, not a core design element. It can be added later without
affecting the fundamental model.

---

## 9. Deploy-Time Concerns (Sketch)

> **Note:** The deploy story is explicitly out of scope for this RFC. This
> section sketches how the build-time model connects to deployment, to validate
> that the design doesn't paint us into a corner.

### 9.1 Secret Population

`kix-deploy` reads the Secret manifest annotations and:
1. For `generate` keys: generates values (random, derived, fixed)
2. For keys without `generate`: looks up values from the configured secret
   source (SOPS file, env vars, interactive prompt)
3. Applies the complete Secret before deploying any dependent resources

### 9.2 Rotation

A rotation is:
1. Generate new values for specified keys
2. Create a new Secret version (content-hash changes → new resource name)
3. Dependent Deployments detect the name change → rolling restart

Content-addressed naming makes rotation a natural consequence of value changes.
The Secret's name changes, so all referencing resources get updated manifests,
triggering redeployment.

### 9.3 "Already Exists" Secrets

For secrets that kix doesn't manage (created by an operator, pre-existing):

```nix
scope.mkSecretRef {
  name = "existing-tls-cert";
  keys = [ "tls.crt" "tls.key" ];
}
```

Analogous to `mkCRDRef` — creates a reference with `out` API and dependency
tracking, but produces no manifest. `kix-deploy` can optionally validate that
the Secret exists in the cluster before deploying dependents.

---

## 10. Summary of New API Surface

| Function | Where | Purpose |
|---|---|---|
| `scope.mkSecret { ... }` | lib/k8s.nix | Create a Secret resource with rich `out` |
| `scope.mkSecretRef { ... }` | lib/k8s.nix | Reference an existing Secret (no manifest) |
| `secret.out.keyRef key` | on resource | Produce `valueFrom.secretKeyRef` structure |
| `secret.out.envFrom` | on resource | Produce `envFrom` entry |
| `secret.out.volume name` | on resource | Produce volume definition |
| `secret.out.mkEnv mapping` | on resource | Map keys to env var names |
| `secret.out.keys` | on resource | List of declared key names |
| `packages/secret` | packages/ | Thin wrapper for standalone secrets |

---

## 11. Open Questions

### 11.1 Should `mkSecret` Be a Scope Method or a Lib Function?

`scope.mkSecret` has access to namespace context and can auto-derive the
resource name. A lib-level `lib.mkSecret` would be more flexible but requires
manual namespace/name wiring. Following the precedent of `scope.mkResource`,
`scope.mkSecret` is recommended.

### 11.2 Content-Addressing and Secret Names

If Secret names are content-addressed, changing a value changes the name,
which triggers redeployment of all consumers. This is desirable for rotation
but problematic if you want to update a secret without restarting pods.

Should secrets be **identity-addressed** by default (stable name, in-place
update) or **content-addressed** (name changes on value change, forces restart)?

Arguments for identity-addressed:
- In-place secret updates don't cause unnecessary restarts
- Matches K8s convention (secrets are mutable)

Arguments for content-addressed:
- Env-var-based secrets don't update without restart anyway
- Explicit restart is safer than hoping kubelet propagates changes
- Rotation becomes a first-class operation in the graph

**Recommendation:** Identity-addressed by default, with an opt-in
`contentAddressed = true` for secrets where rotation should force restarts.

### 11.3 Should `keyRef` Return a Full Env Var or Just `valueFrom`?

Current design: `keyRef` returns `{ valueFrom.secretKeyRef = { ... }; }` — a
partial env var entry that needs `// { name = "..."; }`.

Alternative: `keyRef "password" "DB_PASSWORD"` returns a complete env var entry
`{ name = "DB_PASSWORD"; valueFrom.secretKeyRef = { ... }; }`.

The partial approach is more composable (can be used in contexts beyond env
vars). The complete approach is more ergonomic for the common case. The
`mkEnv` helper (section 8) addresses ergonomics without changing `keyRef`.

### 11.4 Namespace of Cross-Namespace Duplicates

When `mirrorOf` duplicates a secret across namespaces, which namespace "owns"
the canonical values? The source secret's namespace, with all mirrors being
deploy-time copies? Or is ownership a separate concern?

### 11.5 Integration with `mkCRDRef`-style Patterns

cert-manager creates Secrets (TLS certificates) as a side effect of Certificate
CRs. These Secrets aren't created by `mkSecret` — cert-manager's controller
creates them at runtime. How should packages reference these?

A `mkSecretRef` pointing to the expected Secret name works:

```nix
tlsSecret = scope.mkSecretRef {
  name = "${scope.instanceName}-tls";
  keys = [ "tls.crt" "tls.key" "ca.crt" ];
  requires = [ self.certificate ];  # depends on the Certificate CR
};
```

This gives the same `out.keyRef` / `out.volume` API without creating the
Secret resource — cert-manager does that. The `requires` ensures deployment
ordering.

### 11.6 Secret Shape Evolution

When a package adds a new key to its secret in a new version (e.g., postgres
adds `sslmode`), what happens to existing secrets? Options:
- Build-time error: secret shape doesn't match → operator must update
- Warning with default: new key gets a default value in `generate`
- Ignore: new key is optional, package handles its absence

This is a general versioning question that applies to all DI contracts, not
just secrets.
