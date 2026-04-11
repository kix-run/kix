# 76: Secrets in kix — Design Doc

**Status:** Implemented (core primitives + package migration). SOPS CLI commands and deploy-time hydration are not yet implemented.
**Related:** `75_secrets_what_actually_matters.md` (strategic framing), `74_secrets.md` (full RFC), `29_compiler-design.md` (Merkle DAG)

---

## Context

Doc 75 establishes the strategic direction: kix's unique value is the secret **contract model** (shape, DI wiring, build-time validation), not the secret **value store**. SOPS is the default backend. This doc specifies how secrets work in the DSL, how values flow through the system, and how the design stays Vault-compatible.

---

## 1. Two Primitives: `mkSecret` and `mkSecretRef`

Secrets in kix use two scope functions that share the same `out` API but differ in ownership:

| | `scope.mkSecret` | `scope.mkSecretRef` |
|---|---|---|
| **Who creates the value** | kix (via SOPS) | External system (Vault, ESO, cert-manager, operator) |
| **Produces manifest** | Yes — K8s Secret with SOPS ciphertext | No — reference only (like `mkCRDRef`) |
| **Has source + hash** | Yes — content-addressed via ciphertext hash | No — values are runtime-only |
| **Store path** | Yes — participates in Merkle DAG | Yes — for dependency tracking |
| **Consumer API** | `out.keyRef`, `out.mkEnv`, `out.volume` | Identical |

### `scope.mkSecret`

Creates a kix-managed secret. The SOPS-encrypted values become part of the build, content-addressed via hash.

```nix
creds = scope.mkSecret {
  name = "db-credentials";
  keys = [ "username" "password" "host" "port" ];

  # SOPS file containing the encrypted values
  source = ./secrets/db-credentials.yaml;

  # Hash of the decrypted content — like fetchurl's sha256
  # Populated by: kix secrets generate db-credentials
  # Updated by:   kix secrets update-hash db-credentials
  hash = "sha256-Wq3YjKl...";

  # Optional metadata for scorecard/compliance
  meta.classification = "critical";
  meta.rotationPolicy = "90d";

  type = "Opaque";  # K8s secret type, default Opaque
};
```

**The hash model (like `fetchurl`):**
- `kix secrets generate <name>` creates the SOPS file + computes the hash. You commit both.
- `nix build` succeeds with just the hash — no decryption keys needed. The hash is part of the store path.
- `kix deploy` decrypts the SOPS file, hashes the plaintext, verifies it matches the declared hash. Mismatch → error.
- Rotation: update the SOPS file → `kix secrets update-hash <name>` → new hash → commit → rebuild → deploy. Dependents get new manifest hashes → redeployment.

**The manifest** in the Nix store:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: data
  annotations:
    kix.dev/secret-keys: "username,password,host,port"
    kix.dev/sops-source: "secrets/db-credentials.yaml"
    kix.dev/content-hash: "sha256-Wq3YjKl..."
type: Opaque
# No data/stringData — kix-deploy hydrates from SOPS at apply time
```

The content hash in the annotation is what makes dependents content-addressed. When the hash changes, the Secret's store path changes, and every resource that references it (via `out.keyRef`) gets a new dependency edge → new store path → redeployment.

### `scope.mkSecretRef`

References a secret that exists independently of kix. No manifest, no source, no hash. Used for Vault-managed secrets, cert-manager TLS, Infisical-synced secrets, bootstrap secrets.

```nix
# Vault-managed secret
creds = scope.mkSecretRef {
  name = "db-credentials";
  keys = [ "username" "password" "host" "port" ];
  requires = [ instances.vault-operator ];  # optional: deployment ordering
};

# cert-manager TLS secret (created as side effect of Certificate CR)
tlsSecret = scope.mkSecretRef {
  name = "${scope.instanceName}-tls";
  keys = [ "tls.crt" "tls.key" "ca.crt" ];
  requires = [ self.certificate ];
};

# Bootstrap secret (pre-existing, no requires)
pullSecret = scope.mkSecretRef {
  name = "registry-pull-secret";
  keys = [ ".dockerconfigjson" ];
  type = "kubernetes.io/dockerconfigjson";
};
```

Internally similar to `mkCRDRef` — creates a store path for dependency tracking and an `out` API, but emits no deployable manifest. `kix deploy` can optionally verify the Secret exists in the cluster before deploying dependents.

---

## 2. The `out` API

Both `mkSecret` and `mkSecretRef` return a resource with the same enriched `out`:

```nix
secret.out.name              # → "db-credentials" (string with store context)
secret.out.keys              # → [ "username" "password" "host" "port" ]
secret.out.type              # → "Opaque"

