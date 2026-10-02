# 156: The cross-organisation boundary

**Status:** RFC / Draft
**Related:** `45_multi_team_and_operator_models.md` (work styles, assumes mutual trust), `129_scaling_axes_fleet_and_linking.md` §5–6 (linking when trust is low), `127_compiler_target_model.md` (platform imports are the ABI), `117_self_service_platform_interface.md` (schema export; §3.7 eval is not a tenant boundary), `140_catalogue_versions_and_upgrade_windows.md` (per-client pin cadence), `business_discussions/51_kix_airlock.md` (the mirror case: vendor into customer cluster)

## 1. Problem

Two parties share a Kubernetes cluster and both want to use Kix, but neither
should get the other's Kix source:

- **A platform team and its consumers** inside one organisation. The consumers
  may be several teams. The goal is less secrecy than control: consumers, and
  their AI agents, should work against a stable surface without reading or
  editing platform code.
- **Lithus and its clients.** Lithus's platform code is proprietary. Clients
  want to deploy their own workloads with Kix on top of it.

Both cases get equal weight. Lithus has the stronger secrecy need. The
internal case has more consumers and more agents.

Settled in discussion (2026-10-02):

- "Each side cannot see the other's code" means **source**. Whoever runs the
  cluster can read every applied manifest, so hiding output from the platform
  is impossible and is not a goal.
- The consumer receives a **generated, data-only interface flake** (§3).
- The checks we want across the boundary: contract and type checks, ownership
  collisions, cross-boundary network policy, and platform policy and budgets.
  We want to know which of these can be done without much new machinery. If one
  needs a lot, it belongs in a separate enterprise product (§6).

## 2. The rule that draws the line

> **The open core never evaluates code from two trust domains in one
> evaluation. It exchanges data across the boundary.**

This rule is technical, not commercial. Nix evaluation is not a security
boundary (117 §3.7): any package can read anything else in the evaluation, and
the evaluated store paths are world-readable. If both sides' code is evaluated
together, whoever runs that evaluation sees everything. A joint evaluation
therefore needs a host both parties trust, running a sandboxed worker per
pairing, and that host is operational infrastructure. Infrastructure is a
product, so the commercial line falls where the technical line does (§6).

Everything below sorts each wanted capability by one question: can it be
answered from one side's graph plus a data file from the other side?

## 3. The interface flake

The platform build already knows everything a consumer needs: the cluster's
facts, the services on offer, their `out` contracts, and the options a
consumer may set. `kix export-interface <cluster> --for <consumer>` writes
that down as data:

```
lithus-interface-acme/            # one per consumer, published to the consumer
  flake.nix                       # exposes kix.interface; no package code
  facts.json                      # flavor facts: provider, k8s version, storage classes, availability, PSA level
  imports.json                    # granted services: name, roles, out (host, port, secretRef, selector, ...)
  namespaces.json                 # namespaces the consumer owns, with quotas
  policy/                         # platform rules, as scorecard rules and admission policy (§5.4)
  schema/                         # JSON Schema + docs for each granted golden path (117 §3.1)
```

The consumer's cluster definition consumes it:

```nix
kix.buildCluster {
  name = "acme";                               # its own Kix cluster name
  modules = [
    lithus-interface-acme.kix.interface        # flavor + mkImport instances + policy
    ./acme.nix                                  # the consumer's own instances
  ];
}
```

Most of this exists already:

- `mkImport { out = { ... }; roles = [ ... ]; }` (`kix/lib/eval/import.nix`) is
  an instance with no package code. It carries only an `out` contract and the
  roles it fills, and the resolver already treats it as a weak symbol. An
  exported service is one of these with `out` filled from the platform's build.
- A flavor is already the statement of what the environment provides (127).
  The exported facts are the platform's resolved flavor.
- Several Kix clusters can share one Kubernetes cluster since 2026-09-28: each
  command sees only its own cluster's objects, and an orphan another cluster
  still builds is kept (ROADMAP, "Commands see one Kix cluster's objects").
  The consumer deploys as its own Kix cluster onto the platform's Kubernetes
  cluster.
- Secret and service references across the boundary use `mkSecretRef` and
  `mkServiceRef`, which emit import markers polled at deploy time.

New work: the export command, a per-consumer filter over what is exported, and
a small loader that turns the JSON into mkImport instances and a flavor. Only
the `out` values of granted services leave the platform. Package code, other
consumers' grants, and ungranted topology stay behind.

