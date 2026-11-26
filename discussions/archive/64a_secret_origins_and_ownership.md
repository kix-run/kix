# 64a: Where Secrets Come From — Origins, Ownership, and the API They Imply

**Status:** Draft
**Related:** `64_secret_management.md` (umbrella RFC), `22_secrets_di.md` (build-time DSL)

---

## 1. The Real Question

A K8s Secret is just a resource. Vault has paths and policies. An application has a credential it needs to boot. These are three completely different things wearing the same word.

Before designing an API, we need to catalog what actually exists. Every secret in a real cluster has an **origin** (who created the value), an **owner** (who decides when it changes), and **consumers** (who reads it). These three roles don't always live in the same place — and the mismatches are where all the complexity hides.

---

## 2. Taxonomy: Seven Kinds of Secret by Origin

Derived from the actual packages in kixpkgs today + common enterprise patterns.

### Kind 1: Application-internal credentials

**What:** Secrets an app creates for its own use. Encryption keys, CSRF tokens, session signing keys, admin bootstrap passwords.

**Real examples in kixpkgs:**
- firezone: `GUARDIAN_SECRET_KEY`, `SECRET_KEY_BASE`, `DATABASE_ENCRYPTION_KEY`, encryption/signing salts
- harbor: `secretKey`, `CSRF_KEY`, `CORE_SECRET`, `JOBSERVICE_SECRET`

**Origin:** The application itself — or more precisely, the first deploy. These values are random, generated once, and must persist across restarts but are never shared with other applications.

**Owner:** The application package. Nobody else cares about harbor's internal CSRF key. It exists solely because harbor needs it.

**Consumer:** Only the application that created it.

**The key property:** These secrets have no external meaning. They don't connect to any other system. They're the application's internal state that happens to be sensitive. If you regenerate them, the worst that happens is sessions get invalidated or data needs re-encryption.

**What kix should do:** Auto-generate these. The package declares "I need a 32-byte random key called CSRF_KEY" and kix produces it. No human ever sees or manages this value. The application owns it completely.

### Kind 2: Inter-service credentials (producer-created)

**What:** Credentials that one service creates and another consumes. The producer controls the lifecycle; the consumer just reads.

**Real examples in kixpkgs:**
- postgres credentials consumed by immich, n8n, metabase, harbor, firezone
- valkey/redis password consumed by n8n
- harbor's `REGISTRY_CREDENTIAL_PASSWORD` (core → registry communication)

**Origin:** The producing service (postgres) or its operator (StackGres controller). The credential is meaningful only in the context of the producer — a postgres password is useless without the postgres instance.

**Owner:** The producer. Postgres decides its own password rotation policy. The consumer has no say.

**Consumer:** One or more downstream applications, via DI.

**The key property:** There's a **tight coupling between the credential and the service it authenticates against**. The credential's lifecycle is bound to the producer's lifecycle. If you replace the postgres instance, you replace its credentials.

**Current kixpkgs pattern:** This is the biggest mess. Today:
- n8n expects `existingSecret` containing `DB_POSTGRESDB_PASSWORD` — but who creates that secret?
- metabase expects `existingSecret` with DB env vars — same question
- firezone uses `database.passwordSecretRef.name/.key` — points at a secret, but doesn't say who owns it
- harbor has `database.existingSecret` — optional, falls back to inline password in the Secret it creates

The pattern is: the consumer *points at* a secret by name string, and hopes it exists. The producer may or may not create it. The gap between producer and consumer is bridged by... convention. Or manual cluster configuration.

**What kix should do:** This is doc 22's core scenario. The producer exposes `out.credentials`, the consumer accesses it via DI. The secret resource is created by the producer, consumed by the consumer, and the DI graph is the access control. No name strings, no `existingSecret` options.

### Kind 3: External service credentials (operator-provided)

**What:** Credentials for services outside the cluster. Cloud APIs, SaaS tokens, third-party integrations.

