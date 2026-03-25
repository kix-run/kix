# Roadmap

## Foundation (core engine)

- [x] no "defaults"
- [x] Module system via NixOS evalModules for cluster composition
- [x] Global scope object with per-instance context (mkResource, mkClusterResource, rbac helpers)
- [x] Fragment system for separating concerns and teams (mergeFragments with collision detection)
- [x] Content-addressed resources — mkResource produces rich objects with `.out` (name, selector, fqdn, etc.)
- [x] Dependency tracking via Nix string context (attachCtxDeep)
- [x] Helm integration (fetchHelmChart, fromHelmChart, wrapHelmResource)
- [x] Content-hash and identity-hash annotations on resources
- [x] depends-on annotation derived from context
- [x] @luca Post-eval validation — catch errors at build time, not deploy time
  - Cross-namespace scope validation (`meta.scope = "namespace"` prevents cross-ns DI)
  - Consumer-side dependency validation (immich validates postgres has pgvecto.rs extension via `postgres.out.extensionNames`, warns on undersized PVCs)
  - Redundant/duplicate requires detection, orphaned resource detection
  - [ ] General validation framework — package-declared requirements on dependencies (beyond ad-hoc checks)
- [ ] @luca Auto-inject dependencies (e.g. valkey for immich) — the "just make it run" experience where pulling in an app auto-enables what it needs
  - [x] **DI resolution**: explicit override → same-namespace match → cluster-wide match → Nix default → error. Aliases supported. This resolves against *existing* instances in the cluster.
  - [x] **DI-driven defaults** (immich): ingressNginx injected → auto-create ingress (no `enabled` flag); clusterIssuer injected → auto-enable TLS. className derived from `ingressNginx.out.ingressClassName`. TLS secret name auto-derived.
  - [ ] **DI-driven defaults** (remaining): apply pattern to more packages. Prometheus auto-enable metrics when injected. Cluster-level `cluster.domain` should provide sensible host defaults (e.g. `host = "${instanceName}.${cluster.domain}"`), overridable per instance.
  - [ ] **Auto-instantiation from default package set**: the core missing piece. A cluster-level registry of default packages (e.g. `defaults.valkey = packages.valkey;`) so that when a package declares `valkey` as a hard dep and no instance exists, the system auto-creates one from the default. This is what makes `immich = { package = packages.immich; }` fully zero-config — no one has to manually define a valkey instance. Resolution order: (1) match concrete instance in cluster, (2) fall back to alias, (3) auto-instantiate from default package set.
  - (pot nonsense:) Two-tier model: auto-enable if a dependency exists in the cluster; explicit enable triggers full transitive pull-in of everything needed
  - [ ] Packages can declare **default aliases** alongside their options and builders (e.g. cert-manager aliases `clusterissuer`), so dependencies can resolve against general capabilities, not just package names — currently aliases are set in cluster definitions, not package definitions
  - [ ] The available package list for auto-resolution must live under a **dedicated config path** to control what the resolver can pull from
- [x] v2_discussions/11 → injecting storage, certs, and other infra items from the cluster graph (different package types?)
  - Storage DI: PVCs are first-class instances in the cluster definition (packages/persistent-volume-claim). storage-classes exposes `out.storageClassName`. Consuming packages (e.g. immich) take `storage` as a hard DI dep, mount via `storage.out.name`. Package `meta` (lifecycle, scope) enables cross-namespace validation and kix-diff protection.
- [x] Use "already existing" cluster elements — `kix.mkImport { from = package; }` evaluates packages in import mode (lightweight `mkImportResource`, no store paths) to derive `out` properties for DI resolution. Deployed as a marker PackageInstance CR only.
  - [ ] kix deploy should verify imported resources actually exist in the live cluster
- [ ] Default metadata scoping — which resources should global metadata apply to? Not higher-order resources like Deployments/Services, but what about CRDs?
- [ ] Non-manifest side effects — namespace creation, secrets, and images all require API calls outside pure manifest generation; needs a clear model
- [ ] "Wire" vs "compose" coherence — sharing selectors by reference can copy wrong state if labels are accessed; post-processing breaks composition. Needs a principled solution
- [ ] Higher-level abstractions must "imprint" on resources — all relevant information from higher-level logic should be visible on the underlying K8s resource for auditability and tooling
- [ ] Dynamic duplicate dependencies — the same resource (e.g. a second CoreDNS) can be pulled in twice; deduplication is the consumer's responsibility, not the creator's
- [ ] mkManifest pre-creation hook as escape hatch — global function hook for raw access to any resource before it becomes a manifest
- [x] CRDs, creation and basic usage — `mkCRDRef` creates CRD references with auto-generated `mkCR` builders; used by cert-manager, stackgres, monitoring packages
  - [ ] CRD schema management, verification against live cluster, and import from existing CRD definitions
