# 74: Secrets in kix — Origins, DI Model, and the Six Concerns

**Status:** RFC (consolidates docs 22, 64, 64a)
**Related:** `29_compiler-design.md` (Merkle DAG), `48_system_contracts.md` (DI + capabilities), `60_scorecard_rules_design.md` (policy rules), `63a_storage_as_cluster_concern.md` (DI pattern for infra)

---

## 1. Problem

Secrets are the most common infrastructure dependency in Kubernetes, and kix has no model for them. Today, packages handle secrets three ways — all broken:

1. **Values in Nix.** external-dns puts `config.cloudflare.apiKey = "sk-..."` into a Nix option. The plaintext ends up in the Nix store. This is a security bug.

2. **Name-string references.** n8n's `existingSecret`, metabase's `existingSecret`, stackgres' `credentialsSecret` — all reference secrets by opaque name with no shape validation, no dependency tracking, no build-time verification that the secret exists or has the right keys.

3. **No producer-consumer wiring.** Postgres creates credentials. n8n needs them. Today this is bridged by convention: someone creates a Secret with the right name and keys, and both sides hope it matches. The DI graph connects the services but not the credentials.

These gaps mean: no dependency tracking (kix can't detect missing secrets), no shape validation (typos caught at pod startup, not build time), and no lifecycle separation (secret creation conflated with consumer deployment).

---

## 2. Secret Origins — Seven Kinds

Every secret in a real cluster has an **origin** (who created the value), an **owner** (who decides when it changes), and **consumers** (who reads it). These three roles don't always live in the same place — the mismatches are where complexity hides.

### Kind 1: Application-internal credentials

Secrets an app creates for its own use: encryption keys, CSRF tokens, session signing keys, admin bootstrap passwords.

*Examples:* firezone's `GUARDIAN_SECRET_KEY`, `SECRET_KEY_BASE`; harbor's `secretKey`, `CSRF_KEY`, `CORE_SECRET`.

These have no external meaning. Nobody else cares about harbor's CSRF key. If regenerated, the worst that happens is sessions get invalidated. **kix should auto-generate these.** The package declares "I need a 32-byte random key" and kix produces it.

### Kind 2: Inter-service credentials (producer-created)

Credentials one service creates and another consumes. The producer controls the lifecycle.

*Examples:* postgres credentials consumed by immich, n8n, metabase; valkey password consumed by n8n.

The credential's lifecycle is bound to the producer. Replace postgres, replace its credentials. **This is the DI core case** — producer exposes `out.credentials`, consumer accesses via DI.

### Kind 3: External service credentials (operator-provided)

Credentials for services outside the cluster: cloud APIs, SaaS tokens, third-party integrations.

*Examples:* external-dns Cloudflare API key, velero S3 credentials, tailscale OAuth secret.

The value comes from outside the K8s/kix world. kix cannot generate, rotate, or validate it. **kix tracks shape and reference; the value is someone else's problem.** These must never be in the Nix evaluation.

### Kind 4: TLS certificates

X.509 certificates and their private keys, typically managed by cert-manager.

*Examples:* cert-manager-issued ingress TLS, harbor's token-service private key.

TLS certs rotate by necessity via well-established infrastructure (cert-manager, ACME). **kix uses `mkSecretRef`** with a dependency on the Certificate CR. kix declares the shape; cert-manager creates and rotates the actual Secret.

### Kind 5: Synced/replicated secrets (external operator)

Secrets whose source of truth is an external system, synced into K8s by an operator (ESO, Infisical).

*Examples:* Infisical operator syncing to `"infisical-managed-secret"` for shopfront/ledgerly.

The K8s Secret is a cache of the real secret. **kix uses `mkSecretRef`** with shape declaration and operator dependency. Today shopfront lists `"infisical-managed-secret"` as an opaque string — kix has zero visibility into what it contains.

### Kind 6: Derived/computed credentials

Credentials derived from composition: connection strings built from host + port + password, JDBC URLs.

*Examples:* n8n's separate `DB_POSTGRESDB_HOST` + `DB_POSTGRESDB_PASSWORD` forming one logical connection.

**Not a secret concern — it's a wiring concern** that touches secrets. The connection graph (when implemented) handles this.

### Kind 7: Bootstrap/infrastructure secrets

Secrets the cluster infrastructure needs before any application runs: etcd encryption key, cluster CA, `imagePullSecrets`.

kix should not manage these. They pre-date kix. **`mkSecretRef` without `requires`** — the secret is expected to exist.

### Ownership Matrix

| Kind | Creates value | Rotates | Consumes | kix role |
|------|--------------|---------|----------|----------|
| 1. App-internal | kix (auto-gen) | kix or app | Same package | **Full ownership** |
| 2. Inter-service | Producer pkg | Producer/operator | Consumer pkgs via DI | **DI wiring** |
| 3. External cred | Human/cloud | Human/cloud | Packages | **Shape tracking** |
| 4. TLS cert | cert-manager/human | cert-manager | Ingress, apps | **Reference** (`mkSecretRef`) |
| 5. Synced | External store | External store | Packages | **Reference** (`mkSecretRef`) |
| 6. Derived | Composition | N/A | Packages | **Wiring** (not a secret API) |
| 7. Bootstrap | Infra tooling | Infra team | K8s components | **Hands off** |

---

## 3. The DI Model

### 3.1 Design Principles

**Secrets are resources, not special.** A K8s Secret is a namespaced resource like any other. It participates in the dependency graph the same way PVCs and ConfigMaps do.

**Producer model with override.** Following the storage DI pattern, the producer of a secret is the natural owner. Postgres creates its own credential secret. The consumer accesses it through the producer's `out`. But the operator can inject a replacement via DI — the `fastStorage ? storage` pattern applied to secrets.

**Shape is the contract.** A secret has named keys, and consumers depend on specific keys existing. The shape (set of key names) is the contract between producer and consumer. kix validates this at build time.

**Values are opaque at build time.** The Nix evaluation produces a Secret resource with declared keys and deploy-time metadata, but never contains plaintext secret values. This keeps the Nix store clean.

### 3.2 `scope.mkSecret` — Creating Secrets

Creates a K8s Secret resource with a rich `out` API. Implemented in `lib/k8s.nix`, analogous to `mkResource`.

```nix
scope.mkSecret {
  name = "db-credentials";
  keys = [ "username" "password" "host" "port" ];

  # Optional: deploy-time generation rules
  generate = {
    password = { type = "random"; length = 32; };
    username = { type = "fixed"; value = "immich"; };
    # Keys without generate entries must be provided externally
  };

  # Optional: metadata for scorecard/compliance
  meta.classification = "critical";     # feeds scorecard rules
  meta.rotationPolicy = "90d";          # declares intent

  type = "Opaque";  # K8s secret type, default Opaque
}
```

Returns a resource object (`_type = "k8s-resource"`) with enriched `out`:

```nix
secret.out.name             # → metadata.name (string with context)
secret.out.keys             # → [ "username" "password" "host" "port" ]

# Reference builders — produce K8s-native structures
secret.out.keyRef "password"
# → { valueFrom.secretKeyRef = { name = "db-credentials"; key = "password"; }; }

secret.out.envFrom
# → { secretRef = { name = "db-credentials"; }; }

secret.out.volume "db-creds-vol"
# → { name = "db-creds-vol"; secret = { secretName = "db-credentials"; }; }

secret.out.mkEnv {
  DB_PASSWORD = "password";
  DB_USER = "username";
}
# → [
#   { name = "DB_PASSWORD"; valueFrom.secretKeyRef = { name = "..."; key = "password"; }; }
#   { name = "DB_USER"; valueFrom.secretKeyRef = { name = "..."; key = "username"; }; }
# ]
```

All string references carry Nix string context → dependency tracking works automatically.

**Build-time key validation:** `keyRef` validates that the requested key exists in the declared `keys` list. `secret.out.keyRef "nonexistent"` fails at `nix build` time with a clear error.

**The manifest** declares shape and generation rules via annotations but contains no `data` or `stringData`. Values are injected at deploy time.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  annotations:
    kix.dev/secret-keys: "username,password,host,port"
    kix.dev/generate-password: '{"type":"random","length":32}'
type: Opaque
# No data field — values injected by deploy tooling
```

### 3.3 `scope.mkSecretRef` — Referencing Existing Secrets

For secrets that kix doesn't create (cert-manager TLS, Infisical-synced, bootstrap):

```nix
scope.mkSecretRef {
  name = "infisical-managed-secret";
  keys = [ "DATABASE_URL" "API_KEY" "SMTP_PASSWORD" ];
  source.operator = "infisical";            # metadata for audit
  requires = [ instances.infisical-operator ]; # deployment ordering
}
```

Creates a reference with the same `out` API (`keyRef`, `volume`, `mkEnv`) and dependency tracking, but produces no manifest. Optionally, deploy tooling can verify the Secret exists before deploying dependents.

### 3.4 Producer-Consumer Pattern

Postgres creates its own credential secret and exposes it:

```nix
# packages/postgres/default.nix
{ scope, config, storage, credentials ? null }:

let
  creds = if credentials != null
    then credentials  # DI override
    else scope.mkSecret {
      name = "${scope.instanceName}-credentials";
      keys = [ "username" "password" "host" "port" ];
      generate = {
        password = { type = "random"; length = 32; };
        username = { type = "fixed"; value = "postgres"; };
      };
    };
in self: {
  credentialSecret = creds;

  statefulset = scope.mkResource {
    kind = "StatefulSet";
    name = scope.instanceName;
    spec.template.spec.containers = [{
      name = "postgres";
      env = [
        (creds.out.keyRef "password" // { name = "POSTGRES_PASSWORD"; })
        (creds.out.keyRef "username" // { name = "POSTGRES_USER"; })
      ];
    }];
  };

  out.credentials = creds;
}
```

Consumer accesses through the producer's `out`:

```nix
# packages/immich/default.nix
{ scope, config, postgres }:

self: {
  deployment = scope.mkResource {
    kind = "Deployment";
    name = scope.instanceName;
    spec.template.spec.containers = [{
      name = "immich";
      env = [
        (postgres.out.credentials.out.keyRef "password" // { name = "DB_PASSWORD"; })
        (postgres.out.credentials.out.keyRef "host" // { name = "DB_HOST"; })
      ];
    }];
  };
}
```

The dependency graph automatically includes the Secret. Immich's code is identical whether postgres auto-generated credentials or received them via DI override.

### 3.5 Override at Cluster Level

```nix
# Cluster definition — operator brings their own credentials
{
  customDbCreds = {
    package = packages.secret;
    config.keys = [ "username" "password" "host" "port" ];
  };

  postgres = {
    package = packages.postgres;
    deps.credentials = instances.customDbCreds;
  };

  immich = { package = packages.immich; };
  # immich still accesses postgres.out.credentials — unchanged
}
```

### 3.6 `packages/secret` — Standalone Secrets

For secrets not produced by any package (API keys, external creds). A thin wrapper analogous to `packages/persistent-volume-claim`:

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

### 3.7 Where Secrets Live in the Architecture

The ownership matrix determines placement:

- **Instance-level (on the package):** Kind 1 (app-internal) — `scope.mkSecret` inside the build function. Kind 2 (inter-service) — producer creates, exposes via `out`.
- **Cluster-level (module config):** Kind 3 (external creds) and Kind 7 (bootstrap) — standalone instances or cluster-level `secrets` module.
- **Delegated (not in kix):** Kind 4 (TLS), Kind 5 (synced) — kix references via `mkSecretRef`, external operator manages lifecycle.

---

## 4. The Six Concerns and How DI Addresses Each

### Concern 1: Definition & Shape

*"What keys does this secret have?"*

**Addressed by:** `mkSecret` key declarations + `keyRef` build-time validation.

Packages declare keys. Consumers reference them with compile-time validation. Typos and contract mismatches fail at `nix build`, not pod startup. The store DAG enables `kix secrets list` — walk all resources, filter for `kind: Secret`.

**Gap:** Helm imports via `fromHelmChart` produce resources with string-level secret references that bypass `out.keyRef` validation. Accept as unmanaged (scorecard warning) or wrap post-import with `mkSecretRef`.

### Concern 2: Injection

*"How does the secret value reach the container?"*

**Addressed by:** `out.keyRef` (env var), `out.volume` (file mount), `out.envFrom` (bulk env).

The injection mechanism should be orthogonal to the secret definition. A package declares what it needs; how the value reaches the container depends on the cluster's secret provider:

```
                          ┌─ K8s-native: mkSecret → secretKeyRef/volume
definition → injection ───┤─ ESO: ExternalSecret → K8s Secret → secretKeyRef
                          └─ CSI: SecretProviderClass → CSI volume mount
```

**Gap:** No enforcement of injection policy (e.g., "critical secrets must use volume mounts, not env vars"). Addressable via scorecard rules.

### Concern 3: Provisioning & Storage

*"Where do secret values come from and where do they live at rest?"*

**Addressed by:** Provider tier model. The package always calls `scope.mkSecret`; the cluster determines what that means.

| Tier | Source | Stored in | For |
|------|--------|-----------|-----|
| 0: kix-native | `generate` rules | etcd | Dev, simple production |
| 1: Git-encrypted | SOPS/agenix ciphertext in repo | Git + etcd | Production with VCS secrets |
| 2: External store | Vault, AWS SM, GCP SM via ESO | External store + etcd | Enterprise |
| 3: CSI-direct | Vault/KMS via CSI driver | Never touches etcd | Zero-trust / regulated |

Tiers are cluster config, not package config:

```nix
# Dev
{ cluster.secrets.provider = "kix-native"; }

# Production
{ cluster.secrets.provider = "external-secrets";
  cluster.secrets.externalSecrets.store = instances.vault-backend; }
```

`scope.mkSecret` checks the provider and emits the right resource type. Package code is unchanged.

**Gap:** Tier 0 value persistence. When `generate` creates a random password on first deploy and the cluster is rebuilt, the password is lost. Options: (a) accept it for dev/ephemeral, (b) encrypt-and-commit back to repo (promotes to Tier 1), (c) seed-based deterministic generation from a single root secret. See open questions.

### Concern 4: Rotation & Lifecycle

*"How are secrets renewed, and what happens when they change?"*

**Partially addressed.** Three rotation models exist:

- **External rotation (Tier 2/3):** The secret store rotates on its own schedule. ESO syncs. kix is not involved.
- **Build-triggered rotation (Tier 1):** Updated ciphertext → content hash change → dependent Deployments get new hashes → redeployment.
- **Automated rotation:** kix-deploy or a controller rotates on schedule, re-encrypts, triggers redeploy. Not yet designed.

Rotation policy is metadata on the secret:

```nix
scope.mkSecret {
  name = "db-credentials";
  keys = [ "username" "password" ];
  meta.rotationPolicy = {
    maxAge = "90d";
    gracePeriod = "24h";
    strategy = "dual-cred";  # or "in-place", "rolling"
  };
};
```

For env-var secrets (values fixed at container start), rotation requires pod restart. A `restartOnRotation = true` flag adds the Secret's content hash to the Deployment's annotations (like Helm's `checksum/secret`), forcing a rolling update on rotation.

**Gap:** No automated rotation implementation. No dual-credential transition window. These are deploy-time features, not build-time.

### Concern 5: Access Control & Audit

*"Who can read/write which secrets?"*

**Structurally addressed by DI.** If immich depends on postgres, it gets `postgres.out.credentials`. It cannot access `grafana.out.apiKey` unless grafana is in its dependency graph. This is compiler-enforced access control — no other K8s tooling provides this.

Four access control layers:

| Layer | Controls | Mechanism |
|-------|----------|-----------|
| Build-time | Which packages can reference which secrets | DI graph — no dep edge, no access |
| Git-time | Who can modify encrypted values | SOPS access rules, CODEOWNERS |
| Deploy-time | Who can decrypt and apply | kix-deploy RBAC, deploy keys |
| Runtime | Which pods can read which K8s Secrets | K8s RBAC (SA → Role → RoleBinding) |

The DI graph is an implicit access control matrix, made explicit via CLI:

```bash
$ kix secrets access-matrix
SECRET              ACCESSED BY           MECHANISM
db-credentials      immich/deployment     env: DB_PASSWORD, DB_USER
db-credentials      postgres/statefulset  env: POSTGRES_PASSWORD
grafana-api-key     grafana/deployment    volume: /etc/grafana/api-key
```

**Gap:** No audit trail for kix-native secrets. For git-encrypted (Tier 1), git history covers it. For external stores (Tier 2/3), the store's audit log covers it. Tier 0 needs kix-deploy to log rotation events.

### Concern 6: Transport & Zero-Trust

*"How do secrets move between environments without exposure?"*

**Partially addressed** by the values-never-in-nix-store principle and the tier model.

| Threat | Mitigation |
|--------|-----------|
| At rest in git | SOPS/agenix encryption |
| At rest in etcd | etcd encryption at rest, or avoid etcd entirely (Tier 3 CSI) |
| In transit: CI → cluster | TLS (kubectl), or avoid transit (ESO/CSI) |
| In memory | Volume mounts over env vars for critical secrets |

Since kix evaluations never contain plaintext values, build-phase log leaks are structurally impossible. Deploy-time logging needs care.

Air-gapped clusters use Tier 0 or Tier 1 (no external store to reach). The provider config makes this a cluster-level decision.

**Gap:** No CSI integration designed yet. No `kix lint` check for plaintext secrets in Nix files (though this is straightforward).

---

## 5. API Summary

| Function | Purpose |
|----------|---------|
| `scope.mkSecret { name; keys; generate?; meta?; }` | Create a Secret resource with rich `out` |
| `scope.mkSecretRef { name; keys; requires?; source?; }` | Reference an existing Secret (no manifest) |
| `secret.out.keyRef key` | Produce `valueFrom.secretKeyRef` structure |
| `secret.out.envFrom` | Produce `envFrom` entry |
| `secret.out.volume name` | Produce volume definition |
| `secret.out.mkEnv { ENV = "key"; ... }` | Map keys to env var names |
| `secret.out.keys` | List of declared key names |
| `packages/secret` | Thin wrapper for standalone secret instances |

Each secret kind maps to a specific API:

| Kind | API | Defined in |
|------|-----|-----------|
| 1. App-internal | `scope.mkSecret` with `generate` | Package build function |
| 2. Inter-service | `scope.mkSecret` + `out.credentials` via DI | Producer package |
| 3. External cred | `scope.mkSecretRef` or `packages/secret` instance | Cluster definition |
| 4. TLS cert | `scope.mkSecretRef` + `requires = [ certificate ]` | Package with Certificate CR |
| 5. Synced | `packages/external-secret` instance via DI | Cluster definition |
| 6. Derived | Connection graph (not a secret API) | N/A |
| 7. Bootstrap | `scope.mkSecretRef` (no `requires`) | Cluster definition |

---

## 6. Cross-Namespace Secrets

K8s Secrets are namespace-scoped. When two consumers in different namespaces need the same secret, duplicate at build time with a `mirrorOf` hint:

```nix
{ scope, config, sharedCredentials }:
let
  localCreds = scope.mkSecret {
    name = "${scope.instanceName}-db-creds";
    keys = sharedCredentials.out.keys;
    mirrorOf = sharedCredentials;  # deploy-time hint: same values
  };
in self: { /* use localCreds */ }
```

Both produce separate K8s Secret resources. Deploy tooling uses the `mirrorOf` hint to populate duplicates from the same source. This keeps the model simple (secrets are always namespace-local).

---

## 7. Implementation Phases

### Phase 1: Build-time foundation

Implement `mkSecret`, `mkSecretRef`, shape validation, DI wiring, and the `out` API. Add `meta.classification` and `meta.rotationPolicy` as metadata fields (declaration only, no enforcement). Add scorecard rules: `secret-has-shape`, `secret-has-classification`. Fix existing packages that put values in Nix (external-dns, velero) to use references.

### Phase 2: Provider abstraction

Implement `cluster.secrets.provider` with Tier 0 (kix-native) and Tier 1 (SOPS) backends. `scope.mkSecret` checks the provider and emits the right resource. Add `kix secrets list` and `kix secrets access-matrix` CLI commands. Implement `restartOnRotation`.

### Phase 3: External store integration

Tier 2: ESO integration — `scope.mkSecret` emits `ExternalSecret` CRs when provider is `external-secrets`. Add scorecard rules: `secret-rotation-policy`, `secret-no-env-critical`, `secret-provider-tier`.

### Phase 4: Enterprise features

Tier 3: CSI integration. Automated rotation. Compliance exports: secret inventory as SBOM component, rotation compliance as OSCAL assessment. `kix secrets rotate` for emergency rotation.

---

## 8. Open Questions

### 8.1 Tier 0 value persistence: accept loss or derive from seed?

When `generate` creates a random password and the cluster is rebuilt, the password is lost. Options:

- **Accept it** — Tier 0 is for dev/ephemeral clusters
- **Seed-based determinism** — A single encrypted root secret in git derives all generated values. Same seed → same passwords. Root secret rotation cascades all derived values. Trade-off: root compromise → everything compromised.

Seed-based is the most interesting but makes the root secret the most critical secret in the system — turtles all the way down.

### 8.2 Provider selection granularity

Cluster-wide default with per-secret override:

```nix
cluster.secrets.provider = "external-secrets";  # default
scope.mkSecret { name = "api-key"; provider = "sops"; };  # override
```

Or should provider always be cluster-wide? Per-secret overrides add complexity.

### 8.3 Identity-addressed vs content-addressed secret names

- **Identity-addressed (default recommendation):** Stable name, in-place update. Matches K8s convention. Volume-mounted secrets auto-refresh via kubelet.
- **Content-addressed (opt-in):** Name changes on value change → forces pod restart. Better for env-var secrets where kubelet can't help. Explicit rotation.

Recommend identity-addressed by default with `restartOnRotation` for the env-var case.

### 8.4 Should `generate` be a package concern or a provider concern?

Kind 1 secrets (app-internal) need generation. If the package declares `generate.CSRF_KEY = { type = "random"; length = 32; }`, kix-deploy must know how to execute it. If it's a provider concern, the provider needs app-specific knowledge. Leaning package concern — generation rules in Nix evaluation, execution at deploy time.

### 8.5 Helm chart secrets

Helm imports via `fromHelmChart` create Secrets that bypass `mkSecret`. Options: wrap post-import with `mkSecretRef`, auto-scan Helm output for shape declarations, or accept as unmanaged with scorecard warning.

### 8.6 Secret shape evolution

When a package adds a new key to its secret in a new version (postgres adds `sslmode`), what happens to existing secrets? This is a general DI contract versioning question, not secrets-specific.

### 8.7 `mirrorOf` ownership

When duplicating a secret across namespaces, the source secret's namespace owns the canonical values. All mirrors are deploy-time copies. The `mirrorOf` annotation points back to the source.

### 8.8 Provider as DI vs cluster config

Doc 22's `secretProvider` pattern (DI dependency per-package) vs `cluster.secrets.provider` (cluster-wide config). Both are useful — cluster-wide default is simpler for common case, DI override is more flexible. They should compose: cluster config sets the default, individual packages can accept a provider override via DI.
