# 155: Platform versions and compatibility

**Status:** RFC / Draft
**Related:** `127_compiler_target_model.md` (targets, three-valued facts, `kix target probe`), `139_external_inputs_and_resolutions.md` (the resolution test), `146_crd_vendoring_and_upgrades.md` (vendoring upstream data), `140_catalogue_versions_and_upgrade_windows.md` (when a cluster moves), `111_operator_experience.md` (version delta in the plan)

---

## 1. Problem

A Kubernetes distribution installs components for you: the API server, a
CNI, CoreDNS, sometimes an ingress controller, a CSI driver, a metrics
server. Their versions decide which packages work. Kix has no truthful value
for any of them, so it cannot refuse a cluster definition that will break.

The case that prompted this doc is a production RKE2 cluster that moved to
Kubernetes 1.33 while the StackGres operator was at 1.11, whose chart
declares `kubeVersion: 1.18.0-0 - 1.30.x-0`. Two upstream rules then closed
every way forward:

1. **Kubernetes range.** Operators 1.11 to 1.16 bundle fabric8 6.x, which
   rejects the `emulationMajor` field Kubernetes 1.33 returns from
   `/version`. Each of them crash-loops on startup. The supported path
   (1.11, 1.13, 1.15, 1.17) had no runnable intermediate step.
2. **Upgrade hops.** An operator refuses to start when any SGCluster carries
   a `stackgres.io/operatorVersion` annotation older than its `OLDEST`
   constant, which is two minors back (`CrdInstaller.checkUpgrade`). Jumping
   from 1.11 to 1.17 directly was refused too.

The way out was a forced upgrade with annotations patched by hand, webhooks
set to `Ignore`, and a 14 minute outage on one database. The mistake happened
two Kubernetes minors earlier, when RKE2 moved past 1.30. Nothing checked it
at that point.

The monorepo now carries a comment in `flake.nix` warning that StackGres
must be bumped before RKE2. This doc is about turning that comment into a
build failure, and about the general shape behind it: packages that depend on
the versions of platform components.

## 2. What Kix has today

Most of the mechanism exists. None of it is connected.

- `checkMetaStatic` in `kix/lib/meta.nix` checks `meta.k8s.minVersion` and
  `meta.k8s.maxVersion` against the cluster option `k8sVersion`
  (`kix/lib/modules.nix`). Ten packages declare a minimum. None declare a
  maximum. No cluster sets `k8sVersion`, and when it is null the check
  returns no assertions, so every package passes.
- `meta.compatibleWith.<dep>` checks a dependency's version against a
  range, reading `dep._meta.version or dep.out.version`. One package uses it
  (immich, against its database).
- Platform components reach packages as DI symbols. CoreDNS is a
  `kix.mkImport` filling the `dns` role in every flavor. Cilium on RKE2 is
  `cilium-rke2` or `cilium-external`. Their versions are placeholder
  strings: `"rke2-bundled"`, `"external"`, `"lithus-flavor"`. A
  `compatibleWith` constraint against one of them compares a version range
  with the word `external`.
- `stackgres-operator` declares `meta.version = "1.19.0"` as a literal,
  while `operator.image.tag` is an option. An instance that overrides the tag
  runs a different operator from the one its meta describes.
- The monorepo already holds the input. `lithus.kubernetes.rke2Version`
  selects a minor per cluster (`platform/nix/lib/rke2-version-module.nix`),
  and `config.services.rke2.package.version` gives the exact release
  (`platform/nix/modules/lithus-deploy.nix`). Kix never sees either.

## 3. Upstream data

### 3.1 StackGres

The prerequisites page only describes the current release. The full matrix
is the Helm repository index
(`https://stackgres.io/downloads/stackgres-k8s/stackgres/helm/index.yaml`),
where every chart release carries a `kubeVersion` range:

| StackGres | Kubernetes |
|---|---|
| 1.11, 1.12 | 1.18 to 1.30 |
| 1.13, 1.14 | 1.18 to 1.31 |
| 1.15, 1.16 | 1.18 to 1.32 |
| 1.17.0 to 1.17.3 | 1.18 to 1.33 |
| 1.17.4 to 1.18.2 | 1.18 to 1.34 |
| 1.18.3 to 1.18.9 | 1.18 to 1.35 |
| 1.19.0 | 1.25 to 1.36 |
| 1.19.1, 1.19.2 | 1.25 to 1.37 |