**Real examples in kixpkgs:**
- external-dns: Cloudflare API key/token
- velero: S3 credentials for backup storage
- stackgres-cluster: S3 credentials for backup (`backup.s3.credentialsSecret`)
- tailscale: OAuth client secret

**Origin:** A human — someone goes to the Cloudflare dashboard, creates an API token, and copies it into the cluster. Or a cloud IAM policy generates a service account key.

**Owner:** The cluster operator / platform team. These credentials are cluster-level concerns. They pre-exist the applications that use them and outlive any single application's lifecycle.

**Consumer:** One or more applications that need to talk to the external service.

**The key property:** The value comes from outside the Kubernetes/kix world entirely. kix cannot generate it, rotate it, or validate it. It can only *receive* it and *distribute* it to consumers.

**Current kixpkgs pattern:**
- external-dns: `config.cloudflare.apiKey` / `config.cloudflare.apiToken` as Nix options → packaged into a Secret resource inline. The secret value is in the Nix evaluation. This is the antipattern.
- velero: `config.credentials.secretContents` — raw credential content in Nix config
- stackgres: `backup.s3.credentialsSecret` — references an existing Secret by name, better
- tailscale: `config.oauthSecretName` — references an existing Secret by name

**What kix should do:** These must never be in the Nix evaluation. The cluster definition says "there is a Cloudflare token secret with key `api-token`" — a reference, not a value. The value enters through SOPS, an external secret store, or manual `kubectl create secret`. kix tracks the shape and the reference; the value is someone else's problem.

### Kind 4: TLS certificates

**What:** X.509 certificates and their private keys.

**Real examples in kixpkgs:**
- harbor: token-service private key (mounted as file at `/etc/core/private_key.pem`)
- cert-manager-managed TLS secrets for ingress
- firezone: optional SAML certs

**Origin:** Depends on the certificate type:
- ACME/Let's Encrypt → cert-manager controller (fully automated)
- Internal CA → cert-manager with a self-signed or internal issuer
- Externally obtained → human buys a cert, imports it

**Owner:** For automated certs: the cert-manager controller. For manual certs: the platform team.

**Consumer:** Ingress controllers, application TLS endpoints, mutual TLS between services.

**The key property:** TLS certs are secrets with a *built-in expiry*. They rotate by necessity. The infrastructure for rotation (cert-manager, ACME) is well-established and largely orthogonal to application secret management.

**What kix should do:** For cert-manager-managed certs, `mkSecretRef` with `requires = [ self.certificate ]` (doc 22 §11.5). kix declares the shape (`tls.crt`, `tls.key`, `ca.crt`), cert-manager creates and rotates the actual Secret. kix never touches the value. For manually imported certs, same as Kind 3 — external credential, referenced not embedded.

### Kind 5: Synced/replicated secrets (external secret operator)

**What:** Secrets whose source of truth is an external system, synced into K8s by an operator.

**Real examples in kixpkgs:**
- Infisical operator in nw1 cluster → syncs to `"infisical-managed-secret"`
- shopfront/ledgerly reference `"infisical-managed-secret"` in their `backend.secrets`

**Origin:** The external secret store (Infisical, Vault, AWS SM, GCP SM). A human or automated process writes the value there. An operator (ESO, Infisical operator) watches and syncs to K8s Secrets.

**Owner:** Whoever manages the external store. This could be the app team (they set their own secrets in Infisical) or the platform team (they manage Vault policies).

**Consumer:** Applications, via `envFrom` or `secretKeyRef` on the synced K8s Secret.

**The key property:** The K8s Secret is a *cache* of the real secret. The source of truth is elsewhere. Rotation happens in the store; the operator propagates. The K8s Secret can be deleted and recreated without data loss.

**Current kixpkgs pattern:** Applications reference the synced secret by name string (`"infisical-managed-secret"`). kix has no visibility into what keys that secret contains or where it comes from. It's an opaque name.

