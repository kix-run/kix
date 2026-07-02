# 117: Self-Service Platform Interface

**Status:** RFC
**Related:** `91_cicd_organizational_patterns.md` (§5 shift-left self-service), `45_multi_team_and_operator_models.md` (repo topology), `64_init_and_ci_concerns.md` (CI mechanics), `80_structured_diagnostics.md` (agent-readable errors), `interesting_thoughts/89_eval_operator_mode.md` (in-cluster eval), `business_discussions/11_idp_gap_analysis.md` (Pillar 3 market view)

---

## 1. Problem

Platform engineering wants self-service: a developer (or an agent) asks for "a web service with a database" through a simple interface, and the platform provisions it within guardrails set by the platform team.

Runtime tools get a self-service story cheaply. Kro's ResourceGraphDefinition becomes a CRD, the Kubernetes API server becomes the request channel, and a form over the CRD schema becomes the portal. Kix is different: it is a compiler. Intent lives in a git repo and becomes real through a build. The question this RFC answers is: **what does self-service look like when the platform is a compiler, and is that better or worse than the runtime model?**

Doc 91 §5 settled the policy half: the operator gatekeeps policy, not individual changes, and the compiler auto-merges what passes. This doc covers the interface half: what the requester touches, what format requests use, how schemas are defined and versioned, and how a request becomes repo content.

## 2. The Kro/Kix mapping, and where Kro instances actually live

Kro and Kix have almost the same shape, but they run at different points in the lifecycle:

| Kro | Kix |
|---|---|
| ResourceGraphDefinition | Package |
| Generated CRD schema | Package config options (typed module options) |
| CR instance | Package instantiation in a cluster definition |
| CEL wiring between resources | DI, `out` contracts, derived wiring |
| Controller reconcile | Compile + deploy |

Kro's real appeal is that the K8s API server becomes the platform front door. RBAC, validation, audit, and watchability come with it. In practice, though, Kro CR instances are usually not `kubectl apply`'d by developers. They are committed to git behind Flux or Argo, because many organizations have already agreed that git is the intent store. The production Kro pipeline is:

```
git -> GitOps controller -> CR -> Kro controller -> resources
```

That gives three interpretation layers. Each can fail at runtime, and none sees the whole picture. Kix collapses this to `git -> compiler -> resources`, with the whole cluster visible at the single interpretation point. The git work a portal must handle (write a file, open a PR) exists in both models. Kix gets whole-cluster verification in exchange; Kro does not.

One consequence is worth stating plainly: Kro's per-instance validation (CEL type checks at apply time) cannot see across instances. Two requests that validate on their own can still collide on an ingress host, exhaust a namespace quota, or select the same pods. A whole-cluster compile catches these before merge.

## 3. Proposal: the interface is a compile target

The thesis: Kix should not bolt a platform interface onto the side. It should generate the interface from things the repo already contains: schemas, golden paths, request lifecycle data, and agent tools. The proposal has four parts.

### 3.1 Schema export: no second type system

The trap in "define a data interchange format for the platform to write" is creating a second schema layer. If the portal's JSON Schema is hand-written per template, it can drift from the module options that actually interpret the data. That reintroduces the same class of wiring bug Kix exists to eliminate, just at the platform boundary.

So the hard requirement: **the interchange schema is compiled from the module option types, never authored separately.**

```nix
# packages/webapp/default.nix (options already exist today)
options = {
  image    = lib.mkOption { type = types.str; description = "Container image ref"; };
  domain   = lib.mkOption { type = types.str; };
  replicas = lib.mkOption { type = types.ints.positive; default = 2; };
  memory   = lib.mkOption { type = types.str; default = "512Mi"; };
};
```

```bash
$ nix eval .#schemas.webapp --json
```

```json
{
  "$id": "kix://acme/webapp",
  "type": "object",
  "required": ["image", "domain"],
  "properties": {
    "image":    { "type": "string", "description": "Container image ref" },
    "domain":   { "type": "string" },
    "replicas": { "type": "integer", "minimum": 1, "default": 2 },
    "memory":   { "type": "string", "default": "512Mi" }
  }
}
```

