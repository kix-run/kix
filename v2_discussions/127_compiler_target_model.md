# 127: Compiler target model — axioms, roles, and the boundary

**Status:** RFC / Draft
**Related:** `119_core_surface_audit.md` (flavor-as-target verdict, §1/§beyond-11), `120_compiler_theory_mapping.md` (§2 weak/strong symbols, §3.8 legalization), `126_compiler_core_rewrite_plan.md` (Phase 5 flavor pruning — dissolved by this doc), `63a_storage_as_cluster_concern.md`, `93_flavor_barrier_resource.md`, `26_images-vertical-integration.md` (BGP, node images), `106_ops_lifecycle_verbs_and_capacity_check.md`, `interesting_thoughts/69_hardware_driven_scheduling.md`, `archive/45_cluster_hardware_profile.md` (built `cluster.nodes`)

Doc 119 settled that the flavor *mechanism* is core — "capabilities are the
instruction set, platform imports are the ABI." This doc works out what that
actually means structurally, starting from two observations that turn out to be
one problem:

1. `cluster.capabilities` duplicates `meta.provides` and platform imports
   without merit — most capability facts are derivable from the graph.
2. Flavors start at incommensurable "levels" (node-only, bare metal, rke2,
   lithus-with-overrides) and no single abstraction level feels right.

## 1. The boundary model

The stack under a workload is real:

```
L0 nodes/hardware → L1 OS → L2 k8s distro + control plane → L3 platform base (CNI, DNS, storage, LB) → L4 workloads
```

But the compiler never needs this taxonomy. It needs exactly one line: **the
boundary between what the environment provides (axioms) and what kix compiles
(the graph)**. A flavor is a *cut* through the stack, and different flavors cut
at different heights — kind cuts above L3 (everything below is environment: a
*hosted* target), kubeadm cuts at L2 ("platform base is BYO"), lithus cuts
nearly at L2 and is almost *freestanding*: kix compiles the platform base
itself (cilium, OpenEBS, DiskPools) and the environment is rke2 plus node
facts.

There is no canonical level **because the level is a per-cluster choice**. The
target model's job is to make the boundary explicit and movable, not to pick a
height. The Linux triple went through the same confusion (musl vs gnu = same
OS, different runtime; `-ffreestanding` = "no OS, I bring the runtime") and
resolved it the same way: feature facts plus a choice of what you link against
vs what you provide.

Two rules imported from that history:

- **The provider name is the vendor field.** `cluster.provider = "gke"` is
  carried for telemetry and display; nothing in the compiler may branch on it.
  Branch on facts. This is what keeps flavor #14 from ever needing code.
- **Stable under scope growth.** When kix grows downward (doc 26 node images,
  eventually distro config), facts migrate from axiom to derived and the
  boundary moves down. Same mechanism the whole way; no remodel.

## 2. Capabilities split: role-backed (derived) vs substrate (axioms)

Sort today's 14 `cluster.capabilities` fields by where the fact lives:

**Role-backed — derivable, currently triplicated.** `persistentStorage`,
`rwxStorage`, `volumeSnapshots`, `loadBalancer`, `ingressController`, `cni`,
`networkPolicyAPI`. Each states "something provides role X," and the compiler
already has two mechanisms saying exactly that: platform imports (weak — the
environment provides dns/storage) and `meta.provides` (strong — a managed
instance provides network-policy-enforcer). The declared bool is a third,
hand-maintained restatement. lithus is the smoking gun: it forces
`persistentStorage = true` *and* instantiates OpenEBS — one fact, two
statements, free to drift.

These become a **resolved provider index**: role → provider, built from
phase-1 peeked meta + platform import declarations (no new fixpoint — same
timing as the DI resolution index). A needed role with no provider is a link
error, and sub-facts move onto the provider's `out` contract where they belong.

