# Defining a kix package

A complete, code-grounded guide to authoring kix packages, building from
fundamentals up to overrides. Every API name, field, and default in these
chapters is verified against the source in `kix/lib/`. Where a chapter cites a
file (e.g. `kix/lib/eval/scope.nix`), that file is the authority if the prose
ever drifts.

kix is a Kubernetes manifest compiler written in Nix. A **package**
(`kix/packages/<name>/default.nix`) is a function that produces K8s resources;
a **cluster** (`clusters/<name>.nix`) instantiates packages and wires them
together. This guide is about the package side: how to define one, what the
`scope`/`kix`/`lib` toolkit gives you, and how clusters reshape a package
without editing it.

## Read in order

The chapters build on each other. If you are new, read 01 to 03 first, then
sample the rest as needed.

| # | Chapter | What it covers |
|---|---------|----------------|
| 01 | [Overview & mental model](01-overview.md) | The evaluation pipeline (flake to YAML) and the one idea behind everything: a Nix store path *is* a dependency-graph edge. |
| 02 | [Package anatomy](02-package-anatomy.md) | The package shape `{ scope, lib, kix, ... }: { meta?, options?, deps?, build }`, the `self` attrset, the `root` convention, and the build-time warning system. |
| 03 | [Options & config](03-options-and-config.md) | Typed options via `lib.mkOption`, how cluster `config` deep-merges over defaults, and the `config` vs `clusterConfig` build args. |
| 04 | [Resources & the `out` surface](04-resources-and-out.md) | `scope.mkResource` / `mkClusterResource`, the `out` API (`name`/`fqdn`/`selector`/`identityHash`), `requires` vs `extraDeps`, and the label stack. |
| 05 | [Workloads](05-workloads.md) | `mkDeployment` / `mkStatefulSet` / `mkDaemonSet` / `mkJob`, the build-time validators, selector handling, the `serviceAccount` / `headlessService` shorthands, and `rawSelector`. |
| 06 | [Composition helpers (`kix.*`)](06-composition-helpers.md) | `mount.*` + `withMounts`, `service.fromWorkload`, `expose`, `monitor`, `port`, `mkEnvVars`, and the composable build-list pattern. |
| 07 | [Dependency injection](07-dependency-injection.md) | Deps as build args, two-phase calling, DNS-like resolution priority, aliases, `deps` assertions, and imports. |
| 08 | [Secrets, CRDs, RBAC](08-secrets-crds-rbac.md) | `mkSecret` / `mkSecretRef`, `mkCRD` / `mkCRDRef` / `mkCR`, the `crd.nix` pipe builders, the rbac DSL, and `mkWebhookService`. |
| 09 | [Networking & package meta](09-networking-and-meta.md) | Why network policy is *derived* not declared, `meta.provides` / capability ownership, `meta.network.intents`, and the full `meta` reference. |
| 10 | [Helm-backed packages](10-helm-packages.md) | The three tiers, `importChart` + `mkParts`, `fetchHelmChart`, and the lossy-on-purpose normalization. |
| 11 | [Scorecard & rules](11-scorecard.md) | The rule engine, rule levels, the severity precedence chain, and how to legitimately silence findings. |
| 12 | [Overrides (the capstone)](12-overrides.md) | Every lever for changing a package from the cluster definition: aliases, `config`, `labelStyle`, `selectorLabels`, `optional`, `partsOverlays` / `globalPartsOverlays`, `mkLocked`, and `kix.mkEnv`. |

## "I want to ..." quick jump

| Goal | Go to |
|------|-------|
| Understand how deploy ordering works at all | [01](01-overview.md) (store-path DAG) |
| Write my first single-Deployment package | [02](02-package-anatomy.md) + [04](04-resources-and-out.md) + [05](05-workloads.md) |
| Add a typed, overridable config knob | [03](03-options-and-config.md) |
| Emit a Service / Ingress / mounts without boilerplate | [06](06-composition-helpers.md) |
| Depend on another service (postgres, storage, dns) | [07](07-dependency-injection.md) |
| Consume or produce a secret safely | [08](08-secrets-crds-rbac.md) |
| Ship or reference a CRD | [08](08-secrets-crds-rbac.md) |
| Grant RBAC | [08](08-secrets-crds-rbac.md) |
| Wrap a Helm chart | [10](10-helm-packages.md) |
| Mark a package stateful, or declare a capability it provides | [09](09-networking-and-meta.md) |
| Understand why my build warns / fails the scorecard | [02](02-package-anatomy.md) (warnings) + [11](11-scorecard.md) |
| Change a package's behavior *from the cluster* without editing it | [12](12-overrides.md) |
| Run the same services across prod/stage/demo | [12](12-overrides.md) (`kix.mkEnv`) |

## Related references

- `.claude/skills/kix-migration/SKILL.md` - the migration-focused companion (Ansible/Helm to kix, the build/diff loop). Overlaps with this guide but is task-oriented.
- `kix/lib/architecture.md` - the internals map for `kix/lib` itself (read this when *editing* the compiler, not when authoring a package).
- `docs-legacy/BEST-PRACTICES.md`, `docs-legacy/HANDBOOK.md`, `docs-legacy/FEATURE-CATALOG.md` - the durable user-facing docs.