# Reference builders — produce K8s-native structures

secret.out.keyRef "password"
# → { valueFrom.secretKeyRef = { name = "db-credentials"; key = "password"; }; }

secret.out.envFrom
# → { secretRef = { name = "db-credentials"; }; }

secret.out.volume "db-creds-vol"
# → { name = "db-creds-vol"; secret = { secretName = "db-credentials"; }; }

secret.out.mkEnv {
  DB_PASSWORD = "password";
  DB_USER     = "username";
  DB_HOST     = "host";
}
# → [
#   { name = "DB_PASSWORD"; valueFrom.secretKeyRef = { name = "db-credentials"; key = "password"; }; }
#   { name = "DB_USER";     valueFrom.secretKeyRef = { name = "db-credentials"; key = "username"; }; }
#   { name = "DB_HOST";     valueFrom.secretKeyRef = { name = "db-credentials"; key = "host"; }; }
# ]
```

### Build-time key validation

`keyRef` and `mkEnv` validate that requested keys exist in the declared `keys` list:

```nix
secret.out.keyRef "nonexistent"
# → error: secret "db-credentials" does not declare key "nonexistent"
#   declared keys: username, password, host, port
```

Catches typos at `nix build`, not at pod startup.

### String context

All string references carry Nix string context (via `attachCtx`), so using `out.keyRef` in a container spec automatically creates a dependency edge to the Secret's store path. No manual `requires` needed — same as how `storage.out.name` works today.

---

## 3. Declaration Patterns

### 3.1 Inline: producer creates its own secret

The package creates a secret internally and exposes it via `out`. This is the pattern for Kind 1 (app-internal) and Kind 2 (inter-service) secrets.

```nix
# packages/postgres/default.nix
{ meta, options, deps, build }:

meta = {
  provides = [ "postgres" ];
};

deps = {
  credentials = { optional = true; };
  storage = {};
};

build = { self, config, scope, credentials ? null, storage, ... }:
let
  creds = if credentials != null
    then credentials
    else scope.mkSecret {
      name = "${scope.instanceName}-credentials";
      keys = [ "username" "password" "host" "port" ];
      source = ./secrets/${scope.instanceName}-credentials.yaml;
      hash = "sha256-...";
    };
in {
  statefulset = scope.mkStatefulSet {
    name = scope.instanceName;
    spec.template.spec.containers = [{
      name = "postgres";
      image = config.image;
      env =
        (creds.out.mkEnv {
          POSTGRES_PASSWORD = "password";
          POSTGRES_USER = "username";
        });
    }];
  };

  service = self.statefulset
    |> kix.service.fromWorkload { port = 5432; }
    |> scope.mkResource;

  root = self.service;

  # Expose for consumers
  out.credentials = creds;
};
```

### 3.2 Standalone: cluster-level secret instance

For secrets that no package produces — API keys, external credentials, shared tokens. Uses `packages/secret` as a thin wrapper (analogous to `packages/persistent-volume-claim`).

```nix
# packages/secret/default.nix
{ meta, options, build }:

meta = {
  version = "1.0.0";
  description = "Standalone secret instance";
  provides = [ "secret" ];
};

options = {
  keys = lib.mkOption { type = lib.types.listOf lib.types.str; };
  source = lib.mkOption { type = lib.types.path; };
  hash = lib.mkOption { type = lib.types.str; };
  type = lib.mkOption { type = lib.types.str; default = "Opaque"; };
  meta = lib.mkOption { type = lib.types.attrs; default = {}; };
};

build = { self, config, scope, ... }:
let
  secret = scope.mkSecret {
    name = scope.instanceName;
    inherit (config) keys source hash type meta;
  };
in {
  root = secret;
  out = secret.out;
};
```

Cluster definition:

```nix
instances.cloudflare-api = {
  package = packages.secret;
  config = {
    keys = [ "api-token" ];
    source = ./secrets/cloudflare-api.yaml;
    hash = "sha256-...";
  };
};