**Binding modes — the environment exports strong symbols too.** Today's DI
rule "managed shadows import" is right for some roles and dangerous for
others. DNS is *shadowable*: coredns keeps running, your managed instance
simply wins resolution — additive, safe. The CNI on stock kind is
*exclusive*: kindnet owns the pod network, and deploying a second CNI doesn't
shadow it, it breaks the cluster. So an environment-provided role carries a
binding mode as part of the axiom:

- `absent` — role vacant; a managed instance fills it (or link error if
  someone needs it).
- `shadowable` — environment provides a default (weak symbol); a managed
  instance overrides cleanly.
- `exclusive` — environment provides it and the resource is singular (strong
  symbol); a managed instance claiming the role is a **duplicate-symbol error
  at eval**, pointing at the axiom to change (e.g. "use the kind variant with
  the default CNI disabled") rather than a cluster that breaks at deploy.

This extends the existing refusal law (ambiguity throws) across the boundary:
two strong providers never silently coexist, whether both are managed or one
is the environment (`rwxStorage`, `volumeSnapshots` are properties of
the storage provider, not the cluster — doc 63a's conclusion arriving from the
compiler side). `networkPolicyAPI` likely dissolves entirely: the enforcer's
`out.netpol` interface *is* the API statement.

**Substrate — genuine axioms.** `multiNode`, `managedControlPlane`,
`podSecurityEnforcement`, `privilegedContainers`, `daemonSets`,
`nodeAutoscaling`, `gpu`, `availabilityZones`. Common denominator: facts about
layers below the compilation boundary. No graph walk derives `multiNode`; you
cannot compile your way to a second node. These stay declared — or probed
(§5).

Legalization then has three legs: **link checks** (roles resolved),
**substrate gates** (the existing daemonSet/privileged/LB checks, now reading
axioms), and **data passes** (apiVersion schedule vs `k8sVersion`, PSA level
checks — doc 120 §3.8, unchanged by this doc).

## 3. Axioms live in the module system — packages assert via `clusterConfig`

Axioms are ordinary NixOS-style options under `cluster.*`. This is mostly
status quo (`cluster.capabilities`, `cluster.nodes`, `cluster.network` are
already options; packages already receive `clusterConfig`), sharpened into a
rule:

- **Every axiom is a declared, typed option.** The `clusterConfig.cluster.domain`
  incident (doc 119 sharp-edge list: three packages read an undeclared option
  that is always null) is the failure mode this rule kills. Undeclared reads
  are silent nulls; declared options are schema, docs, and merge semantics for
  free. No second type system (doc 117's principle) — the module system *is*
  the target schema.
- **Any package can assert against axioms.** The diagnostics engine
  (`meta.nix` assertions/warnings) already evaluates package-declared
  assertions; pointing them at `clusterConfig` requires no new mechanism:

  ```nix
  meta.assertions = [{
    assertion = clusterConfig.cluster.substrate.rdma.available or false;
    message = "training-operator needs RDMA-capable nodes (substrate.rdma)";
  }];
  ```

  A structured `meta.requires.substrate` sugar can come later by the demand
  test; the raw form works today.
- **Three-valued semantics.** `unknown` (null) is not `false`. Violating a
  declared-false axiom is an error; relying on an unknown one is a warning
  naming the axiom to declare or probe. This keeps sparse target descriptions
  honest — a homelab target that never mentions AZs shouldn't hard-fail a
  package that merely prefers spread.

## 4. The substrate vocabulary — model what *can* be known

The exciting part: once axioms are just options, the vocabulary can grow to
encode real infrastructure knowledge — all optional, all defaulting to
unknown, each admitted only with a consumer (doc 119's demand test — the
vocabulary is open, but every word needs a first sentence). Candidate shape:

```nix
cluster.substrate = {
  topology = {
    region = "eu-central";                     # fleet-level later (69) — declare, don't consume yet
    zones = [ "a" "b" "c" ];
    racks = { r1 = { zone = "a"; }; ... };     # containment hierarchy: region ⊃ zone ⊃ rack
  };
  fabrics = {                                  # connectivity RELATIONS — which nodes share an
    ib-island-1 = {                            # interconnect; distinct from containment (an IB
      type = "infiniband";                     # island can span racks, a rack can host two islands)
      bandwidthGbit = 400;
      topology = "non-blocking";
      nodes = [ "gpu-1" "gpu-2" ... ];
    };
    nvl-domain-a = { type = "nvlink"; nodes = [ ... ]; };   # rack-scale NVLink (NVL72-style)
  };
  nodes.<name> = {                             # extends the built cluster.nodes (45)
    roles, cpu, memory, labels, taints,        # existing
    zone = "a"; rack = "r1";
    gpu = { model = "h100"; count = 8; interconnect = "nvlink"; };  # intra-node NVLink is a node fact
    nics = [ { bandwidthGbit = 100; rdma = "roce"; } ];
    disks = [ { class = "nvme"; iops = 1000000; } ];
  };
  network = {                                  # extends cluster.network
    mtu = 9000;
    dualStack = false;
    bgp = { asn = 64512; peers = [ ... ]; };   # doc 26's capability contract
    lbPool = "10.0.240.0/24";
  };
  power = { ups = true; };                     # homelab: feeds maintenance/backup posture (105)
};
```

What earns each word its place — concrete consumer pairings:

| Axiom | First consumer |
|---|---|
| `topology.zones` + `nodes.*.zone` | derive `topologySpreadConstraints`/PDB posture instead of hand-writing them (automation over brevity — same move as netpol); graduate `hasPDB` from opt-in rule to derivation |
| `nodes.*.gpu`, `nics.rdma` | legalization for AI workloads (doc 72 recipes): a package requiring RDMA on a substrate without it is a *link error at eval*, not a pod stuck in Pending — extends "know what will happen" below the K8s API |
| `fabrics.*` | gang-placement legalization for distributed training (docs 72/73): "this PyTorchJob wants 16 nodes on one IB island; the largest island has 8" fails at eval, not as a job running at ethernet speed; derivation target: node affinities / topology labels (the `gpu.clique`-style domain labels schedulers key on) rendered from the domain membership |
| `nodes.*.cpu/memory` totals | doc 106's capacity-fit check (already planned, already assumes this data) |
| `network.serviceCidr` | doc 109's CIDR budget (already planned) |
| `network.bgp` | doc 26: one declaration → frr/bird config + cilium/metallb CRs |
| `topology.region` | fleet/multi-cluster horizon — declared now at most, consumed never (69 stays future) |
| `power.ups` | backup/maintenance posture hints (105/112) — speculative, listed to show the vocabulary's reach, not to build |

The scheduling question (how deeply to model hardware) stays parked in doc 69;
this doc only claims the *schema location* — when scheduling work starts, its
facts land as substrate axioms rather than a parallel model.

## 5. Flavors decompose: target presets + stock catalogs (demand-rooted)

First, the principle that separates kix from every runtime-managed platform
(OpenShift capabilities, addon managers): **demand-rooted closure. A "choice
to turn something on" does not exist.** Kix compiles top-down: everything in
the artifact is reachable from a demand — a workload dependency, an
operator-declared intent, or a legalization requirement. Nothing is installed
because a platform vendor bundled it. The Activation closure already enforces
this mechanically (unreachable = not in the artifact; orphan detection flags
the half-wired). A flavor therefore never *installs* anything; it declares
three kinds of facts the compiler may use:

- **hardware/substrate facts** (§4 axioms),
- **capability limits** (negative axioms: autopilot's `daemonSets = false`,
  PSA restrictions, exclusive role bindings §2),
- **available stock services** — role providers on offer, used *if demanded*:
  environment-provided ones as weak bindings (kind's coredns), kix-buildable
  ones as `availablePackages` entries that auto-instantiation pulls in when
  the graph demands the role (the resolver already exists — `eval/auto.nix`).

So a flavor decomposes into:

- **Target preset** — the axiom set (facts + limits + weak bindings). Pure
  data, composable by ordinary module layering (`rke2` ⊂ `lithus` is option
  composition, not inheritance).
- **Stock catalog** — the buildable providers a flavor puts on the shelf
  (lithus's cilium + OpenEBS + DiskPools). *Not* instances: catalog entries +
  role bindings, instantiated only on demand. A cluster with no PVC-bearing
  workload compiles on lithus without OpenEBS in the artifact.

lithus = `target(rke2 axioms + node facts + limits)` + `catalog(cni +
storage)`. The current file's weirdness (309 lines, half verbatim
StorageClasses instantiated unconditionally) is exactly the conflation — and
the unconditional part is the OpenShift-style component toggle this section
abolishes.

**Probe: the target file is an environment lockfile.** The unvalidated-flavor
problem (9 of 13 presets are guesses — doc 119) is unsolvable by hand
maintenance. The compiler answer is `-march=native`: a `kix target probe` CLI
verb reads a live cluster (server version, StorageClasses + default,
Ingress/GatewayClasses, CNI/enforcer, PSA labels, node inventory incl. zones
and GPU/NIC labels) and emits a target file. Presets split into *curated*
(tested trio) and *probed* (your actual cluster); the differential test is
`probe(kind cluster) ≡ kind preset`. Probe generates source — the build stays
pure. What `flake.lock` is to inputs, the probed target is to environment
facts.

## 6. Worked examples (conceptual)

**Cilium in your instances on the kind flavor** — the binding-mode case, in
both directions. On *stock* kind, the target declares the cni role
environment-provided and **exclusive** (kindnet owns the pod network). Adding
a cilium instance is then an eval-time duplicate-symbol error: "cni is
exclusively provided by the environment (kindnet); switch to the
no-default-CNI kind target or drop the managed CNI." Today nothing catches
this — you find out at deploy time when two CNIs fight over the nodes. The
working setup (what ludo-kind amounts to) is the *other* kind variant: default
CNI disabled, one axiom different — cni role `absent`. There the cilium
instance fills cni and provides enforcement, and the derived index upgrades
accordingly with zero hand-edited capability bools (today this takes
remembering that kind's preset said `networkPolicyAPI = "none"` and overriding
it). Same package set, two kind targets, and the compiler tells you which one
you're actually on: plain kind + a package needing enforcement = link error;
no-CNI kind + cilium = resolves. The effective capability is computed, not
maintained — and the incompatible combination is refused, not deployed.

**RWX storage** — sub-facts on the provider, not the cluster. A package asks
for the storage role and needs RWX. On EKS the role is satisfied weakly by the
EBS platform axiom, whose contract says `rwx = false` → link error naming both
sides ("immich needs rwx; provider platform-storage(EBS) offers rwx=false").
Add an EFS/Garage instance → strong provider with `rwx = true`, resolves. No
`cluster.capabilities.rwxStorage` bool anywhere — the fact lives on whichever
provider wins, so it can't drift from reality.

**RDMA training job** — substrate axiom + three-valued semantics. A
training-operator package asserts `cluster.substrate` RDMA via
`meta.assertions` against `clusterConfig`. On a probed lithus target whose
node NICs carry `rdma = "roce"` it compiles; on gke-autopilot (declared
absent) it fails at eval with the axiom named — a Pending pod diagnosed before
anything touched a cluster; on a target that never mentions NICs it emits a
warning: "relies on unknown axiom substrate.nodes.*.nics.rdma — declare it or
run `kix target probe`". Error on false, warning on unknown.

**Zones → derived spread** — axioms feeding derivation, not just gates.
`topology.zones = ["a" "b" "c"]` plus node zone facts lets the compiler derive
`topologySpreadConstraints` and PDB posture for multi-replica workloads (the
same automation-over-brevity move as netpol: intent exists, mechanism is
derivable). On a single-zone or zone-unknown target the derivation is skipped
— visibly, not silently, per the three-valued rule.

## 7. Alternatives considered

- **Keep the declared capability matrix** — status quo; rejected: it's the
  drift-prone triplication §2 documents.
- **A capability type system** (graded capability objects, versions, feature
  lattices) — rejected for now: module options are the schema (117); graded
  facts that exist today (PSA levels) are just enum options.
- **Model the stack levels explicitly** (per-layer target sections with a
  fixed taxonomy) — rejected: the boundary is the only distinction the
  compiler consumes; a level taxonomy invites classification debates with no
  consumer.
- **Fleet/region-first modeling** — deferred with doc 69; single-cluster depth
  first.

## 8. Migration sketch (order, not commitment)

1. Provider index: generalize `findCapabilityProvider` + platform-import
   aliases into one role registry (rides doc 121's mechanism, already in
   `eval/hooks.nix`).
2. Point the capability gates at it; prune the role-backed bools from
   `modules.nix`; move rwx/snapshot facts onto storage-provider `out`.
3. Split lithus into target preset + stock catalog (proof case; the lithus
   cluster must build identically as long as its workloads demand storage —
   which they do).
4. Declare the axiom rule: sweep packages for undeclared `clusterConfig`
   reads (the `cluster.domain` class), declare or kill each.
5. Substrate vocabulary: admit words with their first consumer (capacity-fit
   and zones/PDB derivation are the natural firsts).
6. `kix target probe` (CLI work; after the schema settles).

## 9. Grounding: prior art to copy, datasets to mine

Two evidence classes, don't conflate them: **shape evidence** (how systems
that survived contact model this) and **distribution evidence** (what real
clusters actually run — ranks which vocabulary words matter).

**Shape — copy from these:**

- **OpenShift is the strongest validation of this doc's split** — it converged
  on the same three-way decomposition: the `Infrastructure` CR is the target
  record (platform enum + `controlPlaneTopology`/`infrastructureTopology` =
  substrate axioms), `ClusterVersion.capabilities`
  (`baselineCapabilitySet` + `additionalEnabledCapabilities`) selects optional
  components, and `ClusterOperator` objects are the provider index with
  status. **Copy the taxonomy, not the mechanism** (§5): their capability
  *list* is field data on which roles exist in practice; their explicit
  enable/disable *mechanism* exists because a runtime reconciler cannot see
  workload demand — kix derives demand from the graph, so the toggle has no
  kix equivalent. Same inversion for their additive-only ratchet (CVO refuses
  to disable an enabled capability): they can't remove safely because runtime;
  in kix a provider drops out when its last demand does, and the closure diff
  shows it before it happens. Everything is downloadable for review:
  `github.com/openshift/api` carries the Go types with godoc
  (`config/v1/types_infrastructure.go`, `types_cluster_version.go`) and
  generated OpenAPI CRD schemas; the REST reference on docs.openshift.com
  mirrors it per version.
- **Gardener `CloudProfile`** — SAP's fleet manager has a literal
  target-catalog CRD: machine types (cpu/gpu/memory), volume types with
  class, regions with zones, OS images — per provider environment. The
  closest existing schema to §4's substrate vocabulary for hosted targets;
  worth a field-by-field read (`gardener/gardener` repo,
  `example/30-cloudprofile.yaml`).
- **nixpkgs `lib.systems`** — the philosophical relative in our own
  ecosystem: a small identifier (`aarch64-linux`) *elaborates* into a rich
  platform record, and the ironclad convention is branching on elaborated
  facts (`isLinux`, `isAarch64`), never on the string. This is §1's
  vendor-field rule with fifteen years of enforcement history, and the
  elaborate-from-preset pattern is exactly target-preset → resolved record.
- **Talos machine config** — fully declarative node facts (the L0/L1 layer as
  data); relevant the moment doc 26 moves the boundary down.
- **Node Feature Discovery (NFD)** — a ready-made substrate label taxonomy
  (`feature.node.kubernetes.io/network-rdma.available`, cpu/kernel/pci/
  storage/system sources) and the obvious probe backend: `kix target probe`
  should *consume* NFD/GFD labels where present, not reinvent hardware
  detection. GPU clique labels (NVLink domains) come from NVIDIA GFD the same
  way.
- **Slurm `topology.conf` + Kueue Topology CRs** — decades of HPC prior art
  for §4's fabrics (switch hierarchies, blocks/racks); Kueue's
  topology-aware scheduling levels are the K8s-native rendering target.
- **Cluster API `ClusterClass`** — preset composition with typed variables;
  the closest existing thing to "target preset as data".
- **DRA (`ResourceSlice`/`DeviceClass`)** — the emerging upstream device
  vocabulary; align node device facts with it rather than inventing names.

**Distribution — mineable datasets:**

- **`cncf/k8s-conformance`** — per-version `PRODUCT.yaml` for 90+ certified
  distros/platforms: the ground-truth corpus for how many targets exist and
  their self-described type (distribution / hosted / installer). Sibling
  **`cncf/k8s-ai-conformance`** is a capability profile for AI clusters —
  a direct checklist against §4's GPU/fabric axioms.
- **kubesearch.dev (k8s-at-home-search)** — indexes Flux HelmReleases across
  hundreds of public home-ops repos: real frequency data for which role
  providers people actually run (storage, ingress, dns, enforcer, backup) —
  exactly the demand-test input for vocabulary admission and for the OSS-core
  preset set.
- **Cloud instance catalogs** (AWS/GCP/Azure APIs) — machine facts incl.
  network bandwidth and RDMA-capable types (EFA, etc.); the axiom values for
  hosted presets are downloadable, not guessable.
- **Own probe as dataset generator** — every cluster kix can reach (ludo,
  nw1, satchel GKE) probes into a target file; the corpus grows with
  adoption and keeps the schema honest (unprobeable axiom = smell).

Method: copy schemas first; rank vocabulary by corpus frequency; build probe
early because it is both the adoption feature and the data pipeline.

## 10. Open questions

**Resolved 2026-07-05 (shipped as steps 1–2+4, branch `v2/127-role-registry`):**
packages claim roles with `meta.roles`, validated against a closed registry
(`kix/lib/eval/roles.nix`: network-policy-enforcer, dns, storageClasses, cni,
loadBalancer) with shallow out-contracts; the role name doubles as the DI
alias; `meta.provides` survives as scorecard-only vocabulary. Binding modes
live in `cluster.roles.<role>.binding` (absent/shadowable/exclusive), declared
by target presets only — managed instances are strong by nature; exclusive +
managed claimant throws eagerly. Substrate capabilities went three-valued
(null defaults; false = gate error, null = warning). The role-backed bools
are deleted (they had zero compiler consumers). Still open below: substrate
vocabulary (§4), probe (§5), and the remaining questions.

- **Naming:** keep everything under `cluster.*` (packages already read
  `clusterConfig.cluster.*`; zero churn) or introduce `cluster.substrate.*`
  for the new vocabulary while leaving existing options in place? Leaning
  substrate-subtree for new words, no renames of existing ones.
- **Unknown-severity default:** is relying-on-unknown a warning or
  configurable per axiom? (Rides doc 80 diagnostics.)
- **The cni fate, sharpened by binding modes:** the enum axiom dies, but the
  *binding mode* for the role is the axiom that survives — stock kind declares
  cni `exclusive` (kindnet), the no-default-CNI kind variant declares it
  `absent`, EKS declares aws-vpc-cni `exclusive` (or `shadowable`? probably
  exclusive), bare metal declares `absent`. Which other roles are ever
  `exclusive` — openshift's router? managed control-plane admission? — and is
  the mode declared per role generally or only where a flavor opts in?
- **Probe fidelity:** which axioms are probeable (zones, GPUs via node labels,
  PSA via ns labels — yes; RDMA — only if node labels/device plugins expose
  it; UPS — never). Unprobeable axioms stay hand-declared; is that split
  marked in the schema?
- **Who owns node facts** once doc 26 node images land — the target declares
  them or the node module derives them? (The boundary-moves-down story says:
  derived, eventually.)
- Does `meta.requires.substrate` sugar clear the demand test, or do raw
  `meta.assertions` against `clusterConfig` suffice indefinitely?
