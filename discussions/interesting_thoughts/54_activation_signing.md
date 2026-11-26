# 54 — Cryptographic Activation Signing

**Status:** Design exploration
**Related:** `29_compiler-design.md` (section 8: Merkle DAG as compiler IR), `46_thin_operator_production_plan.md` (operator trust model), `45_multi_team_and_operator_models.md` (multi-team trust boundaries)

---

## 1. The Insight

The kix build produces a content-addressed Merkle DAG rooted at the activation. The root hash transitively covers every resource in the cluster — changing any child changes the root. This is the same structural property that makes Git commit signing work: sign the root, verify the tree.

If we sign the activation root hash, the operator can verify that an entire cluster state was produced by an authorized build pipeline. One signature covers every resource, every dependency, the full transitive closure. This is unusually cheap compared to per-artifact signing schemes (cosign, Notary) because the Merkle structure does the fan-out for free.

---

## 2. What Problem This Solves

**Provenance enforcement.** RBAC controls *who can talk to the API server*. Signing controls *what content the operator will accept*. These are orthogonal:

| Mechanism | Question it answers |
|---|---|
| RBAC / kubectl credentials | "Is this user allowed to apply resources?" |
| Activation signing | "Was this manifest produced by an authorized build pipeline?" |

RBAC cannot distinguish between a legitimate `kubectl apply` from CI and a hand-edited manifest applied by someone with valid credentials. Signing can. The operator becomes a gatekeeper that enforces: only content that passed through the build pipeline reaches the cluster.

**Supply chain verification.** Every deployed manifest is cryptographically traceable to a specific build. "What was deployed at time T?" is not just "activation hash X" (which is already true) but "activation hash X, signed by key Y, which traces to CI run Z." The Merkle structure means tampering with any resource invalidates the root signature.

---

## 3. How It Works

### 3.1 Build-time: Sign the activation

The CI pipeline (or local build, for dev clusters) builds the cluster, producing an activation root with a content hash. The build step signs this hash:

```
activation-hash := H(activation content including all child hashes)
signature := Sign(private-key, activation-hash)
```

The signature is attached to the activation CR as an annotation or dedicated field:

```yaml
apiVersion: kix.dev/v1alpha1
kind: Activation
metadata:
  name: cluster-nw1
  annotations:
    kix.dev/signature: "base64-encoded-signature"
    kix.dev/key-id: "ci-pipeline-2026"
spec:
  # ... normal activation spec
```

### 3.2 Deploy-time: Operator verifies

The kix operator, configured with the corresponding public key (or shared secret), verifies the signature before processing an activation:

1. Compute the expected content hash from the activation's spec
2. Verify the signature against the hash using the configured key
3. If verification fails: reject the activation, emit an event explaining why
4. If verification succeeds: proceed with normal deployment

Because the activation hash transitively covers all children, verifying the root is sufficient. The operator does not need to verify each resource individually — the Merkle property guarantees that if the root hash is correct, every child is correct.

### 3.3 Runtime: Drift detection with teeth

Currently kix-diff can detect drift (live state vs built state) by comparing content hashes. With signing, drift detection becomes *enforceable*: a resource whose content doesn't match its expected hash (derived from the signed activation) is provably unauthorized. The operator could optionally reconcile drifted resources back to the signed state.

---

## 4. Symmetric vs Asymmetric Keys

### Symmetric (shared secret)

- Simpler to set up: one key, shared between build and operator
- Sufficient for single-team, single-cluster setups
- **Weakness:** the operator holds the signing key, so a compromised operator can forge signatures
- Good enough for: homelabs, dev clusters, single-team production

### Asymmetric (public/private key pair)

- CI holds the private key, operator only has the public key
- Operator can verify but never forge — strictly better trust model
- **Critical for multi-team:** Team A's operator has Team A's public key. Even if Team B compromises their own operator, they can't forge activations for Team A's namespace.
- Standard pattern: this is exactly how code signing, TLS, and JWT work

**Recommendation:** Start with asymmetric. It's not meaningfully harder to implement and the trust model is correct from day one. Use Ed25519 — small keys, small signatures, fast verification, no configuration pitfalls.

---

## 5. The Content Hash Question

For signing to be meaningful, the hash that gets signed must be **reproducible** and must **cover exactly what gets deployed**.

### Current state