**What kix should do:** `mkSecretRef` that declares the expected shape and the source:

```nix
scope.mkSecretRef {
  name = "infisical-managed-secret";
  keys = [ "DATABASE_URL" "API_KEY" "SMTP_PASSWORD" ];
  source.operator = "infisical";  # metadata for audit
  requires = [ instances.infisical-operator ];
};
```

The ref gives you `out.keyRef` with validation. The `source` metadata feeds into the access matrix. The `requires` ensures the operator is deployed before the consumer.

### Kind 6: Derived/computed credentials

**What:** Credentials derived from other values — connection strings built from host+port+password, JDBC URLs, composite tokens.

**Real examples in kixpkgs:**
- n8n's `DB_POSTGRESDB_HOST` + `DB_POSTGRESDB_PASSWORD` are separate env vars, but the *connection* is one logical credential
- harbor's database connection assembles host, port, username, password from multiple sources

**Origin:** Composition of other secrets + non-secret config. The password comes from a Secret, the host comes from a Service FQDN, the port from the service spec.

**Owner:** Nobody owns the composed value — it's derived. The constituent parts have their own owners (postgres owns the password, the Service owns the hostname).

**Consumer:** The application that needs the connection.

**The key property:** This isn't really a "secret" — it's a wiring concern that happens to include secret components. The `DATABASE_URL=postgres://user:$PASSWORD@host:5432/db` is partly secret (password), partly derived (host, port), partly static (schema, dbname).

**What kix should do:** This is connection wiring (compiler doc §4.1). The connection graph, when implemented, should handle this: the DI system knows immich connects to postgres, and can derive the full set of env vars (including the secret parts via `out.credentials.out.keyRef`). This is not a secret management concern — it's a wiring concern that *touches* secrets.

### Kind 7: Bootstrap/infrastructure secrets

**What:** Secrets that the cluster infrastructure itself needs before any application runs.

**Examples (not yet in kixpkgs but common):**
- etcd encryption key (encrypts secrets at rest in etcd)
- Cluster CA private key
- OIDC provider client secret for K8s API server authentication
- Cloud provider credentials for the CCM (cloud controller manager)
- Pull secrets for private container registries (`imagePullSecrets`)

**Origin:** Cluster provisioning — Terraform, kubeadm, cloud provider, or a human.

**Owner:** The cluster operator / infrastructure team. These pre-date kix entirely.

**Consumer:** Kubernetes components, not application workloads.

**The key property:** kix should not manage these. They exist before kix runs. kix may *reference* them (e.g., `imagePullSecrets` on a ServiceAccount) but should never create or rotate them.

**What kix should do:** `mkSecretRef` without a `requires` — the secret is expected to exist, kix doesn't deploy it. Optional pre-deploy verification ("does this secret exist in the cluster?").

---

## 3. The Ownership Matrix

| Kind | Who creates value | Who rotates | Who decides shape | Who consumes | kix role |
|------|------------------|-------------|------------------|-------------|----------|
| 1. App-internal | kix (auto-gen) | kix or app | Package | Same package | **Full ownership** — generate, store, rotate |
| 2. Inter-service | Producer pkg | Producer/operator | Producer package | Consumer packages via DI | **DI wiring** — producer exposes, consumer accesses |
| 3. External cred | Human/cloud | Human/cloud | Package (expected keys) | One or more packages | **Shape tracking** — reference, validate shape, never touch value |
| 4. TLS cert | cert-manager/human | cert-manager/human | Well-known (tls.crt, tls.key) | Ingress, apps | **Reference** — `mkSecretRef` with cert dependency |
| 5. Synced/external | External store | External store | Store schema | Packages | **Reference** — `mkSecretRef` with operator dependency |
| 6. Derived | Composition | N/A (components rotate) | Connection graph | Packages | **Wiring** — not a secret concern, it's a connection concern |
| 7. Bootstrap | Infra tooling | Infra team | K8s conventions | K8s components | **Hands off** — reference only, never create |