- [ ] auto-sealing of resources? => evaluator turns every attrset that has a "kind" attribute into a resource on first pass of the fixpoint
- [ ] aliases and meta could be on the packages options maybe? => allows default aliases to just be a mkDefault
- [ ] smarter store paths. Nixos puts the package version into the storepath hash-name-version. This helps a lot with diffing fast.

### Validation

- [ ] Deep-check package-level dependencies — verify the package root CRD is pulled in properly
- [ ] Rethink package CR (PackageInstance) wiring and store path visibility — currently `mkCRDRef` creates standalone `crd-ref-*` store paths with no back-reference to the providing package's PackageInstance. Cross-package CRD dependencies don't show up in the Nix store DAG. Need to decide: should the providing package's store path be threaded through the CRD ref context, or should cross-package deps be tracked at a different level?

### Open design questions
- [ ] Package root as common leaf dependency or root
- [ ] Direction of abstraction: deploying an app ON a surface (cloud-run-like) vs. wrapping/composing an app IN a surface (being cloud-run) — this is a concrete UX question that shapes the entire API
- [ ] How to model the derivation vs resource vs module tension — three competing goals in direct conflict: (1) perfectly verifiable traceability (security), (2) complete customization (maintenance), (3) ease of consumption. Modules can't support duplication (multiple SAs), derivations can't be post-modified, resources easily lose dependency tracking
- [ ] Content-addressing means updates launch side-by-side (different hash), not in-place replacement — native K8s rolling update semantics become incompatible. This is a fundamental design property that needs explicit handling
- [ ] Kubenix-style service definitions (`services.coredns."default".enable = true`) — allows multi-instance, attribute-set-keyed service declarations
- [ ] Move to manifest module system — explicit migration step for how manifests are composed

## Security & compliance

> "Security teams have money — platform teams do not. But platform teams can get money from security."

- [ ] Security defaults via mkDefault — e.g. all pods non-root by default, users must mkForce to override
  - mkForce as an auditable signal: any use of mkForce to override security defaults can be flagged, surfaced in review, or blocked by policy
  - The full nix module priority hierarchy (mkDefault → normal → mkOverride → mkForce) is what makes multi-team cluster configs maintainable at scale