Three things follow. The range moves within a minor, so the table is keyed by
full version. The floor moved in 1.19, so a cluster can be stranded from
below as well as above. And the data is not clean: 1.18.9 publishes
`1.35.x-O`, with a letter O.

The two-minor hop limit is not published in any machine-readable form. The
OperatorHub CSVs carry `minKubeVersion` and no `skipRange`. The source of
truth is `StackGresVersion.OLDEST` in the operator.

### 3.2 RKE2

- An RKE2 minor is a Kubernetes minor (`v1.34.5+rke2r1` is Kubernetes
  1.34.5).
- `docs/upgrades/manual.md` in `rancher/rke2-docs`: servers upgrade first,
  one at a time; the Kubernetes version skew policy applies, minors must not
  be skipped, and "nothing in the upgrade process will protect against
  unsupported changes to the Kubernetes version".
- Rolling back a minor needs an etcd snapshot taken on that minor.
- Every tag of `rancher/rke2` has `charts/chart_versions.yaml`, listing the
  bundled charts. Two releases of the same minor:

  | Chart | v1.34.1+rke2r1 | v1.34.5+rke2r1 |
  |---|---|---|
  | rke2-cilium | 1.18.103 | 1.19.100 |
  | rke2-canal | v3.30.3 | v3.31.3 |
  | rke2-coredns | 1.43.302 | 1.45.201 |
  | rke2-ingress-nginx | 4.12.600 | 4.14.303 |
  | rke2-traefik | 34.2.002 | 39.0.002 |

  A patch release can move Cilium a minor. The monorepo's `"1.34"` follows a
  shared nixpkgs pin, so a nixpkgs bump can do exactly that, and Kix does not
  see it. These are chart versions. `rke2-cilium` tracks the Cilium version;
  `rke2-coredns` tracks the upstream CoreDNS chart, so the CoreDNS version
  itself has to come from the chart's `appVersion` in `rancher/rke2-charts`.
- SUSE publishes lifecycle dates per minor; the release channel server
  (`https://update.rke2.io/v1-release/channels`) lists the latest patch per
  minor.

### 3.3 The other flavors

Researched 2026-10-01 from the upstream files, APIs, and docs named in each
row.

| Flavor | Release names | Per-release component record | Who moves the version | Minor skip refused by |
|---|---|---|---|---|
| rke2, lithus | `v1.34.5+rke2r1` | `charts/chart_versions.yaml` per tag | operator | nothing ("nothing in the upgrade process will protect") |
| k3s | `v1.34.12+k3s1` | per tag: `scripts/airgap/image-list.txt` (images), `manifests/traefik.yaml` (chart), `go.mod` (flannel, kube-router, containerd, etcd) | operator | nothing |
| talos | Talos `v1.14.2` **and** a Kubernetes version | `pkg/machinery/constants/constants.go` per tag; allowed Kubernetes range in `pkg/machinery/compatibility/talos1NN` | operator | `talosctl upgrade-k8s` (same or next minor only) |
| kubeadm | Kubernetes `v1.37.0` | `cmd/kubeadm/app/constants/constants.go` (CoreDNS, etcd, pause); `build/dependencies.yaml` | operator | `kubeadm upgrade` (`policy.go`, one minor) |
| kind | kind `v0.33.0` plus node image digest | `pkg/build/nodeimage/const_cni.go`, `const_storage.go`; CoreDNS from the kubeadm constants | operator; no in-place upgrade | n/a, clusters are recreated |
| openshift | OCP `4.20.39` (Kubernetes 1.33.13) | `release.txt` names the Kubernetes version only; every other component is a digest | operator, along the update graph | the cluster-version operator's graph |
| eks | minor plus `eks.N` | `aws eks describe-addon-versions` (default add-on per minor) | provider: patch always, minor at end of extended support | the EKS API |
| gke, gke-autopilot | `1.34.11-gke.1209000` | changelog HTML with Google build numbers; Dataplane V2's Cilium version is not published | provider: channels, exclusions at most until end of support | the GKE API |
| aks | Kubernetes patch | docs table per minor, and a minimum Cilium per minor | provider: components weekly, minor when it falls to N-3 | the AKS API |
| ovh | minor | one prose table per minor, contradicted by another docs page | provider: patch and components; minor forced past end of support | the OVH API |
| scaleway | full version | release changelog prose, missing for 1.36 and 1.37; API has dates, no components | provider: components at any time; minor 30 days after end of support | the Scaleway API |

What the survey shows:

- **Self-hosted distributions publish their components per release, in a
  form a script can read.** RKE2, k3s, Talos, kubeadm, and kind all pin
  component versions in files at the release tag. OpenShift is the
  exception: its payload names Kubernetes and leaves the rest as digests.
- **Managed providers do not.** Only EKS has an API mapping a cluster version
  to component versions, and only for EKS add-ons, which the operator can
  also pin. GKE, AKS, OVH, and Scaleway change components without a commit
  and, except AKS's Cilium table, publish them as prose or not at all.
- **Within a minor, managed component versions only move forward.** A probed
  value is therefore a floor, not a value. AKS publishes its floors per
  minor.
- **The distributions that need a transition check least have one.** kubeadm,
  Talos, OpenShift, and every managed API refuse a skipped minor. RKE2 and
  k3s, the two Kix runs on, refuse nothing.
- **Talos has two release inputs.** The Talos version and the Kubernetes
  version are chosen separately, and Talos publishes which pairs are allowed.
  CoreDNS and flannel arrive with `talosctl upgrade-k8s`, not with the OS
  upgrade, and the machine configuration can override the CoreDNS image.
- **End-of-support dates are machine-readable in some places:**
  `kubernetes/website` `data/releases/schedule.yaml`,
  `https://endoflife.date/api/` (Kubernetes, EKS, OpenShift; not k3s, kind,
  or Talos), `aws eks describe-cluster-versions`, the Red Hat lifecycle API,
  and Scaleway's `deprecated_at` and `end_of_life_at`. SUSE, AKS, and OVH
  publish HTML.
- **Version strings are not uniform.** `v` prefixes come and go (Talos
  1.14.2 dropped them), and suffixes carry build numbers (`+rke2r1`,
  `+k3s1`, `-eksbuild.24`, `-gke.1209000`, chart build digits). Vendored
  data is normalised once, at vendoring time.

## 4. Principles

These are the constraints a design has to meet. Each comes from an existing
Kix rule.

1. **A package depends on a component, never on a distribution.** A package
   that cares about Cilium asks its Cilium dependency for a version. It never
   reads the RKE2 release. This is the rule `cluster.provider` already
   states: nothing may branch on the vendor field.
2. **One input, derived facts.** The cluster names one thing, the
   distribution release. The target preset derives the Kubernetes version
   and every bundled component version from it. Nobody types 1.34 in two
   places.
3. **Upstream data is vendored, not retyped.** StackGres ranges come from the
   Helm index, RKE2 component versions from `chart_versions.yaml`, kept
   current by a `--check` in CI the way doc 146 keeps CRDs current.
4. **Unknown warns, false fails.** Doc 127's three-valued rule. A package
   with a Kubernetes range on a cluster with no `k8sVersion` gets a warning
   naming the option to set. Today it passes silently.
5. **The build never reads the live cluster.** Where a version can change
   underneath the repository, a probe writes it into a source file and a
   check verifies it. The build reads the file. This is doc 127 §5's "probe
   generates source" and doc 139's resolution envelope.
6. **Fix Kix, not the package.** Placeholder versions, the static
   `meta.version`, and the silent null are Kix defects. A package should not
   work around them.

## 5. Design

### 5.1 Three kinds of target

The survey sorts flavors by two questions: does a commit decide the version,
and does upstream publish the components per release.

**Declared, with a component record:** RKE2 and lithus, k3s, Talos, kubeadm,
kind. The operator chooses the release in the repository and nothing changes
it without a commit. The release is an input, written in the cluster
definition or taken from the NixOS configuration in the same flake, and every
component version is derived from vendored release data (§5.2). Talos takes
two inputs and checks the pair against its compatibility range.

**Declared, components unknown:** OpenShift. The release is an input and
fixes the Kubernetes version. Component versions stay null. A package that
constrains one warns, as principle 4 requires, and the operator may declare
a version they have checked.

**Resolved:** EKS, GKE, GKE Autopilot, AKS, OVH, Scaleway. The provider can
change the patch and the components without a commit, and changes the minor
at end of support. Doc 139's test applies: the source can answer differently
tomorrow, and that changes what works without anybody noticing.

- The operator declares the minor, because they choose it until end of
  support, and every provider refuses a skipped minor.
- Component versions and the patch come from a probed target file with doc
  139's envelope (`resolvedAt`, source), written by `kix target probe`. The
  build reads the file and stays pure. A check verb compares the file with
  the cluster.
