# 64: Secret Management — Concerns, Built-In Capabilities, and Enterprise Expectations

**Status:** Draft
**Related:** `22_secrets_di.md` (build-time shape & DI), `54_activation_signing.md` (supply chain signing), `47_air_gapped_deploys.md` (transport), `45_multi_team_and_operator_models.md` (multi-team trust), `29_compiler-design.md` (Merkle DAG properties)

---

## 1. Why Secrets Deserve Their Own RFC

Doc 22 designs the build-time DSL — `mkSecret`, `mkSecretRef`, shape validation, DI wiring. That's the *definition and consumption* concern: how packages declare, reference, and type-check secrets at build time.

But "secret management" is a bundle of at least six distinct concerns, and enterprises evaluate all of them. An incomplete story on any one is a blocker for adoption. This RFC maps the full territory, identifies which concerns kix addresses structurally, which it delegates, and which need new design work.

---

## 2. The Six Concerns

| # | Concern | Question it answers | Who cares most |
|---|---------|-------------------|----------------|
| 1 | **Definition & shape** | "What keys does this secret have?" | App developer |
| 2 | **Injection** | "How does the secret value reach the container?" | App developer, platform engineer |
| 3 | **Provisioning & storage** | "Where do secret values come from and where do they live at rest?" | Platform engineer, security team |
| 4 | **Rotation & lifecycle** | "How are secrets renewed, and what happens when they change?" | Security team, SRE |
| 5 | **Access control & audit** | "Who can read/write which secrets, and is there a trail?" | Security team, compliance |
| 6 | **Transport & zero-trust** | "How do secrets move between environments without exposure?" | Security team, compliance |