The Nix store hash is a content hash of build *inputs* (the Nix derivation). The actual manifest content hash (what you'd verify against a live resource) is computed post-eval, partially in Nix (store paths) and partially in the Rust CLI (structural diffing, normalization).

### What needs to hold

The signed hash must satisfy:

1. **Determinism:** Same inputs always produce the same hash (Nix guarantees this for the eval, but any post-eval processing must also be deterministic)
2. **Coverage:** The hash covers the actual resource content that reaches the cluster, not just the Nix derivation inputs
3. **Transitivity:** The activation hash depends on all child resource hashes (already true via Nix string context)

### Options

**Option A: Sign the Nix store path hash.** Already deterministic and transitive. But the store path hash covers the derivation inputs, not the output content. If the Rust CLI does any content transformation post-eval, the store hash doesn't cover it.

**Option B: Compute a manifest content hash during Nix eval.** Each resource's `out` includes a hash of its rendered YAML. The activation's hash is derived from all resource hashes. This is computable in Nix (hash the final attrset before serialization) but adds eval-time cost.

**Option C: Sign the Rust CLI's output hash.** The CLI builds the cluster, renders all manifests, hashes the output, signs the hash. The operator verifies against the same hash. This is the simplest — it signs exactly what gets deployed. The Merkle transitivity is maintained because the CLI already walks the DAG.

**Recommendation:** Option C for pragmatism. The CLI already computes the final output; adding a hash + signature step there is minimal. Option B is purer (the signature is part of the Nix world) but adds complexity for little practical benefit. Option A doesn't cover post-eval processing.

---

## 6. Multi-Team Trust Boundaries

This is where signing becomes more than a nice-to-have. In the multi-team operator model (discussion 45), different teams own different namespaces. Trust questions arise:

- Can Team A's CI pipeline deploy into Team B's namespace? (Should be no.)
- Can a cluster admin override team boundaries? (Should be yes, with audit trail.)
- If the operator is shared, how does it know which key to use for which namespace?

### Scoped signing

The activation (or per-namespace sub-activations) can be signed with different keys:

```
namespace "team-a" -> signed by team-a-ci-key
namespace "team-b" -> signed by team-b-ci-key
cluster-wide resources -> signed by platform-team-key
```

The operator is configured with a key-to-namespace mapping. A valid signature for `team-a` does not authorize changes to `team-b`. This is a trust boundary that RBAC alone handles clumsily (namespace-scoped service accounts, etc.) but that signing handles naturally.

### Key hierarchy

For organizations that want centralized control:

```
org-root-key
  -> signs team-a-key (authorized for namespaces: team-a-*)
  -> signs team-b-key (authorized for namespaces: team-b-*)
  -> signs platform-key (authorized for cluster-scoped resources)
```

The operator trusts the root key and can verify delegation chains. This is standard PKI — nothing novel, but the Merkle structure makes it cheap to apply.

---

## 7. What This Does NOT Solve

- **Compromised CI pipeline.** If an attacker controls the build pipeline, they can produce validly signed malicious activations. Signing proves provenance, not correctness. (Mitigation: CI pipeline hardening, reproducible builds, approval gates.)
- **Operator compromise.** If the operator is compromised, it can skip verification. (Mitigation: the operator is a small, auditable component; admission webhooks as a second layer.)
- **Secret management.** Signing proves a manifest is authorized, not that its secrets are correct or securely managed. Orthogonal to the sealed-secrets / external-secrets problem.
- **Runtime behavior.** A signed deployment can still have bugs, misconfigurations, or security vulnerabilities in the application code. Signing is about the deployment pipeline, not the application.

---

## 8. Implementation Sketch

### Phase 1: Activation-level signing (minimal viable)

1. Add `--sign` flag to `kix build` (or the activation emission step). Takes a private key path.
2. Compute a content hash over the rendered activation + all referenced resources.
3. Attach signature as annotation on the Activation CR.
4. Add `--verify-signature` mode to the operator. Takes a public key. When enabled, rejects unsigned or invalid activations.
5. Key format: Ed25519, PEM-encoded. Standard tooling can generate them (`openssl`, `ssh-keygen`).

### Phase 2: Verification tooling

1. `kix verify` command: given a built cluster and a public key, verify the activation signature.
2. `kix diff --verify`: when diffing against a live cluster, flag resources whose content doesn't match the signed hash.
3. CI integration: build + sign + push in one step; operator webhook rejects unsigned applies.

### Phase 3: Scoped signing (multi-team)

1. Per-namespace or per-package-group signing with different keys.
2. Key-to-scope mapping in operator config.
3. Delegation chains (optional, for orgs that want PKI-style hierarchy).

---

## 9. Comparison to Existing Approaches

| Approach | Granularity | What it signs | Merkle leverage |
|---|---|---|---|
| **cosign (container images)** | Per image | Image digest | None — each image signed individually |
| **TUF / Notary** | Per repository | Collection of artifacts | Partial — merkle tree of targets, but no dependency semantics |
| **Git commit signing** | Per commit | Commit hash (covers tree) | Full — commit hash covers all files transitively |
| **kix activation signing** | Per cluster state | Activation root (covers all resources) | Full — activation hash covers all resources transitively |

The closest analogy is Git commit signing. Signing one commit verifies the entire repository state at that point. Signing one activation verifies the entire cluster state. The difference: Git commits are append-only history, kix activations are deployable states.

---

## 10. Open Questions

1. **Signature storage:** Annotation on the Activation CR? Separate Secret? External sigstore-style transparency log? Annotations are simplest but have size limits (256KB).

2. **Key rotation:** How does the operator handle key rotation? Accept multiple public keys during transition? Embed key-id in the signature to support parallel keys?

3. **Dev workflow:** Should local `kix apply` require signing? Probably not for dev clusters. The operator could have a `--require-signature=false` mode for dev, `--require-signature=true` for prod.

4. **Interaction with GitOps:** If using a GitOps controller (Flux, ArgoCD) as the apply mechanism, the signature verification would need to happen in an admission webhook rather than the kix operator. Is this worth supporting?

5. **Encrypted activations:** The original idea mentioned encryption. This is a different axis — signing proves provenance, encryption hides content. Encrypted activations would prevent reading the manifests without the key, which matters if manifests contain sensitive structure (endpoint names, internal service topology). Worth exploring separately or overkill?

6. **Hash stability across kix versions:** If the CLI's rendering changes (different YAML serialization, field ordering), the hash changes, invalidating old signatures. Need a stable canonical form for hashing, or version the hash algorithm.