instances.external-dns = {
  package = packages.external-dns;
  deps.apiSecret = instances.cloudflare-api;
};
```

### 3.3 Reference: externally-managed secret

For Vault/ESO/Infisical/cert-manager secrets. Uses `packages/secret-ref` or inline `mkSecretRef`.

```nix
# packages/secret-ref/default.nix
{ meta, options, build }:

meta = {
  version = "1.0.0";
  description = "Reference to an externally-managed secret";
  provides = [ "secret" ];
};

options = {
  keys = lib.mkOption { type = lib.types.listOf lib.types.str; };
  type = lib.mkOption { type = lib.types.str; default = "Opaque"; };
};

build = { self, config, scope, ... }:
let
  ref = scope.mkSecretRef {
    name = scope.instanceName;
    inherit (config) keys type;
  };
in {
  root = ref;
  out = ref.out;
};
```

Cluster definition:

```nix
# Infisical-managed secret — replaces opaque "infisical-managed-secret" string
instances.shopfront-secrets = {
  package = packages.secret-ref;
  config.keys = [ "DATABASE_URL" "API_KEY" "SMTP_PASSWORD" ];
  deps.requires = [ instances.infisical-operator ];
};

instances.shopfront = {
  package = packages.python-app;
  deps.secrets = instances.shopfront-secrets;
};
```

---

## 4. Consumer Patterns

Consumers access secrets identically regardless of whether the secret is kix-managed (mkSecret) or external (mkSecretRef).

### 4.1 Environment variables (most common)

```nix
# Single key
env = [
  (creds.out.keyRef "password" // { name = "DB_PASSWORD"; })
];

# Multiple keys (ergonomic)
env = creds.out.mkEnv {
  DB_PASSWORD = "password";
  DB_USER = "username";
  DB_HOST = "host";
};

# All keys as env vars
envFrom = [ creds.out.envFrom ];
```

### 4.2 Volume mounts

```nix
# Mount entire secret as a directory
volumes = [ (creds.out.volume "db-creds-vol") ];
volumeMounts = [{ name = "db-creds-vol"; mountPath = "/etc/db-creds"; readOnly = true; }];

# Or via kix.mount helper (if we add one)
# kix.mount.secret creds { mountPath = "/etc/db-creds"; }
```

### 4.3 DI chain: consumer → producer → secret

```nix
# immich consumes postgres credentials through DI
# packages/immich/default.nix
build = { self, config, scope, postgres, ... }:
{
  deployment = scope.mkDeployment {
    name = scope.instanceName;
    spec.template.spec.containers = [{
      name = "immich";
      image = config.image;
      env = postgres.out.credentials.out.mkEnv {
        DB_PASSWORD = "password";
        DB_USER = "username";
        DB_HOST = "host";
        DB_PORT = "port";
      };
    }];
  };
};
```

Immich doesn't know or care whether postgres auto-generated credentials (mkSecret) or received them via DI override (mkSecretRef pointing at Vault). The contract is the same: keys `[username, password, host, port]`.

---

## 5. The Value Flow

```
 Developer workflow                         Build                          Deploy
┌─────────────────────┐    ┌──────────────────────────┐    ┌─────────────────────────┐
│                     │    │                          │    │                         │
│ kix secrets generate│    │  nix build               │    │  kix deploy             │
│   → SOPS file       │───▶│   → reads hash only     │───▶│   → reads SOPS file     │
│   → hash in .nix    │    │   → hash in store path  │    │   → decrypts            │
│   → commit both     │    │   → no decryption keys  │    │   → verifies hash       │
│                     │    │   → manifest with hash   │    │   → hydrates Secret     │
│ kix secrets rotate  │    │     annotation           │    │   → applies to cluster  │
│   → new SOPS file   │    │                          │    │                         │
│   → new hash        │    │  dependents get new      │    │  rolling restart of     │
│   → commit          │    │  store paths (content-   │    │  consumers that         │
│   → triggers rebuild│    │  addressed via hash)     │    │  reference the secret   │
│                     │    │                          │    │                         │
└─────────────────────┘    └──────────────────────────┘    └─────────────────────────┘
```

### Hash verification at deploy time

```
kix deploy reads Secret manifest:
  → finds kix.dev/sops-source annotation → locates SOPS file
  → finds kix.dev/content-hash annotation → expected hash
  → decrypts SOPS file → computes actual hash
  → if match: populate stringData, apply Secret
  → if mismatch: ERROR "secret db-credentials has changed,
                        run `kix secrets update-hash db-credentials`"
```

This is the `fetchurl` pattern applied to secrets: the hash is the contract between build and deploy. If someone rotates a secret outside the build pipeline, the deploy catches it.

### Content-addressing through the DAG

```
Secret "db-credentials"
  store path: /nix/store/abc123-db-credentials (hash includes content-hash annotation)
     │
     ├─ referenced by postgres StatefulSet (via creds.out.keyRef in env)
     │    store path: /nix/store/def456-postgres (hash includes abc123 dependency)
     │
     └─ referenced by immich Deployment (via postgres.out.credentials.out.keyRef)
          store path: /nix/store/ghi789-immich (hash includes abc123 transitively)
```

Changing the secret hash → new Secret store path → new postgres store path → new immich store path → all three get redeployed. The Merkle DAG propagates changes automatically.

---

## 6. CLI Commands

### `kix secrets generate <name>`

Creates a new secret: generates random values (or prompts for external values), encrypts with SOPS, outputs the hash for the Nix expression.

```bash
$ kix secrets generate db-credentials --keys username,password,host,port \
    --generate password:random:32 \
    --generate username:fixed:postgres \
    --set host:postgres.data.svc \
    --set port:5432

Created: secrets/db-credentials.yaml (SOPS encrypted)
Hash:    sha256-Wq3YjKl...

Add to your mkSecret call:
  source = ./secrets/db-credentials.yaml;
  hash = "sha256-Wq3YjKl...";
```

### `kix secrets update-hash <name>`

Re-computes the hash after a SOPS file has been modified (rotation, manual edit).

```bash
$ kix secrets update-hash db-credentials
Old hash: sha256-Wq3YjKl...
New hash: sha256-Xr4ZkLm...

Updated: packages/postgres/default.nix:14
  hash = "sha256-Xr4ZkLm...";
```

### `kix secrets rotate <name>`

Generates new values, encrypts, updates hash, all in one step. Equivalent to generate + update-hash for an existing secret.

```bash
$ kix secrets rotate db-credentials --regenerate password
Rotated: secrets/db-credentials.yaml
New hash: sha256-Yp5AlNn...

Updated: packages/postgres/default.nix:14
  hash = "sha256-Yp5AlNn...";

Affected resources (will redeploy on next kix deploy):
  - postgres/statefulset (env: POSTGRES_PASSWORD)
  - immich/deployment (env: DB_PASSWORD, DB_USER, DB_HOST, DB_PORT)
```

### `kix secrets show <name>`

Decrypts and displays a secret (requires SOPS/age key).

```bash
$ kix secrets show db-credentials
Secret: db-credentials
Source: secrets/db-credentials.yaml
Hash:   sha256-Wq3YjKl...

Keys:
  username = postgres
  password = Kj8#mP2...
  host     = postgres.data.svc
  port     = 5432
```

### `kix secrets list`

Lists all secrets in the cluster build.

```bash
$ kix secrets list
NAME              TYPE        KEYS                        SOURCE                    CLASSIFICATION
db-credentials    mkSecret    username,password,host,port  secrets/db-creds.yaml     critical
api-key           mkSecret    token                        secrets/api-key.yaml      -
infisical-creds   mkSecretRef DATABASE_URL,API_KEY         (external: infisical)     -
tls-cert          mkSecretRef tls.crt,tls.key              (external: cert-manager)  -
```

### `kix secrets access-matrix`

Shows which resources consume which secrets, derived from the DI graph.

```bash
$ kix secrets access-matrix
SECRET              ACCESSED BY              MECHANISM
db-credentials      postgres/statefulset     env: POSTGRES_PASSWORD, POSTGRES_USER
db-credentials      immich/deployment        env: DB_PASSWORD, DB_USER, DB_HOST, DB_PORT
api-key             external-dns/deployment  env: CLOUDFLARE_API_TOKEN
infisical-creds     shopfront/deployment       envFrom (all keys)
```

---

## 7. Good Practices

### DO: producer exposes, consumer accesses via DI

```nix
# Producer
out.credentials = creds;

# Consumer
env = postgres.out.credentials.out.mkEnv { DB_PASS = "password"; };
```

### DO: use mkSecretRef for anything kix doesn't create

```nix
# cert-manager TLS, Infisical-synced, pre-existing bootstrap secrets
scope.mkSecretRef { name = "..."; keys = [ ... ]; }
```

### DO: declare all keys, even if you only consume some

```nix
# Postgres secret has 4 keys, immich uses 3 — declare all 4 on the producer
scope.mkSecret { keys = [ "username" "password" "host" "port" ]; ... }

# Consumer picks what it needs
postgres.out.credentials.out.mkEnv { DB_PASS = "password"; DB_HOST = "host"; }
```

### DON'T: put secret values in Nix config options

```nix
# BAD — value ends up in Nix store
config.cloudflare.apiKey = "sk-abc123...";

# GOOD — reference via DI
deps.apiSecret = instances.cloudflare-api;  # a packages/secret instance
```

### DON'T: reference secrets by name string

```nix
# BAD — opaque, no validation, no dependency tracking
envFrom = [{ secretRef.name = "infisical-managed-secret"; }];

# GOOD — validated keys, dependency tracking, access matrix
envFrom = [ deps.secrets.out.envFrom ];
```

### DON'T: create secrets at deploy time (generators)

```nix
# BAD — breaks reproducibility, not content-addressed
scope.mkSecret { generate.password = { random = 32; }; }

# GOOD — generate once, commit the encrypted result
# $ kix secrets generate db-creds --generate password:random:32
scope.mkSecret { source = ./secrets/db-creds.yaml; hash = "sha256-..."; }
```

---

## 8. Vault Compatibility Path

The design is Vault-compatible without any changes to the consumer-side API:

| Concern | SOPS (default) | Vault (future) |
|---------|---------------|----------------|
| Secret creation | `mkSecret` + SOPS file | `mkSecretRef` + ESO/Vault operator |
| Value storage | SOPS-encrypted in git | Vault KV store |
| Deploy-time hydration | kix-deploy decrypts SOPS | ESO controller syncs from Vault |
| Content-addressing | Hash of ciphertext | N/A (runtime-only, no build-time hash) |
| Rotation | `kix secrets rotate` → new SOPS → commit → rebuild | Vault auto-rotates → ESO re-syncs → pod restart via annotation |
| Consumer code | `creds.out.keyRef "pass"` | Identical |

Switching from SOPS to Vault for a specific secret = replace the `mkSecret` instance with a `mkSecretRef` instance in the cluster definition. Consumer packages unchanged.

```nix
# Before (SOPS)
instances.db-creds = {
  package = packages.secret;
  config = { keys = [...]; source = ...; hash = ...; };
};

# After (Vault)
instances.db-creds = {
  package = packages.secret-ref;
  config.keys = [...];
  deps.requires = [ instances.vault-operator ];
};

# Consumer: unchanged
instances.postgres.deps.credentials = instances.db-creds;
```

---

## 9. Implementation in `lib/k8s.nix`

`scope.mkSecret` is a new scope function (like `scope.mkDeployment`) that internally calls `mkResource` and enriches the `out`:

```nix
# Sketch — actual implementation will be in lib/k8s.nix or lib/secret.nix
mkSecret = { name, keys, source ? null, hash ? null, type ? "Opaque", meta ? {}, ... }:
let
  # Build the secret-specific out helpers
  secretOut = {
    inherit keys type;

    keyRef = key:
      assert builtins.elem key keys
        || throw "secret \"${name}\" does not declare key \"${key}\"\n  declared keys: ${builtins.concatStringsSep ", " keys}";
      { valueFrom.secretKeyRef = { name = attachCtx name; inherit key; }; };

    mkEnv = mapping:
      lib.mapAttrsToList (envName: secretKey:
        (secretOut.keyRef secretKey) // { name = envName; }
      ) mapping;

    envFrom = { secretRef = { name = attachCtx name; }; };

    volume = volName: {
      name = volName;
      secret = { secretName = attachCtx name; };
    };
  };

  # The underlying K8s Secret resource (if kix-managed)
  resource = scopeMkResource {
    apiVersion = "v1";
    kind = "Secret";
    inherit name type;
    metadata.annotations = {
      "kix.dev/secret-keys" = builtins.concatStringsSep "," keys;
    }
    // lib.optionalAttrs (source != null) {
      "kix.dev/sops-source" = toString source;
    }
    // lib.optionalAttrs (hash != null) {
      "kix.dev/content-hash" = hash;
    }
    // lib.optionalAttrs (meta ? classification) {
      "kix.dev/classification" = meta.classification;
    }
    // lib.optionalAttrs (meta ? rotationPolicy) {
      "kix.dev/rotation-policy" = meta.rotationPolicy;
    };
    # No data/stringData — kix-deploy hydrates from SOPS
    outputs = {};  # suppress default outputs, we override below
  };