- A probed version is a **floor**. Within a minor the provider only moves
  forward, so "Cilium 1.17.18 or newer" can be checked against it and holds
  until the next probe. A maximum cannot be: the warning says the provider
  can move past it without a commit. Where the provider publishes floors
  per minor (AKS for Cilium), the vendored floor stands in until the first
  probe.
- EKS add-ons are the exception. The operator pins them, so they are
  declared, and `describe-addon-versions` is vendorable data.

### 5.2 The release is a flavor input

Each flavor that can know its components declares one option for the
release, and derives everything else from a vendored table:

```nix
# kix/lib/flavors/rke2.nix
options.rke2.release = lib.mkOption {
  type = lib.types.nullOr lib.types.str;   # "v1.34.5+rke2r1"
  default = null;
};

config = let r = releases.${cfg.rke2.release} or (throw "..."); in {
  k8sVersion = r.kubernetes;               # "1.34.5"
  instances.kube-system.platform-dns.package = kix.mkImport {
    roles = [ "dns" ];
    out = { name = "coredns"; version = r.components.coredns; ... };
  };
};
```

- `releases` is `kix/lib/flavors/rke2/releases.json`, vendored from
  `chart_versions.yaml` per tag plus `appVersion` from `rancher/rke2-charts`.
- An unregistered release fails evaluation and names the vendoring command,
  as `rke2-version-module.nix` does for an unregistered minor today.
- A null release leaves every derived fact null, so consumers warn.
- In the monorepo, the lithus cluster sets
  `rke2.release = config.services.rke2.package.version` from the node
  configuration. Bumping RKE2 then rebuilds the Kix cluster in the same
  `nix flake check`.

Packages do not read `rke2.release`. They read `k8sVersion` (a substrate
fact every package depends on implicitly) and `out.version` on the
dependencies they declare. Whether this is enforced, or a convention, is open
(§8).

### 5.3 Components carry real versions

`out.version` on a role provider or import is a version string or null.
Placeholder words go. A package Kix deploys (`cilium` on kind or k3s) reports
its own version. A component the environment installs reports the version the
target preset derived. `cilium-external` takes a `version` option, null by
default, for the case where the operator knows the version and Kix cannot
derive it.

`meta.version` becomes the effective version. For an operator package whose
version is an image tag option, the tag is the version, and the package's
constraints are looked up by it.

### 5.4 Package constraints come from upstream

A package whose upstream publishes a Kubernetes range gets it from vendored
data keyed by its effective version:

```nix
# kix/packages/stackgres-operator/default.nix
meta.k8s = kubeVersions.${config.operator.image.tag}
  or (throw "stackgres-operator ${tag} is not in upstream/kube-versions.json; run the vendoring script");
```

`upstream/kube-versions.json` holds the Helm `kubeVersion` per release,
normalised into `{ minVersion; maxVersion; }`. A package may narrow a range
with a reason when field experience disagrees with upstream, and the reason
appears in the error.