**Agents.** The consumer repo holds the consumer's code, a pinned data flake,
and generated schemas and docs. An agent working there can learn the full
contract from `schema/` and cannot reach platform code, because it is not on
disk. This is the main thing the internal case wants, and it needs nothing
beyond the export.

## 4. Pinning and change flow

No integration repo is needed in the open core. Each side owns its own repo,
and the interface is a versioned artifact between them.

- **Platform → consumer.** The platform publishes interface versions (git
  tags on a repo the consumer can read, or a tarball). The consumer pins one
  in `flake.lock`. Moving the pin is a PR in the consumer repo, and Kix
  compiles it before merge (117 §4). How fast a client must move is the
  catalogue-window question of doc 140.
- **Consumer → platform: usage files.** The consumer build writes
  `usage.json`: which granted imports it references and which `out` fields it
  reads. The consumer publishes it back. The platform's CI checks every
  consumer's usage file against the interface it is about to publish, and
  fails with "removing `postgres.out.replicaHost` breaks acme". This is a
  consumer-driven contract test (the Pact pattern), done on data only.

That gives each side early warning of the other's breaking changes without
either reading the other's source.

## 5. The four checks

### 5.1 Contract and type checks: free

The consumer's evaluation resolves its references against the exported
imports. A reference to a service that was not granted, or to an `out` field
that does not exist, fails evaluation on the consumer's machine. This is
ordinary DI resolution against mkImport instances. On the platform side, the
usage files (§4) cover the reverse direction.

### 5.2 Ownership collisions: a deploy-time check, backed by RBAC where possible

Two deployment shapes need different answers.

**The consumer has scoped rights.** The platform holds the cluster and can
enforce the split with RBAC. Kix generates each consumer's permissions from
the same export (Role, RoleBinding, ServiceAccount or OIDC binding): rights
only in the namespaces in `namespaces.json`, and no cluster-scoped rights
unless granted. A consumer build that tries to create `Namespace/monitoring`
or its own CNI gets a 403 from the API server.

**Both sides are cluster admins.** This is the usual Lithus arrangement, and
RBAC separates nothing. Here the collision check from 129 §6 is the main
protection, not a same-organisation extra. `kix deploy` refuses to apply an
object, or claim a strong role, that another Kix cluster's active Activation
record owns.

The check fits the rule in §2 because it reads only data already in the
cluster. Activation records list the objects each Kix cluster owns, by kind,
namespace, and name, and an admin can read all of them anyway. No source
crosses the boundary. Most of the reading side exists: since 2026-09-28 every
sweep attributes each object to its Kix cluster through the records
(`fetch::attribute`). What is missing is the refusal.

That changes one current default. Today two Kix clusters that render the same
object share it, and an orphan another cluster still builds is kept. Between
organisations, sharing should be refused unless both sides declare it, for
example a CRD the platform installs and the consumer also bundles. This needs
an answer to the ROADMAP open question "Two Kix clusters that render one shared
object differently". A plausible answer is a per-pair setting: same-organisation
Kix clusters share by default, and cross-organisation pairs refuse by default.

With admin rights on both sides, the check prevents mistakes, not misuse.
`kubectl` and Helm bypass it, and so does a deploy with the check switched
off. It turns "the client's agent overwrote our ingress controller" into a
refused deploy with the owning Kix cluster named. The interface flake also
lists the platform's namespaces and strong roles as reserved, so the
consumer's evaluation refuses them before deploy.

### 5.3 Cross-boundary network policy: grants make it one-sided

This is the one that looks like it needs both graphs, and it does not if
access is a grant rather than a discovered edge.

- **Consumer egress** to platform services is derived today: edges reaching
  import-mode references produce egress rules (`plugins/netpol/derive.nix`),
  using the selectors and ports in the import's `out`.
- **Platform ingress** from consumers is derived from the grant list the
  platform already keeps to produce the export: "acme may reach
  `postgres-shared`" becomes an ingress rule on `postgres-shared` from acme's
  namespaces. The platform never needs to know which consumer workload makes
  the call. Namespace labels are a safe selector when the platform creates
  the consumer namespaces and the consumer has no rights to relabel them.
  When the consumer is also an admin, the labels are guarded only as well as
  §5.2 guards any other platform object.
- **Consumer → consumer** traffic goes through the platform as a grant too, or
  is denied.

