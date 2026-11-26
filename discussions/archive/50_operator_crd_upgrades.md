# Operator & CRD Upgrade Strategy

## The General Problem

Upgrading a Kubernetes operator involves two coupled artifacts: the CRDs (API schema) and the operator binary (reconciliation logic). They must stay compatible. The standard industry practice is **CRDs first, then operator**, because:

- New operator code may expect new CRD fields/versions
- Old operator code generally tolerates extra CRD fields it doesn't know about
- Deleting a CRD to "re-create" it deletes all custom resources cluster-wide

### Common pitfalls in the wild

- **Helm won't upgrade CRDs** — `helm upgrade` skips the `crds/` directory entirely. Operators must apply them out-of-band.
- **Field removals** in CRDs can fail if existing CRs still carry those fields — requires CR cleanup or a conversion webhook.
- **Conversion webhooks** must stay available during CRD version transitions; if the operator serves one and goes down during upgrade, the API server can't convert stored versions.
- **RBAC drift** — new operator versions often need new permissions that aren't obvious until reconciliation silently fails.
- **Skipping versions** — many operators don't support skipping minor versions; each step may have migration logic.

### How other tools handle it

| Approach | CRD handling |
|---|---|
| Helm | CRDs applied on install only; upgrades require manual `kubectl apply` |
| OLM | Manages CRD upgrades automatically via ClusterServiceVersion |
| Kustomize / raw manifests | Explicit `kubectl apply` before operator |
| Flux / ArgoCD | Split CRDs into separate Kustomization/Application with sync-wave ordering |

## Why kix makes this trivial

### 1. Dependency ordering already solves the sequencing problem

kix's activation system has wave-based dependency ordering. An operator package naturally declares its CRDs, and the activation system ensures CRDs are applied before the operator Deployment. No manual intervention, no sync-wave annotations, no split Kustomizations — the dependency graph handles it.

### 2. CRD-aware operator versioning via content hashing

CRDs in a well-designed package depend on nothing external — they are pure content. This means their hashes are stable and deterministic. An operator can know the CRD hashes it was built against.

This enables **seamless side-by-side operator upgrades**:

- Deploy the new operator version alongside the old one
- The new operator knows which CRD schema versions it owns (by hash)
- Once the new CRDs are applied, the new operator takes over reconciliation
- The old operator can be drained and removed

This requires multi-activation support (multiple activation refs targeting the same package at different versions), but eliminates the upgrade-in-place risk entirely. There is no window where the operator is down or incompatible with its CRDs.

### 3. What this means in practice

The entire "CRD upgrade best practices" section from the Kubernetes ecosystem — manual CRD application, sync-wave ordering, version-skip guards — collapses into the normal kix deployment flow. An operator upgrade is just a version bump in the cluster definition; the dependency graph and activation system handle the rest.
