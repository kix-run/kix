# 77: Secrets Implementation — SOPS Deploy-time Hydration

**Status:** In Progress — implementation-only doc. The design docs below are archived but **still carry open questions**.

## Secrets design corpus (archived, open questions remain)

The first SOPS flow is shipping against the minimum viable design. The broader secrets story is not closed; each archived doc has unresolved items that should be consulted before expanding scope:

- **`archive/74_secrets.md`** — Unified RFC: seven origin types, DI model, six concerns, provider tiers. *Open:* origin taxonomy vs. what we actually ship; whether tiering survives contact with real consumers.
- **`archive/75_secrets_what_actually_matters.md`** — Cuts 74 down to Problem A (values) vs. Problem B (contracts). *Open:* whether SOPS-default / ship-contracts-with-values holds once a second provider lands.
- **`archive/76_secrets_design.md`** — Concrete API (`mkSecret`, `mkSecretRef`, `out.keyRef`, DI override, CLI). *Open:* cross-namespace refs (see 78), DI override ergonomics, hash-verification failure UX.
- **`archive/77_secret_access_control_modules.md`** — Module-system layer over SOPS (teams/keys/rules, `.sops.yaml` generation, rekey workflow, severity-tiered diff/deploy gates). *Open:* whether this lives in kix or a sibling tool; revocation safety.
- **`archive/78_cross_namespace_secret_refs.md`** — `mkSecretRef` cross-namespace consumption can't be copy-on-build and drifts on copy-on-deploy. *Open:* capability-driven resolution (operator-native / CSI / reflector / static-copy), compile-time error as default.

If you extend secrets work beyond the deploy-time hydration scope below, start by re-reading the relevant archived doc — the design is not actually settled.

---

## Scope

Ship the first working end-to-end secrets flow:
1. Deploy-time SOPS decryption in the Rust CLI (`kix deploy`)
2. Integration test: deploy a cluster with secrets to kind, verify a pod can read them

## What's Already Done

- `scope.mkSecret` and `scope.mkSecretRef` primitives (lib/k8s.nix, lib/eval/scope.nix)
- `packages/secret` and `packages/secret-ref` wrappers
- Secret `out` API (keyRef, mkEnv, envFrom, volume) with build-time key validation
- kix.dev/sops-source and kix.dev/content-hash annotations on Secret manifests

## What We Build Now

### 1. Deploy-time Secret Hydration (Rust)

In `cli/kix/src/cluster/`, add a `secrets` module:
- **Before apply_wave**: scan manifests for Secrets with `kix.dev/sops-source`
- **Hydrate**: shell out to `sops --decrypt <path>` to get plaintext YAML
- **Verify hash**: if `kix.dev/content-hash` annotation exists, compute SHA-256 of sorted plaintext, verify match
- **Inject**: populate `stringData` in the manifest JSON before applying

The flow hooks into `reconcile.rs` — before each wave, hydrate any Secrets in that wave.

### 2. SOPS Tooling in devenv

Add `sops` and `age` to devenv.nix packages.

### 3. Test Cluster with Secrets

Create `clusters/test-secrets.nix`:
- A postgres-like app that reads credentials from a Secret via env vars
- A standalone `packages/secret` instance with SOPS source
- Verification: pod starts, reads env vars correctly

### 4. Integration Test Script

`tests/secrets-integration.sh`:
1. Generate age keypair
2. Create SOPS-encrypted secret file
3. Create kind cluster
4. `kix deploy` the test-secrets cluster
5. Verify with kubectl that the Secret has correct data
6. Port-forward and query the app to verify env vars are set
7. Cleanup

## Design Decisions

- **Shell out to sops**: No Rust SOPS library is mature. Shelling out to `sops --decrypt` is reliable and matches what users have installed.
- **Hash verification**: SHA-256 of the canonical JSON of the decrypted SOPS data (sorted keys). Optional — if no `kix.dev/content-hash`, skip verification.
- **Age keys**: Use `SOPS_AGE_KEY_FILE` env var (standard SOPS convention). Default to `~/.config/sops/age/keys.txt`.
- **Error handling**: If SOPS decryption fails, abort deploy with clear error. If hash mismatch, abort with message to run `kix secrets update-hash`.

## Files to Create/Modify

### New files:
- `cli/kix/src/cluster/secrets.rs` — SOPS hydration logic
- `clusters/test-secrets.nix` — test cluster definition
- `tests/secrets-integration.sh` — end-to-end test

### Modified files:
- `cli/kix/src/cluster/mod.rs` — add `pub mod secrets;`
- `cli/kix/src/cluster/reconcile.rs` — call secrets hydration before apply
- `devenv.nix` — add sops, age
- `clusters/flake.nix` — add test-secrets cluster
- `ROADMAP.md` — mark SOPS integration items

---

## Pre-deploy decryptability assertion (design note — v2_discussions/105 §B6)

**Risk:** today, SOPS hydration runs lazily in `cli/kix/src/cluster/scheduler.rs`
(see `secrets::hydrate_secrets` invoked per-wave around line 822). A missing
or wrong age key surfaces only when the *first wave that contains a secret*
schedules — by which point earlier waves have already applied. The deploy
ends in a half-applied state and the operator gets a per-wave error rather
than an upfront "you cannot decrypt your own cluster".

**Proposed gate:** at the start of `kix deploy`, before any apply, walk every
SOPS-encrypted secret referenced in the activation closure and attempt
decryption with the operator's configured age key. If any fail, abort with a
single structured error listing every failure (path, namespace, instance,
SOPS error message). No wave runs.

**Hooks:**
- New function `secrets::assert_all_decryptable(manifests)` in
  `cli/kix/src/cluster/secrets.rs`. Reuses `needs_hydration` to filter
  candidates, calls `decrypt_sops` on each, but discards the plaintext —
  this is purely a probe. Aggregates `SecretError`s into a single
  `DecryptabilityReport`.
- Call site in `cli/kix-cli/src/commands/deploy.rs::run_deploy_async`
  (around the existing pre-flight checks; before scheduler construction).
  On failure, render a structured diagnostic via the same channel as
  scorecard findings (see v2_discussions/80 §5a) so `kix deploy --dry-run`
  surfaces the same error.
- The SOPS source paths are already available without hydration — they're
  literal `/nix/store/...` paths in the `kix.dev/sops-source` annotation,
  so the pre-flight only needs the manifest list, not a kubectl round-trip.

**Severity & escape hatch:** structured error, blocks deploy. A
`--skip-decryptability-check` flag on `kix deploy` is the deliberate escape
hatch (rebuild-from-zero scenarios where the operator is intentionally
deploying a cluster definition whose secrets they can't decrypt — rare
enough to require a flag, never a default).

**What this does NOT cover:** secret *contents* (wrong password, expired
token). That's a runtime concern. This gate only proves "the operator
running `kix deploy` can produce plaintext for every encrypted secret in
the closure" — which is the smallest bar that keeps deploys from wedging
mid-wave on a key mismatch.

**Open:** how this composes with the multi-team key-split scenario
(archived `77_secret_access_control_modules.md` and doc 104). For the
single-operator case the gate is unambiguous; multi-team needs to decide
whether the deploying operator must be able to decrypt *every* secret or
only the ones they're meant to rotate.