- [ ] CVE tracking — integrate with NixOS security tracker (https://tracker.security.nixos.org/suggestions/) for awareness of vulnerabilities in dependencies
- [ ] Automated compliance — continuous verification against regulatory frameworks (SOC2, HIPAA, PCI-DSS)
- [ ] Secret handling and injection (agenix, etc.) — hashes of encrypted secrets don't trigger spurious changes; injection happens in kix-deploy
  - [ ] Auto-management — weekly rolling of auto-created credentials (e.g. postgres users)
  - [ ] Revoking team member permissions
- [ ] Supply chain security (SLSA) — locked inputs for everything: not just flake inputs but arbitrary external git refs, downloads (must carry hash), and file references. Partial immunity to supply chain attacks
- [ ] Run static analysis of kyverno and other policy engines at build time — sane defaults out of the box
- [ ] Network policies — autogenerate, check, verify, and abstract (cilium compatible); can be partially inferred from dependency graph (if you depend on a service, you need DNS access to it)
- [ ] Permission system in kix deploy — what blast radius am I allowed to have

## Platform capabilities (module-level features)

> "If Prometheus is already there, why not auto-enable it in CoreDNS?"

- [ ] Capability switchboard — turning on Prometheus sets `config.metrics.enabled` globally; packages can react with `lib.mkIf config.services.prometheus.enable`. This is also a platform capability signal: a machine-readable, introspectable feature advertisement (could also exist for AI)
- [ ] Modules that auto-configure based on cluster features — "if we have a prometheus, I will use it"; "wherever I run, I expect a DNS entry for X"
- [ ] Importable decision sets — like nixos-hardware profiles but for clusters (e.g. `import security-hardened` changes default pod settings across all packages)
- [ ] Community module registry — e.g. a CNCF k8s-packages flake where `services.rook.enable = true` just works
- [ ] Separation of team concerns with priority — security team can push requirements at higher priority on every module, not just as pre/post processors but as orthogonal constraints

## Warnings, errors, checks

- [x] Misuse of `requires` detection
- [x] Missing resources in graph detection
- [x] Build-time error on illegal configurations — immich throws at eval time if postgres is missing required pgvecto.rs extension (`postgres.out.extensionNames`). Infra packages expose validated metadata via `main.out` for consumer-side checks.
- [ ] Compatibility checks on packages (incompatible k8s version, incompatible with prometheus < 4.5.23, etc.)
- [ ] Sanity checks on namespace resource quotas and similar
- [x] Stateful resource discovery — package `meta.lifecycle = "stateful"` flags stateful packages; `meta.scope = "namespace"` prevents cross-namespace DI for namespace-bound resources (PVCs). Consumer-side validation (e.g. immich warns if PVC < 50Gi) via `builtins.trace` in build.
- [ ] Compatibility matrix — four distinct failure phases: build, deploy, health, application. Need to know *when* things will fail, not just *if*
- [ ] Encodable "known issues" — broken side effects should be expressible in code so a problem can't recur; capturing institutional knowledge about failure modes directly in the DSL
- [ ] Templating parity — ensure the DSL can express everything a Helm template can, as a migration enabler
- [ ] allow a resource to be defined as `self.deployment = moved { new attr name, message }` to inform a consumer of changes. We could have more and more advanced of these.

## DSL improvements

- [x] Auto-derived selectors on resources (.out.selector)
- [x] RBAC DSL — pipe-friendly intent-based API (watch, reconcile, own, grant, etc.)
- [x] Auto-selectors derived from resource spec/labels (`.out.selector`)
- [x] RBAC DSL with intent-based verbs
- [ ] HPA as dependency / composition — auto-wires scaling to the right target
- [ ] Pipe-friendly resource composition — `binary |> as deployment |> expose { port = 9090; }` — kix as *the* platform engineering language, replacing the wild west of ansible/helm/scripts
- [ ] Builder/transformer placement — should package builders (`withCert`, `mkCertificate`) live on `out` (via `main.out`) or on parts directly? Current: `main.out` for DI-visible transforms, parts for package-internal helpers like `mkCertificate`. Storage uses plain values (`out.storageClassName`) rather than transformers. Needs a clear convention as more infra packages expose builders
- [ ] Remove `outputs` design — custom `outputs` on `mkResource` is a bolted-on escape hatch; port, fqdn, and other DI-visible values should be auto-derived or come from a richer `out` model, not manual string declarations per resource. `main.out` (package-level out) partially addresses this — it allows complex types (lists, functions) beyond stringified resource outputs (e.g. stackgres-cluster exposes `out.extensionNames` as a list, cluster-issuers exposes `out.withCert` as a function). But per-resource `outputs` still exists for simple string values like port.
- [ ] Port wiring logic — carry port information up through container → pod → service → ingress; prevent wiring things that don't have a route
- [ ] Functional composition as correctness — "this service wraps this app, this HPA wraps this app, you figure out the rest"; correct wiring emerges from composition, not from template deduplication
- [ ] Image convention — `"${config.image.repository}:${config.image.tag}"` + `imagePullPolicy` is repeated in every package. Standardize as a single option (full image string or structured with a helper) so packages don't each reinvent image construction
- [ ] Better CoreDNS corefile handling
- [ ] Full CoreDNS binary building
- [ ] selector based on "identity" to say "i want this and exactly this resource"

## Post eval validation (kix validate)

- [ ] OpenAPI schema validation at build time — K8s resources have a known openAPI spec, verify against it during eval


## Drift detection & diffing (kix diff)

- [x] kix-dump — normalize and dump live cluster state
- [x] kix-diff — compare kix output against dump (summary, renames, modified, identical)
- [ ] Diff on instance level (grouped by package instance)
- [ ] Diff on resource level (individual resource changes)
- [ ] Warnings when PVCs change or major versions change — hint on the package definition
- [ ] Live-cluster sanity checks (resource limits, etc.)
- [ ] Content-hash-based drift detection — recompute hash and compare against live state, contrast with nix store evaluation

## Deployment & reconciliation (kix deploy)

- [ ] Wave rollouts — dependency graph fully describes deployment order; deploy in correct waves. Note: dependencies describe *order* but NOT readiness/liveness — these are separate concerns
- [ ] Wait for ready across all resource types
- [ ] Non-K8s side effects (e.g. Forgejo user creation) — start with execution on "ssh", later crossplane or provider plugins
- [ ] Auto-collect readiness — custom general runtime readiness checks (also outside k8s)
- [ ] Auto-inject package identity labels (hash?, otherwise package name + version, like helm best practice)
- [ ] Rollback — point to previous content hash; previous version may still be cached in nix store or even still running
- [ ] Canary rollouts — everything runs in parallel via different hashes; unchanged subsystems are reused (same hash = same resource); update only redeploys what changed
- [ ] Migrations as k8s jobs — defined per package for major version upgrades; package hints whether a major version change is rollback-safe (e.g. postgres: only one version)
- [ ] Rollout pattern as a developer choice — no magical "always works" pattern due to state; stateless deps can duplicate, stateful deps need careful management
  - The system should ideally auto-classify dependencies by statefulness, not just surface the choice
- [ ] Consistent cluster state guarantee — a fully-evaluated, locked cluster state means the entire set of resources is known to be self-consistent. No "helm installed something with a different env var" surprises

## Graph & observability

> "Since we have content-addressing, we can see a full dependency tree. Not only great for garbage collection, but especially interesting for debugging and cluster reasoning."

- [ ] Graph view — visualize the full dependency tree of resources in the cluster
  - As a debugging confidence tool: "we can't prevent bugs, but we want to very quickly give you confidence in knowing where it is" — reduce time-to-localize, not just time-to-prevent
- [ ] Garbage collection — unreferenced resources are detectable
- [ ] Integration with monitoring (prometheus, etc.) for runtime graph enrichment — understand consequences of changes
- [ ] Cross-service failure debugging — understanding why something failed across many microservices, enriched by the dependency graph

## Tooling & CLI

- [ ] kix CLI working without installed nix
- [ ] LSP or code smell checks for kix package definitions
- [ ] Rust bridge to nix binary (https://github.com/nixops4/nix-bindings-rust)
- [ ] Allow bringing a values.yaml for helm migration
- [ ] Dry-run / planning mode — "do the builds without the servers"; evaluate what a cluster would look like before hardware exists, as a planning and risk assessment tool ("what would break?")

### Break glass — emergency escape hatches
- [ ] Strip dependency context — remove a resource from the DAG without deleting it (e.g. `builtins.unsafeDiscardStringContext` on a specific dep reference) to unlink a broken dependency and allow the rest of the graph to deploy
- [ ] Force-override a single resource — bypass the content-addressed pipeline for one resource (pin its manifest directly) when the DSL can't express what you need right now
- [ ] Skip a package from the cluster build — `exclude = [ "package-name" ];` at the cluster level to drop a package entirely without editing its definition
- [ ] Partial deploy — deploy a subset of the graph (e.g. only one wave or one namespace) when a broken package blocks the full rollout
- [ ] Escape-hatch annotations — mark resources with `kix.dev/unmanaged: "true"` so kix-diff ignores them, allowing manual hotfixes to coexist temporarily
- [ ] Audit trail for escape hatches — any break-glass action should be visible in the build output / diff summary so it doesn't silently become permanent

### GitOps & operator
- [ ] Trivial GitOps — evaluate nix recipe, when all is built, replace the current hash of the head node
- [ ] kix operator — argo-like nix operator that re-evaluates from git; can reconcile with live cluster state as input variable
  - Inline operators: current cluster state as a pure input — side effects that depend on cluster state can be *configured* (not just executed) in the functional system. This is a general purity capability, not just an operator concern. Solves 90% of operator use cases and can be shipped as part of the package
  - Open question: how does this handle hashes and drift?
- [ ] feature parity with helm, argo, flux

### Advanced deployment
- [ ] PR as its own isolated deployment / fast preview environments — reuse unchanged systems (same hash), everything else gets its own deployment; touching data needs consideration
- [ ] Multi-zone, multi-cluster management — runtime concern for failover, but can model through re-eval with global cluster state variables
  - Client cluster provisioning: backwards compatibility across all clusters is critical; cluster config depends on per-client negotiations
  - Replaces fragile playbooks (Ansible "what changed?" pipelines with unexpected results) with functional, reproducible evaluation
- [ ] Feature parity with helm, argo, flux (as a long-term benchmark) — but framed as replacement, not complement: kix eliminates the need for a separate GitOps operator stack
- [ ] Running jobs — install/run separation: "install" produces a derivation with ready manifests, "run" executes with ownership linked to a completing job → fully garbage-collectable

### Vertical integration
> May require bootstrapping an entire ecosystem, not just adding features — potentially not "standalone" (inspiration: Tilt's local dev loop model)
- [ ] Vertical integration with build pipelines (and their hashes) — from source to running container
- [ ] nix-snapshotter — skip Docker entirely
- [ ] Local dev loop — Tilt-inspired watch + rebuild + deploy cycle for fast inner-loop iteration, distinct from GitOps
- [ ] Potentially trivial air-gapped environments
- [ ] Replacing etcd with a nix store (very speculative)
- [ ] hardware.nix type file to describe what is raw available and derive helpers, storage, etc etc

### AI & developer experience
- [ ] AI skills: recommended in-kix actions on warnings/errors; skill to read changelogs and derive warnings and checks
- [ ] Code completion and editor integration for the kix DSL

### Permission system

- [ ] enable platform teams and cluster operators to loop in application developers safely

### Ecosystem & adoption
- [ ] Functional CRDs — deploy against kix, not k8s directly; the end user never needs to think about CRDs/operators. kix evaluates the "need" into manifests (imperative CRD operators replaced by pure evaluation where possible)
  - Stateful operators should stay; pure configuration operators can be absorbed
- [ ] Backbone infra layer — define reuse patterns and cross-service/cross-app logic (e.g. shared storage, common sidecars) to reduce redundancy
- [ ] Service mesh bindings — content-addressed "binds" that translate hashes into public service space; resolves cross-team dependencies at cluster level
- [ ] Backstage as natural evolution — catalog, ownership, libraries

## Case studies & documentation

- [ ] @luca Immich (from simple to full) — package is functional with DI-driven ingress/TLS, extension validation, storage validation, ML worker, metrics. Cluster definitions exist for ludo (homelab) and example. Remaining: document the progression from bare minimum to full production config, auto-derive host from `cluster.domain`.
- [ ] How-to case studies for simple cases
- [ ] Create skill/guide for proper package creation
- [ ] Naming conventions for packages, services, resources, etc.
- [ ] Naming of the project and internals
- [ ] Mocked-up code examples as a design validation tool — "what would the code look like if an engineer used this feature?" Use prospective API sketches to stress-test design decisions before building
- [ ] Intro tutorial as a design artifact — "what would the intro tutorial look like?" is a feedback mechanism for whether the design is understandable, not just a docs task
- [ ] Demo video / README showing the 2-min value pitch:
  - Spin up something with deep dependencies
  - Make a fundamental change and watch it propagate
  - Per-environment overrides (dev: resources /10, staging: no limits, prod: full limits)
  - "You don't have to wipe and restart anymore"
  - Code completion working in the demo
  - "This is what I want" — no separate argo/flux/etc setup needed

## Key risks & design principles

- **Nix adoption barrier** — nix has clear advantages but hasn't taken over the world; we need to actively study *why* people who know about nix's benefits still choose not to use it — not just build features. The intro tutorial and DX must be approachable for a non-nix user. Positioning: nix scales; helm and friends do not.
- **Adoption is the #1 killer of platforms** — not features. The experience for a non-infra developer must be so easy a novice could use it. Datadog vs Prometheus is the cautionary tale (user acquisition beats technical correctness).
- **"Not simple, but intuitive"** — the goal isn't to reduce the interface, but to distill inherent complexity into intuitive form. If the tool is "too smart", the user has to think about the tool rather than their work (mental overhead as a design constraint).
- **Eval times** — content-addressing could lead to long eval times; unclear if path caching helps.
- **Abstraction balance** — narrow interface ≠ less cognitive load; making things simpler than they are creates a dangerous illusion. Don't abstract away physical properties (cost, latency, SLA) — they're leaky abstractions people care about.
- **"Composability and cohesion over capability and completeness"** — the platform will grow by itself, but composability and cohesion must be actively protected.
- **Show value in weeks** — don't over-engineer. Find immediate MVPs and GTM opportunities. The demo must be compelling quickly, not after all features are built.
- **IaC as readable, long-lived intent** — "express ideas in a language you can re-read a year ago". This is a core reason to use nix over YAML/templating: the configuration is human-readable code, not opaque generated output.