in
  resource // { out = resource.out // secretOut; };

# mkSecretRef — like mkCRDRef, store path but no manifest
mkSecretRef = { name, keys, type ? "Opaque", requires ? [], ... }:
let
  secretOut = { /* same keyRef, mkEnv, envFrom, volume helpers */ };
  refPath = builtins.toFile "secret-ref-${name}" (builtins.toJSON { inherit name keys type; });
in {
  _type = "secret-ref";
  outPath = refPath;
  inherit requires;
  out = { name = attachCtx name; inherit keys type; } // secretOut;
};
```

---

## 10. Open Questions

### 10.1 Source path resolution

`source = ./secrets/db-creds.yaml` is a Nix path — it gets copied to the Nix store. The SOPS file content becomes part of the store path hash (good for content-addressing). But `kix deploy` needs to find the original SOPS file to decrypt it (the store copy is read-only). Options:
- kix-deploy reads from the store path (SOPS can decrypt from any path)
- kix-deploy resolves back to the original path via an annotation
- The source annotation is the relative repo path, kix-deploy finds it from the repo root

### 10.2 Hash of what exactly?

The hash could be:
- Hash of the decrypted plaintext values (strongest verification, requires decryption to compute)
- Hash of the encrypted SOPS file (no decryption needed to compute, but doesn't verify content)
- Hash of the SOPS file is implicit via Nix store path (if `source` is a Nix path, Nix hashes the file content automatically)

If `source` is a Nix path, Nix's own content-addressing may be sufficient — changing the SOPS file changes the store path automatically. The explicit `hash` field might only be needed for the deploy-time verification step ("did someone modify the SOPS file after the last build?").

### 10.3 Cross-namespace secrets

K8s Secrets are namespace-scoped. When two consumers in different namespaces need the same secret, the current proposal (doc 74) suggests `mirrorOf` for build-time duplication. With the hash model, both mirrors would share the same source + hash, so kix-deploy hydrates both from the same SOPS file.

### 10.4 How should postgres "pipe through" received credentials?

The current pattern (`credentials ? null`, create own if null) works but has a question: if postgres receives external credentials, should it still declare the `host` and `port` keys (which it knows from its own service), or does the external credential already include those? This is a contract evolution question — the DI override must match the shape contract.

### 10.5 `extraHashes` — pinning secrets from the outside

A package like postgres creates its own `mkSecret` with a `hash`. But the cluster operator may want to pin or override that hash without modifying the postgres package. This is important for rotation workflows: the SOPS file changes, the hash changes, but you update the hash in the cluster definition, not in `packages/postgres/default.nix`.

Options:
- `extraHashes` on the instance config: a list of `{ name = "db-creds"; hash = "sha256-..."; }` that overrides the package-declared hash at the cluster level
- Hash as a module option: `instances.postgres.secrets.db-credentials.hash = "sha256-..."` overrides the inline hash
- Hash as DI: the `credentials` dep carries the hash, and the producer's `mkSecret` reads it from the dep if provided (circular? maybe not if the hash is on the dep's config, not its out)

The simplest approach: `mkSecret` accepts `hash` as an optional parameter, and the cluster definition can inject it via a config option on the package. The package declares `options.credentialHash` (with no default), the cluster sets it, the build reads `config.credentialHash` into `mkSecret { hash = config.credentialHash; }`. This keeps the package pure and the hash externally controllable.

Alternatively, `scope.mkSecret` could look up hashes from a cluster-level registry (`clusterConfig.secrets.hashes.${name}`) as a fallback when no `hash` is passed inline. This would let operators pin any secret's hash from the cluster definition without any package changes.

### 10.6 Integration with `kix.mount` helpers

`kix.mount.pvc` exists for storage. Should we add `kix.mount.secret` for the volume mount pattern? This would handle volumes + volumeMounts together, matching the PVC ergonomics.
