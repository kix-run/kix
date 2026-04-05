# 75: Secrets — What Actually Matters

**Status:** Brainstorm
**Related:** `74_secrets.md` (full RFC), `29_compiler-design.md` (compiler model)

---

## The Blocker

Doc 74 is 400 lines covering seven origin types, four provider tiers, six concerns, CSI drivers, enterprise maturity models, and compliance exports. Meanwhile: zero packages in kixpkgs have proper secret wiring. Firezone stuffs 9 plaintext values into Nix. n8n hopes a magic-named secret exists. Shopfront points at an opaque Infisical string. The design is enormous and nothing shipped.

This document asks: what's the core insight that cuts through the noise, and what do we actually build?

---

## Why External Secret Tools Exist

The instinct that secrets are "blown out of proportion" is half right. The industry conflates two very different problems:

**Problem A: Where do secret values live?** This is storage — SOPS, Vault, 1Password, AWS Secrets Manager. A solved problem with many solutions. A SOPS flake with 30-day rotation is genuinely sufficient here for most teams.

**Problem B: How do services declare, share, and validate secret contracts?** This is wiring — which keys does postgres expose? Which does immich consume? Does a typo in a key name fail at build time or at 3am? When a credential rotates, which deployments need to restart?

Everyone designs from Problem A up: "let's integrate Vault!" But the actual day-to-day pain is Problem B. And nobody solves Problem B — not Vault, not ESO, not SOPS, not 1Password. They all store values. None of them model contracts.

### Why people reach for 1Password/Vault/Bitwarden integrations specifically

Three real gaps that SOPS doesn't cover:

1. **Dynamic team changes.** Adding/removing people from SOPS requires re-encrypting every file they had access to. In a growing team, this is constant friction. Vault/1Password handle membership changes instantly.

2. **Granularity.** SOPS is per-file. You can't say "Alice sees the DB password but not the Stripe key" if they're in the same file. One file per secret is possible but messy at scale.

3. **Audit of reads.** Git blame shows who changed ciphertext, but not who decrypted it. Vault logs every read. Compliance cares about reads, not just writes.

These are real. They matter at scale. But they're all Problem A concerns — they're about value management, not contract management.

---

## The Core Insight

**kix's unique value is Problem B, not Problem A.**

kix is the only tool that can say: "postgres declares keys `[user, pass, host, port]`, immich consumes `[pass, host]`, the contract is validated at compile time, rotation triggers redeployment of exactly the right dependents, and here's the full access matrix showing who reads what."

No secret store does this. Vault doesn't know that immich expects a key called `host` in the postgres credential. 1Password doesn't know that rotating the DB password should restart immich but not grafana. ESO syncs values but has zero visibility into consumer expectations.

This is the same pattern kix applies everywhere: the dependency graph IS the source of truth. Storage DI doesn't care whether you use Longhorn or Ceph — kix validates the contract (access modes, size) regardless. Secret DI shouldn't care whether you use SOPS or Vault — kix validates the contract (keys, shape, rotation policy) regardless.

### But: the design must scale into compliance

Getting the wiring right isn't enough if it paints us into a corner. The secret model must have hooks for:

- **Read audit.** When kix-deploy or the operator decrypts a secret, that's a loggable event. The build-time access matrix says who *can* read; runtime audit says who *did* read.
- **Rotation compliance.** The build declares `meta.rotationPolicy = "90d"`. A CI check or operator watch verifies the last rotation timestamp. Build warns, operator alerts.
- **Access control evolution.** Today: DI graph is the access boundary (compiler-enforced). Tomorrow: this maps to K8s RBAC, SOPS rules, or Vault policies. The graph is the single source of truth that generates backend-specific access rules.

The architecture decision: declare everything at compile time, enforce at runtime. The compiler doesn't need to implement rotation — it needs to emit rotation policy as metadata that a runtime system (operator, CI cron, external controller) can act on.

---

## The Vault vs 1Password Line — And Why It Matters

This distinction is the key to understanding the entire secret tool landscape:

**1Password / Bitwarden / SOPS = shared password stores.** They store a credential. Multiple consumers share it. If someone leaves the team, you can remove their access to the *store*, but the credential itself is unchanged. The database still accepts the old password. You must rotate manually, update all consumers manually, hope nothing breaks.

**Vault = per-identity ephemeral credentials.** Vault doesn't store a DB password — it has a root credential and *creates temporary postgres users on demand*. `svc_immich_a3f2` with a 24h TTL. When the lease expires, Vault runs `DROP USER`. Revoking access = drop the user, no cascade. No shared password ever exists.