---

## 4. Where Should Secrets Live in kix's Architecture?

### 4.1 Instance-level vs module-level vs cluster-level

The ownership matrix answers this directly:

**Instance-level (on the package):**
- Kind 1 (app-internal): The package declares and owns it. `scope.mkSecret` inside the build function. No other instance cares.
- Kind 2 (inter-service): The producer instance creates it. `out.credentials` makes it available to consumers through DI.

**Cluster-level (module config):**
- Kind 3 (external creds): The cluster operator provides these. They belong in the cluster definition, not inside any package. A standalone secret instance (like `packages/secret` from doc 22) or a cluster-level `secrets` module option.
- Kind 7 (bootstrap): References to pre-existing secrets. Cluster config.

**Delegated (not in kix at all):**
- Kind 4 (TLS): cert-manager manages the lifecycle. kix just references.
- Kind 5 (synced): External operator manages sync. kix just references.
- Kind 6 (derived): Not a secret — it's wiring.

### 4.2 Should applications be able to manage their own secrets?

**Yes, for Kind 1.** Harbor needs a CSRF key. It should declare that need and kix should generate it. The package is the right owner because nobody else understands what `CSRF_KEY` means or what constraints it has (length, charset, algorithm).

**No, for Kind 3.** An application should never conjure a Cloudflare API token into existence. That's an external credential managed by a human or cloud IAM.

**Through DI, for Kind 2.** An application doesn't "manage" the postgres password — it receives it from postgres via DI. But the postgres *package* may manage its own password generation.

The current external-dns pattern (putting `config.cloudflare.apiKey` as a Nix option with the actual value) is wrong — it puts a Kind 3 secret into a Kind 1 slot. The value ends up in the Nix store. The fix: external-dns should take a secret *reference*, not a secret *value*.

### 4.3 Should secrets be centralized in the module system?

**No single centralized registry.** Different kinds of secrets have different owners. Centralizing them implies a single authority, which doesn't match reality.

**But:** The module system is the right place for *cluster-operator-provided* secrets (Kind 3, Kind 7). These are cross-cutting concerns that affect multiple packages. A `cluster.secrets` namespace in the module system makes sense for these:

```nix
# Cluster definition
{
  cluster.secrets.cloudflare-api = {
    keys = [ "api-token" ];
    # No value — just declares the secret's existence and shape
  };

  cluster.secrets.registry-pull = {
    keys = [ ".dockerconfigjson" ];
    type = "kubernetes.io/dockerconfigjson";
  };
}
```

Packages that need Cloudflare credentials resolve against this via DI — the same way they resolve against `ingressController` or `storageClasses` today.

### 4.4 The Infisical pattern: where does it fit?

Infisical (and ESO, Vault operator, etc.) is a *secret provider* — it converts secrets from an external store into K8s Secrets. The applications don't talk to Infisical directly; they consume the K8s Secret that Infisical syncs.

This creates a two-level dependency:
```
Application → K8s Secret (synced) → Infisical operator → External store
```

kix needs to model both edges:
1. Application → K8s Secret: `mkSecretRef` with shape validation
2. K8s Secret → Infisical operator: `requires` on the operator instance

The cluster definition wires the provider:
```nix
{
  infisical = { package = packages.infisical-operator; };

  shopfront-secrets = {
    package = packages.external-secret;  # thin wrapper
    config.store = instances.infisical;
    config.secretPath = "/shopfront/production";
    config.keys = [ "DATABASE_URL" "API_KEY" ];
  };

  shopfront = {
    package = packages.python-app;
    deps.secrets = instances.shopfront-secrets;
  };
}
```

This makes the synced secret a first-class instance in the DI graph, not an opaque name string.

---

## 5. What This Means for the API

Each kind of secret implies a different API surface:

