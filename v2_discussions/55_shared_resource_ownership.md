# Shared Resource Ownership — CRDs, Namespaces, and Multi-Activation

**Status:** Open problem — needs design
**Related:** `45_multi_team_and_operator_models.md`, `50_operator_crd_upgrades.md`, `44_operator_remaining_work.md`

---

## 1. The Problem

The kix DAG encodes that "we need this CRD to deploy" or "we need this namespace to exist". These dependencies are real and important — they drive wave ordering and ensure resources are applied in the right sequence.

But the same DAG also implies **ownership**: when an activation is deleted, its finalizer cleans up everything it "owns". For resources that are genuinely owned by a single activation (Deployments, ConfigMaps, Services), this is correct. For resources that are **shared infrastructure** — CRDs, Namespaces, CoreDNS, cert-manager — ownership semantics break down.

### What happens today

- A single activation deploys CRDs + Namespaces + workloads.
- Finalizer cleanup deletes everything including CRDs, which breaks the API server for those resource types.
- The operator currently hard-codes a skip list (`activations.kix.dev`, `packageinstances.kix.dev`) during cleanup, and always skips Namespace deletion.
- This is a band-aid. The real issue is that "depends on" ≠ "owns".

### Why it matters for multi-activation

When multiple activations share a cluster:
- Team A's activation declares it needs `cert-manager` CRDs.
- Team B's activation also needs them.
- If Team A's activation is deleted, it must NOT delete the CRDs that Team B depends on.
- But if BOTH are deleted, the CRDs should be cleaned up.

This is reference counting / shared ownership, and it applies to: CRDs, Namespaces, shared infrastructure packages (cert-manager, ingress controllers, monitoring stack), RBAC cluster roles, etc.

---

## 2. Current State (Single-Activation Model)

As long as `actual cluster = single activation` and nothing else runs in the cluster, the problem is manageable:

- The activation owns everything.
- On delete, skip CRDs and Namespaces (current behavior), clean up the rest.
- The operator can manage itself — the activation contains its own CRDs.

This works for dev/demo clusters and single-team setups.

---

## 3. Open Questions for Multi-Activation

### 3a. How should shared resources be expressed in the DAG?

Options:
- **Dependency without ownership:** A resource can be "required by" an activation without being "owned by" it. The DAG edge means "apply before me" but the cleanup finalizer doesn't include it.
- **Reference-counted ownership:** Resources track which activations reference them (the `kix.dev/activations` annotation already does this). Cleanup only deletes a resource when its activation reference set becomes empty.
- **Separate infrastructure activation:** Shared resources live in a dedicated "infra" activation that is never deleted. Team activations depend on it but don't own its resources.

### 3b. Can the operator manage itself?

The activation includes its own CRDs and potentially its own operator Deployment. This creates circular dependencies:
- The operator needs the CRD to watch Activations.
- The Activation includes the CRD.
- Deleting the last Activation deletes the CRD, breaking the operator.

For self-management to work, the operator's own CRDs must be treated as "infrastructure" that outlives any single activation.

### 3c. How does this interact with the Nix evaluation?

The Nix evaluation currently produces one DAG per cluster. If multiple activations contribute to a cluster, the evaluator needs to:
- Know which resources are shared vs. activation-scoped.
- Produce separate DAGs per activation, with shared resources either duplicated or referenced.
- Handle version conflicts (two activations wanting different CRD versions).

---

## 4. Possible Evolution Path

1. **Now:** Single activation per cluster. Hard-coded skip lists for cleanup. Works for demos and dev.
2. **Next:** Reference-counted ownership using `kix.dev/activations` annotation. Cleanup only deletes resources owned exclusively by the deleted activation. Requires the annotation to be reliable.
3. **Later:** Infrastructure activations as a first-class concept. Shared resources live in a separate activation with its own lifecycle. Team activations declare dependencies on the infra activation.
4. **Eventually:** The Nix evaluator understands activation boundaries and can split a cluster definition into multiple activation DAGs with explicit shared-resource contracts.

---

## 5. Implementation Notes

The `kix.dev/activations` annotation (set by `update_activations_annotation` in `apply.rs`) already tracks which activations reference each resource. This is the foundation for reference-counted cleanup — the finalizer just needs to check whether other activations still reference a resource before deleting it.

The operator currently hard-codes skip lists for its own CRDs. This should evolve into a general mechanism, not a growing list of special cases.
