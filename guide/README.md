# Defining a kix package

Package-authoring reference. APIs/fields/defaults verified against `kix/lib/`. Cited file (e.g. `kix/lib/eval/scope.nix`) is authority on drift.

Package = `kix/packages/<name>/default.nix`, a function producing K8s resources. Cluster = `clusters/<name>.nix`, instantiates and wires packages.

## Files

| File | Sections |
|------|----------|
| [00-ideas.md](00-ideas.md) | The *why* behind the authoring API (design principles). Read before the reference. |
| [01-fundamentals.md](01-fundamentals.md) | Overview & mental model · Package anatomy · Options & config |
| [02-authoring.md](02-authoring.md) | Resources & `out` · Workloads · Composition helpers (`kix.*`) · Dependency injection |
| [03-advanced.md](03-advanced.md) | Secrets/CRDs/RBAC · Networking & meta · Helm packages · Scorecard · Overrides · Context/closure internals |

New: read 01 top-to-bottom, then sample 02/03.

## "I want to ..."

| Goal | Go to |
|------|-------|
| Deploy ordering / mental model | [Overview](01-fundamentals.md#overview--mental-model) |
| First single-Deployment package | [Anatomy](01-fundamentals.md#package-anatomy) + [Resources](02-authoring.md#resources-and-the-out-surface) + [Workloads](02-authoring.md#workloads) |
| Typed, overridable config knob | [Options & config](01-fundamentals.md#options--config) |
| Service / Ingress / mounts without boilerplate | [Composition helpers](02-authoring.md#composition-helpers-kix) |
| Depend on another service (postgres, storage, dns) | [Dependency injection](02-authoring.md#dependency-injection) |
| Consume / produce a secret safely | [Secrets/CRDs/RBAC](03-advanced.md#secrets-crds-rbac) |
| Ship / reference a CRD; grant RBAC | [Secrets/CRDs/RBAC](03-advanced.md#secrets-crds-rbac) |
| Wrap a Helm chart | [Helm packages](03-advanced.md#helm-backed-packages) |
| Mark stateful / declare a provided capability | [Networking & meta](03-advanced.md#networking--package-meta) |
| Build warns / fails scorecard | [Anatomy](01-fundamentals.md#package-anatomy) + [Scorecard](03-advanced.md#scorecard--rules) |
| Change package behavior from the cluster without editing it | [Overrides](03-advanced.md#overrides) |
| Same services across prod/stage/demo | [Overrides](03-advanced.md#overrides) (`kix.mkEnv`) |

## Related

- `.claude/skills/kix-migration/SKILL.md` - migration companion (Ansible/Helm to kix, build/diff loop). Task-oriented; overlaps this guide.
- `kix/lib/architecture.md` - internals map for `kix/lib`. Read when *editing* the compiler, not authoring a package.
- `docs-legacy/{BEST-PRACTICES,HANDBOOK,FEATURE-CATALOG}.md` - durable user-facing docs.