Constraints between packages use `out.version` of the dependency, through
`compatibleWith` today and the `deps.<dep>.version` form ROADMAP already
plans. Where several consumers would encode the same version rule ("Cilium
1.15 or newer supports `enableDefaultDeny`"), the provider exposes the
feature on `out` instead and owns the version-to-feature mapping once. Doc
127 already moves sub-facts like this onto the provider.

### 5.5 Transition rules compare two builds

Some rules are about moving from one state to the next:

- StackGres moves at most two minors per step.
- Kubernetes moves one minor per step, on every declared target.
- The Kubernetes version and a package that constrains it do not move in the
  same step, because the distribution and `kix deploy` are separate
  actuators with nothing ordering them. While RKE2 rolls, servers run both
  minors, so a package has to support both.

A single build cannot check these. `kix diff` and the deploy plan already
compare an old build with a new one and report version changes per package
(doc 111). Transition rules run there, against the old build's recorded
versions, never against the live cluster. In CI that is the base branch
against the pull request.

A package declares its hop limit next to the range it constrains. Nothing
upstream publishes StackGres's limit, so the package states it and cites
`StackGresVersion.OLDEST` as the source.

### 5.6 Lookahead

The build can also say how much room is left:

- **Ceiling.** "Kubernetes 1.36 is the newest version stackgres-operator
  1.19.0 supports. Bump the operator before the next minor." A warning, so
  the order is visible before the distribution moves.
- **Forced upgrades.** On a resolved target the provider's end-of-support
  date is a scheduled transition. If a package does not support the next
  minor, the warning names the date the provider will move the cluster.

## 6. Worked examples

**The StackGres lock, replayed.** Cluster on RKE2 1.30 with StackGres 1.11. A commit
bumps `rke2Version` to 1.31. The Kix cluster in the same flake now derives
`k8sVersion = "1.31.x"`, and `stackgres-operator` 1.11.0 has
`maxVersion = "1.30"`: evaluation fails, naming both. The operator bumps
StackGres to 1.13 first (two minors, supports 1.30 and 1.31), deploys, then
bumps RKE2. Before that, at 1.30, the ceiling warning had already said that
1.30 was the last version 1.11 supports.

**A nixpkgs bump moves Cilium.** lab1 follows the shared `"1.34"` pin. A
nixpkgs bump takes RKE2 from 1.34.1 to 1.34.5. The derived Cilium version
moves from 1.18 to 1.19, the diff shows a version change on the CNI provider,
and `cilium-rke2`, which writes values for the bundled chart, can refuse a
values key the new chart does not accept.

**A managed cluster moves underneath the repository.** A GKE cluster on the
Regular channel at 1.34, with a "no minor upgrades" exclusion. Its probed
target file says Kubernetes 1.34.11 and the end of standard support, 25
January 2027, from the cluster's upgrade info. A package declares a maximum
of 1.34. The build passes with a warning: "GKE will move this cluster to
1.35 after 25 January 2027; stackgres-operator 1.18.2 supports up to 1.34."
Nothing in the repository changes on that date, so the warning is the only
place the deadline appears before the cluster moves. The probe after the
upgrade records 1.35, and the next build fails until the operator is bumped,
by which point the cluster already runs a version the operator does not
support. On a resolved target the warning is what prevents the jam.

## 7. Alternatives considered

- **Read versions from the cluster at build time.** Rejected by principle 5.
  The build would depend on network state, and a wrong answer decides what
  runs.
- **Constraints keyed by distribution** (`meta.k8s.rke2 = ...`). Rejected by
  principle 1. A package would need a branch for every flavor, and would be
  wrong on the ones it forgot.
- **Ranges typed into each package.** Works on day one and goes stale on the
  first version bump. The StackGres table changes every few patch releases.
- **The API server as an import with `out.version`.** Uniform with other
  components, but every package depends on the API server, so every package
  would declare the same dependency. `k8sVersion` stays a cluster fact,
  derived by the same flavor input.
- **Helm's `kubeVersion` string as the Kix meta format.** It is the upstream
  vocabulary, but Kix would need a semver range parser in Nix and would carry
  upstream typos into evaluation. The vendoring script normalises it once;
  meta keeps the min/max form it already checks.

## 8. Open questions

1. **Does the StackGres hop count operator versions or annotation
   versions?** The check reads `stackgres.io/operatorVersion` on each
   SGCluster. If only an SGDbOps `securityUpgrade` moves that annotation, two
   consecutive hops need a security upgrade in between, and the transition
   rule has to know it.
2. **Enforcing principle 1.** Should `rke2.release` be invisible to
   packages (not in `clusterConfig`), or is a convention enough?
3. **One vendoring script or two?** CRDs, Helm `kubeVersion` ranges, and
   distribution release tables are all upstream facts pinned per version.
   Extending `scripts/vendor-crds.py` keeps one `--check` job; a sibling
   script keeps each small.
4. **Where transition rules are declared.** A package-level
   `meta.upgrade` (hop limit, required intermediate versions) versus a
   general rule hook that receives the old and new builds.
5. **Severity of the ceiling warning.** Always on, or only when the target's
   release is within some distance of end of support.
6. **Talos component versions.** CoreDNS and flannel are applied by
   `talosctl upgrade-k8s`, using that `talosctl`'s constants, unless the
   machine configuration overrides the image. Is the Talos version the right
   key, or does the preset need the machine configuration's images?
7. **Probe cadence on resolved targets.** A floor is only as fresh as the
   last probe. Is `kix target probe` run by CI on a schedule, by every
   deploy, or by the operator, and how old may a probe be before the build
   warns?
8. **End-of-support data.** Vendor dates per flavor from the sources in
   §3.3, or read them from the probe where the provider exposes them per
   cluster (GKE, EKS)? SUSE, AKS, and OVH publish HTML only.
9. **Kubernetes API removals.** Once `k8sVersion` is reliable, every emitted
   `apiVersion` can be checked against the Kubernetes removal schedule
   (doc 127 §2 lists this as a data pass). Same input, separate doc.