These concerns are orthogonal — you can have excellent shape validation (#1) with terrible rotation (#4), or strong audit (#5) with no automation (#4). Enterprises expect a coherent story across all six. The rest of this RFC works through each.

---

## 3. Concern 1: Definition & Shape

**Status:** Designed in doc 22, not yet implemented.

This is the build-time contract: a secret declares its keys, and consumers reference them with compile-time validation. `mkSecret` creates the resource, `out.keyRef` produces typed references, `mkSecretRef` handles externally-managed secrets.

### What enterprises expect

- **Schema enforcement.** "Every secret must declare its keys" — no dangling `secretKeyRef` strings. kix gets this for free if packages use `mkSecret`/`mkSecretRef`. Helm imports are the gap — `fromHelmChart` produces resources with string-level secret references that bypass `out.keyRef` validation.
- **Secret inventory.** "Show me every secret in the cluster." The store DAG makes this a traversal: walk all resources, filter for `kind: Secret` and `kind: ExternalSecret`. The CLI can expose this as `kix secrets list`.
- **Classification.** Not all secrets are equal. A database password is sensitive; an API endpoint URL in a secret is merely private. Enterprises want metadata: `classification = "critical" | "sensitive" | "internal"`. This flows naturally into scorecard rules (doc 60) — a `critical` secret without rotation policy triggers a finding.

### Design note: classification as metadata

```nix
scope.mkSecret {
  name = "db-credentials";
  keys = [ "username" "password" ];
  meta.classification = "critical";  # feeds scorecard rules
  meta.rotationPolicy = "90d";       # declares intent, enforced by concern 4
};
```

Classification is *declared* at definition time but *consumed* by rotation, audit, and compliance systems. It's metadata on the secret resource, not a separate system.

---

## 4. Concern 2: Injection

**Status:** Designed in doc 22 (`keyRef`, `envFrom`, `volume`, `mkEnv`).

Injection is the mechanical question: how does the secret value reach the running container? The three K8s-native mechanisms are:

1. **Environment variables** via `secretKeyRef` — most common, simplest, but values visible in `kubectl describe pod` and process listings
2. **Volume mounts** — files at a path, supports hot-reload (kubelet updates mounted secrets), more secure than env vars
3. **CSI driver** (secrets-store-csi-driver) — mounts secrets directly from an external store (Vault, AWS Secrets Manager) without a K8s Secret resource existing at all

### What enterprises expect

- **Env vars for convenience, volumes for security.** Many enterprises mandate volume mounts for sensitive secrets and reserve env vars for non-sensitive config. kix's `out.keyRef` and `out.volume` support both — but there's no enforcement mechanism. A scorecard rule could check: "critical-classified secrets must not be injected via env vars."
- **CSI driver integration.** Enterprises using Vault or cloud KMS often use the Secrets Store CSI Driver to avoid K8s Secret resources entirely. The secret value never hits etcd. kix would need a `mkCSISecretMount` or a provider abstraction that swaps the injection mechanism based on cluster config.

### Design note: injection as a provider concern

The injection mechanism should be orthogonal to the secret definition. A package declares "I need key `password` from secret `db-credentials`" — *how* that value reaches the container depends on the cluster's secret provider:

```
                              ┌─ K8s-native: mkSecret → secretKeyRef/volume mount
definition ─→ injection ─────┤─ ESO: ExternalSecret → K8s Secret → secretKeyRef
                              └─ CSI: SecretProviderClass → CSI volume mount
```

This parallels the `secretProvider` pattern from doc 22 §7.2. The package code is the same regardless of backend. The cluster config selects the provider.

---

## 5. Concern 3: Provisioning & Storage

**Status:** Partially sketched in doc 22 §9 (hydration model). Needs concrete design.

This is the hardest concern: where do secret *values* come from, and where do they live at rest?

### The landscape

| Approach | Values come from | Values stored in | Who manages lifecycle |
|----------|-----------------|-----------------|----------------------|
| **Manual** | Human enters in kubectl/console | etcd (K8s Secret) | Human |
| **Git-encrypted** (SOPS, sealed-secrets, agenix) | Encrypted in repo | Git + etcd | Human + CI |
| **External store** (Vault, AWS SM, GCP SM, Azure KV) | External API | External store + etcd (via ESO) | External system |
| **Auto-generated** (kix-deploy `generate`) | Generated at deploy time | etcd (+ backup?) | kix |
| **Cert-manager** (TLS) | ACME protocol | etcd (K8s Secret) | cert-manager controller |
| **Operator-managed** (e.g. StackGres creates pg credentials) | Operator logic | etcd (K8s Secret) | Operator |

kix doesn't need to *be* all of these. It needs to *integrate with* all of them and provide sane defaults for the simple cases.

### Tier model

Following the DI pattern, provisioning can be tiered:

**Tier 0: kix-native (default).** For dev clusters and simple production. `mkSecret` with `generate` rules. kix-deploy creates the secret on first deploy, stores values in etcd. No external dependencies.

**Tier 1: Git-encrypted.** For production clusters that want secrets in version control. Values encrypted with SOPS/agenix, committed to the repo (or a data flake). kix-deploy decrypts at apply time. The Nix eval sees ciphertext, never plaintext.

**Tier 2: External secret store.** For enterprises with existing Vault/cloud KMS infrastructure. kix emits ExternalSecret CRs (via ESO) instead of K8s Secrets. The secret value never touches the kix pipeline — ESO syncs it from the store at runtime.

**Tier 3: CSI-direct.** For zero-trust environments. No K8s Secret resource at all. The secrets-store-csi-driver mounts values directly from the external store into the pod filesystem. The secret value never touches etcd.

### The key insight: tiers are cluster config, not package config

A package always says:
```nix
creds = scope.mkSecret { name = "db-creds"; keys = [ "password" ]; };
```

The cluster determines what that *means*:

```nix
# Tier 0: kix-native (default — no config needed)

# Tier 1: git-encrypted
cluster.secrets.provider = "sops";
cluster.secrets.sopsConfig = ./sops.yaml;

# Tier 2: external store
cluster.secrets.provider = "external-secrets";
cluster.secrets.externalSecrets.store = instances.vault-backend;

# Tier 3: CSI direct
cluster.secrets.provider = "csi";
cluster.secrets.csi.providerClass = instances.vault-csi;
```

The `scope.mkSecret` implementation checks `clusterConfig.secrets.provider` and emits the right resource type. Packages are unchanged.

### Open question: Tier 0 value persistence

Doc 22 §9.2 raises this: when `generate` creates a random password on first deploy, where does that value live? If etcd is the only store and the cluster is rebuilt, the password is lost. Options:

1. **Accept it** — Tier 0 is for dev/ephemeral clusters where this is fine
2. **Encrypt-and-commit** — kix-deploy generates the value, encrypts it, commits back to the repo. Now it's Tier 1. Requires write access to the repo from the deploy pipeline.
3. **Backup to data flake** — similar to (2) but writes to a separate secrets flake
4. **Seed-based determinism** — `generate` uses a master seed (from a single root secret in git) to derive all generated values deterministically. Same seed → same passwords. Root secret rotation cascades all derived values.

Option 4 is the most interesting. A single root secret (encrypted in git) deterministically derives all generated credentials. This gives content-addressability (same inputs → same outputs), reproducibility across rebuilds, and a single secret to manage. The trade-off: compromise of the root secret compromises everything derived from it.

---

## 6. Concern 4: Rotation & Lifecycle

**Status:** Not designed.

### Why rotation matters more than people think

Rotation isn't just a compliance checkbox. It limits the window of exposure: if a credential leaks, it's only valid until the next rotation. Without rotation, a leaked credential is valid forever.

### The three rotation models

**Model A: External rotation.** The secret store (Vault, AWS SM) rotates values on its own schedule. ESO syncs the new value to K8s. kix is not involved — it just consumes whatever ESO provides.

**Model B: Build-triggered rotation.** A new build includes updated ciphertext (someone rotated the SOPS-encrypted value). The content hash changes → the Secret resource hash changes → dependent Deployments get new hashes → redeployment. This is doc 22's content-addressed rotation. It works but is manual — someone has to update the encrypted value.

**Model C: Automated rotation.** kix-deploy (or a kix controller) rotates secrets on a schedule, re-encrypts, and triggers a new build/deploy cycle. This is the "auto-management" item on the roadmap.

### What enterprises expect

- **Rotation policy declaration.** "This secret rotates every 90 days." Declared on the secret definition, enforced by the platform.
- **Rotation without downtime.** Dual-credential patterns: the old and new credential are both valid during a transition window. The app reads the new one; the old one is revoked after the window closes. This requires application-level support (read from a file that gets updated, not an env var that's fixed at startup).
- **Rotation audit.** "When was this secret last rotated? By whom?" Ties into concern 5.
- **Forced rotation on incident.** "Rotate all secrets in namespace X immediately." A CLI command (`kix secrets rotate --namespace X`) that triggers emergency rotation.

### Design note: rotation policy as metadata

```nix
scope.mkSecret {
  name = "db-credentials";
  keys = [ "username" "password" ];
  meta.rotationPolicy = {
    maxAge = "90d";         # rotate every 90 days
    gracePeriod = "24h";    # old value valid for 24h after rotation
    strategy = "dual-cred"; # or "in-place" or "rolling"
  };
};
```

For Tier 2/3 (external stores), the rotation policy maps to the store's native rotation config (Vault dynamic secrets, AWS SM rotation lambdas). For Tier 0/1, kix-deploy implements rotation.

### Interaction with content-addressing

Doc 22 §11.2 asks whether secrets should be identity-addressed (stable name) or content-addressed (name changes on value change). For rotation, this matters:

- **Volume-mounted secrets:** kubelet auto-refreshes mounted secrets. Identity-addressed works — the Secret name stays the same, the content updates, kubelet propagates. No pod restart needed.
- **Env-var secrets:** values are fixed at container start. Rotation requires a pod restart. Content-addressing forces this naturally (new hash → new Deployment hash → rolling update). Identity-addressing misses it — the Secret updates but pods keep the old value.

**Recommendation:** Default to identity-addressed (doc 22's recommendation), but add a `restartOnRotation = true` flag that makes the Secret's content hash part of the Deployment's annotation (like Helm's `checksum/secret`). This gives the best of both: stable names for volume mounts, forced restarts for env vars.

---

## 7. Concern 5: Access Control & Audit

**Status:** Not designed. This is the #1 enterprise concern.

### The layers

| Layer | Controls | Mechanism |
|-------|----------|-----------|
| **Build-time** | Which packages can reference which secrets | DI graph — if a secret isn't in your deps, you can't access it |
| **Git-time** | Who can modify encrypted secret values | SOPS access rules, git branch protection, CODEOWNERS |
| **Deploy-time** | Who can decrypt and apply secrets | kix-deploy RBAC, deploy keys, signing (doc 54) |
| **Runtime** | Which pods can read which K8s Secrets | K8s RBAC (ServiceAccount → Role → RoleBinding), NetworkPolicy for external stores |

### What kix provides structurally

**Build-time access control via DI is already strong.** If immich depends on postgres, it gets `postgres.out.credentials`. It cannot access `grafana.out.apiKey` unless grafana is in its dependency graph. This is a compiler-enforced access boundary — you can't reference a secret you don't depend on. No other K8s tooling provides this.

**The RBAC DSL (doc 29 §3.4) can enforce runtime access.** If a package declares `rbac.read` on a secret, the compiler emits the matching Role/RoleBinding. The compiler could also *verify* that no package reads a secret it doesn't own — a cross-reference check: "Deployment X has `secretKeyRef` to Secret Y, but X's ServiceAccount has no RBAC permission for Secret Y."

### What enterprises expect beyond this

- **Audit trail.** "Who changed secret X, when, and what was the old value?" For git-encrypted secrets, this is git history. For external stores, this is the store's audit log. For kix-native secrets, kix-deploy needs to log rotation events.
- **Break-glass procedures.** "I need to read a production secret value in an emergency." This is operational tooling — `kix secrets show --secret db-creds --namespace prod` that decrypts and displays a value, with mandatory audit logging. Dangerous by design — it should require MFA or approval.
- **Least privilege for deploy pipeline.** The CI pipeline shouldn't need access to every secret — only the ones in the diff. Doc 22 §9.1 mentions this: "if a deploy only touches app resources and no secret ciphertext changed, the deployer doesn't need decryption keys for any secret." This is a powerful property. Enterprise security teams will love it because it minimizes blast radius of a compromised CI pipeline.
- **Secret sprawl detection.** "How many secrets exist in the cluster? Which ones are unused? Which ones haven't been rotated in 180 days?" This is a reporting/compliance concern. The secret inventory (concern 1) combined with rotation metadata (concern 4) feeds this.

### Design note: the DI graph as an access control matrix

The dependency graph implicitly encodes who can access what:

```
immich ──deps──→ postgres ──out.credentials──→ db-credentials (Secret)
grafana ──deps──→ grafana-api-key (Secret)
```

This is an access control matrix — but it's currently implicit. Making it explicit:

```bash
$ kix secrets access-matrix
SECRET              ACCESSED BY           MECHANISM
db-credentials      immich/deployment     env: DB_PASSWORD, DB_USER
db-credentials      postgres/statefulset  env: POSTGRES_PASSWORD
grafana-api-key     grafana/deployment    volume: /etc/grafana/api-key
```

This is derivable from the store DAG + resource inspection. No new design needed — just a CLI query.

---

## 8. Concern 6: Transport & Zero-Trust

**Status:** Partially addressed by doc 47 (air-gapped), doc 54 (signing).

Transport is: how do secrets move between the origin (where they're created/stored) and the destination (the pod)?

### The threat model

| Threat | Description | Mitigation |
|--------|-------------|------------|
| **At rest in git** | Encrypted values in the repo | SOPS/agenix encryption, key management |
| **At rest in etcd** | K8s Secrets are base64, not encrypted by default | etcd encryption at rest (K8s feature), or avoid etcd entirely (CSI) |
| **In transit: CI → cluster** | Secret values flow from decrypt → kubectl apply | TLS (kubectl always uses TLS), or avoid transit entirely (ESO/CSI) |
| **In transit: store → pod** | External store → ESO → K8s Secret → kubelet → pod | Mutual TLS, short-lived tokens, pod identity |
| **In memory** | Secret visible in container's /proc/environ or memory | Process isolation, no env var injection for critical secrets |

### What enterprises expect

- **End-to-end encryption.** The secret value is encrypted from origin to destination. Only the consuming process can decrypt. This is the CSI + Vault Agent model — Vault encrypts, the sidecar in the pod decrypts. kix can't provide this natively, but it can integrate by emitting the right CSI / sidecar config.
- **No secrets in CI logs.** Build pipelines should never print secret values. Since kix evals never contain plaintext values (doc 22 §2.4), this is structurally guaranteed for the build phase. Deploy-time logging needs care.
- **Secret scanning in git.** Pre-commit hooks that detect accidentally committed plaintext secrets. Not kix-specific, but kix could provide a `kix lint` check that scans the repo for patterns that look like plaintext secrets in Nix files.
- **Network segmentation.** The secret store is only reachable from specific nodes/namespaces. This ties into NetworkPolicy derivation (doc 37) — if a pod uses ESO, it needs egress to the secret store.

### Air-gapped environments (doc 47 extension)

Air-gapped clusters complicate external secret stores — Vault might be inside the air gap, but cloud KMS isn't. kix's tier model handles this: air-gapped clusters use Tier 0 (kix-native) or Tier 1 (git-encrypted) since there's no external store to reach. The `cluster.secrets.provider` config makes this a cluster-level decision.

---

## 9. Enterprise Maturity Model

Enterprises don't adopt all six concerns at once. There's a natural progression:

### Level 1: "We have secrets, they work" (most teams today)

- Secrets as K8s Secrets, manually created or in Helm values
- No rotation, no audit, no access control beyond K8s RBAC
- **kix equivalent:** Tier 0 with `mkSecret` + `generate`. Already better than manual because of shape validation and DI wiring.

### Level 2: "Secrets are in version control" (security-aware teams)

- SOPS or sealed-secrets for encryption at rest
- Git history as audit trail
- Rotation is manual but tracked
- **kix equivalent:** Tier 1 with git-encrypted values. Content-addressed rotation via build pipeline.

### Level 3: "Secrets come from a central store" (enterprise standard)

- Vault, AWS SM, or cloud KMS as source of truth
- ESO syncs to K8s
- Automatic rotation via store policies
- RBAC on the store controls who can read/write
- **kix equivalent:** Tier 2 with ExternalSecret emission. Rotation policy declared in kix, enforced by the store.

### Level 4: "Zero-trust secrets" (regulated industries, finance, healthcare)

- No K8s Secret resources at all — CSI direct mount
- Mutual TLS between pod and secret store
- Hardware security modules (HSMs) for key storage
- Real-time audit logging with SIEM integration
- Break-glass procedures with multi-party approval
- **kix equivalent:** Tier 3 with CSI provider. Audit integration via compliance exports (doc 61).

### What kix should ship first

Level 1-2 out of the box. Level 3-4 via provider integration. The scorecard (doc 60) tells you where you are and what's missing. A scorecard rule like "no secrets without rotation policy" nudges teams from Level 1 to Level 2.

---

## 10. The Scorecard Connection

The scorecard rules system (doc 60, `lib/rules/`) is the natural enforcement point. Secret-specific rules:

| Rule | Level | Severity |
|------|-------|----------|
| `secret-has-shape` | Manifest | Warning — secrets without declared keys can't be validated |
| `secret-has-classification` | Manifest | Info — unclassified secrets can't be prioritized |
| `secret-no-env-critical` | Manifest | Error — critical secrets must not be injected via env vars |
| `secret-rotation-policy` | Manifest | Warning — secrets without rotation policy are unbounded |
| `secret-rotation-compliance` | Cluster | Error — secrets past their rotation deadline |
| `secret-access-least-privilege` | Package | Warning — pod has RBAC for secrets it doesn't reference |
| `secret-no-plaintext-in-nix` | Package | Error — detected plaintext secret patterns in Nix source |
| `secret-provider-tier` | Cluster | Info — cluster uses Tier 0 (kix-native) for production |
| `namespace-secret-sprawl` | Namespace | Warning — namespace has >N secrets (configurable threshold) |

These rules compose with the existing severity-per-scope model: production namespaces escalate `secret-rotation-policy` to Error, dev namespaces keep it as Info.

---

## 11. Multi-Team Secret Boundaries

From doc 45, multi-team setups create trust boundaries around secrets:

### Shared monorepo (doc 45 §2a)

All teams can technically see all encrypted secret ciphertext in git. Access control is via SOPS rules: team A's secrets are encrypted to team A's key. Team B can see the ciphertext but can't decrypt.

The DI graph prevents cross-team secret *consumption* at build time. Team B's package can't reference team A's secret unless there's a dependency edge.

### Federated flakes (doc 45 §2b)

Each team's secrets live in their own repo. The cluster flake imports team flakes but doesn't have their decryption keys. kix-deploy needs per-team keys (or team-specific deploy pipelines that handle their own secrets).

### Independent activations (doc 45 §2c)

Complete isolation — each team's secrets are in their own activation. The operator validates per-namespace signing keys (doc 54). No cross-team secret visibility.

### Enterprise expectation: namespace-scoped secret visibility

"Team A should not be able to `kubectl get secret` in team B's namespace." This is standard K8s RBAC — not kix-specific. But kix can *verify* the RBAC is correct: "does team A's ServiceAccount have any RBAC bindings that grant secret access in team B's namespace?" This is a whole-cluster analysis pass (compiler pass 5 from doc 29).

---

## 12. Implementation Roadmap

### Phase 1: Build-time foundation (near-term)

Implement doc 22. This gives us `mkSecret`, `mkSecretRef`, shape validation, DI wiring, and the `out` API. Packages can declare and consume secrets with compile-time safety.

Add `meta.classification` and `meta.rotationPolicy` as metadata fields (no enforcement yet — just declaration).

Add basic scorecard rules: `secret-has-shape`, `secret-has-classification`.

### Phase 2: Provider abstraction (medium-term)

Implement `cluster.secrets.provider` with Tier 0 (kix-native) and Tier 1 (SOPS) backends. `scope.mkSecret` checks the provider and emits the right resource.

Add `kix secrets list` and `kix secrets access-matrix` CLI commands.

Implement `restartOnRotation` annotation for env-var-based secrets.

### Phase 3: External store integration (medium-term)

Tier 2: ESO integration. `scope.mkSecret` emits `ExternalSecret` CRs when the provider is `external-secrets`. The package API is unchanged.

Add scorecard rules: `secret-rotation-policy`, `secret-no-env-critical`, `secret-provider-tier`.

### Phase 4: Enterprise features (longer-term)

Tier 3: CSI integration for zero-trust environments.

Automated rotation via kix-deploy or a dedicated controller.

Compliance export extensions (doc 61): secret inventory as part of SBOM, rotation compliance as part of OSCAL assessment.

`kix secrets rotate` emergency rotation command.

Break-glass `kix secrets show` with audit logging.

---

## 13. Architectural Principle: kix Is Not a Secret Store

kix is a compiler. It knows the *shape* of secrets (keys, classification, rotation policy, access graph), but it never stores or manages secret *values* at the build layer. Values are always handled by a provider — even the simplest provider (Tier 0 kix-native) is a deploy-time concern, not a build-time concern.

This separation is what makes the tier model work. The compiler output is the same regardless of whether the secret value comes from `generate`, SOPS, Vault, or an HSM. The store DAG, dependency tracking, scorecard rules, and access matrix all work on the *shape* — which is available at build time — without ever touching the *value*.

This is also why kix can safely emit secrets into the Nix store. The store path contains the Secret manifest with shape metadata and annotations, but no `data` or `stringData` field. The manifest is a *declaration of intent* ("I need a secret with these keys"), not a *container of values*.

---

## 14. Real-World Signal: Sam / Satchel (GKE Startup)

From the Sam interview (`interviews/sam-satchel.md`): Satchel is a GKE-based startup using Terraform, Firebase, and Google Workspace groups. His perspective highlights several secret management concerns from the "pragmatic startup CTO" angle:

### 14.1 Google Workspace groups as secret access control

Sam uses Google Workspace groups for org-wide role management — database access, service account impersonation, the works. This is a common pattern in Google Cloud shops: IAM bindings reference Workspace groups, and secret access flows through the same groups.

**Implication for kix:** In Tier 2/3, the secret store (GCP Secret Manager) has its own IAM. kix doesn't manage cloud IAM — that's Terraform's job (or Pulumi's, or gcloud's). But kix should *declare the expectation*: "this secret comes from GCP Secret Manager, and access requires the `secretmanager.secretAccessor` role on service account X." This declaration feeds into the access matrix (§7) and can be verified: "does the pod's GCP service account (via Workload Identity) actually have access to this secret?"

### 14.2 Environment management and secret separation

Sam has dev and prod environments with shared modules (submodules in Terraform). Secrets must differ across environments — prod has real credentials, dev has generated/test ones.

**Implication for kix:** The tier model (§5) handles this naturally. Dev clusters use Tier 0 (auto-generated), prod clusters use Tier 2 (GCP Secret Manager). The package code is identical — only `cluster.secrets.provider` differs. This is the same pattern as `cluster.registryMirror` for air-gapped (doc 47): environment-level config, not package-level code.

```nix
# clusters/dev/default.nix
{ cluster.secrets.provider = "kix-native"; }  # auto-generate everything

# clusters/prod/default.nix
{ cluster.secrets.provider = "external-secrets";
  cluster.secrets.externalSecrets.store = instances.gcp-secret-manager; }
```

### 14.3 CI/CD plan/apply flow for secrets

Sam's workflow: PR triggers plan (diff), manual accept, then apply. For secrets, the "plan" step raises the question: what does a secret diff look like?

- **Shape changes** (new key added): visible in the diff, reviewable
- **Value changes** (rotation): depends on tier. Tier 1 (SOPS): ciphertext change visible. Tier 2: ExternalSecret CR unchanged — the diff shows nothing because the value is external. Tier 0: `generate` rules are deterministic, so the diff shows nothing unless the rule changed.

This connects to open question §15.3. The plan/apply workflow needs a clear story for "what changed about secrets in this PR."

### 14.4 Emergency access / business continuity

Sam has emergency accounts ("if I die, TK can access everything"). This is the break-glass concern from §7. For a startup, this means: someone who isn't the usual operator must be able to decrypt and apply secrets. The SOPS key or Vault root token needs to be in a safe (literal or figurative) that the emergency contact can access.

**Implication for kix:** The break-glass procedure (`kix secrets show`) needs to be documented as part of disaster recovery. For Tier 1 (SOPS), this means documenting which keys can decrypt and where recovery keys are stored. For Tier 2 (external store), this means the store's own break-glass procedure. kix can generate a "secret recovery runbook" as part of compliance exports (doc 61).

---

## 15. Open Questions

### 15.1 Provider selection granularity

Should the provider be cluster-wide (`cluster.secrets.provider`) or per-secret? A cluster might use Vault for database credentials but SOPS for API keys. Per-secret is more flexible but adds complexity.

**Leaning:** Cluster-wide default with per-secret override:
```nix
cluster.secrets.provider = "external-secrets";  # default
scope.mkSecret { name = "api-key"; provider = "sops"; };  # override
```

### 15.2 How to handle Helm chart secrets

Helm charts imported via `fromHelmChart` create K8s Secrets that bypass `mkSecret`. These secrets don't have shape declarations, classification, or rotation policies. Options:
- Wrap them post-import with `mkSecretRef`
- Scan Helm output for Secrets and auto-generate shape declarations
- Accept them as unmanaged (scorecard warning)

### 15.3 Secret value diffing

`kix-diff` compares manifests. If a Secret's shape changes (new key added), the diff should show it. But if only the *value* changes (rotation), the diff depends on the tier: Tier 1 (SOPS) shows ciphertext change, Tier 2/3 shows no change (the ExternalSecret CR is the same, the value is external). Is this confusing?

### 15.4 Interaction with `kix.mkLocked` (doc 42)

If a platform team locks a secret provider (`cluster.secrets.provider = kix.mkLocked "external-secrets"`), should packages be able to override with `provider = "sops"` per-secret? The lock should probably apply to the cluster default, not prevent per-secret overrides. But this needs thought.

### 15.5 Seed-based deterministic generation

If we go with option 4 from §5 (seed-based determinism for Tier 0), the root seed becomes the most critical secret in the system. How is the root seed itself managed? Turtles all the way down — the root seed must be provisioned manually or via an external store, making Tier 0 not fully self-contained.

### 15.6 Secret expiry as a build-time signal

If `meta.rotationPolicy.maxAge = "90d"` and the last rotation was 91 days ago, should the build *fail*? This requires the build to know when the last rotation happened — which is deploy-time state leaking into build time. The alternative: a CI check (`kix secrets check-rotation`) that runs alongside the build but is not part of it.

### 15.7 Provider as DI

The `secretProvider` pattern from doc 22 §7.2 makes the provider a DI dependency. The `cluster.secrets.provider` approach makes it cluster config. These are different mechanisms — should they unify? The DI approach is more flexible (different packages can use different providers naturally), but the cluster config approach is simpler for the common case.