| Kind | API | Lives in |
|------|-----|----------|
| 1. App-internal | `scope.mkSecret { keys; generate; }` | Package build function |
| 2. Inter-service | Producer: `scope.mkSecret` + `out.credentials`. Consumer: `deps.postgres.out.credentials.out.keyRef` | Producer package (create), consumer package (read via DI) |
| 3. External cred | `scope.mkSecretRef { name; keys; }` or cluster-level declaration | Cluster definition |
| 4. TLS cert | `scope.mkSecretRef { name; keys = ["tls.crt" "tls.key"]; requires = [...]; }` | Package that creates the Certificate CR |
| 5. Synced | `packages/external-secret` instance in cluster def, consumed via DI | Cluster definition (wiring), package (consumption via DI) |
| 6. Derived | Connection graph / wiring DSL (not a secret API) | N/A |
| 7. Bootstrap | `scope.mkSecretRef { name; keys; }` (no `requires`, pre-existing) | Cluster definition |

The unifying principle: **`mkSecret` for things kix creates. `mkSecretRef` for things that exist independently. DI for distribution.** Everything else (providers, rotation, audit) layers on top without changing the core API.

---

## 6. The Gaps That Hurt Today

Looking at the actual kixpkgs code:

1. **Values in Nix.** external-dns, velero, firezone all put secret values into Nix options. These end up in the Nix store, readable by anyone with store access. Every `config.cloudflare.apiKey = "sk-..."` is a security bug.

2. **Name-string references.** n8n's `existingSecret`, metabase's `existingSecret`, stackgres' `credentialsSecret` — all reference secrets by name with no shape validation, no dependency tracking, no way to know at build time if the secret exists or has the right keys.

3. **No producer-consumer wiring.** Postgres creates credentials. n8n needs postgres credentials. Today this is bridged by convention: someone creates a Secret with the right name and keys, and both sides hope it matches. The DI graph connects the *services* but not the *credentials*.

4. **Infisical as opaque magic.** shopfront lists `"infisical-managed-secret"` as a string. kix has zero visibility into what that secret contains, where it comes from, or whether the Infisical operator is even deployed. It's a hole in the dependency graph.

Fixing gaps 1-3 is doc 22. Fixing gap 4 requires `mkSecretRef` + an external-secret package pattern.

---

## 7. Open Questions

### 7.1 Should `generate` be a package concern or a provider concern?

Kind 1 secrets (app-internal) need generation. Who generates?
- **Package concern:** The package declares `generate.CSRF_KEY = { type = "random"; length = 32; }`. kix-deploy executes it.
- **Provider concern:** A secret provider generates all secrets, including app-internal ones. The package just declares keys.

If it's a package concern, the generation rules are in the Nix evaluation (good for validation) but kix-deploy must know how to execute them (coupling). If it's a provider concern, the generation is delegated (cleaner) but the provider needs to understand app-specific requirements (charset, length).

### 7.2 Can an application rotate its own secrets?

Kind 1 secrets (app-internal) — should the application be able to trigger "generate me a new CSRF_KEY"? This implies a runtime API (CRD? webhook? annotation change?) that kix or the operator responds to. For now, probably out of scope — rotation of app-internal secrets can be tied to redeployment.

### 7.3 How do multi-instance scenarios work?

If two postgres instances exist in a cluster (team A's and team B's), each has its own credentials. The DI graph handles this naturally (team A's immich gets team A's postgres credentials). But cluster-level secrets (Kind 3) are shared — there's one Cloudflare API token for the whole cluster. How does the module system distinguish "per-instance" from "cluster-wide"?

### 7.4 What about secrets that span Kind boundaries?

A database password might start as Kind 2 (postgres auto-generates it) but an enterprise mandates it be Kind 5 (stored in Vault, synced by ESO). The DI override pattern from doc 22 §4.3 handles this — you replace the auto-generated secret with a Vault-synced one. But the override needs to preserve the shape contract. This is the `secretProvider` DI pattern.