The cost is granularity. Platform ingress allows a consumer's namespaces, not a
specific consumer workload. Workload-level ingress would need the consumer's
graph, which is a joint evaluation (§6). For the Lithus case the
namespace-level rule is the right trust unit anyway.

### 5.4 Platform policy and budgets: two forms from one source

The platform's rules (quotas, PSA level, allowed registries, required
probes, maximum replicas) are written once as a Kix policy module and exported
in two forms:

1. **Scorecard rules** in `policy/`, which the consumer's `kix check` runs
   locally and in pre-commit. This gives early feedback and SARIF output.
2. **Admission policy** (ValidatingAdmissionPolicy, plus ResourceQuota and
   LimitRange on consumer namespaces) that the platform's own build deploys.
   This is the guarantee, enforced by the cluster whatever tool the consumer
   used.

Shipping the scorecard rules as data needs one check: today rules are Nix
functions. Exported rules are platform code the consumer evaluates. That is
acceptable if the rules are published openly (they describe policy, not
platform internals) and the consumer evaluates them in their own trust domain.
If rule source must stay secret, only the admission form is exported and the
consumer finds out at server-side dry-run (51 axis 2, rung 2).

Cluster-wide capacity (do all consumers together fit on the nodes) is not
answerable from one side and is not attempted. Quotas bound it.

## 6. What needs joint evaluation

What remains after §5 is what genuinely needs both graphs in one evaluation:

| Capability | Why it needs both graphs |
|---|---|
| Workload-level network policy across the boundary | Platform ingress must name consumer workloads |
| Whole-cluster preview | One `kix diff` over platform and all consumers |
| Redacted cross-boundary diagnostics | "Your change fails because of platform resource X", rewritten so X's details stay hidden (51 axis 1, rung 3) |
| Platform-change impact beyond `out` fields | "Your Postgres upgrade changes connection behaviour that acme's migration Job depends on" |
| Cross-organisation rollout ordering | Deploy platform change, then consumer changes, as one plan |
| Whole-cluster capacity planning | Real requests from every side against real nodes |

All of these need a trusted evaluator: a host both parties trust, holding
both sources, evaluating in an isolated worker, and returning to each side only
what that side may see. The pieces it would reuse are already designed: the
per-tenant worker (117 §3.7), the Airlock's redaction and exposure dial (51),
and the operator reporting cluster state back. Operationally it is Kix Cloud
plus the operator.

**Technical recommendation:** §3 to §5 belong in the open core. Each is a
small extension of something that exists, and none adds a new trust
assumption. §6 is a separate product. Each of its rows is a convenience or a
finer grain over something §5 already guarantees coarsely, so a team that
never buys it still has a safe boundary.

The business answer may move the line further in (for example, keeping
`kix export-interface` for paid tiers). The technical constraint only says the
line cannot move further out: the open core cannot offer joint evaluation
without someone running the trusted host.

## 7. Examples: what works and what does not

The examples use Lithus as the platform and Acme as a client. Both are cluster
admins unless stated. "Open core" means the design in §3 to §5. "Joint
evaluation" means the paid trusted evaluator in §6.

### Works in the open core

- **Acme connects an app to the shared Postgres.** Lithus has granted Acme
  `postgres-shared`. Acme's app references it, Kix fills in the host, port,
  and secret from the interface, and generates Acme's egress rule. Lithus's
  build generates the matching ingress rule from its grant. Neither side
  reads the other's code.
- **Acme typos a field.** Acme's app reads `postgres-shared.out.hots`. Acme's
  build fails on Acme's laptop with "no such field". Nothing reaches the
  cluster.
- **Acme uses a service it was not granted.** Acme references
  `redis-internal`. It is not in Acme's interface, so Acme's build fails before
  deploy.
- **Lithus is about to remove a field Acme uses.** Lithus's CI reads Acme's
  `usage.json`, sees Acme reads `postgres-shared.out.replicaHost`, and fails
  Lithus's PR with "this breaks acme". Lithus decides whether to keep the
  field or warn Acme first.
- **Acme's agent tries to deploy its own ingress controller.** Acme's build
  refuses, because the interface marks the ingress role as Lithus's. If Acme
  edits the interface to get past that, `kix deploy` still refuses, because
  Lithus's deploy record owns the ingress controller.
- **Acme's agent tries to overwrite `ConfigMap/coredns`.** Same as above:
  `kix deploy` refuses and names the Lithus Kix cluster as the owner.