The mapping is mechanical: `submodule` to object, `listOf` to array, `enum` to enum, `ints.positive` to integer with minimum. Types that cannot serialize (functions, packages, raw derivations) are not exposable. That makes the platform surface boundary a property of the type system instead of a convention. Prior art exists (NixOS options documentation JSON, clan-core's module-to-JSON-Schema export); this pass is known to be feasible.

The portal is then a simple renderer over exported schemas. It holds no schema knowledge of its own, so it cannot drift.

### 3.2 Golden paths are partially-applied packages

A golden path is not a new artifact type. It is a package where the platform team locks most options and exposes a small remaining set:

```nix
# clusters/acme/platform.nix  (platform team owns this file)
goldenPaths.web-service = kix.mkGoldenPath {
  package = kix.packages.webapp;
  locked = {
    storageClass = "zpool-fast";
    podHardening = "restricted";
    memory       = lib.mkDefault "512Mi";
  };
  exposed = [ "image" "domain" "replicas" ];
  limits.replicas.max = 5;
};
```

After `exposed` and `limits` are applied, Kix can generate a smaller schema for the fields the requester is allowed to set. The portal renders that schema, and agents receive it as a tool signature. The compiler then verifies the locked values and the requested values together, per request, against the whole cluster.

Kro cannot express this directly. An RGD schema is one flat, hand-authored surface. It has no checked relationship between what the RGD exposes and what the underlying resources accept. In Kix, the lock/expose split is function application, checked by the same evaluator as everything else.

For v1, this lives entirely on the platform side: package authors do nothing special. Two likely evolutions are recognized, but deliberately not designed here:

- **Author-declared surface**: package authors mark options as platform-exposable in package meta, and golden paths may only expose from that set. This gives authors a stable contract ("these options are safe to hand to non-experts") at the cost of a new meta concept on every package.
- **Layered projection**: authors declare the safe surface, and the platform narrows it further per golden path. This is the likely long-term shape if golden paths proliferate across many clusters, but it needs the author-declared layer to exist first.

Both are additive on top of the v1 construct. Neither changes the instance format below.

### 3.3 Instance files: the interchange format

Requests land in the repo as data files, one instance per file:

```
clusters/acme/instances/
  team-payments/
    checkout-api.json
    checkout-db.json
```

```json
{
  "path": "web-service",
  "name": "checkout-api",
  "spec": {
    "image": "ghcr.io/acme/checkout:1.4.2",
    "domain": "checkout.acme.dev",
    "replicas": 3
  }
}
```

A small library function ingests the directory:

```nix
# clusters/acme/default.nix
imports = [ (kix.loadInstances ./instances) ];
```

Each file resolves its golden path, applies `spec` as config, and becomes an ordinary package instantiation. Nothing downstream needs to know that the instance arrived as JSON rather than Nix. `builtins.fromJSON` plus the module system is the entire ingestion mechanism (helm.nix already reads JSON this way).

The envelope is deliberately small: `path`, `name`, `spec`. Directory location carries team ownership, and maps onto CODEOWNERS for the PR lane. Repo topology questions (monorepo vs. federated team repos pinned as flake inputs) belong to doc 45. Instance files work with whichever topology a cluster uses, with the monorepo `instances/` directory as the default.

### 3.4 The request lifecycle is the PR lifecycle

Self-service platforms tend to grow request-management systems: pending, approved, provisioned, denied, with a queue UI and an audit trail. Git already implements this state machine:

| Request state | Git primitive |
|---|---|
| Pending | Open PR containing the instance file |
| Under review | PR review, with the compiled preview (diff, blast radius, scorecard) as the review artifact |
| Approved + provisioned | Merge, then deploy of the resulting activation |
| Denied | Closed PR, with reasons in review comments |
| Audit trail | Git log plus activation history |
| Request queue UI | The PR list |

Kix should not build request management. It should make the PR carry enough compiled evidence (exact diff, cost and blast radius, policy scorecard) that the merge decision is mechanical for the common case. Doc 91 §5's auto-merge lane then closes the loop: requests that stay on a blessed path, inside budget, and stateless can self-approve. The platform team's ongoing job is to define the policy that decides which PRs auto-merge. That is the scorecard rules engine that already exists (doc 60, archived).

This also makes the latency comparison with Kro more honest. Kro takes seconds from `kubectl apply` to reconcile. A naive git flow takes minutes and a human review. With the auto-merge lane, the blessed-path case is: portal writes file, CI compiles (~seconds on current clusters), policy passes, merge, operator deploys. Latency approaches the runtime model while keeping preview, audit, and rollback.

### 3.5 Agents consume the same interface

The exported schema from §3.1 is not just a form definition. A JSON Schema with a name, description, and typed parameters is also the shape of an agent tool definition (MCP / function calling). One compilation pass can therefore serve both audiences: humans get a form, agents get a tool.

Concept sketch of the loop:

```
tool: create_web-service        # derived from the web-service golden path schema

agent> create_web-service(name: "checkout-api",
                          image: "ghcr.io/acme/checkout:1.4.2",
                          domain: "checkout.acme.dev", replicas: 8)

kix:   writes instances/team-payments/checkout-api.json on a branch, compiles
       error[limit]: replicas 8 exceeds web-service max 5 (platform.nix:9)

agent> retry with replicas: 5
kix:   compiles clean; opens PR with diff + scorecard
policy: blessed path, in budget, stateless -> auto-merge -> deploy
```

Two observations follow, and both affect how existing work is prioritized:

1. **Structured diagnostics are the agent UX.** An agent iterates by reading compiler errors. "replicas 8 exceeds max 5, set in platform.nix:9" is actionable; a Nix trace is not. Doc 80 is therefore a platform feature, not only developer experience.
2. **Agents do not need a separate governance path.** Form users, editor users, and agents all converge on the same thing: a PR carrying a compiled preview, judged by compiler plus policy. The reviewer never needs to care who or what authored the JSON. Contrast the runtime model, where an agent's mistake is live the moment the CR is applied.

For a form-based portal, Kix competes with mature incumbents. For agent-driven self-service, a typed repo that can be compiled and previewed is a better foundation than a live API. Runtime tools cannot retrofit that compile step. This is likely where the interface actually gets used.

### 3.6 Validation: schema for speed, eval for truth

The exported schema (§3.1) is deliberately not the real validator. It covers what JSON Schema can express: types, required fields, enums, ranges. That tier lives in the browser (or in the agent's tool definition), fires per keystroke, and exists to make the interface responsive.

The authoritative tier is the compiler itself, used the way an IDE uses a language server: nobody reimplements the compiler's rules for the editor; a service runs the real compiler and maps its diagnostics back onto source positions. Here the source positions are form fields. A validation service holds a warm checkout of the repo, writes the candidate spec in as an instance file, evaluates the cluster, and returns structured diagnostics. Everything a schema cannot express comes for free, because it is the same eval that gates the PR: DI resolution, port existence, cross-instance ingress collisions, budget and policy checks.

This puts three requirements on Kix, all extensions of planned work rather than new machinery:

1. **Field-level attribution.** Diagnostics (doc 80) must attribute errors down to instance file plus option path. An option path maps one-to-one onto a JSON pointer, and a JSON pointer onto a form field. Cluster-level errors with no single field render as form-level errors.
2. **Batch reporting.** Nix stops at the first throw; a form (or an agent) wants all errors in one round. Doc 120 §3.4's recovery points get a second consumer here.
3. **A warm service.** Whole-cluster eval takes seconds on current clusters, which is fine on submit but not per keystroke. This wants a long-running `kix serve --validate` process, not a cold build per request.

Two properties fall out. First, submitted content is data, not code: evaluating a hostile JSON file through the loader executes nothing, which is why the input side can be exposed to low-trust requesters at all. Second, this one endpoint is the whole integration surface: the web form, the agent loop (propose, check, fix), CI on the PR, and any ticketing-system integration all speak the same "here is a candidate spec, what is wrong with it" call. Preview is the same service asked to go one step further and return the diff instead of just the verdict.

Only eval is needed for validation: all Kix checks fire at evaluation time, and "build" for a Kix cluster is little more than writing the manifest files (preview needs that build step; it is milliseconds on top of the eval). The one blur is `importChart`, which renders charts during eval; its cache key is chart + values text, so a form field only pays a re-render when it actually feeds a chart's values.

### 3.7 Hosting note: the validation service is the tenant worker

Running this service for multiple customers has one non-negotiable and one remembered trick.

The non-negotiable: **Nix eval is not a tenant boundary.** Pure-eval mode is good defense in depth, but the evaluator was never designed to contain hostile code, and a shared writable store would put every tenant's manifests (topology, hostnames, images) in one world-readable directory. The floor is one worker (container or microVM) plus one Nix store per tenant, with the store mounted at the canonical `/nix` as a detachable volume. Requests themselves are data and were never the risk; the tenant's own package code is what the boundary contains.

SaaS economics then come from around the worker, not inside it: a shared pool of pre-warmed *blank* workers that attach a tenant volume on demand (pool sized to concurrent demand, not tenant count), scale-to-zero per tenant, and a shared **read-only binary cache** all tenants substitute from, which gets better as tenants converge on the same stdlib and charts. The trick to remember: Nix's experimental **local-overlay store** takes this further, a shared read-only lower store holding the common paths with a per-tenant writable upper layer, giving disk dedup across tenants without a shared writable store. Replit runs this pattern at large scale. Start with the plain per-tenant volume; adopt the overlay when disk or cold-start substitution starts to hurt.

The same worker image is the on-prem product: SaaS runs many workers densely, enterprise runs one inside their own walls, and the deployment topology is the pricing tier. The worker must therefore stay self-contained and never assume the shared cache or control plane is nearby.

## 4. Versioning: mostly becomes git state

Runtime platforms need a versioning protocol (served versions, storage versions, conversion webhooks) because the intent store is decoupled in time from its interpreters. Live CRs must survive an RGD upgrade underneath them.

In the git-mediated model, instance files and the schema that interprets them are pinned in the same repo state. That has a few consequences:

- **The commit is the version.** No version field is required in the envelope.
- **Schema evolution is a refactor, not a migration protocol.** Changing a golden path's exposed options is a PR that must recompile every existing instance file. Breakage surfaces in CI before anything deploys. The fix is a codemod over JSON files in the same PR, landed atomically.
- **Version skew degrades to a rebase conflict.** If a portal wrote a file against a schema that moved before merge, the PR fails to compile; the portal re-fetches the schema and re-renders. Git already owns this failure mode.
- **Graceful windows are a package author's choice, not infrastructure.** A package that wants to accept two generations of spec can take a `schemaVersion` field and normalize internally (the NixOS `stateVersion` pattern). Nothing platform-level needs to exist for this.

Federated topologies (instances in team repos, package set pinned as a flake input) reintroduce skew across the pin, but they do so explicitly. Upgrading the pin is itself a compile-checked PR in the consuming repo.

## 5. Day-2 read-back: an assembly gap, not an architecture gap

Compilation answers "what will this change do"; it cannot answer "what state is my thing in now." A portal needs the second answer too.

Kro writes status onto the CR instance, and a portal reads it with one GET. Two honest qualifiers on that convenience: the status is shallow (resources created and became ready, not "your app is healthy"), and it is paid for with watch churn on the API server. Nothing architectural stops Kix from matching and exceeding it: the operator already watches deployed state for drift and health.

The gap is assembly. The pieces are the activation CR (deployed generation, content hashes), `kix health` (per-package live status), and a compiled catalog artifact carrying per-instance endpoints, owners, and dashboards as data inside the cluster artifact, so a portal can key live status by identifiers the compiler embedded. All of these exist or are on the roadmap (docs 62, 106, business 11 Pillar 1), but nothing joins them into a "status of my request" endpoint today. This is the part of the proposal with the least existing machinery. The recommendation is to treat catalog export plus status join as its own design doc once §3.1 and §3.3 exist.

## 6. Verdict vs. Kro

Same UX ceiling: both converge on a schema-driven form (or agent tool) in front of git. The differences are underneath:

| Dimension | Kix (this RFC) | Kro |
|---|---|---|
| Validation scope | Whole cluster, pre-merge | Per instance, at apply |
| Cross-instance conflicts | Compile error | Runtime discovery |
| Preview | Exact diff + blast radius before merge | None (apply and watch) |
| Schema evolution | Atomic repo-wide refactor, compiler-proven | CRD versioning under live instances |
| Golden path definition | Partial application over typed options | Flat hand-authored RGD schema |
| Request lifecycle | PR lifecycle, policy auto-merge | Build your own around the API server |
| Agent safety | Propose/compile/iterate before anything is live | Mistakes are live on apply |
| Runtime footprint | Inert manifests + thin operator | Controller with broad write permissions |
| Control-plane load | None added at request time; the work happens at build | Generated CRDs, per-RGD controllers, watch churn on the API server |
| Latency (blessed path) | Seconds-to-low-minutes via auto-merge | Seconds |
| Day-2 status read-back | Pieces exist, not yet joined (§5) | Built in, but shallow (CR status) |
| Adoption cost | Nix, a repo, CI | Install controller, write RGD |
| Ecosystem gravity | None yet | K8s SIG subproject |

Better or worse: for form-portal self-service today, Kro is faster to first wow. Kix is stronger in the places that matter at scale: verification, evolution, and audit. For agent-driven self-service, the compile step is the safety property, and only the compile-time model has it.

## 7. Alternatives considered

- **Portal-owned database as intent store, git as derived output.** Rejected: this recreates the drift problem between the platform's database and the repo, forfeits PR review as the approval mechanism, and makes the compiler a downstream consumer instead of the gate.
- **Hand-authored JSON Schemas per golden path.** Rejected per §3.1: a second type system that drifts from the module options interpreting the data.
- **Compile Kix packages into Kro RGDs.** Technically conceivable (both are resource graphs), but strategically wrong. It discards whole-cluster verification, the single property this RFC is built on, to inherit a runtime we do not control.
- **CRs as compiler inputs (runtime front door, compile-time core).** An operator mode could watch a request CRD, feed instances into the eval as JSON input, recompile the cluster, and apply. This would give Kro's UX with Kix's verification: the compile becomes the admission check. Deferred rather than rejected: it needs in-cluster eval (interesting_thoughts/89) and reopens doc 55's ownership questions. It has since been proposed independently a second time (as "manage requests via the operator instead of git"), which is usually the signal to take an idea seriously; promoted to open question 6.

## 8. Open questions

1. **Schema export fidelity.** Which module option types must round-trip to JSON Schema for real packages, and what happens at the boundary (e.g. `nullOr (submodule ...)`, freeform attrsets)? This needs a survey over existing package options.
2. **`loadInstances` failure UX.** A malformed instance file should produce a doc-80 diagnostic pointing at the JSON file and key, not a Nix trace into the loader.
3. **Limits vocabulary.** `limits.replicas.max` in §3.2 is ad hoc. Should golden-path limits reuse the scorecard rules engine instead of growing a parallel constraint language?
4. **Identity in the auto-merge lane.** Team ownership via directory + CODEOWNERS covers humans; what identity does an agent's proposal carry, and does the policy lane need to distinguish it? (Suspicion from §3.5: it should not, but secrets and budget attribution may force it.)
5. **Catalog/status join (§5).** This needs its own design doc: what exactly does the compiled catalog artifact contain, and what serves the "status of my request" query?
6. **The operator as request channel (§7).** For organizations where requesters must not touch git at all, the operator could accept requests directly as CRs fed into the compile. What is the minimum version: does it require in-cluster eval (interesting_thoughts/89), or can the operator delegate compilation to CI and only gate on the result?