This is the 80/20 line:
- **80% of the value:** a SOPS-managed credential with forced rotation on revocation. When someone leaves, rotate the secret → kix rebuilds → kix-deploy updates postgres AND all consumers via the dependency graph → rolling restart. The forced restart IS the revocation. This is strictly better than 1Password because the coordination is automated through the build.
- **20% of the value (Vault territory):** per-identity ephemeral credentials with zero-coordination revocation. No shared passwords at all. Requires deep service integration (Vault's database secrets engine knows how to CREATE/DROP postgres users). kix could offer this for common services (postgres, valkey) as an enhancement, but the compliance/audit overhead belongs to Vault.

### Why "SOPS + forced rotation" is the right MVP

1. **No external dependencies.** No Vault server to run, no cloud service to pay for. Git is the store.
2. **Content-addressable.** When a secret value changes, the ciphertext changes, the hash changes, dependents get new manifests. Rotation flows through the Merkle DAG naturally.
3. **Revocation is a rotation.** `kix secrets rotate --name db-creds` → regenerate → re-encrypt → commit → rebuild → deploy. The dependency graph handles the cascade to postgres AND all consumers. This is something 1Password/Bitwarden fundamentally cannot do.
4. **Reproducible.** Same repo state → same cluster state. No runtime fetches that might fail.
5. **Team-compatible.** `.sops.yaml` controls who can decrypt what. Age keys are easy to distribute.

The gaps (per-identity credentials, read audit, zero-coordination revocation) are real but they're the Vault 20%. A team that needs those has Vault — kix swaps the backend and keeps the contracts.

### Human database access without exposing secrets

The service password must never be shown to a human. When a developer needs to query the database:

- **Client certificates (mTLS):** Each developer gets a short-lived client cert from a kix-managed CA. Postgres authenticates via `pg_hba.conf` cert rules. Revoke = don't renew cert. The service uses password auth via a separate `pg_hba.conf` entry. No password ever exposed to humans.
- **kubectl exec into a debug pod:** The pod has credentials mounted. K8s RBAC controls who can exec. Revocation = remove RBAC binding. Risk: a sophisticated user could extract the password from the pod's environment/filesystem.
- **Future: per-identity DB users for common services.** For postgres and valkey specifically, kix could create ephemeral DB users (like Vault's dynamic secrets). This captures 80% of Vault's database secrets engine value for the most common services, without requiring Vault.

### Alternative: just expose secrets and rotate on offboarding

A simpler approach that's likely good enough for Sam and most small-to-medium teams: let authorized users see secrets directly, and rotate when someone leaves. This works because forced rotation through the dependency graph makes rotation cheap — which is the key insight.

- **`kix secrets show db-creds`** — decrypts and displays the secret if the user has the SOPS/age private key. The SOPS key distribution (`age` keys listed in `.sops.yaml`) IS the access control. Alice has a key → she can decrypt. She leaves → remove her key from `.sops.yaml`, rotate affected secrets.
- **`kubectl get secret` with RBAC** — K8s RBAC controls who can `kubectl get secret` in which namespace. kix can compile the RBAC rules from the DI graph (if you're in the team that owns the namespace, you can read its secrets). Offboarding = remove RBAC binding + rotate.
- **Rotation on offboarding is the whole revocation story.** `kix secrets rotate --name db-creds` → regenerate → re-encrypt → commit → rebuild → kix-deploy updates postgres AND all consumers. The dependency graph makes this a one-command operation. The reason people fear rotation is coordination — kix eliminates the coordination.

Key properties of this approach:
1. Secrets are accessible to authorized developers (via SOPS keys or K8s RBAC)
2. Offboarding is one command: rotate affected secrets, dependency graph handles cascade
3. No new infrastructure (no CA, no Vault, no sidecars)
4. Audit trail: git blame on SOPS files shows who changed what, `.sops.yaml` changes show access grants/revocations

Both approaches can coexist — mTLS for teams that want zero-exposure, direct access + rotate-on-offboarding for teams that want simplicity. The forced rotation path is the MVP; mTLS and ephemeral DB users are enhancements.

---

## What kix Should Actually Own

### Layer 1: Contract model (build-time, ships first)

The DI wiring for secrets. This is the thing nothing else provides.

- `scope.mkSecret { keys; generate?; meta?; }` — declares a secret with shape
- `scope.mkSecretRef { keys; requires?; }` — references an existing secret
- `secret.out.keyRef key` — compile-time validated reference
- `secret.out.mkEnv { ENV = "key"; }` — ergonomic env wiring
- DI: producer exposes `out.credentials`, consumer accesses via deps
- DI override: cluster operator can swap any secret via deps injection
- Build-time validation: typo in key name → build error, not runtime error
- Access matrix: derivable from the store DAG (`kix secrets access-matrix`)
- Metadata hooks: `meta.classification`, `meta.rotationPolicy` — declared now, enforced later

### Layer 2: Value backend — SOPS flake (ships with layer 1)

The default answer to "where do values live?"

- Encrypted values in a SOPS flake (separate repo or same repo, operator's choice)
- kix-deploy decrypts at apply time — only needs keys for secrets in the current diff
- `generate` rules for dev/ephemeral: kix-deploy creates random values on first apply
- Content-addressed: ciphertext change → manifest hash change → dependent redeployment
- Rotation = update the SOPS file + rebuild. The dependency graph handles cascade.

### Layer 3: Lifecycle enforcement (ships shortly after)

The runtime side — operator or CI enforcing what the compiler declared.

- Rotation check: `meta.rotationPolicy = "90d"` + last-rotation timestamp → warning/error in CI or operator alert
- Auto-rotation via CI cron: scheduled job that generates new values, encrypts with SOPS, commits, triggers rebuild
- Read audit: kix-deploy logs every secret decryption event (which secret, which deploy, which keys)
- `kix secrets rotate --name db-creds` CLI command for emergency rotation
- Scorecard rules: `secret-rotation-overdue`, `secret-no-env-critical`, `secret-unclassified`

### Layer 4: Backend swap (later, when customers need it)

When a team outgrows SOPS:

- `cluster.secrets.provider = "external-secrets"` → `scope.mkSecret` emits ExternalSecret CRs instead of K8s Secrets
- `cluster.secrets.provider = "csi"` → emit SecretProviderClass + CSI volume mounts
- Package code unchanged — the contract model is backend-agnostic by design
- The access matrix still works — it's derived from the DI graph, not the backend

---

## What We DON'T Build

- **A secret store.** kix is not Vault. Values live in SOPS/Vault/cloud KMS/whatever.
- **A key management system.** Age/GPG/KMS key distribution is the operator's problem.
- **Runtime secret injection sidecars.** That's Vault Agent / CSI driver territory.
- **Enterprise IAM integration.** Vault policies, GCP IAM, AWS IAM — these are backend concerns. kix models the contract; the backend enforces access.

---

## Answering the Original Questions

**Why are integrations to 1Password/Bitwarden useful at all?**
Honestly? They're mostly useful as password stores for humans, not for service-to-service credentials. They solve team access control (membership changes), granularity (per-key), and convenience (web UI for non-technical users). But they can't rotate a DB password and cascade the change to consumers — that's the critical gap. kix with SOPS + forced rotation is strictly better for service credentials because the dependency graph automates the coordination that 1Password leaves manual.

**Why is a SOPS flake with 30-day rotation not enough?**
It IS enough for values. It's not enough for wiring. The missing piece is: which packages need which keys, validated at compile time, with rotation flowing through the dependency graph. And crucially: `kix secrets rotate` doesn't just update SOPS — it updates postgres AND rebuilds all consumers in one pipeline run. That's the thing nobody else does.

**What about Sam's scenario (revocation on offboarding)?**
Break-glass via master key = trivial. Revoking a human's DB access: if humans never see the service password (kix manages it end-to-end), there's nothing to revoke for service credentials. For human DB access: client certificates (mTLS to postgres, short-lived, kix-managed CA) mean revocation = don't renew cert. No password rotation needed, no service disruption. For the long-term: per-identity ephemeral DB users for common services (postgres, valkey) captures 80% of Vault's value without running Vault.

**What's actually important day-to-day that should be easy and smooth?**
1. Adding a new secret to a package without touching any other package
2. Connecting a consumer to a producer's credentials through DI (not name strings)
3. Getting a build error when a key name is wrong (not a pod crash)
4. Seeing which deployments will restart when a secret rotates (the access matrix)
5. Auto-generating credentials for dev clusters without manual setup
6. Rotating a production credential with one command and knowing exactly what restarts
7. Offboarding a team member without manual secret rotation across services

---

## The "Just Build This" Plan

Ship layers 1+2+3 together. Don't iterate — the contract model without a value backend is useless (you can't test it), a value backend without contracts is just SOPS (already exists), and rotation without the dependency graph is just a cron job.

### The full MVP deliverables

**Build-time (Nix):**
1. **`scope.mkSecret` + `scope.mkSecretRef`** in `lib/k8s.nix` — contract primitives with shape, keys, metadata
2. **`packages/secret`** — thin wrapper for standalone secret instances
3. **`secret.out.*`** API — `keyRef`, `mkEnv`, `volume`, `envFrom`, `keys`
4. **Migrate existing packages** — fix firezone (9 plaintext values!), n8n, external-dns, velero, etc.
5. **Scorecard rules** — `secret-has-shape`, `secret-plaintext-in-nix`, `secret-rotation-overdue`

**Value backend (SOPS):**
6. **SOPS flake integration** — encrypted values in a separate flake or same repo
7. **kix-deploy SOPS decryption** — decrypt at apply time, only needs keys for secrets in the current diff
8. **`generate` for dev/ephemeral** — kix-deploy auto-creates random values on first apply

**Lifecycle (CLI + CI):**
9. **`kix secrets list`** — inventory all secrets in the cluster
10. **`kix secrets access-matrix`** — who reads what, derived from DI graph
11. **`kix secrets rotate --name X`** — regenerate → re-encrypt → commit → rebuild → deploy
12. **Rotation policy** — `meta.rotationPolicy = "90d"` → CI check warns/errors when overdue

**Future (documented, not built yet):**
- Per-identity ephemeral DB users for postgres/valkey (80% of Vault's database secrets engine)
- Client certificate auth for human DB access (mTLS via kix-managed CA)
- Backend swap to ESO/Vault/CSI via `cluster.secrets.provider`
- Read audit logging in kix-deploy/operator