- **Acme runs a container as root on a cluster that forbids it.** Acme's
  `kix check` reports it locally from the exported policy rules. If Acme
  ignores that, the cluster's admission policy rejects the Pod.
- **Lithus upgrades the cluster and changes a fact.** Lithus publishes a new
  interface version with the new Kubernetes version. Acme moves the pin in a
  PR, and Acme's build tells Acme what no longer fits before Acme merges.
- **An AI agent works in Acme's repo.** It can read the schemas and docs for
  every service Acme may use. It cannot read Lithus's packages, because they
  are not in the repo.

### Does not work in the open core

- **Lithus wants to see why Acme's build failed.** Lithus cannot see Acme's
  source, only what Acme deploys. Acme has to share the error.
- **Lithus wants to let only Acme's `billing` app reach Postgres, not all of
  Acme.** The open core allows Acme's namespaces as a whole. Per-workload
  rules need both graphs: joint evaluation.
- **Acme wants one diff showing its change and Lithus's pending change
  together.** Each side previews only its own Kix cluster. Joint evaluation.
- **Acme's deploy fails because of a Lithus resource, and Acme wants to know
  which one.** The open core can say "refused: owned by Kix cluster lithus".
  It cannot explain the internals of Lithus's resource. A redacted
  explanation is joint evaluation.
- **Lithus wants to know whether all clients together fit on the nodes.**
  Quotas bound each client. A whole-cluster answer needs every client's real
  requests in one place: joint evaluation.
- **Lithus wants to roll out a Postgres change, then Acme's matching change,
  as one plan.** Each side deploys on its own schedule. Joint evaluation.

### Does not work at all

- **Acme uses a Lithus golden path without seeing its code.** A golden path is
  a Lithus package. Using it means having its source. Lithus either publishes
  it openly or compiles Acme's request itself (§9, question 2).
- **Lithus hides Acme's deployed manifests from Lithus.** Lithus runs the
  cluster and can read everything in it. Only Acme's source stays private.
- **Acme, as an admin, is prevented from changing Lithus's resources at
  all.** The ownership check stops Kix deploys. It does not stop `kubectl
  edit`. Only scoped RBAC does that, and Acme then has to give up admin
  rights.

## 8. Work, roughly in order

1. `kix export-interface`: facts, granted imports, namespaces, schemas. Data
   only, filtered per consumer.
2. Interface loader in `kix/lib`: JSON to mkImport instances, flavor, reserved
   names and roles.
3. Deploy-time ownership refusal across Kix clusters, with a per-pair sharing
   setting (§5.2). Needed first for Lithus, where both sides are admins.
   Generated per-consumer RBAC and namespace quotas follow, from the same
   grant list.
4. Ingress derivation from grants in the netpol plugin.
5. `usage.json` emission on the consumer side and a platform CI check against
   it.
6. Policy export: scorecard rules plus generated admission policy.

1 and 2 alone are useful to the internal case (agents and source separation)
and to a first Lithus client.

## 9. Open questions

1. **Grant model.** Where does the platform declare "acme may use
   `postgres-shared`"? Per-consumer files in the platform repo, or a field on
   the exported instance? It drives RBAC, ingress, and the export, so it needs
   one home.
2. **Golden paths across the boundary.** 117's golden paths are partially
   applied platform packages. A consumer that wants a platform-provided "web
   app" shape needs the package code, which breaks §2. Either golden paths are
   published openly as a separate public package set, or the consumer submits
   instance files and the platform compiles them (117's request model, which
   gives up the consumer's own `kix deploy`).
3. **Who runs the operator.** One Kix operator per Kubernetes cluster owned by
   the platform, reconciling both Kix clusters? Or one per Kix cluster? The
   consumer must not gain the platform operator's rights through it.
4. **Are policy rules secret?** If a Lithus client must not see Lithus's
   rules, §5.4 loses its local half. Rules are probably fine to publish.
5. **Same-organisation teams.** Does a platform team with internal consumers
   want the full split, or the sliced compilation of 129 §6 with CODEOWNERS?
   The split costs the cross-team eval-time checks. A plausible answer is that
   internal teams start sliced and move to the split when they want agent
   isolation.
6. **Interface distribution.** A git repo per consumer is simple, but at many
   consumers a registry (or the Lithus portal) serving versioned tarballs may
   fit better.
